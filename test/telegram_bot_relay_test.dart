import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/gateway_events.dart';
import 'package:opencode_mobile/channels/channel_agent_port.dart';
import 'package:opencode_mobile/channels/channel_outbox.dart';
import 'package:opencode_mobile/channels/channel_provider.dart';
import 'package:opencode_mobile/channels/channel_sessions.dart';
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
  final sendTargets = <String>[];
  int _updateID = 100;
  int _conflicts = 0;
  int lastPolledOffset = 0;
  var _loseSendAck = false;

  String get origin => 'http://127.0.0.1:${_server.port}';

  int enqueue(
    String text, {
    Object? from = _owner,
    Object? chat = _owner,
    String type = 'private',
    bool isBot = false,
  }) {
    _pending.add({
      'update_id': ++_updateID,
      'message': {
        'message_id': _updateID,
        'date': 0,
        'text': text,
        'chat': {'id': chat, 'type': type},
        'from': {'id': from, 'is_bot': isBot},
      },
    });
    return _updateID;
  }

  /// Makes the next `getUpdates` answer 409, the way Telegram does when a
  /// webhook or another poller already owns the bot.
  void conflictOnce() => _conflicts = 1;
  void loseSendAcknowledgementOnce() => _loseSendAck = true;

  Future<void> _handle(HttpRequest request) async {
    final method = request.uri.pathSegments.last;
    calls.add(method);
    final body = request.method == 'POST'
        ? await utf8.decoder.bind(request).join()
        : '';
    if (method == 'sendMessage' && _loseSendAck) {
      _loseSendAck = false;
      _recordSend(body);
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    final response = await _respond(method, body, request.uri.queryParameters);
    request.response
      ..statusCode = response.status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(response.payload));
    await request.response.close();
  }

  Future<({int status, Map<String, dynamic> payload})> _respond(
    String method,
    String body,
    Map<String, String> query,
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
        final offset = int.tryParse(query['offset'] ?? '') ?? 0;
        lastPolledOffset = offset;
        _pending.removeWhere((update) => (update['update_id'] as int) < offset);
        final batch = List<Map<String, dynamic>>.of(_pending);
        return (status: 200, payload: {'ok': true, 'result': batch});
      case 'sendMessage':
        _recordSend(body);
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

  void _recordSend(String body) {
    final decoded = jsonDecode(body) as Map;
    sends.add('${decoded['text']}');
    sendTargets.add('${decoded['chat_id']}');
  }

  Future<void> close() => _server.close(force: true);
}

class _Recorder extends ChannelAgentPort {
  final prompts = <String>[];
  final replyReads = <String>[];
  Future<void> Function()? beforePromptReceipt;
  final recoveries = <(String, String)>[];
  ChannelAgentReply? recoverable;
  String? reply;
  var stops = 0;

  @override
  Future<String> sendPrompt(ChannelPromptRequest request) async {
    await request.onSessionReady?.call(
      const ChannelSessionBinding(
        sessionID: 'ses-1',
        directory: _directory,
        workspace: '',
      ),
    );
    prompts.add(request.text);
    await beforePromptReceipt?.call();
    return 'ses-1';
  }

  @override
  Future<void> stopTask(String? sessionID) async => stops++;

  @override
  Future<String?> latestReply(String sessionID) async {
    replyReads.add(sessionID);
    return reply;
  }

  @override
  Future<ChannelAgentReply?> replyForMessage(
    String sessionID,
    String messageID,
  ) async {
    replyReads.add('$sessionID/$messageID');
    final text = reply;
    return text == null
        ? null
        : ChannelAgentReply(text: text, messageId: messageID);
  }

  @override
  Future<ChannelAgentReply?> recoverReply(
    String sessionID,
    DateTime startedAt,
    String prompt, {
    String? observedMessageId,
  }) async {
    recoveries.add((sessionID, prompt));
    return recoverable;
  }

  @override
  String statusText() => '本机 OpenCode 已连接；Agent 当前空闲。';

  @override
  bool isBusy(String sessionID) => false;
}

class _Harness {
  _Harness(this.telegram, this.bridge, this.recorder);

  final _FakeTelegram telegram;
  final TelegramBotBridge bridge;
  final _Recorder recorder;
  bool supported = true;
  String profile = _profile;
  void Function()? _hostListener;

  void changeSupported(bool value) {
    supported = value;
    _hostListener?.call();
  }

  void changeProfile(String value) {
    profile = value;
    _hostListener?.call();
  }

  static Future<_Harness> start({
    bool enabled = true,
    bool configured = true,
    Stream<EventEnvelope>? events,
    String? reply,
    Duration replyRecoveryInterval = const Duration(seconds: 10),
    Duration pairingWindow = const Duration(minutes: 3),
  }) async {
    final telegram = await _FakeTelegram.start();
    telegramApiOrigin = telegram.origin;
    SharedPreferences.setMockInitialValues({
      if (configured) '${TelegramBotBridge.chatIDKeyPrefix}$_profile': _owner,
      '${TelegramBotBridge.enabledKeyPrefix}$_profile': enabled,
    });
    FlutterSecureStorage.setMockInitialValues({
      if (configured) '${TelegramBotBridge.tokenKeyPrefix}$_profile': _token,
    });
    final recorder = _Recorder()..reply = reply;
    late final _Harness harness;
    final bridge = TelegramBotBridge(
      preferences: await SharedPreferences.getInstance(),
      secureStorage: const FlutterSecureStorage(),
      events: events ?? const Stream<EventEnvelope>.empty(),
      profileID: () => harness.profile,
      directory: () => _directory,
      workspace: () => '',
      supported: () => harness.supported,
      addHostListener: (listener) => harness._hostListener = listener,
      removeHostListener: (_) => harness._hostListener = null,
      agent: recorder,
      replyRecoveryInterval: replyRecoveryInterval,
      pairingWindow: pairingWindow,
    );
    harness = _Harness(telegram, bridge, recorder);
    await bridge.initialize();
    return harness;
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

void _emitV2(
  StreamController<EventEnvelope> events,
  Api2EventAdapter adapter,
  String type, [
  Map<String, Object?> extra = const {},
]) {
  for (final event in adaptApi2EventJson(adapter, {
    'type': type,
    'data': {'sessionID': 'ses-1', ...extra},
  })) {
    events.add(event);
  }
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

  test(
    'v2 completion before the prompt receipt still returns the final text once',
    () async {
      final events = StreamController<EventEnvelope>.broadcast();
      final harness = await _Harness.start(events: events.stream);
      addTearDown(harness.stop);
      addTearDown(events.close);
      final receipt = Completer<void>();
      addTearDown(() {
        if (!receipt.isCompleted) receipt.complete();
      });
      harness.recorder.beforePromptReceipt = () => receipt.future;
      harness.telegram.enqueue('汇报一下环境');
      await _waitFor(() => harness.recorder.prompts.isNotEmpty);
      final adapter = Api2EventAdapter();
      _emitV2(events, adapter, 'session.execution.started');
      _emitV2(events, adapter, 'session.text.ended', {
        'assistantMessageID': 'msg-environment',
        'ordinal': 0,
        'text': '环境已检查。',
      });
      _emitV2(events, adapter, 'session.text.ended', {
        'assistantMessageID': 'msg-environment',
        'ordinal': 1,
        'text': '构建工具已就绪。',
      });
      _emitV2(events, adapter, 'session.step.ended', {
        'assistantMessageID': 'msg-environment',
      });
      _emitV2(events, adapter, 'session.execution.succeeded');
      _emitV2(events, adapter, 'session.idle');
      const answer = '环境已检查。\n构建工具已就绪。';
      await _waitFor(() => harness.telegram.sends.contains(answer));
      expect(harness.telegram.sends, isNot(contains('已转发给本地 Agent。')));
      receipt.complete();
      await _waitFor(() => harness.telegram.sends.contains('已转发给本地 Agent。'));
      expect(
        harness.telegram.sends.where((text) => text == answer),
        hasLength(1),
      );
      expect(harness.recorder.replyReads, isEmpty);
    },
  );

  test(
    'switching the app view does not replace the session that owes a reply',
    () async {
      final events = StreamController<EventEnvelope>.broadcast();
      final harness = await _Harness.start(
        events: events.stream,
        reply: '原会话的结果',
      );
      addTearDown(harness.stop);
      addTearDown(events.close);
      harness.telegram.enqueue('处理原会话');
      await _waitFor(() => harness.telegram.sends.isNotEmpty);
      await harness.bridge.bindSession('ses-2');
      final adapter = Api2EventAdapter();
      _emitV2(events, adapter, 'session.step.ended', {
        'assistantMessageID': 'msg-original',
      });
      _emitV2(events, adapter, 'session.execution.succeeded');
      await _waitFor(() => harness.telegram.sends.contains('原会话的结果'));
      expect(harness.recorder.replyReads, ['ses-1/msg-original']);
      expect(harness.bridge.snapshot.sessionID, 'ses-2');
      expect(harness.telegram.sendTargets.toSet(), {_owner});
    },
  );

  test(
    'a reconnect keeps the task and can recover a missed terminal event',
    () async {
      final events = StreamController<EventEnvelope>.broadcast();
      final harness = await _Harness.start(
        events: events.stream,
        replyRecoveryInterval: const Duration(milliseconds: 30),
      );
      addTearDown(harness.stop);
      addTearDown(events.close);
      harness.telegram.enqueue('请检查环境');
      await _waitFor(() => harness.telegram.sends.isNotEmpty);
      final engine = harness.bridge.engine;
      harness.changeSupported(false);
      harness.recorder.recoverable = const ChannelAgentReply(
        text: '补回的结果',
        messageId: 'msg-done',
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(harness.telegram.sends, isNot(contains('补回的结果')));
      harness.changeSupported(true);
      await _waitFor(() => harness.telegram.sends.contains('补回的结果'));
      expect(harness.bridge.engine, same(engine));
      expect(harness.recorder.recoveries, contains(('ses-1', '请检查环境')));
      _emitV2(events, Api2EventAdapter(), 'session.execution.succeeded');
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(
        harness.telegram.sends.where((text) => text == '补回的结果'),
        hasLength(1),
      );
      expect(harness.recorder.prompts, ['请检查环境']);
    },
  );

  test(
    'a lost Telegram acknowledgement is recorded without a duplicate send',
    () async {
      final events = StreamController<EventEnvelope>.broadcast();
      final harness = await _Harness.start(
        events: events.stream,
        reply: '结果已经生成',
      );
      addTearDown(harness.stop);
      addTearDown(events.close);
      harness.telegram.enqueue('执行测试');
      await _waitFor(() => harness.telegram.sends.isNotEmpty);
      final engine = harness.bridge.engine!;
      final settled = engine.outbox.changes.firstWhere(
        (entry) =>
            entry.purpose == DeliveryPurpose.finalAnswer && entry.isTerminal,
      );
      harness.telegram.loseSendAcknowledgementOnce();
      final adapter = Api2EventAdapter();
      _emitV2(events, adapter, 'session.step.ended', {
        'assistantMessageID': 'msg-done',
      });
      _emitV2(events, adapter, 'session.execution.succeeded');
      expect(
        (await settled.timeout(const Duration(seconds: 5))).status,
        OutboxStatus.unknown,
      );
      await engine.drainOutbox();
      expect(
        harness.telegram.sends.where((text) => text == '结果已经生成'),
        hasLength(1),
      );
      expect(harness.recorder.prompts, ['执行测试']);
    },
  );

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

  group('automatic binding', () {
    test(
      'accepts only a fresh matching private start, then enables the relay',
      () async {
        final harness = await _Harness.start(enabled: false, configured: false);
        addTearDown(harness.stop);
        final pairing = harness.bridge.beginPairing(replacementToken: _token);
        await _waitFor(() => harness.bridge.pairingLink != null);
        final link = harness.bridge.pairingLink!;
        expect(link.scheme, 'https');
        expect(link.host, 't.me');
        expect(link.path, '/demo_bot');
        final code = link.queryParameters['start']!;
        expect(code, matches(RegExp(r'^[A-Za-z0-9_-]{8}$')));
        expect(link.toString(), isNot(contains(_token)));

        harness.telegram.enqueue('这条消息不能成为绑定凭证', from: 999, chat: 999);
        harness.telegram.enqueue('/start ${code}x');
        harness.telegram.enqueue(
          '/start $code',
          type: 'supergroup',
          chat: -100,
        );
        harness.telegram.enqueue(
          '/start $code',
          from: 999,
          isBot: true,
          chat: 999,
        );
        final mismatched = harness.telegram.enqueue('/start $code', from: 999);
        await _waitFor(() => harness.telegram.lastPolledOffset > mismatched);
        expect(harness.bridge.snapshot.configured, isFalse);
        expect(harness.bridge.isPairing, isTrue);
        expect(harness.telegram.calls, isNot(contains('deleteWebhook')));
        expect(harness.recorder.prompts, isEmpty);

        harness.telegram.enqueue('/start $code');
        harness.telegram.enqueue('同一批次的消息不能启动任务');
        await pairing;
        expect(harness.bridge.pairingSucceeded, isTrue);
        expect(harness.bridge.snapshot.chatID, _owner);
        expect(harness.bridge.snapshot.enabled, isTrue);
        expect(harness.bridge.pairingLink, isNull);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('${TelegramBotBridge.chatIDKeyPrefix}$_profile'),
          _owner,
        );
        expect(
          await const FlutterSecureStorage().read(
            key: '${TelegramBotBridge.tokenKeyPrefix}$_profile',
          ),
          _token,
        );

        harness.telegram.enqueue('/start $code', from: 999, chat: 999);
        harness.telegram.enqueue('开始第一个任务');
        await _waitFor(() => harness.recorder.prompts.isNotEmpty);
        expect(harness.recorder.prompts, ['开始第一个任务']);
        expect(harness.bridge.snapshot.chatID, _owner);
      },
    );

    for (final end in ['cancelled', 'expired', 'profile changed']) {
      test('$end links cannot bind any user or store the token', () async {
        final harness = await _Harness.start(
          enabled: false,
          configured: false,
          pairingWindow: end == 'expired'
              ? const Duration(milliseconds: 350)
              : const Duration(minutes: 3),
        );
        addTearDown(harness.stop);
        final attempt = harness.bridge.beginPairing(replacementToken: _token);
        await _waitFor(() => harness.bridge.pairingLink != null);
        final code = harness.bridge.pairingLink!.queryParameters['start'];
        if (end == 'cancelled') harness.bridge.cancelPairing();
        if (end == 'profile changed') harness.changeProfile('profile-2');
        await attempt;
        if (end == 'expired') {
          expect(harness.bridge.pairingError, contains('过期'));
        }
        harness.telegram.enqueue('/start $code');
        expect(harness.bridge.isPairing, isFalse);
        expect(harness.bridge.pairingLink, isNull);
        expect(harness.bridge.snapshot.enabled, isFalse);
        expect(harness.bridge.snapshot.configured, isFalse);
        expect(harness.recorder.prompts, isEmpty);
        expect(
          await const FlutterSecureStorage().read(
            key: '${TelegramBotBridge.tokenKeyPrefix}$_profile',
          ),
          isNull,
        );
      });
    }

    test(
      'a conflicting bot receiver is reported without taking over its webhook',
      () async {
        final harness = await _Harness.start(enabled: false, configured: false);
        addTearDown(harness.stop);
        harness.telegram.conflictOnce();
        await harness.bridge.beginPairing(replacementToken: _token);
        expect(harness.bridge.pairingError, contains('占用'));
        expect(harness.telegram.calls, isNot(contains('deleteWebhook')));
        expect(harness.bridge.snapshot.configured, isFalse);
      },
    );
  });
}
