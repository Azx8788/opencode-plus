import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/channel_provider.dart';
import 'package:opencode_mobile/channels/providers/telegram_provider.dart';

const _token = '123456789:fixture-bot-token-never-render';

/// A real HTTP transport, including lost response headers and keep-alive.
class _Api {
  _Api(this.server) {
    server.listen(_handle);
  }

  final HttpServer server;
  final polls = <({String method, Map<String, dynamic> values, int? port})>[];
  int? maxWait;
  int? pollError;
  String? pollErrorDescription;
  int? chatError;
  bool malformed = false;
  int dropped = 0;

  String get origin => 'http://127.0.0.1:${server.port}';

  Future<void> _handle(HttpRequest request) async {
    final method = request.uri.pathSegments.last;
    final body = await utf8.decoder.bind(request).join();
    final values = body.isEmpty
        ? <String, dynamic>{...request.uri.queryParameters}
        : jsonDecode(body) as Map<String, dynamic>;
    Object result = true;
    int? error;
    if (method == 'getMe') {
      result = {'is_bot': true, 'username': 'fixture_bot'};
    } else if (method == 'getChat') {
      result = {'id': 424242, 'type': 'private'};
      error = chatError;
    } else if (method == 'getUpdates') {
      polls.add((
        method: request.method,
        values: values,
        port: request.connectionInfo?.remotePort,
      ));
      final wait = int.parse('${values['timeout']}');
      if (maxWait != null && wait > maxWait!) {
        dropped++;
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      // Do not spin when the test server has no messages.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      error = pollError;
      result = [
        // Repeats the same update even after acknowledgement to exercise the
        // receiver's offset guard across shorter polls and reconnections.
        {
          'update_id': 101,
          'message': {
            'message_id': 1,
            'date': 1700000000,
            'text': 'hello',
            'chat': {'id': 424242, 'type': 'private'},
            'from': {'id': 424242, 'is_bot': false},
          },
        },
      ];
    }
    request.response.headers.contentType = ContentType.json;
    if (error != null) {
      request.response.statusCode = error;
      request.response.write(
        jsonEncode({
          'ok': false,
          'error_code': error,
          'description': method == 'getUpdates'
              ? pollErrorDescription ?? 'fixture error'
              : error == 400
              ? 'Bad Request: chat not found'
              : 'fixture error',
        }),
      );
    } else if (malformed && method == 'getUpdates') {
      request.response.write('<html>not an API response</html>');
    } else {
      request.response.write(jsonEncode({'ok': true, 'result': result}));
    }
    await request.response.close();
  }
}

/// Injects typed connect failures without a DNS lookup or a 12-second timeout.
class _FailingClient implements HttpClient {
  _FailingClient(this.error, {this.afterConnect = false});
  final Object error;

  /// True opens the request and fails while waiting for the response, the way
  /// a dropped long poll does; false fails before the socket is established.
  final bool afterConnect;
  @override
  Future<HttpClientRequest> postUrl(Uri uri) async =>
      afterConnect ? _FailingRequest(error) : throw error;
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FailingRequest implements HttpClientRequest {
  _FailingRequest(this.error);
  final Object error;
  @override
  HttpHeaders get headers => _Headers();
  @override
  Future<HttpClientResponse> close() async => throw error;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Receive condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late _Api api;
  late TelegramProvider provider;

  setUp(() async {
    api = _Api(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    provider = TelegramProvider(
      accountId: 'fixture',
      token: _token,
      chatId: '424242',
      apiOrigin: () => api.origin,
      maxBackoff: const Duration(milliseconds: 30),
    );
  });

  tearDown(() async {
    await provider.dispose();
    await api.server.close(force: true);
  });

  test(
    'token verification can pass while receiving fails, then shorter polls recover once',
    () async {
      api.maxWait = 5;
      final notice = await provider.probe();
      expect(notice, contains('Token 验证成功'));
      expect(notice, contains('不验证消息接收'));
      final messages = <InboundChannelMessage>[];
      final errors = <String>[];
      final events = provider.events.listen((event) {
        if (event is InboundChannelMessage) messages.add(event);
        if (event is ProviderStatusChanged && event.status.lastError != null) {
          errors.add(event.status.lastError!);
        }
      });
      addTearDown(events.cancel);
      await provider.connect();
      await _until(() => api.polls.length >= 5);

      expect(api.dropped, 2);
      expect(api.polls.take(5).map((p) => p.values['timeout']), [
        25,
        10,
        5,
        5,
        5,
      ]);
      expect(api.polls.every((p) => p.method == 'POST'), isTrue);
      expect(api.polls.first.values['allowed_updates'], ['message']);
      expect(api.polls.last.values['offset'], 102);
      expect(messages, hasLength(1));
      expect(provider.offset, 102);
      expect(provider.status.state, ProviderState.online);
      expect(provider.status.lastError, isNull);
      expect(provider.status.consecutiveFailures, 0);
      expect(errors.first, contains('getUpdates'));
      expect(errors.first, contains('10 秒'));
      expect(errors.last, contains('5 秒'));
      expect(errors.join(), isNot(contains(_token)));
      // The recovered connection is reused, not another TLS handshake per poll.
      expect(api.polls.skip(2).map((p) => p.port).toSet(), hasLength(1));

      await provider.disconnect();
      final pollsBefore = api.polls.length;
      provider.resumeReceiving();
      await _until(() => api.polls.length > pollsBefore);
      final resumed = api.polls[pollsBefore].values;
      expect(resumed['timeout'], 5);
      expect(resumed['offset'], 102);
    },
  );

  for (final code in [401, 409, 429]) {
    test(
      'API $code is not mistaken for a long-poll transport failure',
      () async {
        api.pollError = code;
        await provider.connect();
        await _until(() => api.polls.length >= 2);
        expect(api.polls.every((p) => p.values['timeout'] == 25), isTrue);
        expect(provider.status.state, ProviderState.reconnecting);
        expect(provider.status.lastError, isNot(contains('检查网络')));
        expect(provider.status.lastError, isNot(contains('将改用')));
      },
    );
  }

  test(
    'an invalid successful response names getUpdates instead of blaming connectivity',
    () async {
      api.malformed = true;
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      await expectLater(
        provider.readUpdates(client: client, wait: const Duration(seconds: 1)),
        throwsA(
          isA<TelegramFailure>()
              .having(
                (e) => e.message,
                'message',
                contains('getUpdates：返回了无法识别'),
              )
              .having(
                (e) => e.canShortenPoll,
                'no transport fallback',
                isFalse,
              ),
        ),
      );
    },
  );

  test('a gateway failure exposes its code, never the raw response', () async {
    api.pollError = 504;
    api.pollErrorDescription =
        'Upstream: https://api.telegram.org/bot$_token/getUpdates';
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await expectLater(
      provider.readUpdates(client: client, wait: const Duration(seconds: 25)),
      throwsA(
        isA<TelegramFailure>()
            .having((e) => e.canShortenPoll, 'gateway timeout', isTrue)
            .having((e) => e.message, 'code', contains('504'))
            .having(
              (e) => e.message,
              'raw response',
              isNot(contains('Upstream')),
            )
            .having((e) => e.message, 'secret', isNot(contains(_token))),
      ),
    );
  });

  test(
    'a getChat failure is not mislabeled as a missing private chat',
    () async {
      api.chatError = 503;
      await expectLater(
        provider.probe(),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'stage', contains('getChat'))
              .having(
                (e) => e.message,
                'not missing chat',
                isNot(contains('/start')),
              ),
        ),
      );
      api.chatError = 400;
      expect(await provider.probe(), contains('/start'));
    },
  );

  test(
    'a dropped response permits shorter polling and names the receive stage',
    () async {
      await expectLater(
        provider.readUpdates(
          client: _FailingClient(
            TimeoutException('$_token raw timeout'),
            afterConnect: true,
          ),
          wait: const Duration(seconds: 25),
        ),
        throwsA(
          isA<TelegramFailure>()
              .having((e) => e.canShortenPoll, 'adaptive receive', isTrue)
              .having((e) => e.message, 'stage', contains('getUpdates：等待响应超时'))
              .having((e) => e.message, 'secret', isNot(contains(_token))),
        ),
      );
    },
  );

  for (final (error, label) in <(Object, String)>[
    (TimeoutException('$_token raw timeout'), '建立连接超时'),
    (const HandshakeException('$_token certificate'), 'TLS'),
    (const SocketException('Failed host lookup $_token'), 'DNS'),
    (const SocketException('Connection refused $_token'), '无法建立连接'),
  ]) {
    test(
      'connect error $label is specific and contains no credential',
      () async {
        await HttpOverrides.runZoned(() async {
          await expectLater(
            provider.probe(),
            throwsA(
              isA<FormatException>()
                  .having((e) => e.message, 'stage', contains('getMe'))
                  .having((e) => e.message, 'reason', contains(label))
                  .having((e) => e.message, 'secret', isNot(contains(_token))),
            ),
          );
        }, createHttpClient: (_) => _FailingClient(error));
      },
    );
  }

  test('disconnect cancels retry and an old receiver never resumes', () async {
    api.pollError = 409;
    await provider.connect();
    await _until(() => provider.status.state == ProviderState.reconnecting);
    await provider.disconnect();
    final count = api.polls.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(api.polls, hasLength(count));
    expect(provider.status.state, ProviderState.disabled);
  });
}
