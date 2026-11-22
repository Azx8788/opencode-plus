import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/telegram/telegram_bot.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

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
  final sendChatIDs = <String>[];
  int _updateID = 100;
  int _conflicts = 0;

  String get origin => 'http://127.0.0.1:${_server.port}';

  void enqueue(
    String text, {
    Object? from = _owner,
    Object? chat = _owner,
    String? username,
  }) {
    _pending.add({
      'update_id': ++_updateID,
      'message': {
        'message_id': _updateID,
        'date': 0,
        'text': text,
        'chat': {'id': chat, 'type': 'private'},
        'from': {
          'id': from,
          'is_bot': false,
          'username': ?username,
        },
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
        sendChatIDs.add(
          decoded is Map ? decoded['chat_id']?.toString() ?? '' : '',
        );
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
  final hostListeners = <void Function()>[];
  String profileID = _profile;
  var stops = 0;
}

class _BindingPreferences extends InMemorySharedPreferencesStore {
  _BindingPreferences(super.data) : super.withData();

  final bindingStarted = Completer<void>();
  Completer<void>? bindingGate;
  bool refuseBinding = false;
  bool refuseRemoval = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.${TelegramBotBridge.boundUserIDKeyPrefix}$_profile') {
      if (!bindingStarted.isCompleted) bindingStarted.complete();
      final gate = bindingGate;
      if (gate != null) await gate.future;
      if (refuseBinding) return false;
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (refuseRemoval &&
        key == 'flutter.${TelegramBotBridge.boundUserIDKeyPrefix}$_profile') {
      return false;
    }
    return super.remove(key);
  }
}

class _Harness {
  _Harness(this.telegram, this.bridge, this.recorder, this.preferences);

  final _FakeTelegram telegram;
  final TelegramBotBridge bridge;
  final _Recorder recorder;
  final SharedPreferences preferences;

  static Future<_Harness> start({
    bool enabled = true,
    String username = '',
    String chatID = _owner,
    String boundUserID = '',
    Stream<EventEnvelope>? events,
    String? reply,
  }) async {
    final telegram = await _FakeTelegram.start();
    telegramApiOrigin = telegram.origin;
    SharedPreferences.setMockInitialValues({
      '${TelegramBotBridge.chatIDKeyPrefix}$_profile': chatID,
      '${TelegramBotBridge.usernameKeyPrefix}$_profile': username,
      '${TelegramBotBridge.boundUserIDKeyPrefix}$_profile': boundUserID,
      '${TelegramBotBridge.enabledKeyPrefix}$_profile': enabled,
    });
    FlutterSecureStorage.setMockInitialValues({
      '${TelegramBotBridge.tokenKeyPrefix}$_profile': _token,
    });
    final recorder = _Recorder();
    final preferences = await SharedPreferences.getInstance();
    final bridge = TelegramBotBridge(
      preferences: preferences,
      secureStorage: const FlutterSecureStorage(),
      events: events ?? const Stream<EventEnvelope>.empty(),
      profileID: () => recorder.profileID,
      directory: () => _directory,
      workspace: () => '',
      supported: () => true,
      addHostListener: recorder.hostListeners.add,
      removeHostListener: recorder.hostListeners.remove,
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
    return _Harness(telegram, bridge, recorder, preferences);
  }

  void switchProfile(String profileID) {
    recorder.profileID = profileID;
    for (final listener in List.of(recorder.hostListeners)) {
      listener();
    }
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

  test('a username alone can enable the relay and bind its reply ID', () async {
    final harness = await _Harness.start(enabled: false, chatID: '');
    addTearDown(harness.stop);
    await harness.bridge.saveConfiguration(
      username: ' @Owner_Name ',
      enabled: true,
    );
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    expect(harness.bridge.snapshot.username, 'owner_name');
    expect(harness.bridge.snapshot.chatID, isEmpty);
    expect(harness.bridge.snapshot.configured, isTrue);
    expect(harness.bridge.snapshot.awaitingBinding, isTrue);

    harness.telegram.enqueue(
      'ignore this',
      from: 999,
      chat: 999,
      username: 'other',
    );
    harness.telegram.enqueue('ignore missing username');
    harness.telegram.enqueue('first instruction', username: 'OWNER_NAME');
    await _waitFor(() => harness.telegram.sends.isNotEmpty);
    expect(harness.recorder.prompts, ['first instruction']);
    expect(harness.telegram.sendChatIDs, [_owner]);
    expect(harness.bridge.snapshot.boundUserID, _owner);
    expect(harness.bridge.snapshot.awaitingBinding, isFalse);
    expect(
      harness.preferences.getString(
        '${TelegramBotBridge.boundUserIDKeyPrefix}$_profile',
      ),
      _owner,
    );
  });

  test('a restored binding rejects username takeover after renames', () async {
    final harness = await _Harness.start(
      username: 'owner_name',
      chatID: '',
      boundUserID: _owner,
    );
    addTearDown(harness.stop);
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue(
      'intruder',
      from: 999,
      chat: 999,
      username: 'owner_name',
    );
    harness.telegram.enqueue('renamed owner', username: 'new_owner_name');
    harness.telegram.enqueue('owner without username');
    await _waitFor(() => harness.telegram.sends.length == 2);
    expect(harness.recorder.prompts, ['renamed owner', 'owner without username']);
    expect(harness.telegram.sendChatIDs, [_owner, _owner]);
    expect(harness.bridge.snapshot.boundUserID, _owner);
  });

  test('an optional ID adds a constraint on first username binding', () async {
    final harness = await _Harness.start(username: 'owner_name');
    addTearDown(harness.stop);
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue(
      'wrong ID',
      from: 999,
      chat: 999,
      username: 'owner_name',
    );
    harness.telegram.enqueue('wrong username', username: 'other_name');
    harness.telegram.enqueue('/start', username: 'owner_name');
    await _waitFor(() => harness.telegram.sends.isNotEmpty);
    expect(harness.recorder.prompts, isEmpty);
    expect(harness.telegram.sends, hasLength(1));
    expect(harness.telegram.sends.single, contains('已连接到 OpenCode Plus'));
    expect(harness.bridge.snapshot.boundUserID, _owner);
  });

  test('editing identity clears the old binding and optional ID', () async {
    final harness = await _Harness.start(
      enabled: false,
      username: 'owner_name',
      boundUserID: _owner,
    );
    addTearDown(harness.stop);
    await harness.bridge.saveConfiguration(username: 'new_owner', enabled: true);
    expect(harness.bridge.snapshot.chatID, isEmpty);
    expect(harness.bridge.snapshot.boundUserID, isEmpty);
    expect(harness.bridge.snapshot.awaitingBinding, isTrue);
    expect(
      harness.preferences.getString(
        '${TelegramBotBridge.chatIDKeyPrefix}$_profile',
      ),
      isEmpty,
    );
    expect(
      harness.preferences.containsKey(
        '${TelegramBotBridge.boundUserIDKeyPrefix}$_profile',
      ),
      isFalse,
    );
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue('old owner', username: 'owner_name');
    harness.telegram.enqueue(
      'new owner',
      from: 999,
      chat: 999,
      username: 'new_owner',
    );
    await _waitFor(() => harness.telegram.sends.isNotEmpty);
    expect(harness.recorder.prompts, ['new owner']);
    expect(harness.telegram.sendChatIDs, ['999']);
    expect(harness.bridge.snapshot.boundUserID, '999');
  });

  test('saving the same username preserves its stable binding', () async {
    final harness = await _Harness.start(
      enabled: false,
      username: 'owner_name',
      chatID: '',
      boundUserID: _owner,
    );
    addTearDown(harness.stop);
    await harness.bridge.saveConfiguration(
      username: '@OwNeR_NaMe',
      enabled: false,
    );
    expect(harness.bridge.snapshot.username, 'owner_name');
    expect(harness.bridge.snapshot.boundUserID, _owner);
    await harness.bridge.saveConfiguration(username: 'owner_name', enabled: true);
    expect(harness.bridge.snapshot.boundUserID, _owner);
  });

  test('enabling requires a valid username or ID', () async {
    final harness = await _Harness.start(enabled: false, chatID: '');
    addTearDown(harness.stop);
    await expectLater(
      harness.bridge.saveConfiguration(enabled: true),
      throwsFormatException,
    );
    await expectLater(
      harness.bridge.saveConfiguration(username: 'Display Name', enabled: true),
      throwsFormatException,
    );
    await expectLater(
      harness.bridge.saveConfiguration(
        username: 'owner_name',
        chatID: '-123',
        enabled: true,
      ),
      throwsFormatException,
    );
    expect(harness.telegram.calls, isEmpty);
    expect(harness.bridge.snapshot.enabled, isFalse);
  });

  test('username-only token verification waits for a private message', () async {
    final harness = await _Harness.start(
      enabled: false,
      username: 'owner_name',
      chatID: '',
    );
    addTearDown(harness.stop);
    final notice = await harness.bridge.testConnection();
    expect(notice, contains('@demo_bot'));
    expect(notice, contains('@owner_name'));
    expect(notice, contains('/start'));
    expect(harness.telegram.calls, ['getMe']);
    expect(harness.bridge.snapshot.boundUserID, isEmpty);
  });

  test('agent notices wait for binding, then use the numeric ID', () async {
    final events = StreamController<EventEnvelope>.broadcast();
    final harness = await _Harness.start(
      username: 'owner_name',
      events: events.stream,
    );
    addTearDown(() async {
      await events.close();
      await harness.stop();
    });
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    await harness.bridge.bindSession('ses-1');
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
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(harness.telegram.sends, isEmpty);

    harness.telegram.enqueue('/start', username: 'owner_name');
    await _waitFor(() => harness.telegram.sends.length == 1);
    events.add(
      EventEnvelope(
        type: 'permission.asked',
        directory: _directory,
        properties: {'sessionID': 'ses-1'},
      ),
    );
    await _waitFor(() => harness.telegram.sends.length == 2);
    expect(harness.telegram.sends.last, contains('等待权限或问题确认'));
    expect(harness.telegram.sendChatIDs, [_owner, _owner]);
  });

  test('verification does not reuse an edited-away ID or binding', () async {
    final harness = await _Harness.start(
      enabled: false,
      username: 'owner_name',
      boundUserID: _owner,
    );
    addTearDown(harness.stop);
    final notice = await harness.bridge.testConnection(
      username: 'new_owner',
      chatID: '',
    );
    expect(notice, contains('@new_owner'));
    expect(harness.telegram.calls, ['getMe']);
    expect(harness.bridge.snapshot.boundUserID, _owner);
  });

  test('server profiles keep username bindings isolated', () async {
    final harness = await _Harness.start(
      username: 'owner_name',
      chatID: '',
      boundUserID: _owner,
    );
    addTearDown(harness.stop);
    const secondProfile = 'profile-2';
    await harness.preferences.setString(
      '${TelegramBotBridge.usernameKeyPrefix}$secondProfile',
      'second_owner',
    );
    await harness.preferences.setBool(
      '${TelegramBotBridge.enabledKeyPrefix}$secondProfile',
      true,
    );
    const secure = FlutterSecureStorage();
    await secure.write(
      key: '${TelegramBotBridge.tokenKeyPrefix}$secondProfile',
      value: _token,
    );
    harness.switchProfile(secondProfile);
    await _waitFor(
      () =>
          harness.bridge.snapshot.profileID == secondProfile &&
          harness.bridge.snapshot.phase == TelegramBotPhase.polling,
    );
    expect(harness.bridge.snapshot.username, 'second_owner');
    expect(harness.bridge.snapshot.boundUserID, isEmpty);
    harness.telegram.enqueue('old account', username: 'owner_name');
    harness.telegram.enqueue(
      'second account',
      from: 999,
      chat: 999,
      username: 'second_owner',
    );
    await _waitFor(() => harness.telegram.sends.isNotEmpty);
    expect(harness.recorder.prompts, ['second account']);
    expect(harness.telegram.sendChatIDs, ['999']);
    expect(
      harness.preferences.getString(
        '${TelegramBotBridge.boundUserIDKeyPrefix}$_profile',
      ),
      _owner,
    );
    expect(
      harness.preferences.getString(
        '${TelegramBotBridge.boundUserIDKeyPrefix}$secondProfile',
      ),
      '999',
    );
  });

  test('a refused binding write never forwards the instruction', () async {
    final harness = await _Harness.start(username: 'owner_name', chatID: '');
    addTearDown(harness.stop);
    final preferences = _BindingPreferences(
      await SharedPreferencesStorePlatform.instance.getAll(),
    )..refuseBinding = true;
    SharedPreferencesStorePlatform.instance = preferences;
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue('must not execute', username: 'owner_name');
    await _waitFor(
      () => harness.bridge.snapshot.phase == TelegramBotPhase.error,
    );
    expect(harness.bridge.snapshot.lastError, contains('无法保存'));
    expect(harness.bridge.snapshot.boundUserID, isEmpty);
    expect(harness.recorder.prompts, isEmpty);
    expect(harness.telegram.sends, isEmpty);
    expect(
      harness.preferences.getString(
        '${TelegramBotBridge.boundUserIDKeyPrefix}$_profile',
      ),
      isEmpty,
    );
  });

  test('identity edits drain an in-flight binding before clearing it', () async {
    final harness = await _Harness.start(username: 'owner_name', chatID: '');
    addTearDown(harness.stop);
    final gate = Completer<void>();
    // Release the fake disk write even if an assertion fails.
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final preferences = _BindingPreferences(
      await SharedPreferencesStorePlatform.instance.getAll(),
    )..bindingGate = gate;
    SharedPreferencesStorePlatform.instance = preferences;
    await _waitFor(() => harness.telegram.calls.contains('getUpdates'));
    harness.telegram.enqueue('old pending instruction', username: 'owner_name');
    await preferences.bindingStarted.future.timeout(const Duration(seconds: 8));
    final saving = harness.bridge.saveConfiguration(
      username: 'new_owner',
      enabled: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gate.complete();
    await saving;
    expect(harness.bridge.snapshot.username, 'new_owner');
    expect(harness.bridge.snapshot.boundUserID, isEmpty);
    expect(harness.recorder.prompts, isEmpty);
    expect(harness.telegram.sends, isEmpty);
    await harness.preferences.reload();
    expect(
      harness.preferences.containsKey(
        '${TelegramBotBridge.boundUserIDKeyPrefix}$_profile',
      ),
      isFalse,
    );
  });

  test('refusing to clear a binding cannot enable a new identity', () async {
    final harness = await _Harness.start(
      username: 'owner_name',
      chatID: '',
      boundUserID: _owner,
    );
    addTearDown(harness.stop);
    final preferences = _BindingPreferences(
      await SharedPreferencesStorePlatform.instance.getAll(),
    )..refuseRemoval = true;
    SharedPreferencesStorePlatform.instance = preferences;
    await expectLater(
      harness.bridge.saveConfiguration(username: 'new_owner', enabled: true),
      throwsFormatException,
    );
    expect(harness.bridge.snapshot.enabled, isFalse);
    expect(harness.bridge.snapshot.phase, TelegramBotPhase.disabled);
    await harness.preferences.reload();
    expect(
      harness.preferences.getString(
        '${TelegramBotBridge.usernameKeyPrefix}$_profile',
      ),
      'owner_name',
    );
    expect(
      harness.preferences.getString(
        '${TelegramBotBridge.boundUserIDKeyPrefix}$_profile',
      ),
      _owner,
    );
    expect(harness.recorder.prompts, isEmpty);
    expect(harness.telegram.sends, isEmpty);
  });

  test('removing configuration deletes username and account binding', () async {
    final harness = await _Harness.start(
      enabled: false,
      username: 'owner_name',
      chatID: '',
      boundUserID: _owner,
    );
    addTearDown(harness.stop);
    await harness.bridge.clearConfiguration();
    expect(harness.bridge.snapshot.configured, isFalse);
    expect(harness.bridge.snapshot.username, isEmpty);
    expect(harness.bridge.snapshot.boundUserID, isEmpty);
    for (final prefix in [
      TelegramBotBridge.usernameKeyPrefix,
      TelegramBotBridge.boundUserIDKeyPrefix,
    ]) {
      expect(harness.preferences.containsKey('$prefix$_profile'), isFalse);
    }
  });
}
