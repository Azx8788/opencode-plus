import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/client.dart';
import 'package:opencode_mobile/api2/dialect.dart';
import 'package:opencode_mobile/api2/gateway.dart';
import 'package:opencode_mobile/api2/models.dart';
import 'package:opencode_mobile/domain/command_receipt_transport.dart';
import 'package:opencode_mobile/domain/command_receipts.dart'
    show CommandReceiptException;
import 'package:opencode_mobile/domain/long_term_memory.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/domain/server_gateway.dart';
import 'package:opencode_mobile/state/offline_queue.dart';
import 'package:opencode_mobile/state/steer_escrow.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A send must reach the server through one preparation path, under one
/// identity, and must be stoppable up to the moment the request leaves.
/// These tests pin the parts of that contract a fake server can observe.
class _FakeServer {
  _FakeServer();

  late final HttpServer _server;
  final calls = <String>[];
  final bodies = <String, List<Map<String, dynamic>>>{};

  /// Runs before the prompt response is written; used to hold a request open
  /// while a test cancels it.
  Future<void> Function()? onPrompt;

  /// Response body for `POST /session/{id}/prompt`.
  Map<String, dynamic> Function(String sessionID, Map<String, dynamic> body)?
  promptReceipt;

  /// Status code for `GET /session/{id}` (the permission-policy read).
  int sessionStatus = 200;

  int get port => _server.port;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final path = request.uri.path;
      calls.add('${request.method} $path');
      final raw = await utf8.decoder.bind(request).join();
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          bodies.putIfAbsent('${request.method} $path', () => []).add(decoded);
        }
      }
      request.response.headers.contentType = ContentType.json;
      if (path.endsWith('/instructions/entries/${MemoryPromptContext.key}')) {
        request.response.statusCode = 204;
      } else if (path.endsWith('/session/s')) {
        if (sessionStatus != 200) {
          request.response.statusCode = sessionStatus;
        } else {
          request.response.write(
            jsonEncode({
              'data': {
                'id': 's',
                'agent': 'build',
                'permissions': [],
                'metadata': {
                  'oc.mobile.permissionRequests': {
                    'version': 1,
                    'original': [],
                    'applied': [],
                  },
                },
              },
            }),
          );
        }
      } else if (path.endsWith('/agent/build')) {
        request.response.write(
          jsonEncode({
            'data': {'id': 'build', 'permissions': []},
          }),
        );
      } else if (path.endsWith('/prompt')) {
        await onPrompt?.call();
        final body = bodies['POST $path']?.last ?? const {};
        final sessionID = path.split('/')[path.split('/').length - 2];
        request.response.write(
          jsonEncode({
            'data':
                promptReceipt?.call(sessionID, body) ??
                {
                  'id': body['id'] ?? 'msg_server',
                  'sessionID': sessionID,
                  'type': 'user',
                  'delivery': 'steer',
                  'time': {'created': 1},
                  'payload': {'text': body['text']},
                },
          }),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);

  int countOf(String call) => calls.where((entry) => entry == call).length;
}

class _Hold implements PromptCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  @override
  bool get isCancelled => _cancelled;

  @override
  void throwIfCancelled() {
    if (_cancelled) throw const PromptCancelledException();
  }

  @override
  void Function() onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return () {};
    }
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in [..._listeners]) {
      listener();
    }
    _listeners.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('prompt receipts', () {
    test('a "user" receipt is a prompt receipt, not an unknown type', () {
      final item = Api2InboxItem.fromJson({
        'id': 'msg_1',
        'sessionID': 's',
        'type': 'user',
        'payload': {'text': 'hi'},
      })!;
      expect(item.isPrompt, isTrue);
    });

    test('the older "prompt" type still parses as a prompt receipt', () {
      final item = Api2InboxItem.fromJson({
        'id': 'msg_1',
        'sessionID': 's',
        'type': 'prompt',
      })!;
      expect(item.isPrompt, isTrue);
    });

    test('a command receipt is not a prompt receipt', () {
      final item = Api2InboxItem.fromJson({
        'id': 'msg_1',
        'sessionID': 's',
        'type': 'command',
      })!;
      expect(item.isPrompt, isFalse);
    });

    test('the nested time.created is read, not only the flat timeCreated', () {
      final nested = Api2InboxItem.fromJson({
        'id': 'msg_1',
        'type': 'user',
        'time': {'created': 1700000000000},
      })!;
      expect(nested.timeCreated, 1700000000000);
      final flat = Api2InboxItem.fromJson({
        'id': 'msg_1',
        'type': 'user',
        'timeCreated': 5,
      })!;
      expect(flat.timeCreated, 5);
    });
  });

  group('exact-ID send', () {
    late _FakeServer server;
    late Api2Client client;
    late Api2Gateway gateway;

    setUp(() async {
      // The widget binding installs an HttpClient that answers every request
      // with 400; these groups talk to a real loopback server.
      HttpOverrides.global = null;
      server = _FakeServer();
      await server.start();
      client = Api2Client.connect(
        baseUrl: server.baseUrl,
        password: '',
        directory: '/unrelated',
      );
      client.transport.settleDialect(Api2Dialect.stable);
      gateway = Api2Gateway(client: client)..serverRunsTools = (_) => true;
    });

    tearDown(() async {
      client.close();
      await server.stop();
    });

    test('the caller-chosen message ID is what the server is asked to '
        'admit', () async {
      await gateway.promptWithMessageID(
        's',
        messageID: 'msg_fixed',
        text: 'hello',
      );
      final body = server.bodies['POST /api/session/s/prompt']!.single;
      expect(body['id'], 'msg_fixed');
      expect(server.countOf('POST /api/session/s/prompt'), 1);
    });

    test('a receipt for a different message is refused', () async {
      server.promptReceipt = (_, _) => {
        'id': 'msg_something_else',
        'sessionID': 's',
        'type': 'user',
      };
      await expectLater(
        gateway.promptWithMessageID('s', messageID: 'msg_fixed', text: 'hi'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.toString(),
            'message',
            contains('different message'),
          ),
        ),
      );
    });

    test('a receipt for another session is refused', () async {
      server.promptReceipt = (_, _) => {
        'id': 'msg_fixed',
        'sessionID': 'other',
        'type': 'user',
      };
      await expectLater(
        gateway.promptWithMessageID('s', messageID: 'msg_fixed', text: 'hi'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.toString(),
            'message',
            contains('different message'),
          ),
        ),
      );
    });

    test('a command receipt is not accepted as a prompt receipt', () async {
      server.promptReceipt = (_, _) => {
        'id': 'msg_fixed',
        'sessionID': 's',
        'type': 'command',
      };
      await expectLater(
        gateway.promptWithMessageID('s', messageID: 'msg_fixed', text: 'hi'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.toString(),
            'message',
            contains('different message'),
          ),
        ),
      );
    });

    test('the exact-ID path runs the same preparation as an ordinary send: '
        'permission policy, memory, then the prompt', () async {
      gateway.memoryContext = (_) async => MemoryPromptContext(
        value: 'Only approved memory',
        isCurrent: () => true,
      );
      await gateway.promptWithMessageID(
        's',
        messageID: 'msg_fixed',
        text: 'hi',
      );
      final permission = server.calls.indexOf('GET /api/session/s');
      final memory = server.calls.indexOf(
        'PUT /api/experimental/session/s/instructions/entries/'
        '${MemoryPromptContext.key}',
      );
      final prompt = server.calls.indexOf('POST /api/session/s/prompt');
      expect(permission, greaterThanOrEqualTo(0));
      expect(memory, greaterThan(permission));
      expect(prompt, greaterThan(memory));
    });

    test('a refusal during preparation provably sent nothing', () async {
      server.sessionStatus = 500;
      await expectLater(
        gateway.promptWithMessageID('s', messageID: 'msg_fixed', text: 'hi'),
        throwsA(isA<PromptNotSentException>()),
      );
      expect(server.countOf('POST /api/session/s/prompt'), 0);
    });
  });

  group('stopping a send', () {
    late _FakeServer server;
    late Api2Client client;
    late Api2Gateway gateway;

    setUp(() async {
      // The widget binding installs an HttpClient that answers every request
      // with 400; these groups talk to a real loopback server.
      HttpOverrides.global = null;
      server = _FakeServer();
      await server.start();
      client = Api2Client.connect(
        baseUrl: server.baseUrl,
        password: '',
        directory: '/unrelated',
      );
      client.transport.settleDialect(Api2Dialect.stable);
      gateway = Api2Gateway(client: client)..serverRunsTools = (_) => true;
    });

    tearDown(() async {
      client.close();
      await server.stop();
    });

    test('a stop during the admission fence posts nothing', () async {
      final hold = _Hold();
      final fence = Completer<void>();
      gateway.beforeSessionDispatch = (_) => fence.future;
      final sending = gateway.promptWithMessageID(
        's',
        messageID: 'msg_fixed',
        text: 'hi',
        cancel: hold,
      );
      hold.cancel();
      fence.complete();
      await expectLater(sending, throwsA(isA<PromptCancelledException>()));
      expect(server.countOf('POST /api/session/s/prompt'), 0);
    });

    test('a stop after preparation but before the request posts nothing', () async {
      final hold = _Hold();
      gateway.memoryContext = (_) async {
        // The person stops while the memory sync is in flight.
        hold.cancel();
        return MemoryPromptContext(value: 'memory', isCurrent: () => true);
      };
      await expectLater(
        gateway.promptAsync('s', text: 'hi', cancel: hold),
        throwsA(isA<PromptCancelledException>()),
      );
      expect(server.countOf('POST /api/session/s/prompt'), 0);
    });

    test('a stop during the request abandons it and reports a stop, not a '
        'server error', () async {
      final hold = _Hold();
      final arrived = Completer<void>();
      final release = Completer<void>();
      server.onPrompt = () async {
        if (!arrived.isCompleted) arrived.complete();
        await release.future;
      };
      final sending = gateway.promptAsync('s', text: 'hi', cancel: hold);
      await arrived.future;
      hold.cancel();
      release.complete();
      // The request had left, so the server may hold it: the caller must not
      // read this as "nothing was sent".
      await expectLater(
        sending,
        throwsA(
          isA<PromptCancelledException>().having(
            (stop) => stop.afterDispatch,
            'afterDispatch',
            isTrue,
          ),
        ),
      );
    });

    test('a stop before the request is reported as nothing sent', () async {
      final hold = _Hold()..cancel();
      await expectLater(
        gateway.promptAsync('s', text: 'hi', cancel: hold),
        throwsA(
          isA<PromptCancelledException>().having(
            (stop) => stop.afterDispatch,
            'afterDispatch',
            isFalse,
          ),
        ),
      );
      expect(server.countOf('POST /api/session/s/prompt'), 0);
    });

    test('a send with no cancellation still works', () async {
      await gateway.promptAsync('s', text: 'hi');
      expect(server.countOf('POST /api/session/s/prompt'), 1);
    });
  });

  group('offline replay', () {
    test('the receipt transport sends through the gateway, so the '
        'preparation cannot be skipped', () async {
      final calls = <String>[];
      final gateway = _RecordingGateway(calls);
      await CommandReceiptTransport(gateway).dispatch(
        QueuedPrompt(
          id: 'queued-1',
          messageID: 'msg_stable',
          profileID: 'p',
          sessionID: 's',
          text: 'offline words',
          createdAt: 1,
        ),
        'msg_stable',
      );
      expect(calls, ['prepare+send:msg_stable']);
    });

    test('a gateway that cannot take an exact ID is refused rather than '
        'sent by another route', () async {
      final transport = CommandReceiptTransport(_PlainGateway());
      await expectLater(
        transport.dispatch(
          QueuedPrompt(
            id: 'queued-1',
            profileID: 'p',
            sessionID: 's',
            text: 'x',
            createdAt: 1,
          ),
          'msg_stable',
        ),
        throwsA(isA<CommandReceiptException>()),
      );
    });
  });

  group('queued prompt identity', () {
    test('a message ID survives a persistence round trip', () {
      final entry = QueuedPrompt(
        id: 'queued-1',
        messageID: 'msg_stable',
        profileID: 'p',
        sessionID: 's',
        text: 'words',
        createdAt: 1,
      );
      final restored = QueuedPrompt.fromJson(entry.toJson())!;
      expect(restored.messageID, 'msg_stable');
      expect(restored.resolvedMessageID, 'msg_stable');
    });

    test('a retry of the same entry keeps one identity', () {
      final entry = QueuedPrompt(
        id: 'queued-1',
        messageID: 'msg_stable',
        profileID: 'p',
        sessionID: 's',
        text: 'words',
        createdAt: 1,
      );
      expect(entry.withDispatchedAt(9).resolvedMessageID, 'msg_stable');
      expect(entry.withError('x').resolvedMessageID, 'msg_stable');
    });

    test('an entry written before IDs existed keeps its own, minted once', () {
      final entry = QueuedPrompt.fromJson({
        'id': 'queued-1',
        'profileID': 'p',
        'sessionID': 's',
        'text': 'words',
        'createdAt': 1,
      })!;
      expect(entry.messageID, isNull);
      final minted = entry.resolvedMessageID;
      expect(minted, startsWith('msg_'));
      expect(entry.withMessageID(minted).resolvedMessageID, minted);
    });
  });

  group('steer escrow', () {
    late SharedPreferences prefs;
    late SteerEscrowStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = SteerEscrowStore(prefs: prefs);
    });

    test('held text survives a restart and is scoped to its session', () async {
      await store.add(
        const SteerEscrowEntry(
          id: 'inbox-1',
          sessionID: 's',
          text: 'taken back',
          at: 1,
        ),
      );
      await store.add(
        const SteerEscrowEntry(
          id: 'inbox-2',
          sessionID: 'other',
          text: 'elsewhere',
          at: 2,
        ),
      );
      final reopened = SteerEscrowStore(prefs: prefs);
      expect(
        reopened.read().where((entry) => entry.sessionID == 's').single.text,
        'taken back',
      );
    });

    test('the same inbox item is not escrowed twice', () async {
      await store.add(
        const SteerEscrowEntry(id: 'i', sessionID: 's', text: 'a', at: 1),
      );
      await store.add(
        const SteerEscrowEntry(id: 'i', sessionID: 's', text: 'b', at: 2),
      );
      expect(store.read().single.text, 'b');
    });

    test('releasing one item leaves the others held', () async {
      await store.add(
        const SteerEscrowEntry(id: 'i', sessionID: 's', text: 'a', at: 1),
      );
      await store.add(
        const SteerEscrowEntry(id: 'j', sessionID: 's', text: 'b', at: 2),
      );
      await store.remove('i');
      expect(store.read().map((entry) => entry.id), ['j']);
    });

    test('releasing a session clears exactly that session', () async {
      await store.add(
        const SteerEscrowEntry(id: 'i', sessionID: 's', text: 'a', at: 1),
      );
      await store.add(
        const SteerEscrowEntry(id: 'j', sessionID: 't', text: 'b', at: 2),
      );
      await store.removeSession('s');
      expect(store.read().map((entry) => entry.id), ['j']);
    });

    test('unreadable stored data reports itself instead of claiming a hold',
        () async {
      await prefs.setString('oc.steerEscrow', '{not json');
      final reopened = SteerEscrowStore(prefs: prefs);
      expect(reopened.read(), isEmpty);
      expect(reopened.readable, isFalse);
    });
  });
}

/// Records that the exact-ID path is the one taken.
class _RecordingGateway implements ServerGateway, CorrelatedPromptGateway {
  _RecordingGateway(this.calls);
  final List<String> calls;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(
    commandReceipts: true,
  );

  @override
  bool get isClosed => false;

  @override
  String? get directory => null;

  @override
  String? get workspace => null;

  @override
  String createPromptMessageID() => 'msg_created';

  @override
  Future<void> promptWithMessageID(
    String sessionID, {
    required String messageID,
    required String text,
    ModelRef? model,
    String? agent,
    String? variant,
    List<PromptAttachment> attachments = const [],
    List<PromptAgentMention> agentMentions = const [],
    PromptDelivery? delivery,
    void Function()? beforeSend,
    PromptCancellation? cancel,
  }) async {
    beforeSend?.call();
    calls.add('prepare+send:$messageID');
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A gateway with no exact-ID capability.
class _PlainGateway implements ServerGateway {
  @override
  ServerCapabilities get capabilities => const ServerCapabilities(
    commandReceipts: true,
  );

  @override
  bool get isClosed => false;

  @override
  String? get directory => null;

  @override
  String? get workspace => null;

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
