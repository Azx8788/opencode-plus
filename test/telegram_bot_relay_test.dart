import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/telegram/telegram_bot.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end contract for the relay: a real [TelegramBotBridge] long-polls a
/// local stand-in for the Bot API, dispatches the updates it receives, and
/// posts its replies back. Only the Telegram server is a stand-in; the poll
/// loop, allowlist, dispatch and reply paths are the shipping ones.
const _token = '123456789:AAH-test-token-value-1234567890';
const _owner = '424242';
const _profile = 'profile-1';
const _directory = '/home/owner/projects/demo-project';

class _FakeTelegram {
  _FakeTelegram._(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakeTelegram> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeTelegram._(server);
  }

  final HttpServer _server;
  final _pending = <Map<String, dynamic>>[];
  final calls = <String>[];
  final sends = <String>[];
  int _updateID = 100;
  int _conflicts = 0;

  String get origin => 'http://127.0.0.1:${_server.port}';

  void enqueue(String text, {Object? from = _owner, Object? chat = _owner}) {
    _pending.add({
      'update_id': ++_updateID,
      'message': {
        'message_id': _updateID,
        'date': 0,
        'text': text,
        'chat': {'id': chat, 'type': 'private'},
        'from': {'id': from, 'is_bot': false},
      },
    });
  }

  /// Makes the next `getUpdates` answer 409, the way Telegram does when a
  /// webhook or another poller already owns the bot.
  void conflictOnce() => _conflicts = 1;

  Future<void> _handle(HttpRequest request) async {
    final method = request.uri.pathSegments.last;
    calls.add(method);
    final body = request.method == 'POST'
        ? await utf8.decoder.bind(request).join()
        : '';
    final response = await _respond(method, body);
    request.response
      ..statusCode = response.status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(response.payload));
    await request.response.close();
  }

  Future<({int status, Map<String, dynamic> payload})> _respond(
    String method,
    String body,
  ) async {
    switch (method) {
      case 'getUpdates':
        if (_conflicts > 0) {
          _conflicts--;
          return (
            status: 409,
            payload: {
              'ok': false,
              'error_code': 409,
              'description': 'Conflict: terminated by other getUpdates request',
            },
          );
        }
        // A real long poll blocks; answering at once would spin the loop.
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final batch = List<Map<String, dynamic>>.of(_pending);
        _pending.clear();
        return (status: 200, payload: {'ok': true, 'result': batch});
      case 'sendMessage':
        final decoded = jsonDecode(body);
        sends.add(decoded is Map ? decoded['text']?.toString() ?? '' : '');
        return (
          status: 200,
          payload: {
            'ok': true,
            'result': {'message_id': 1},
          },
        );
      case 'getMe':
        return (
          status: 200,
          payload: {
            'ok': true,
            'result': {'id': 123456789, 'is_bot': true, 'username': 'demo_bot'},
          },
        );
      case 'getChat':
        return (
          status: 200,
          payload: {
            'ok': true,
            'result': {'id': int.parse(_owner), 'type': 'private'},
          },
        );
      default:
        return (status: 200, payload: {'ok': true, 'result': true});
    }
  }

  Future<void> close() => _server.close(force: true);
}

class _Recorder {
  final prompts = <String>[];
  var stops = 0;
}

class _Harness {
  _Harness(this.telegram, this.bridge, this.recorder);

  final _FakeTelegram telegram;
  final TelegramBotBridge bridge;
  final _Recorder recorder;

  static Future<_Harness> start({
    bool enabled = true,
    Stream<EventEnvelope>? events,
    String? reply,
  }) async {
    final telegram = await _FakeTelegram.start();
    telegramApiOrigin = telegram.origin;
    SharedPreferences.setMockInitialValues({
      '${TelegramBotBridge.chatIDKeyPrefix}$_profile': _owner,
      '${TelegramBotBridge.enabledKeyPrefix}$_profile': enabled,
    });
    FlutterSecureStorage.setMockInitialValues({
      '${TelegramBotBridge.tokenKeyPrefix}$_profile': _token,
    });
    final recorder = _Recorder();
    final bridge = TelegramBotBridge(
      preferences: await SharedPreferences.getInstance(),
      secureStorage: const FlutterSecureStorage(),
      events: events ?? const Stream<EventEnvelope>.empty(),
      profileID: () => _profile,
      directory: () => _directory,
      workspace: () => '',
      supported: () => true,
      addHostListener: (_) {},
      removeHostListener: (_) {},
      sendPrompt: (text) async {
        recorder.prompts.add(text);
        return 'ses-1';
      },
      stopAgent: () async => recorder.stops++,
      readLatestReply: () async => reply,
      agentStatus: () => '本机 OpenCode 已连接；Agent 当前空闲。',
      isSessionBusy: (_) => false,
    );
    await bridge.initialize();
    return _Harness(telegram, bridge, recorder);
  }

  Future<void> stop() async {
    bridge.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await telegram.close();
  }
}

Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for ${reason ?? 'condition'}');
}

void main() {
  tearDownAll(() => telegramApiOrigin = 'https://api.telegram.org');

  test(
    'claims the bot and publishes its command menu before polling',
    () async {
      final harness = await _Harness.start();
      addTearDown(harness.stop);
      await _waitFor(
        () => harness.bridge.snapshot.phase == TelegramBotPhase.polling,
        reason: 'the first successful poll',
      );
      expect(harness.telegram.calls, contains('deleteWebhook'));
      expect(harness.telegram.calls, contains('setMyCommands'));
      expect(harness.telegram.calls, contains('getUpdates'));
    },
  );

  test('a plain message reaches the agent and the session is bound', () async {
    final harness = await _Harness.start();
    addTearDown(harness.stop);
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue('list the changed files');
    await _waitFor(() => harness.telegram.sends.isNotEmpty, reason: 'the ack');
    expect(harness.recorder.prompts, ['list the changed files']);
    expect(harness.telegram.sends.single, contains('已转发给本地 Agent'));
    expect(harness.bridge.snapshot.sessionID, 'ses-1');
  });

  test('/status reports the project, the binding and the poll state', () async {
    final harness = await _Harness.start();
    addTearDown(harness.stop);
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue('/status');
    await _waitFor(
      () => harness.telegram.sends.isNotEmpty,
      reason: 'the status',
    );
    final status = harness.telegram.sends.single;
    expect(status, contains('本机 OpenCode 已连接'));
    expect(status, contains('项目：demo-project'));
    expect(status, contains('会话：未绑定'));
    expect(status, contains('机器人：正在接收消息'));
    expect(harness.recorder.prompts, isEmpty);
  });

  test('/stop asks the app to interrupt, /new drops the binding', () async {
    final harness = await _Harness.start();
    addTearDown(harness.stop);
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue('/stop');
    await _waitFor(
      () => harness.telegram.sends.isNotEmpty,
      reason: 'the stop ack',
    );
    expect(harness.recorder.stops, 1);
    expect(harness.telegram.sends.last, contains('已请求停止'));

    harness.telegram.enqueue('/new');
    await _waitFor(
      () => harness.telegram.sends.length == 2,
      reason: '/new ack',
    );
    expect(harness.telegram.sends.last, contains('新的 Agent 会话'));
    expect(harness.bridge.snapshot.sessionID, isNull);
  });

  test('another Telegram account is ignored even in a private chat', () async {
    final harness = await _Harness.start();
    addTearDown(harness.stop);
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue('rm -rf /', from: 999, chat: 999);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(harness.recorder.prompts, isEmpty);
    expect(harness.telegram.sends, isEmpty);
  });

  test('a 409 conflict is reported instead of looking healthy', () async {
    final harness = await _Harness.start();
    addTearDown(harness.stop);
    harness.telegram.conflictOnce();
    await _waitFor(
      () => harness.bridge.snapshot.phase == TelegramBotPhase.error,
      reason: 'the reported failure',
    );
    expect(harness.bridge.snapshot.lastError, contains('占用'));
  });

  test('agent progress and the finished reply come back to Telegram', () async {
    final events = StreamController<EventEnvelope>.broadcast();
    final harness = await _Harness.start(
      events: events.stream,
      reply: '已修改 3 个文件，测试通过。',
    );
    addTearDown(() async {
      await events.close();
      await harness.stop();
    });
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue('fix the build');
    await _waitFor(() => harness.telegram.sends.isNotEmpty);

    events.add(
      EventEnvelope(
        type: 'session.status',
        directory: _directory,
        properties: {
          'sessionID': 'ses-1',
          'status': {'type': 'busy'},
        },
      ),
    );
    await _waitFor(
      () => harness.telegram.sends.any((text) => text.contains('已开始处理任务')),
      reason: 'the started notice',
    );

    events.add(
      EventEnvelope(
        type: 'session.status',
        directory: _directory,
        properties: {
          'sessionID': 'ses-1',
          'status': {'type': 'idle'},
        },
      ),
    );
    await _waitFor(
      () => harness.telegram.sends.any(
        (text) => text.contains('已修改 3 个文件，测试通过。'),
      ),
      reason: 'the finished reply',
    );
  });

  test('a disabled relay never polls', () async {
    final harness = await _Harness.start(enabled: false);
    addTearDown(harness.stop);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(harness.telegram.calls, isEmpty);
    expect(harness.bridge.snapshot.phase, TelegramBotPhase.disabled);
  });

  test('verifying a token reports the bot and the reachable chat', () async {
    final harness = await _Harness.start(enabled: false);
    addTearDown(harness.stop);
    final notice = await harness.bridge.testConnection();
    expect(notice, contains('@demo_bot'));
    expect(notice, contains('可以与该用户私聊'));
  });
}
