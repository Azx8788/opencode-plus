import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_provider.dart';
import 'package:opencode_mobile/channels/providers/onebot11_provider.dart';

const _selfQq = '10001';
const _token = 'reverse-token-value';

/// A stand-in for the protocol implementation in reverse mode: it dials the
/// port the provider listens on, exactly as NapCat's WebSocket client does.
class _Peer {
  _Peer(this.socket);

  final WebSocket socket;
  final actions = <Map<String, dynamic>>[];

  static Future<_Peer> connect(
    int port, {
    String? token = _token,
    String path = '/',
  }) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port$path',
      headers: token == null ? null : {'Authorization': 'Bearer $token'},
    );
    final peer = _Peer(socket);
    socket.listen((frame) {
      final decoded = jsonDecode(frame as String);
      if (decoded is! Map) return;
      final action = decoded['action']?.toString();
      if (action == null) return;
      peer.actions.add({
        'action': action,
        'params': decoded['params'] is Map
            ? Map<String, dynamic>.from(decoded['params'] as Map)
            : <String, dynamic>{},
      });
      socket.add(
        jsonEncode({
          'status': 'ok',
          'retcode': 0,
          'data': {'message_id': 7001},
          'echo': decoded['echo'],
        }),
      );
    });
    return peer;
  }

  void lifecycle({String selfId = _selfQq}) {
    socket.add(
      jsonEncode({
        'post_type': 'meta_event',
        'meta_event_type': 'lifecycle',
        'sub_type': 'connect',
        'self_id': int.tryParse(selfId) ?? selfId,
        'time': 1700000000,
      }),
    );
  }
}

/// Binds an ephemeral port, notes the number and releases it so the provider
/// can take it. The window is short and the port is chosen by the kernel.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  test('reverse mode refuses to listen without a token', () async {
    final provider = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: '',
      accessToken: '',
      transport: OneBot11Transport.reverse,
      listenHost: '127.0.0.1',
      listenPort: await _freePort(),
    );
    addTearDown(provider.dispose);

    await provider.connect();

    expect(provider.status.state, ProviderState.needsSetup);
    expect(provider.status.detail, contains('Access Token'));
  });

  test('reverse mode accepts the peer and reports the account online', () async {
    final port = await _freePort();
    final provider = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: '',
      accessToken: _token,
      transport: OneBot11Transport.reverse,
      listenHost: '127.0.0.1',
      listenPort: port,
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.detail?.contains('已监听') ?? false);

    final peer = await _Peer.connect(port);
    addTearDown(() => peer.socket.close());
    peer.lifecycle();

    await _waitFor(() => provider.status.state == ProviderState.online);
    expect(provider.selfId, _selfQq);
    expect(provider.status.detail, contains(_selfQq));
  });

  test('a wrong token is refused with 401 and never reaches the agent', () async {
    final port = await _freePort();
    final provider = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: '',
      accessToken: _token,
      transport: OneBot11Transport.reverse,
      listenHost: '127.0.0.1',
      listenPort: port,
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.detail?.contains('已监听') ?? false);

    await expectLater(
      _Peer.connect(port, token: 'not-the-token'),
      throwsA(isA<WebSocketException>()),
    );
    expect(provider.status.state, isNot(ProviderState.online));
  });

  test('the access_token query parameter is accepted for other clients', () async {
    final port = await _freePort();
    final provider = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: '',
      accessToken: _token,
      transport: OneBot11Transport.reverse,
      listenHost: '127.0.0.1',
      listenPort: port,
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.detail?.contains('已监听') ?? false);

    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/?access_token=$_token',
    );
    addTearDown(() => socket.close());
    socket.add(
      jsonEncode({
        'post_type': 'meta_event',
        'meta_event_type': 'lifecycle',
        'sub_type': 'connect',
        'self_id': int.parse(_selfQq),
      }),
    );

    await _waitFor(() => provider.status.state == ProviderState.online);
  });

  test('a dropped peer leaves the port open for the next connection', () async {
    final port = await _freePort();
    final provider = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: '',
      accessToken: _token,
      transport: OneBot11Transport.reverse,
      listenHost: '127.0.0.1',
      listenPort: port,
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.detail?.contains('已监听') ?? false);

    final first = await _Peer.connect(port);
    first.lifecycle();
    await _waitFor(() => provider.status.state == ProviderState.online);
    await first.socket.close();
    await _waitFor(() => provider.status.state == ProviderState.reconnecting);

    final second = await _Peer.connect(port);
    addTearDown(() => second.socket.close());
    second.lifecycle();
    await _waitFor(() => provider.status.state == ProviderState.online);
  });

  test('a message from the reverse peer reaches the channel', () async {
    final port = await _freePort();
    final provider = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: '',
      accessToken: _token,
      transport: OneBot11Transport.reverse,
      listenHost: '127.0.0.1',
      listenPort: port,
    );
    addTearDown(provider.dispose);
    final messages = <String>[];
    final subscription = provider.events.listen((event) {
      if (event is InboundChannelMessage) {
        messages.add(event.message.promptText);
      }
    });
    addTearDown(subscription.cancel);

    await provider.connect();
    await _waitFor(() => provider.status.detail?.contains('已监听') ?? false);
    final peer = await _Peer.connect(port);
    addTearDown(() => peer.socket.close());
    peer.lifecycle();
    await _waitFor(() => provider.status.state == ProviderState.online);
    peer.socket.add(
      jsonEncode({
        'post_type': 'message',
        'message_type': 'group',
        'message_id': 51,
        'group_id': 90001,
        'user_id': 20002,
        'self_id': int.parse(_selfQq),
        'message': [
          {
            'type': 'text',
            'data': {'text': '从反向连接发来'},
          },
        ],
      }),
    );

    await _waitFor(() => messages.isNotEmpty);
    expect(messages.single, '从反向连接发来');
  });

  test('get_group_list is parsed, sorted and typed', () async {
    final provider = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: 'ws://127.0.0.1:1',
    );
    addTearDown(provider.dispose);

    final groups = [
      {'group_id': 30003, 'group_name': 'Zeta', 'member_count': 3},
      {'group_id': 10001, 'group_name': 'Alpha', 'max_member_count': 200},
      {'group_id': '20002', 'group_name': 'Beta'},
      {'group_name': 'no id'},
    ];
    final server = await _ActionServer.start((action) {
      if (action == 'get_group_list') return {'status': 'ok', 'retcode': 0, 'data': groups};
      return {'status': 'ok', 'retcode': 0, 'data': {}};
    });
    addTearDown(server.close);
    final connected = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: server.url,
      accessToken: _token,
    );
    addTearDown(connected.dispose);
    await connected.connect();
    await _waitFor(() => connected.status.state == ProviderState.online);

    final result = await connected.fetchGroupList();

    expect(result.map((group) => group.id), ['10001', '20002', '30003']);
    expect(result.first.name, 'Alpha');
    expect(result.first.maxMemberCount, 200);
    expect(result[1].name, 'Beta');
  });

  test('get_login_info fills the nickname the lifecycle event lacks', () async {
    final server = await _ActionServer.start(
      (action) => {
        'status': 'ok',
        'retcode': 0,
        'data': {'user_id': int.parse(_selfQq), 'nickname': '小号'},
      },
    );
    addTearDown(server.close);
    final provider = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: server.url,
      accessToken: _token,
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);

    final login = await provider.fetchLoginInfo();

    expect(login.id, _selfQq);
    expect(login.nickname, '小号');
  });

  test('a failed get_group_list is an error, not an empty list', () async {
    final server = await _ActionServer.start(
      (action) => {'status': 'failed', 'retcode': 1400, 'message': '群列表不可用'},
    );
    addTearDown(server.close);
    final provider = OneBot11Provider(
      accountId: 'qq-1',
      webSocketUrl: server.url,
      accessToken: _token,
    );
    addTearDown(provider.dispose);
    await provider.connect();
    await _waitFor(() => provider.status.state == ProviderState.online);

    await expectLater(provider.fetchGroupList(), throwsA(isA<OneBotFailure>()));
  });
}

/// A minimal forward OneBot server: lifecycle on connect, one answer per action.
class _ActionServer {
  _ActionServer._(this._server, this._answer) {
    _server.listen(_handle);
  }

  static Future<_ActionServer> start(
    Map<String, Object?> Function(String action) answer,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _ActionServer._(server, answer);
  }

  final HttpServer _server;
  final Map<String, Object?> Function(String action) _answer;

  String get url => 'ws://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((frame) {
      final decoded = jsonDecode(frame as String);
      if (decoded is! Map) return;
      final action = decoded['action']?.toString() ?? '';
      socket.add(jsonEncode({..._answer(action), 'echo': decoded['echo']}));
    });
    socket.add(
      jsonEncode({
        'post_type': 'meta_event',
        'meta_event_type': 'lifecycle',
        'sub_type': 'connect',
        'self_id': int.parse(_selfQq),
      }),
    );
  }

  Future<void> close() => _server.close(force: true);
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
