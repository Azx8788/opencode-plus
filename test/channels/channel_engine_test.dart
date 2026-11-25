import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_identity.dart';
import 'package:opencode_mobile/channels/channel_inbox.dart';
import 'package:opencode_mobile/channels/channel_message.dart';
import 'package:opencode_mobile/channels/channel_outbox.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  group('inbound routing', () {
    test('a direct message becomes a prompt and an ack', () async {
      final harness = await EngineHarness.start(singleConversation: true);
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('列出改动的文件'));
      await waitFor(() => harness.agent.prompts.isNotEmpty);

      expect(harness.agent.prompts.single.text, '列出改动的文件');
      expect(harness.agent.prompts.single.conversation.conversationId, 'dm-1');
      await waitFor(() => harness.provider.sent.isNotEmpty);
      expect(harness.provider.sent.single.text, contains('已转发给本地 Agent'));
      expect(harness.engine.boundSessionID, 'ses-1');
    });

    test('the same message id twice runs the agent once', () async {
      final harness = await EngineHarness.start();
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('跑测试', id: 'dup-1'));
      harness.provider.deliver(directMessage('跑测试', id: 'dup-1'));
      await waitFor(() => harness.provider.sent.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(harness.agent.prompts, hasLength(1));
      expect(harness.engine.duplicateCount, 1);
    });

    test('a message without text is answered, not sent to the agent', () async {
      final harness = await EngineHarness.start();
      addTearDown(harness.stop);

      harness.provider.deliver(imageOnlyMessage());
      await waitFor(() => harness.provider.sent.isNotEmpty);

      expect(harness.agent.prompts, isEmpty);
      expect(harness.provider.sent.single.text, contains('只支持文字'));
    });

    test('an agent that is not connected is reported, not queued', () async {
      final harness = await EngineHarness.start(agentReady: false);
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('跑测试'));
      await waitFor(() => harness.provider.sent.isNotEmpty);

      expect(harness.agent.prompts, isEmpty);
      expect(harness.provider.sent.single.text, contains('未连接'));
    });

    test('a failed send never re-runs the agent', () async {
      final harness = await EngineHarness.start();
      addTearDown(harness.stop);
      harness.provider.failSends = true;

      harness.provider.deliver(directMessage('修复构建'));
      await waitFor(() => harness.agent.prompts.isNotEmpty);
      await waitFor(() => harness.provider.attempts.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(harness.agent.prompts, hasLength(1));
      final entries = await ChannelOutbox(
        preferences: harness.preferences,
      ).pendingFor('fake', 'bot-1');
      expect(
        entries.where((entry) => entry.status == OutboxStatus.failed),
        isNotEmpty,
      );
    });
  });

  group('task lifecycle', () {
    test(
      'a second message during a run is a supplement, not a new task',
      () async {
        final harness = await EngineHarness.start(singleConversation: true);
        addTearDown(harness.stop);

        harness.provider.deliver(directMessage('先跑测试', id: 'm-1'));
        await waitFor(() => harness.agent.prompts.isNotEmpty);
        harness.provider.deliver(directMessage('顺便修一下格式', id: 'm-2'));
        await waitFor(() => harness.agent.prompts.length == 2);

        expect(harness.agent.prompts.map((request) => request.text), [
          '先跑测试',
          '顺便修一下格式',
        ]);
        expect(harness.engine.currentTask?.supplements, 1);
      },
    );

    test(
      '/queue waits for the running task and then starts a new one',
      () async {
        final harness = await EngineHarness.start(singleConversation: true);
        addTearDown(harness.stop);

        harness.provider.deliver(directMessage('长任务', id: 'm-1'));
        await waitFor(() => harness.agent.prompts.isNotEmpty);
        harness.provider.deliver(directMessage('/queue 再跑一次测试', id: 'm-2'));
        await waitFor(() => harness.engine.queuedCount == 1);

        expect(harness.agent.prompts, hasLength(1));
        expect(harness.engine.queuedPrompts, ['再跑一次测试']);

        harness.engine.handleAgentEvent(
          EventEnvelope(
            type: 'session.status',
            properties: {
              'sessionID': 'ses-1',
              'status': {'type': 'idle'},
            },
          ),
        );
        await waitFor(() => harness.agent.prompts.length == 2);
        expect(harness.agent.prompts.last.text, '再跑一次测试');
        expect(harness.engine.queuedCount, 0);
      },
    );

    test('/stop interrupts through the agent port', () async {
      final harness = await EngineHarness.start(singleConversation: true);
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('长任务'));
      await waitFor(() => harness.agent.prompts.isNotEmpty);
      harness.provider.deliver(directMessage('/stop', id: 'm-2'));
      await waitFor(() => harness.agent.stopped.isNotEmpty);

      expect(harness.agent.stopped.single, 'ses-1');
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text.contains('已请求停止'),
        ),
      );
    });

    test(
      '/new drops the binding so the next message starts a session',
      () async {
        final harness = await EngineHarness.start(singleConversation: true);
        addTearDown(harness.stop);

        harness.provider.deliver(directMessage('第一件事'));
        await waitFor(() => harness.engine.boundSessionID == 'ses-1');
        harness.provider.deliver(directMessage('/new', id: 'm-2'));
        await waitFor(() => harness.engine.boundSessionID == null);

        harness.agent.nextSession = 'ses-2';
        harness.provider.deliver(directMessage('第二件事', id: 'm-3'));
        await waitFor(() => harness.engine.boundSessionID == 'ses-2');
      },
    );

    test('/status names the project, the session and the channel', () async {
      final harness = await EngineHarness.start(singleConversation: true);
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('/status'));
      await waitFor(() => harness.provider.sent.isNotEmpty);

      final status = harness.provider.sent.single.text;
      expect(status, contains('本机 OpenCode 已连接'));
      expect(status, contains('项目：demo'));
      expect(status, contains('会话：未绑定'));
      expect(status, contains('渠道：正在接收消息'));
      expect(harness.agent.prompts, isEmpty);
    });

    test('a permission request is announced but never approved', () async {
      final harness = await EngineHarness.start(singleConversation: true);
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('删掉临时文件'));
      await waitFor(() => harness.agent.prompts.isNotEmpty);
      harness.engine.handleAgentEvent(
        EventEnvelope(
          type: 'permission.asked',
          properties: {'sessionID': 'ses-1'},
        ),
      );
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text.contains('不会自动批准'),
        ),
      );
      expect(harness.engine.waitingPermission, isTrue);

      harness.provider.deliver(directMessage('/approve', id: 'm-2'));
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text.contains('不会代替你'),
        ),
      );
      expect(harness.engine.waitingPermission, isTrue);
    });
  });

  group('group policy and isolation', () {
    test('a group message must mention the bot', () async {
      final harness = await EngineHarness.start();
      addTearDown(harness.stop);

      harness.provider.deliver(groupMessage('随便聊聊', mentions: false));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(harness.agent.prompts, isEmpty);
      expect(harness.engine.lastDenial?.denial, PolicyDenial.mentionRequired);

      harness.provider.deliver(groupMessage('看一下构建', id: 'gm-2'));
      await waitFor(() => harness.agent.prompts.isNotEmpty);
      expect(harness.agent.prompts.single.text, '看一下构建');
    });

    test('a group that is not allowlisted is ignored', () async {
      final harness = await EngineHarness.start();
      addTearDown(harness.stop);

      harness.provider.deliver(groupMessage('看一下构建', group: 'g-other'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(harness.agent.prompts, isEmpty);
      expect(harness.engine.lastDenial?.denial, PolicyDenial.groupNotAllowed);
    });

    test('an unauthorised sender gets no reply and no prompt', () async {
      final harness = await EngineHarness.start();
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('rm -rf /', sender: 'stranger'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(harness.agent.prompts, isEmpty);
      expect(harness.provider.sent, isEmpty);
      expect(harness.engine.lastDenial?.denial, PolicyDenial.userNotAllowed);
    });

    test('two groups get two conversations and two sessions', () async {
      final harness = await EngineHarness.start();
      addTearDown(harness.stop);
      harness.agent.sessionFor = (request) =>
          'ses-${request.conversation.conversationId}';

      harness.provider.deliver(groupMessage('任务一', group: 'g1', id: 'a1'));
      await waitFor(() => harness.agent.prompts.length == 1);
      harness.provider.deliver(groupMessage('任务二', group: 'g2', id: 'b1'));
      await waitFor(() => harness.agent.prompts.length == 2);

      final keys = harness.agent.prompts
          .map((request) => request.conversation.value)
          .toSet();
      expect(keys, hasLength(2));
      expect(
        harness.agent.prompts.map(
          (request) => request.conversation.conversationId,
        ),
        ['g1', 'g2'],
      );
    });

    test('two members of one group never share a session', () async {
      final harness = await EngineHarness.start();
      addTearDown(harness.stop);
      harness.agent.sessionFor = (request) =>
          'ses-${request.conversation.ownerActorId}';

      harness.provider.deliver(
        groupMessage('我是甲', group: 'g1', sender: 'u1', id: 'a1'),
      );
      await waitFor(() => harness.agent.prompts.length == 1);
      harness.provider.deliver(
        groupMessage('我是乙', group: 'g1', sender: 'u2', id: 'b1'),
      );
      await waitFor(() => harness.agent.prompts.length == 2);

      final owners = harness.agent.prompts
          .map((request) => request.conversation.ownerActorId)
          .toList();
      expect(owners, ['u1', 'u2']);
      expect(
        harness.agent.prompts
            .map((request) => request.conversation.value)
            .toSet(),
        hasLength(2),
      );
    });
  });

  group('progress and completion', () {
    test('progress is throttled and the final answer is sent once', () async {
      final harness = await EngineHarness.start(
        singleConversation: true,
        progressInterval: const Duration(minutes: 1),
      );
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('改代码'));
      await waitFor(() => harness.agent.prompts.isNotEmpty);

      final busy = EventEnvelope(
        type: 'session.status',
        properties: {
          'sessionID': 'ses-1',
          'status': {'type': 'busy'},
        },
      );
      harness.engine.handleAgentEvent(busy);
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text.contains('已开始处理任务'),
        ),
      );

      final tool = EventEnvelope(
        type: 'message.part.updated',
        properties: {
          'sessionID': 'ses-1',
          'part': {
            'type': 'tool',
            'tool': 'bash',
            'state': {'status': 'running'},
          },
        },
      );
      harness.engine.handleAgentEvent(tool);
      harness.engine.handleAgentEvent(tool);
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text.contains('Agent 进度'),
        ),
      );
      expect(
        harness.provider.sent
            .where((message) => message.text.contains('Agent 进度'))
            .length,
        1,
      );

      final idle = EventEnvelope(
        type: 'session.status',
        properties: {
          'sessionID': 'ses-1',
          'status': {'type': 'idle'},
        },
      );
      harness.engine.handleAgentEvent(idle);
      await waitFor(
        () => harness.provider.sent.any((message) => message.text == '完成。'),
      );
      final before = harness.provider.sent.length;
      harness.engine.handleAgentEvent(idle);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(harness.provider.sent.length, before);
    });

    test('an agent error is reported without re-running anything', () async {
      final harness = await EngineHarness.start(singleConversation: true);
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('跑一下'));
      await waitFor(() => harness.agent.prompts.isNotEmpty);
      harness.engine.handleAgentEvent(
        EventEnvelope(
          type: 'session.error',
          properties: {'sessionID': 'ses-1'},
        ),
      );
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text.contains('遇到错误'),
        ),
      );
      expect(harness.agent.prompts, hasLength(1));
    });
  });

  group('channel isolation', () {
    test('two channels run side by side on one inbox and outbox', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final inbox = ChannelInbox(preferences: preferences);
      final outbox = ChannelOutbox(preferences: preferences);
      final first = await EngineHarness.start(
        singleConversation: true,
        providerId: 'channel-a',
        sharedPreferences: preferences,
        sharedInbox: inbox,
        sharedOutbox: outbox,
      );
      addTearDown(first.stop);
      final second = await EngineHarness.start(
        singleConversation: true,
        providerId: 'channel-b',
        sharedPreferences: preferences,
        sharedInbox: inbox,
        sharedOutbox: outbox,
      );
      addTearDown(second.stop);

      first.provider.deliver(directMessage('渠道一', providerId: 'channel-a'));
      second.provider.deliver(directMessage('渠道二', providerId: 'channel-b'));

      await waitFor(
        () => first.agent.prompts.isNotEmpty,
        reason:
            'channel-a prompt (denial=${first.engine.lastDenial}, '
            'state=${first.provider.status.state}, '
            'attempts=${first.provider.attempts.length})',
      );
      await waitFor(
        () => second.agent.prompts.isNotEmpty,
        reason: 'channel-b prompt (denial=${second.engine.lastDenial})',
      );
      await waitFor(
        () => first.provider.sent.isNotEmpty,
        reason: 'channel-a send (attempts=${first.provider.attempts.length})',
      );
      await waitFor(
        () => second.provider.sent.isNotEmpty,
        reason: 'channel-b send',
      );

      expect(first.provider.sent.single.text, contains('已转发'));
      expect(second.provider.sent.single.text, contains('已转发'));
      expect(first.agent.prompts.single.conversation.providerId, 'channel-a');
      expect(second.agent.prompts.single.conversation.providerId, 'channel-b');
    });

    test('one channel failing to send leaves the other working', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final inbox = ChannelInbox(preferences: preferences);
      final outbox = ChannelOutbox(preferences: preferences);
      final first = await EngineHarness.start(
        singleConversation: true,
        providerId: 'channel-a',
        sharedPreferences: preferences,
        sharedInbox: inbox,
        sharedOutbox: outbox,
      );
      addTearDown(first.stop);
      final second = await EngineHarness.start(
        singleConversation: true,
        providerId: 'channel-b',
        sharedPreferences: preferences,
        sharedInbox: inbox,
        sharedOutbox: outbox,
      );
      addTearDown(second.stop);
      first.provider.failSends = true;

      first.provider.deliver(directMessage('渠道一', providerId: 'channel-a'));
      second.provider.deliver(directMessage('渠道二', providerId: 'channel-b'));

      await waitFor(() => first.agent.prompts.isNotEmpty);
      await waitFor(() => second.agent.prompts.isNotEmpty);
      await waitFor(() => second.provider.sent.isNotEmpty);

      expect(first.provider.sent, isEmpty);
      expect(second.provider.sent.single.text, contains('已转发'));
      expect(first.engine.providerStatus.lastError, isNull);
    });
  });
}

/// A message the engine must reject without running anything: media only,
/// which no text prompt can represent.
ChannelMessage imageOnlyMessage() => ChannelMessage(
  providerId: 'fake',
  accountId: 'bot-1',
  conversationId: 'dm-1',
  conversationType: ChannelConversationKind.direct,
  senderId: 'u1',
  messageId: 'img-1',
  segments: const [
    ChannelSegment(type: ChannelSegmentType.image, targetId: 'file-1'),
  ],
  receivedAt: DateTime(2026, 11, 24, 12),
);
