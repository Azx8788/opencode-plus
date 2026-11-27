import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';

import 'fakes.dart';

/// A turn's answer must reach the chat exactly once, whatever the next turn
/// does. These tests pin the timing that used to lose it.
void main() {
  group('a turn that ends as the next one starts', () {
    // The old code decided delivery in two callbacks that both read
    // `runtime.running`: one fired at 350 ms and returned when the flag was
    // false, the other at 500 ms and returned when it was true. A queued
    // prompt starting the next turn between them satisfied both conditions and
    // the answer was dropped. The delays below bracket that window.
    for (final delay in [10, 200, 350, 400, 480, 500, 700]) {
      test(
        'answers once when the next turn starts $delay ms after idle',
        () async {
          final harness = await EngineHarness.start(singleConversation: true);
          addTearDown(harness.stop);

          harness.provider.deliver(directMessage('跑测试', id: 'in-1'));
          await waitFor(() => harness.agent.prompts.length == 1);
          harness.engine.handleAgentEvent(_status('busy'));
          await waitFor(
            () => harness.provider.sent.any(
              (message) => message.text.contains('已开始处理任务'),
            ),
          );

          // The person adds a correction; it joins the running turn.
          harness.provider.deliver(directMessage('再加个日志', id: 'in-2'));
          await waitFor(() => harness.agent.prompts.length == 2);

          // The turn ends, but the server has not finished writing the answer.
          harness.agent.reply = null;
          harness.engine.handleAgentEvent(_messageDone('m-1'));
          harness.engine.handleAgentEvent(_status('idle'));

          // The queued correction starts the next turn.
          await Future<void>.delayed(Duration(milliseconds: delay));
          harness.engine.handleAgentEvent(_status('busy'));

          // The first answer lands after the next turn has already started.
          harness.agent
            ..reply = '第一轮结果'
            ..replyId = 'm-1';
          await waitFor(
            () =>
                harness.provider.sent.any((message) => message.text == '第一轮结果'),
            reason: 'the first answer at $delay ms',
          );

          // The second turn answers with its own message.
          harness.agent
            ..reply = '第二轮结果'
            ..replyId = 'm-2';
          harness.engine.handleAgentEvent(_messageDone('m-2'));
          harness.engine.handleAgentEvent(_status('idle'));
          await waitFor(
            () =>
                harness.provider.sent.any((message) => message.text == '第二轮结果'),
            reason: 'the second answer at $delay ms',
          );

          final texts = harness.provider.sent.map((m) => m.text).toList();
          expect(
            texts.where((text) => text == '第一轮结果'),
            hasLength(1),
            reason: 'delivered once at $delay ms: $texts',
          );
          expect(
            texts.where((text) => text == '第二轮结果'),
            hasLength(1),
            reason: 'delivered once at $delay ms: $texts',
          );
          expect(
            texts.any((text) => text.startsWith('Agent 更新')),
            isFalse,
            reason:
                'a final answer must not be labelled a progress update: $texts',
          );
          expect(
            texts.any((text) => text.contains('没有可显示的文字回复')),
            isFalse,
            reason:
                'an answer existed, so the fallback must not be used: $texts',
          );
        },
      );
    }

    test(
      'a message that a tool follows is an update, and is not repeated',
      () async {
        final harness = await EngineHarness.start(singleConversation: true);
        addTearDown(harness.stop);

        harness.provider.deliver(directMessage('改代码', id: 'in-1'));
        await waitFor(() => harness.agent.prompts.length == 1);
        harness.engine.handleAgentEvent(_status('busy'));

        harness.agent
          ..reply = '先读一下文件'
          ..replyId = 'm-1';
        harness.engine.handleAgentEvent(_messageDone('m-1'));
        harness.engine.handleAgentEvent(_tool('read'));

        await waitFor(
          () => harness.provider.sent.any(
            (message) => message.text.contains('先读一下文件'),
          ),
        );
        final update = harness.provider.sent.firstWhere(
          (message) => message.text.contains('先读一下文件'),
        );
        expect(update.text, startsWith('Agent 更新'));

        // The session goes idle on the same message: it is already delivered.
        harness.engine.handleAgentEvent(_status('idle'));
        await Future<void>.delayed(const Duration(milliseconds: 600));

        expect(
          harness.provider.sent
              .where((message) => message.text.contains('先读一下文件'))
              .length,
          1,
        );
      },
    );

    test('stop cancels the turn, so a late answer is not delivered', () async {
      final harness = await EngineHarness.start(singleConversation: true);
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
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(
        harness.provider.sent.any((message) => message.text == '迟到的结果'),
        isFalse,
        reason: 'a cancelled turn must not speak',
      );
    });

    test('a correction is acknowledged differently from a new task', () async {
      final harness = await EngineHarness.start(singleConversation: true);
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('跑测试', id: 'in-1'));
      await waitFor(() => harness.provider.sent.isNotEmpty);
      expect(harness.provider.sent.last.text, contains('已转发给本地 Agent'));

      harness.engine.handleAgentEvent(_status('busy'));
      harness.provider.deliver(directMessage('再加个日志', id: 'in-2'));
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text.contains('已并入当前任务'),
        ),
      );

      expect(
        harness.provider.sent
            .where((message) => message.text.contains('已转发给本地 Agent'))
            .length,
        1,
      );
    });

    test(
      'running is true when any conversation runs, not the first one',
      () async {
        final harness = await EngineHarness.start();
        addTearDown(harness.stop);

        var sessions = 0;
        harness.agent.sessionFor = (_) => 'ses-${++sessions}';

        harness.provider.deliver(directMessage('甲的任务', sender: 'u1', id: 'a1'));
        await waitFor(() => harness.agent.prompts.length == 1);
        harness.agent
          ..reply = '甲的答案'
          ..replyId = 'm-1';
        harness.engine.handleAgentEvent(_status('busy'));
        harness.engine.handleAgentEvent(_messageDone('m-1'));
        harness.engine.handleAgentEvent(_status('idle'));
        await waitFor(() => !harness.engine.isRunning);

        // The first conversation is idle; the second one is executing. Reading
        // one arbitrary runtime would report the first and answer false.
        harness.provider.deliver(
          directMessage('乙的任务', sender: 'u2', conversation: 'dm-2', id: 'b1'),
        );
        await waitFor(() => harness.agent.prompts.length == 2);
        harness.engine.handleAgentEvent(_status('busy', session: 'ses-2'));

        expect(harness.engine.isRunning, isTrue);

        harness.agent
          ..reply = '乙的答案'
          ..replyId = 'm-2';
        harness.engine.handleAgentEvent(_messageDone('m-2', session: 'ses-2'));
        harness.engine.handleAgentEvent(_status('idle', session: 'ses-2'));
        await waitFor(() => !harness.engine.isRunning);
      },
    );
  });
}

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

EventEnvelope _tool(String name, {String session = 'ses-1'}) => EventEnvelope(
  type: 'message.part.updated',
  properties: {
    'sessionID': session,
    'part': {
      'type': 'tool',
      'tool': name,
      'state': {'status': 'running'},
    },
  },
);
