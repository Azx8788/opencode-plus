import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_provider.dart';
import 'package:opencode_mobile/channels/channel_tasks.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  group('the state machine', () {
    test('a finished task cannot start running again', () {
      final record = _record();

      expect(ChannelTaskMachine.move(record, ChannelTaskStatus.running), isTrue);
      expect(
        ChannelTaskMachine.move(record, ChannelTaskStatus.completed),
        isTrue,
      );
      expect(ChannelTaskMachine.move(record, ChannelTaskStatus.running), isFalse);
      expect(record.status, ChannelTaskStatus.completed);
    });

    test('a cancelled task stays cancelled', () {
      final record = _record();
      expect(
        ChannelTaskMachine.move(record, ChannelTaskStatus.cancelled),
        isTrue,
      );
      expect(
        ChannelTaskMachine.move(record, ChannelTaskStatus.completed),
        isFalse,
      );
    });

    test('delivery is a separate fact from the agent finishing', () {
      final record = _record()
        ..status = ChannelTaskStatus.completed
        ..result = '做完了'
        ..delivery = ChannelDeliveryStatus.failed;

      expect(record.answeredButUndelivered, isTrue);
      record.delivery = ChannelDeliveryStatus.delivered;
      expect(record.answeredButUndelivered, isFalse);
    });
  });

  group('the store', () {
    test('survives a restart', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ChannelTaskStore(preferences: preferences);

      store.record(_record(id: 't1', prompt: '跑测试'));
      store.update('t1', status: ChannelTaskStatus.running);
      await store.settle();

      final reopened = ChannelTaskStore(preferences: preferences);
      final record = reopened.recent().single;

      expect(record.id, 't1');
      expect(record.prompt, '跑测试');
      expect(record.status, ChannelTaskStatus.running);
    });

    test('a refused move is not written', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ChannelTaskStore(preferences: preferences);

      store.record(_record(id: 't1'));
      store.update('t1', status: ChannelTaskStatus.cancelled);
      store.update('t1', status: ChannelTaskStatus.completed);
      await store.settle();

      expect(store.recent().single.status, ChannelTaskStatus.cancelled);
    });

    test('keeps a bounded window and drops finished tasks first', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ChannelTaskStore(preferences: preferences, capacity: 3);

      for (var i = 0; i < 5; i++) {
        store.record(_record(id: 't$i'));
      }
      store.update('t0', status: ChannelTaskStatus.cancelled);
      await store.settle();

      final ids = store.recent().map((record) => record.id).toList();
      expect(ids, hasLength(3));
      expect(ids, isNot(contains('t0')));
    });
  });

  group('the engine records what happened', () {
    test('a finished task carries its answer and its delivery', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ChannelTaskStore(preferences: preferences);
      final harness = await EngineHarness.start(
        singleConversation: true,
        ledger: store,
      );
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('跑测试', id: 'in-1'));
      await waitFor(() => harness.agent.prompts.length == 1);
      harness.engine.handleAgentEvent(_status('busy'));

      harness.agent
        ..reply = '测试通过'
        ..replyId = 'm-1';
      harness.engine.handleAgentEvent(_messageDone('m-1'));
      harness.engine.handleAgentEvent(_status('idle'));
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text == '测试通过',
        ),
      );
      await store.settle();

      final record = store.recent().single;
      expect(record.status, ChannelTaskStatus.completed);
      expect(record.result, '测试通过');
      expect(record.delivery, ChannelDeliveryStatus.delivered);
      expect(record.sessionId, 'ses-1');
      expect(record.answeredButUndelivered, isFalse);
    });

    test('a stopped task is recorded as cancelled, not completed', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ChannelTaskStore(preferences: preferences);
      final harness = await EngineHarness.start(
        singleConversation: true,
        ledger: store,
      );
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('跑测试', id: 'in-1'));
      await waitFor(() => harness.agent.prompts.length == 1);
      harness.engine.handleAgentEvent(_status('busy'));
      harness.provider.deliver(directMessage('/stop', id: 'in-2'));
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text.contains('已请求停止'),
        ),
      );

      harness.agent
        ..reply = '迟到的结果'
        ..replyId = 'm-1';
      harness.engine.handleAgentEvent(_messageDone('m-1'));
      harness.engine.handleAgentEvent(_status('idle'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await store.settle();

      final record = store.recent().single;
      expect(record.status, ChannelTaskStatus.cancelled);
      expect(record.result, isNull);
    });

    test('a send the platform refused is visible on the task', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ChannelTaskStore(preferences: preferences);
      final harness = await EngineHarness.start(
        singleConversation: true,
        ledger: store,
      );
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('跑测试', id: 'in-1'));
      await waitFor(() => harness.agent.prompts.length == 1);
      harness.engine.handleAgentEvent(_status('busy'));

      // The platform refuses the final answer.
      harness.provider.receipt = DeliveryReceipt.failed('平台拒绝', retryable: false);
      harness.agent
        ..reply = '测试通过'
        ..replyId = 'm-1';
      harness.engine.handleAgentEvent(_messageDone('m-1'));
      harness.engine.handleAgentEvent(_status('idle'));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await store.settle();

      final record = store.recent().single;
      expect(record.status, ChannelTaskStatus.completed);
      expect(record.delivery, ChannelDeliveryStatus.failed);
      expect(record.answeredButUndelivered, isTrue);
    });
  });
}

ChannelTaskRecord _record({String id = 't1', String prompt = '做点事'}) =>
    ChannelTaskRecord(
      id: id,
      providerId: 'fake',
      accountId: 'bot-1',
      conversationId: 'dm-1',
      userId: 'u1',
      prompt: prompt,
      createdAt: DateTime(2026, 11, 26, 12),
    );

EventEnvelope _status(String type, {String session = 'ses-1'}) => EventEnvelope(
  type: 'session.status',
  properties: {
    'sessionID': session,
    'status': {'type': type},
  },
);

EventEnvelope _messageDone(String id, {String session = 'ses-1'}) =>
    EventEnvelope(
      type: 'message.updated',
      properties: {
        'sessionID': session,
        'info': {
          'id': id,
          'role': 'assistant',
          'time': {'created': 1, 'completed': 2},
        },
      },
    );
