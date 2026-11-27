import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_identity.dart';
import 'package:opencode_mobile/channels/channel_message.dart';
import 'package:opencode_mobile/channels/channel_provider.dart';
import 'package:opencode_mobile/channels/channel_tasks.dart';
import 'package:opencode_mobile/channels/manager/manager_agent.dart';
import 'package:opencode_mobile/channels/manager/manager_client.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  group('the client', () {
    test('reads a tool call and a plain answer', () async {
      final server = await _MockModel.start([
        {
          'choices': [
            {
              'message': {
                'content': '',
                'tool_calls': [
                  {
                    'id': 'call-1',
                    'type': 'function',
                    'function': {
                      'name': 'send_message',
                      'arguments': '{"text":"收到"}',
                    },
                  },
                ],
              },
            },
          ],
        },
      ]);
      addTearDown(server.stop);
      final client = ManagerModelClient(
        baseUrl: server.baseUrl,
        apiKey: 'sk-test',
        model: 'manager-model',
      );
      addTearDown(client.close);

      final reply = await client.complete(messages: const [], tools: const []);

      expect(reply.toolCalls.single.name, 'send_message');
      expect(reply.toolCalls.single.arguments['text'], '收到');
      expect(server.lastAuth, 'Bearer sk-test');
      expect(server.lastBody['model'], 'manager-model');
    });

    test('a 401 becomes a sentence, not a stack trace', () async {
      final server = await _MockModel.start([
        {
          'error': {'message': 'invalid key'},
        },
      ], status: 401);
      addTearDown(server.stop);
      final client = ManagerModelClient(
        baseUrl: server.baseUrl,
        apiKey: 'bad',
        model: 'm',
        retryDelay: Duration.zero,
      );
      addTearDown(client.close);

      await expectLater(
        client.complete(messages: const [], tools: const []),
        throwsA(
          isA<ManagerModelError>().having(
            (error) => error.message,
            'message',
            contains('401'),
          ),
        ),
      );
      expect(server.served, 1);
    });

    test('retries a busy gateway once and uses the second answer', () async {
      final server = await _MockModel.start(
        [
          {'error': 'busy'},
          _plain('可以用了'),
        ],
        statuses: [429, 200],
      );
      addTearDown(server.stop);
      final client = ManagerModelClient(
        baseUrl: server.baseUrl,
        apiKey: 'k',
        model: 'm',
        retryDelay: Duration.zero,
      );
      addTearDown(client.close);
      expect(
        (await client.complete(messages: const [], tools: const [])).content,
        '可以用了',
      );
      expect(server.served, 2);
    });

    test('stops after one retry if the gateway is still busy', () async {
      final server = await _MockModel.start([
        {'error': 'busy'},
      ], status: 503);
      addTearDown(server.stop);
      final client = ManagerModelClient(
        baseUrl: server.baseUrl,
        apiKey: 'k',
        model: 'm',
        retryDelay: Duration.zero,
      );
      addTearDown(client.close);
      await expectLater(
        client.complete(messages: const [], tools: const []),
        throwsA(isA<ManagerModelError>()),
      );
      expect(server.served, 2);
    });
  });

  group('the agent', () {
    test('a send_message reaches the host and counts as speaking', () async {
      final server = await _MockModel.start([
        _call('send_message', {'text': '收到，开始处理'}),
        _plain('好的'),
      ]);
      addTearDown(server.stop);
      final host = _FakeHost();
      final agent = ChannelManagerAgent(
        client: ManagerModelClient(
          baseUrl: server.baseUrl,
          apiKey: 'k',
          model: 'm',
        ),
      );

      final outcome = await agent.handleUserMessage(
        conversationKey: 'c1',
        text: '帮我跑测试',
        host: host,
      );

      expect(outcome.spoke, isTrue);
      expect(host.sent, ['收到，开始处理']);
    });

    test(
      'submit_task hands the executor the text and returns its id',
      () async {
        final server = await _MockModel.start([
          _call('submit_task', {'text': '跑一遍测试'}),
          _call('send_message', {'text': '已提交'}),
          _plain('好的'),
        ]);
        addTearDown(server.stop);
        final host = _FakeHost();
        final agent = ChannelManagerAgent(
          client: ManagerModelClient(
            baseUrl: server.baseUrl,
            apiKey: 'k',
            model: 'm',
          ),
        );

        final outcome = await agent.handleUserMessage(
          conversationKey: 'c1',
          text: '跑测试',
          host: host,
        );

        expect(host.submitted, ['跑一遍测试']);
        expect(outcome.spoke, isTrue);
        // The tool result the model received carried the id.
        expect(
          server.toolResults.any((result) => result.contains('task-1')),
          isTrue,
        );
      },
    );

    test('an answer without send_message is not speaking', () async {
      final server = await _MockModel.start([
        {
          'choices': [
            {
              'message': {'content': '好的，我来处理'},
            },
          ],
        },
      ]);
      addTearDown(server.stop);
      final host = _FakeHost();
      final agent = ChannelManagerAgent(
        client: ManagerModelClient(
          baseUrl: server.baseUrl,
          apiKey: 'k',
          model: 'm',
        ),
      );

      final outcome = await agent.handleUserMessage(
        conversationKey: 'c1',
        text: '你好',
        host: host,
      );

      expect(outcome.spoke, isFalse);
      expect(host.sent, isEmpty);
    });

    test('stay_silent is a decision, not a failure', () async {
      final server = await _MockModel.start([
        _call('stay_silent', {'reason': '重复消息'}),
      ]);
      addTearDown(server.stop);
      final host = _FakeHost();
      final agent = ChannelManagerAgent(
        client: ManagerModelClient(
          baseUrl: server.baseUrl,
          apiKey: 'k',
          model: 'm',
        ),
      );

      final outcome = await agent.handleUserMessage(
        conversationKey: 'c1',
        text: '你好',
        host: host,
      );

      expect(outcome.spoke, isFalse);
      expect(outcome.silentByChoice, isTrue);
    });
  });

  group('the engine with a manager', () {
    test('the manager speaks, and the engine does not talk over it', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ChannelTaskStore(preferences: preferences);
      final server = await _MockModel.start([
        _call('submit_task', {'text': '跑一遍测试'}),
        _call('send_message', {'text': '收到，已开始'}),
        _plain('好的'),
        _call('send_message', {'text': '结果是：全部通过'}),
        _plain('好的'),
      ]);
      addTearDown(server.stop);
      final agent = ChannelManagerAgent(
        client: ManagerModelClient(
          baseUrl: server.baseUrl,
          apiKey: 'k',
          model: 'm',
        ),
      );
      final harness = await EngineHarness.start(
        singleConversation: true,
        ledger: store,
        manager: agent,
      );
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('跑测试', id: 'in-1'));
      await waitFor(() => harness.agent.prompts.length == 1);
      await waitFor(
        () => harness.provider.sent.any((message) => message.text == '收到，已开始'),
      );

      // No "已转发" receipt: the manager is the one talking.
      await store.settle();
      expect(
        store.recent().single.delivery,
        ChannelDeliveryStatus.pending,
        reason: 'the acknowledgment is not a task-result receipt',
      );
      expect(
        harness.provider.sent.any(
          (message) => message.text.contains('已转发给本地 Agent'),
        ),
        isFalse,
      );

      harness.engine.handleAgentEvent(_status('busy'));
      harness.agent
        ..reply = '全部通过'
        ..replyId = 'm-1';
      harness.engine.handleAgentEvent(_messageDone('m-1'));
      harness.engine.handleAgentEvent(_status('idle'));

      await waitFor(
        () =>
            harness.provider.sent.any((message) => message.text == '结果是：全部通过'),
      );
      // The executor's raw text was not relayed by the engine as well.
      expect(
        harness.provider.sent.where((message) => message.text == '全部通过').length,
        0,
      );
      await waitFor(
        () => store.recent().single.delivery == ChannelDeliveryStatus.delivered,
      );
      expect(store.recent().single.status, ChannelTaskStatus.completed);
    });

    test(
      'a silent submission gets a receipt without executing twice',
      () async {
        final server = await _MockModel.start([
          _call('submit_task', {'text': '跑测试'}),
          _plain('好的'),
        ]);
        addTearDown(server.stop);
        final client = ManagerModelClient(
          baseUrl: server.baseUrl,
          apiKey: 'k',
          model: 'm',
        );
        addTearDown(client.close);
        final harness = await EngineHarness.start(
          manager: ChannelManagerAgent(client: client),
        );
        addTearDown(harness.stop);
        harness.provider.deliver(directMessage('帮我跑测试'));
        await waitFor(() => harness.provider.sent.isNotEmpty);
        expect(harness.agent.prompts.single.text, '跑测试');
        expect(harness.provider.sent.single.text, '已转发给本地 Agent。');
      },
    );

    test(
      'a group member cannot read or cancel another member’s task',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = ChannelTaskStore(
          preferences: await SharedPreferences.getInstance(),
        );
        const other = ConversationKey(
          workspaceId: 'profile-1',
          providerId: 'fake',
          accountId: 'bot-1',
          conversationType: ChannelConversationKind.group,
          conversationId: 'g1',
          ownerActorId: 'u2',
        );
        store.record(
          ChannelTaskRecord(
            id: 'other-task',
            providerId: other.providerId,
            accountId: other.accountId,
            userId: other.ownerActorId,
            conversationId: other.conversationId,
            workspaceId: other.workspaceId,
            conversationKey: other.value,
            sessionId: 'ses-other',
            prompt: 'private prompt',
            result: 'private result',
            createdAt: DateTime.now(),
            status: ChannelTaskStatus.running,
          ),
        );
        await store.settle();
        final server = await _MockModel.start([
          _call('get_task_result', {'task_id': 'other-task'}),
          _call('list_tasks', {}),
          _call('cancel_task', {'task_id': 'other-task'}),
          _call('send_message', {'text': '没有这个任务'}),
          _plain('好的'),
        ]);
        addTearDown(server.stop);
        final client = ManagerModelClient(
          baseUrl: server.baseUrl,
          apiKey: 'k',
          model: 'm',
        );
        addTearDown(client.close);
        final harness = await EngineHarness.start(
          ledger: store,
          manager: ChannelManagerAgent(client: client),
        );
        addTearDown(harness.stop);
        harness.provider.deliver(groupMessage('查询任务'));
        await waitFor(() => harness.provider.sent.isNotEmpty);
        expect(
          server.toolResults,
          containsAll([
            '{"error":"没有这个任务"}',
            '{"tasks":[]}',
            '{"cancelled":false}',
          ]),
        );
        expect(harness.agent.stopped, isEmpty);
        expect(store.recent().single.status, ChannelTaskStatus.running);
      },
    );

    test('unknown final delivery is not followed by a raw fallback', () async {
      final server = await _MockModel.start([
        _call('submit_task', {'text': '跑测试'}),
        _plain('好的'),
        _call('send_message', {'text': '已整理的结果'}),
        _plain('好的'),
      ]);
      addTearDown(server.stop);
      final client = ManagerModelClient(
        baseUrl: server.baseUrl,
        apiKey: 'k',
        model: 'm',
      );
      addTearDown(client.close);
      final harness = await EngineHarness.start(
        manager: ChannelManagerAgent(client: client),
      );
      addTearDown(harness.stop);
      harness.provider.deliver(directMessage('帮我跑测试'));
      await waitFor(() => harness.provider.sent.isNotEmpty);
      harness.provider.receipt = const DeliveryReceipt.unknown('确认丢失');
      harness.agent
        ..reply = '原始结果'
        ..replyId = 'm-1';
      harness.engine.handleAgentEvent(_messageDone('m-1'));
      harness.engine.handleAgentEvent(_status('idle'));
      await waitFor(() => server.served == 4);
      await harness.engine.drainOutbox();
      expect(harness.provider.attempts.map((message) => message.text), [
        '已转发给本地 Agent。',
        '已整理的结果',
      ]);
    });

    test('a manager that cannot be reached falls back to the relay', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ChannelTaskStore(preferences: preferences);
      // A closed port: the request fails immediately.
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = socket.port;
      await socket.close();
      final agent = ChannelManagerAgent(
        client: ManagerModelClient(
          baseUrl: 'http://127.0.0.1:$deadPort/v1',
          apiKey: 'k',
          model: 'm',
        ),
      );
      final harness = await EngineHarness.start(
        singleConversation: true,
        ledger: store,
        manager: agent,
      );
      addTearDown(harness.stop);

      harness.provider.deliver(directMessage('跑测试', id: 'in-1'));

      await waitFor(() => harness.agent.prompts.length == 1);
      await waitFor(
        () => harness.provider.sent.any(
          (message) => message.text.contains('已转发给本地 Agent'),
        ),
      );
    });
  });
}

Map<String, Object?> _plain(String text) => {
  'choices': [
    {
      'message': {'content': text},
    },
  ],
};

Map<String, Object?> _call(String name, Map<String, Object?> arguments) => {
  'choices': [
    {
      'message': {
        'content': '',
        'tool_calls': [
          {
            'id': 'call-$name',
            'type': 'function',
            'function': {'name': name, 'arguments': jsonEncode(arguments)},
          },
        ],
      },
    },
  ],
};

class _FakeHost implements ManagerHost {
  final List<String> sent = [];
  final List<String> submitted = [];

  @override
  String get channelLabel => 'Telegram 私聊 1';

  @override
  String get projectLabel => 'demo';

  @override
  Future<String?> submitTask(String text) async {
    submitted.add(text);
    return 'task-1';
  }

  @override
  Future<bool> sendMessage(String text) async {
    sent.add(text);
    return true;
  }

  @override
  ChannelTaskRecord? taskById(String id) => null;

  @override
  List<ChannelTaskRecord> recentTasks({int limit = 10}) => const [];

  @override
  Future<bool> cancelTask(String id) async => true;
}

/// A loopback Chat Completions server with a scripted list of answers.
class _MockModel {
  _MockModel._(this._server, this._responses, this._statuses);

  final HttpServer _server;
  final List<Map<String, Object?>> _responses;
  final List<int> _statuses;

  int _served = 0;
  int get served => _served;
  String? lastAuth;
  Map<String, Object?> lastBody = const {};
  String? lastToolResult;
  final List<String> toolResults = [];

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  static Future<_MockModel> start(
    List<Map<String, Object?>> responses, {
    int status = 200,
    List<int>? statuses,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final model = _MockModel._(server, responses, statuses ?? [status]);
    server.listen(model._handle);
    return model;
  }

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    lastAuth = request.headers.value(HttpHeaders.authorizationHeader);
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      lastBody = Map<String, Object?>.from(decoded);
      final messages = decoded['messages'];
      if (messages is List) {
        for (final message in messages.reversed) {
          if (message is Map && message['role'] == 'tool') {
            lastToolResult = message['content']?.toString();
            toolResults.add(lastToolResult!);
            break;
          }
        }
      }
    }
    final requestNumber = _served++;
    final index = requestNumber.clamp(0, _responses.length - 1);
    request.response
      ..statusCode = _statuses[requestNumber.clamp(0, _statuses.length - 1)]
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(_responses[index]));
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
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
