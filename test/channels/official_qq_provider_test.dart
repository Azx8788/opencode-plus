import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_message.dart';
import 'package:opencode_mobile/channels/channel_provider.dart';
import 'package:opencode_mobile/channels/providers/official_qq_provider.dart';

const _appId = '102000001';
const _secret = 'test-client-secret-value';

/// A stand-in for the QQ Open Platform: the token endpoint, the gateway
/// lookup, the WebSocket gateway and the message OpenAPI, all on one port.
class _FakeQq {
  _FakeQq._(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakeQq> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeQq._(server);
  }

  final HttpServer _server;
  int tokenRequests = 0;
  int gatewayRequests = 0;
  int connections = 0;
  int sendStatus = 0;
  int unauthorizedOnce = 0;
  bool ackHeartbeats = true;
  bool sendHello = true;
  bool autoReady = true;
  int heartbeatInterval = 300;
  WebSocket? socket;
  final frames = <Map<String, dynamic>>[];
  final sends = <Map<String, dynamic>>[];
  final paths = <String>[];
  final tokenBodies = <Map<String, dynamic>>[];
  final authHeaders = <String?>[];

  String get apiBase => 'http://127.0.0.1:${_server.port}';

  String get wsUrl => 'ws://127.0.0.1:${_server.port}/websocket';

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    paths.add(path);
    authHeaders.add(request.headers.value(HttpHeaders.authorizationHeader));
    if (path == '/app/getAppAccessToken') {
      tokenRequests++;
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        tokenBodies.add(Map<String, dynamic>.from(decoded));
      }
      _json(request, {
        'access_token': 'tok-$tokenRequests',
        'expires_in': '7200',
      });
      return;
    }
    if (path == '/gateway') {
      gatewayRequests++;
      _json(request, {'url': wsUrl, 'shards': 1});
      return;
    }
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final upgraded = await WebSocketTransformer.upgrade(request);
      connections++;
      socket = upgraded;
      upgraded.listen((frame) {
        final decoded = jsonDecode(frame as String);
        if (decoded is! Map) return;
        final payload = Map<String, dynamic>.from(decoded);
        frames.add(payload);
        switch (payload['op']) {
          case 1:
            if (ackHeartbeats) upgraded.add(jsonEncode({'op': 11}));
          case 2:
            if (autoReady) {
              upgraded.add(
                jsonEncode({
                  'op': 0,
                  's': 1,
                  't': 'READY',
                  'd': {
                    'version': 1,
                    'session_id': 'sess-1',
                    'user': {'id': 'bot-1', 'username': '机器人', 'bot': true},
                    'shard': [0, 0],
                  },
                }),
              );
            }
          case 6:
            upgraded.add(
              jsonEncode({'op': 0, 's': 9, 't': 'RESUMED', 'd': ''}),
            );
        }
      });
      if (sendHello) {
        upgraded.add(
          jsonEncode({
            'op': 10,
            'd': {'heartbeat_interval': heartbeatInterval},
          }),
        );
      }
      return;
    }
    if (path.contains('/messages')) {
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        sends.add(Map<String, dynamic>.from(decoded));
      }
      if (unauthorizedOnce > 0) {
        unauthorizedOnce--;
        _json(request, {'code': 11244, 'message': 'token expired'}, 401);
        return;
      }
      if (sendStatus != 0) {
        _json(request, {'code': 40034, 'message': '被限流了'}, sendStatus);
        return;
      }
      _json(request, {'id': 'qq-msg-${sends.length}', 'timestamp': 1});
      return;
    }
    _json(request, {'code': 404, 'message': 'not found'}, 404);
  }

  void _json(HttpRequest request, Object payload, [int status = 200]) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(payload));
    request.response.close();
  }

  void dispatch(String type, Map<String, Object?> data, {int seq = 2}) {
    socket?.add(jsonEncode({'op': 0, 's': seq, 't': type, 'd': data}));
  }

  void closeSocket() => socket?.close();

  Future<void> close() async {
    await socket?.close();
    await _server.close(force: true);
  }
}

OfficialQqProvider _provider(_FakeQq server) => OfficialQqProvider(
  accountId: _appId,
  appId: _appId,
  clientSecret: _secret,
  apiBase: server.apiBase,
  tokenBase: server.apiBase,
  minBackoff: const Duration(milliseconds: 10),
  maxBackoff: const Duration(milliseconds: 40),
);

void main() {
  test(
    'exchanges the secret for a token, then identifies on the gateway',
    () async {
      final server = await _FakeQq.start();
      addTearDown(server.close);
      final provider = _provider(server);
      addTearDown(provider.dispose);

      await provider.connect();
      await _waitFor(() => provider.status.state == ProviderState.online);

      expect(server.tokenBodies.single['appId'], _appId);
      expect(server.tokenBodies.single['clientSecret'], _secret);
      expect(server.authHeaders, contains('QQBot tok-1'));
      final identify = server.frames.firstWhere((frame) => frame['op'] == 2);
      final data = identify['d'] as Map<String, dynamic>;
      expect(data['token'], 'QQBot tok-1');
      expect(data['intents'], OfficialQqProvider.defaultIntents);
    },
  );

  test('a C2C message becomes a direct conversation with the openid', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    final provider = _provider(server);
    addTearDown(provider.dispose);
    final messages = <ChannelMessage>[];
    provider.events.listen((event) {
      if (event is InboundChannelMessage) messages.add(event.message);
    });

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.dispatch('C2C_MESSAGE_CREATE', {
      'id': 'msg-100',
      'content': ' 帮我看看日志 ',
      'timestamp': '2026-11-24T12:00:00+08:00',
      'author': {'user_openid': 'openid-a'},
    });
    await _waitFor(() => messages.isNotEmpty);

    final message = messages.single;
    expect(message.conversationType, ChannelConversationKind.direct);
    expect(message.conversationId, 'openid-a');
    expect(message.senderId, 'openid-a');
    expect(message.promptText, '帮我看看日志');
    expect(message.messageId, 'msg-100');
    expect(message.extensions['user_openid'], 'openid-a');
  });

  test(
    'a group at-message is a group conversation and already addressed',
    () async {
      final server = await _FakeQq.start();
      addTearDown(server.close);
      final provider = _provider(server);
      addTearDown(provider.dispose);
      final messages = <ChannelMessage>[];
      provider.events.listen((event) {
        if (event is InboundChannelMessage) messages.add(event.message);
      });

      await provider.connect();
      await _waitFor(() => provider.status.state == ProviderState.online);
      server.dispatch('GROUP_AT_MESSAGE_CREATE', {
        'id': 'msg-200',
        'content': '跑一下测试',
        'group_openid': 'group-1',
        'author': {'member_openid': 'member-1'},
      });
      await _waitFor(() => messages.isNotEmpty);

      final message = messages.single;
      expect(message.conversationType, ChannelConversationKind.group);
      expect(message.conversationId, 'group-1');
      expect(message.senderId, 'member-1');
      expect(message.mentionsAccount, isTrue);
      expect(message.extensions['group_openid'], 'group-1');
    },
  );

  test('a channel at-message maps to a channel conversation', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    final provider = _provider(server);
    addTearDown(provider.dispose);
    final messages = <ChannelMessage>[];
    provider.events.listen((event) {
      if (event is InboundChannelMessage) messages.add(event.message);
    });

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.dispatch('AT_MESSAGE_CREATE', {
      'id': 'msg-300',
      'content': '频道消息',
      'channel_id': 'chan-1',
      'guild_id': 'guild-1',
      'author': {'id': 'user-9'},
    });
    await _waitFor(() => messages.isNotEmpty);

    expect(messages.single.conversationType, ChannelConversationKind.channel);
    expect(messages.single.conversationId, 'chan-1');
    expect(messages.single.mentionsAccount, isTrue);
  });

  test('passive replies carry msg_id and an increasing msg_seq', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    final provider = _provider(server);
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.dispatch('C2C_MESSAGE_CREATE', {
      'id': 'msg-100',
      'content': '你好',
      'author': {'user_openid': 'openid-a'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));

    const address = ChannelAddress(
      providerId: 'qq-official',
      accountId: _appId,
      conversationId: 'openid-a',
      conversationType: ChannelConversationKind.direct,
      replyToMessageId: 'msg-100',
    );
    final first = await provider.send(
      const RenderedChannelMessage(text: '第一条'),
      const DeliveryContext(address: address, purpose: DeliveryPurpose.ack),
    );
    final second = await provider.send(
      const RenderedChannelMessage(text: '第二条'),
      const DeliveryContext(
        address: address,
        purpose: DeliveryPurpose.finalAnswer,
      ),
    );

    expect(first.status, DeliveryStatus.delivered);
    expect(second.status, DeliveryStatus.delivered);
    expect(server.paths, contains('/v2/users/openid-a/messages'));
    expect(server.sends.first['msg_id'], 'msg-100');
    expect(server.sends.first['msg_seq'], 1);
    expect(server.sends.last['msg_seq'], 2);
    expect(server.sends.first['content'], '第一条');
  });

  test('a rate limit is deferred, not failed', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    final provider = _provider(server);
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.dispatch('C2C_MESSAGE_CREATE', {
      'id': 'msg-100',
      'content': '你好',
      'author': {'user_openid': 'openid-a'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    server.sendStatus = 429;

    final receipt = await provider.send(
      const RenderedChannelMessage(text: 'hi'),
      const DeliveryContext(
        address: ChannelAddress(
          providerId: 'qq-official',
          accountId: _appId,
          conversationId: 'openid-a',
          conversationType: ChannelConversationKind.direct,
          replyToMessageId: 'msg-100',
        ),
        purpose: DeliveryPurpose.finalAnswer,
      ),
    );
    expect(receipt.status, DeliveryStatus.deferred);
    expect(receipt.retryAfter, isNotNull);
  });

  test('a 401 refreshes the token once and retries the send', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    final provider = _provider(server);
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.dispatch('C2C_MESSAGE_CREATE', {
      'id': 'msg-100',
      'content': '你好',
      'author': {'user_openid': 'openid-a'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    server.unauthorizedOnce = 1;

    final receipt = await provider.send(
      const RenderedChannelMessage(text: 'hi'),
      const DeliveryContext(
        address: ChannelAddress(
          providerId: 'qq-official',
          accountId: _appId,
          conversationId: 'openid-a',
          conversationType: ChannelConversationKind.direct,
          replyToMessageId: 'msg-100',
        ),
        purpose: DeliveryPurpose.finalAnswer,
      ),
    );

    expect(receipt.status, DeliveryStatus.delivered);
    expect(server.tokenRequests, 2);
  });

  test(
    'the passive window refuses the sixth reply and protects the last slot',
    () async {
      final server = await _FakeQq.start();
      addTearDown(server.close);
      final provider = _provider(server);
      addTearDown(provider.dispose);
      final notices = <String>[];
      provider.events.listen((event) {
        if (event is ProviderNotice) notices.add(event.text);
      });

      await provider.connect();
      await _waitFor(() => provider.status.state == ProviderState.online);
      server.dispatch('C2C_MESSAGE_CREATE', {
        'id': 'msg-100',
        'content': '你好',
        'author': {'user_openid': 'openid-a'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      const address = ChannelAddress(
        providerId: 'qq-official',
        accountId: _appId,
        conversationId: 'openid-a',
        conversationType: ChannelConversationKind.direct,
        replyToMessageId: 'msg-100',
      );
      for (var index = 0; index < 4; index++) {
        final receipt = await provider.send(
          RenderedChannelMessage(text: '回复 $index'),
          const DeliveryContext(address: address, purpose: DeliveryPurpose.ack),
        );
        expect(receipt.status, DeliveryStatus.delivered);
      }

      // One slot left: a progress note must not consume it.
      final progress = await provider.send(
        const RenderedChannelMessage(text: '进度'),
        const DeliveryContext(
          address: address,
          purpose: DeliveryPurpose.progress,
        ),
      );
      expect(progress.status, DeliveryStatus.failed);
      expect(progress.error, contains('保留给最终结果'));
      expect(notices, isNotEmpty);

      final finalAnswer = await provider.send(
        const RenderedChannelMessage(text: '结果'),
        const DeliveryContext(
          address: address,
          purpose: DeliveryPurpose.finalAnswer,
        ),
      );
      expect(finalAnswer.status, DeliveryStatus.delivered);

      final sixth = await provider.send(
        const RenderedChannelMessage(text: '多余'),
        const DeliveryContext(
          address: address,
          purpose: DeliveryPurpose.finalAnswer,
        ),
      );
      expect(sixth.status, DeliveryStatus.failed);
      expect(sixth.error, contains('次数已用尽'));
    },
  );

  test(
    'a reply to an unknown msg_id is refused instead of pushed actively',
    () async {
      final server = await _FakeQq.start();
      addTearDown(server.close);
      final provider = _provider(server);
      addTearDown(provider.dispose);
      await provider.connect();
      await _waitFor(() => provider.status.state == ProviderState.online);

      final receipt = await provider.send(
        const RenderedChannelMessage(text: 'hi'),
        const DeliveryContext(
          address: ChannelAddress(
            providerId: 'qq-official',
            accountId: _appId,
            conversationId: 'openid-a',
            conversationType: ChannelConversationKind.direct,
            replyToMessageId: 'never-seen',
          ),
          purpose: DeliveryPurpose.finalAnswer,
        ),
      );
      expect(receipt.status, DeliveryStatus.failed);
      expect(receipt.error, contains('被动回复'));
      expect(server.sends, isEmpty);
    },
  );

  test('an expired passive window is reported, not retried forever', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    var now = DateTime(2026, 11, 24, 12);
    final provider = OfficialQqProvider(
      accountId: _appId,
      appId: _appId,
      clientSecret: _secret,
      apiBase: server.apiBase,
      tokenBase: server.apiBase,
      minBackoff: const Duration(milliseconds: 10),
      maxBackoff: const Duration(milliseconds: 40),
      clock: () => now,
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.dispatch('C2C_MESSAGE_CREATE', {
      'id': 'msg-100',
      'content': '你好',
      'author': {'user_openid': 'openid-a'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));

    now = now.add(const Duration(minutes: 6));
    final receipt = await provider.send(
      const RenderedChannelMessage(text: 'hi'),
      const DeliveryContext(
        address: ChannelAddress(
          providerId: 'qq-official',
          accountId: _appId,
          conversationId: 'openid-a',
          conversationType: ChannelConversationKind.direct,
          replyToMessageId: 'msg-100',
        ),
        purpose: DeliveryPurpose.finalAnswer,
      ),
    );
    expect(receipt.status, DeliveryStatus.failed);
    expect(receipt.error, contains('过期'));
    expect(server.sends, isEmpty);
  });

  test('a socket drop resumes the session instead of re-identifying', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    final provider = _provider(server);
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.closeSocket();
    await _waitFor(
      () => server.connections >= 2,
      timeout: const Duration(seconds: 3),
    );

    final resume = server.frames.where((frame) => frame['op'] == 6).toList();
    expect(resume, isNotEmpty);
    final data = resume.first['d'] as Map<String, dynamic>;
    expect(data['session_id'], 'sess-1');
    expect(data['seq'], 1);
    expect(server.frames.where((frame) => frame['op'] == 2), hasLength(1));
  });

  test('a missing heartbeat ACK forces a reconnect', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    server.ackHeartbeats = false;
    server.heartbeatInterval = 60;
    final provider = OfficialQqProvider(
      accountId: _appId,
      appId: _appId,
      clientSecret: _secret,
      apiBase: server.apiBase,
      tokenBase: server.apiBase,
      heartbeatTolerance: 1,
      minBackoff: const Duration(milliseconds: 10),
      maxBackoff: const Duration(milliseconds: 40),
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

  test('an invalid session re-identifies from scratch', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    final provider = _provider(server);
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);
    server.socket?.add(jsonEncode({'op': 9, 'd': false}));
    await _waitFor(
      () => server.frames.where((frame) => frame['op'] == 2).length >= 2,
      timeout: const Duration(seconds: 3),
    );
    await _waitFor(() => provider.status.state == ProviderState.online);
  });

  test('a bad AppID fails as a credential problem, not a retry loop', () async {
    final server = await _FakeQq.start();
    addTearDown(server.close);
    final provider = OfficialQqProvider(
      accountId: _appId,
      appId: _appId,
      clientSecret: _secret,
      apiBase: 'http://127.0.0.1:${server._server.port}/wrong',
      tokenBase: 'http://127.0.0.1:${server._server.port}/wrong',
      minBackoff: const Duration(milliseconds: 10),
      maxBackoff: const Duration(milliseconds: 20),
    );
    addTearDown(provider.dispose);

    await provider.connect();
    await _waitFor(() => provider.status.lastError != null);
    expect(provider.status.state, isNot(ProviderState.online));
    expect(provider.status.lastError, isNotNull);
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
