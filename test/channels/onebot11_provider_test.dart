import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_message.dart';
import 'package:opencode_mobile/channels/channel_provider.dart';
import 'package:opencode_mobile/channels/providers/onebot11_provider.dart';

const _selfQq = '10001';
const _accessToken = 'test-token-value';

/// A stand-in for LLBot's OneBot 11 forward WebSocket server: it upgrades the
/// connection, sends the lifecycle event, records actions and answers them with
/// the echo the client sent.
class _FakeOneBot {
  _FakeOneBot._(this._server, this._selfId) {
    _server.listen(_handle);
  }

  static Future<_FakeOneBot> start({
    String selfId = _selfQq,
    bool requireToken = true,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeOneBot._(server, selfId)..requireToken = requireToken;
  }

  final HttpServer _server;
  final String _selfId;
  bool requireToken = true;
  bool rejectUpgrade = false;
  bool sendLifecycle = true;
  bool answerActions = true;
  int connections = 0;
  WebSocket? socket;
  final actions = <Map<String, dynamic>>[];
  final authHeaders = <String?>[];
  Map<String, Object?> Function(String action, Map<String, dynamic> params)?
  actionResult;

  String get url => 'ws://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest request) async {
    authHeaders.add(request.headers.value(HttpHeaders.authorizationHeader));
    if (rejectUpgrade) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    final upgraded = await WebSocketTransformer.upgrade(request);
    connections++;
    socket = upgraded;
    upgraded.listen((frame) {
      final decoded = jsonDecode(frame as String);
      if (decoded is! Map) return;
      final action = decoded['action']?.toString();
      if (action == null) return;
      final params = decoded['params'] is Map
          ? Map<String, dynamic>.from(decoded['params'] as Map)
          : <String, dynamic>{};
      actions.add({'action': action, 'params': params});
      if (!answerActions) return;
      final custom = actionResult?.call(action, params);
      final payload =
          custom ??
          <String, Object?>{
            'status': 'ok',
            'retcode': 0,
            'data': {'message_id': 4242},
          };
      upgraded.add(jsonEncode({...payload, 'echo': decoded['echo']}));
    });
    if (sendLifecycle) {
      upgraded.add(
        jsonEncode({
          'post_type': 'meta_event',
          'meta_event_type': 'lifecycle',
          'sub_type': 'connect',
          'self_id': int.tryParse(_selfId) ?? _selfId,
          'time': 1700000000,
        }),
      );
    }
  }

  void push(Map<String, Object?> event) {
    socket?.add(
      jsonEncode({
        'self_id': int.tryParse(_selfId) ?? _selfId,
        'time': 1700000000,
        ...event,
      }),
    );
  }

  void dropSocket() => socket?.close();

  Future<void> close() async {
    await socket?.close();
    await _server.close(force: true);
  }
}

void main() {
  test(
    'connects, reports the account and normalises a private message',
    () async {
      final server = await _FakeOneBot.start();
      addTearDown(server.close);
      final provider = OneBot11Provider(
        accountId: 'one',
        webSocketUrl: server.url,
        accessToken: _accessToken,
        expectedSelfId: _selfQq,
        minBackoff: const Duration(milliseconds: 10),
      );
      addTearDown(provider.dispose);
      final messages = <ChannelMessage>[];
      provider.events.listen((event) {
        if (event is InboundChannelMessage) messages.add(event.message);
      });

      await provider.connect();
      await _waitFor(() => provider.status.state == ProviderState.online);

      expect(provider.selfId, _selfQq);
      expect(server.authHeaders.single, 'Bearer $_accessToken');

      server.push({
        'post_type': 'message',
        'message_type': 'private',
        'sub_type': 'friend',
        'message_id': 77,
        'user_id': 20002,
        'raw_message': '你好',
        'message': [
          {
            'type': 'text',
            'data': {'text': '你好'},
          },
        ],
      });
      await _waitFor(() => messages.isNotEmpty);
      final message = messages.single;
      expect(message.conversationType, ChannelConversationKind.direct);
      expect(message.conversationId, '20002');
      expect(message.senderId, '20002');
      expect(message.promptText, '你好');
      expect(message.messageId, '77');
    },
  );

  test('a wrong token never reaches the lifecycle event', () async {
    final server = await _FakeOneBot.start();
    addTearDown(server.close);
    server.rejectUpgrade = true;
    final provider = OneBot11Provider(
      accountId: 'one',
      webSocketUrl: server.url,
      accessToken: 'wrong',
      expectedSelfId: _selfQq,
      minBackoff: const Duration(milliseconds: 10),
      maxBackoff: const Duration(milliseconds: 40),
    );
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.lastError != null);
    expect(provider.status.state, ProviderState.reconnecting);
    expect(provider.status.lastError, contains('Access Token'));
    expect(provider.status.state, isNot(ProviderState.online));
  });

  test('a mismatched self_id disconnects instead of answering', () async {
    final server = await _FakeOneBot.start(selfId: '99999');
    addTearDown(server.close);
    final provider = OneBot11Provider(
      accountId: 'one',
      webSocketUrl: server.url,
      expectedSelfId: _selfQq,
      minBackoff: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.error);
    expect(provider.status.lastError, contains('self_id 不匹配'));
    expect(provider.status.state, isNot(ProviderState.online));
  });

  test(
    'a group message with an at segment is recognised as addressed',
    () async {
      final server = await _FakeOneBot.start();
      addTearDown(server.close);
      final provider = OneBot11Provider(
        accountId: 'one',
        webSocketUrl: server.url,
        expectedSelfId: _selfQq,
        minBackoff: const Duration(milliseconds: 10),
      );
      addTearDown(provider.dispose);
      final messages = <ChannelMessage>[];
      provider.events.listen((event) {
        if (event is InboundChannelMessage) messages.add(event.message);
      });

      await provider.connect();
      await _waitFor(() => provider.status.state == ProviderState.online);
      server.push({
        'post_type': 'message',
        'message_type': 'group',
        'group_id': 30003,
        'message_id': 88,
        'user_id': 20002,
        'message': [
          {
            'type': 'at',
            'data': {'qq': _selfQq},
          },
          {
            'type': 'text',
            'data': {'text': ' 看一下构建'},
          },
          {
            'type': 'image',
            'data': {'file': 'a.jpg'},
          },
        ],
        'sender': {'user_id': 20002, 'nickname': '甲'},
      });
      await _waitFor(() => messages.isNotEmpty);

      final message = messages.single;
      expect(message.conversationType, ChannelConversationKind.group);
      expect(message.conversationId, '30003');
      expect(message.mentionsAccount, isTrue);
      expect(message.promptText, '看一下构建');
      expect(
        message.segments.map((segment) => segment.type),
        containsAll([
          ChannelSegmentType.mention,
          ChannelSegmentType.text,
          ChannelSegmentType.image,
        ]),
      );
      expect(message.senderName, '甲');
    },
  );

  test('send uses structured segments and correlates the echo', () async {
    final server = await _FakeOneBot.start();
    addTearDown(server.close);
    final provider = OneBot11Provider(
      accountId: 'one',
      webSocketUrl: server.url,
      expectedSelfId: _selfQq,
      minBackoff: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);

    final receipt = await provider.send(
      const RenderedChannelMessage(text: '第一行\n第二行 [CQ:at,qq=1]'),
      const DeliveryContext(
        address: ChannelAddress(
          providerId: 'onebot11',
          accountId: 'one',
          conversationId: '30003',
          conversationType: ChannelConversationKind.group,
          replyToMessageId: '88',
        ),
        purpose: DeliveryPurpose.finalAnswer,
      ),
    );

    expect(receipt.status, DeliveryStatus.delivered);
    expect(receipt.messageId, '4242');
    final action = server.actions.single;
    expect(action['action'], 'send_group_msg');
    final params = action['params'] as Map<String, dynamic>;
    expect(params['group_id'], 30003);
    final segments = params['message'] as List;
    expect(segments.first, {
      'type': 'reply',
      'data': {'id': '88'},
    });
    expect(segments.last['type'], 'text');
    expect(
      (segments.last['data'] as Map)['text'],
      '第一行\n第二行 [CQ:at,qq=1]',
      reason: 'text is sent verbatim as a segment, never re-encoded as CQ',
    );
  });

  test('a non-zero retcode is a failure, not a delivered message', () async {
    final server = await _FakeOneBot.start();
    addTearDown(server.close);
    server.actionResult = (action, params) => {
      'status': 'failed',
      'retcode': 100,
      'message': '参数错误',
      'wording': 'bad request',
    };
    final provider = OneBot11Provider(
      accountId: 'one',
      webSocketUrl: server.url,
      expectedSelfId: _selfQq,
      minBackoff: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);

    final receipt = await provider.send(
      const RenderedChannelMessage(text: 'hi'),
      const DeliveryContext(
        address: ChannelAddress(
          providerId: 'onebot11',
          accountId: 'one',
          conversationId: '20002',
          conversationType: ChannelConversationKind.direct,
        ),
        purpose: DeliveryPurpose.finalAnswer,
      ),
    );

    expect(receipt.status, DeliveryStatus.failed);
    expect(receipt.error, contains('100'));
    expect(receipt.error, contains('bad request'));
  });

  test('an unanswered action is unknown, never silently delivered', () async {
    final server = await _FakeOneBot.start();
    addTearDown(server.close);
    server.answerActions = false;
    final provider = OneBot11Provider(
      accountId: 'one',
      webSocketUrl: server.url,
      expectedSelfId: _selfQq,
      actionTimeout: const Duration(milliseconds: 120),
      minBackoff: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);

    final receipt = await provider.send(
      const RenderedChannelMessage(text: 'hi'),
      const DeliveryContext(
        address: ChannelAddress(
          providerId: 'onebot11',
          accountId: 'one',
          conversationId: '20002',
          conversationType: ChannelConversationKind.direct,
        ),
        purpose: DeliveryPurpose.finalAnswer,
      ),
    );
    expect(receipt.status, DeliveryStatus.unknown);
  });

  test('a silent peer trips the heartbeat watchdog', () async {
    final server = await _FakeOneBot.start();
    addTearDown(server.close);
    final provider = OneBot11Provider(
      accountId: 'one',
      webSocketUrl: server.url,
      expectedSelfId: _selfQq,
      watchdogInterval: const Duration(milliseconds: 30),
      heartbeatTimeout: const Duration(milliseconds: 80),
      minBackoff: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    await _waitFor(
      () => provider.status.state == ProviderState.reconnecting,
      timeout: const Duration(seconds: 3),
    );
    expect(provider.status.lastError, contains('心跳'));
  });

  test('a dropped socket reconnects and reports online again', () async {
    final server = await _FakeOneBot.start();
    addTearDown(server.close);
    final provider = OneBot11Provider(
      accountId: 'one',
      webSocketUrl: server.url,
      expectedSelfId: _selfQq,
      minBackoff: const Duration(milliseconds: 10),
      maxBackoff: const Duration(milliseconds: 30),
    );
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.dropSocket();
    await _waitFor(
      () => server.connections >= 2,
      timeout: const Duration(seconds: 3),
    );
    await _waitFor(() => provider.status.state == ProviderState.online);
  });

  test('an unknown event or segment never breaks the connection', () async {
    final server = await _FakeOneBot.start();
    addTearDown(server.close);
    final provider = OneBot11Provider(
      accountId: 'one',
      webSocketUrl: server.url,
      expectedSelfId: _selfQq,
      minBackoff: const Duration(milliseconds: 10),
    );
    addTearDown(provider.dispose);
    final messages = <ChannelMessage>[];
    provider.events.listen((event) {
      if (event is InboundChannelMessage) messages.add(event.message);
    });

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.push({'post_type': 'notice', 'notice_type': 'group_upload'});
    server.push({
      'post_type': 'message',
      'message_type': 'private',
      'message_id': 91,
      'user_id': 20002,
      'message': [
        {
          'type': 'mystery',
          'data': {'payload': 1},
        },
        {
          'type': 'text',
          'data': {'text': '仍然可以收到'},
        },
      ],
    });
    await _waitFor(() => messages.isNotEmpty);
    expect(messages.single.promptText, '仍然可以收到');
    expect(messages.single.segments.first.type, ChannelSegmentType.unknown);
    expect(provider.status.state, ProviderState.online);
  });
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Timed out');
}
