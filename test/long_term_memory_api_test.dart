import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/client.dart';
import 'package:opencode_mobile/api2/dialect.dart';
import 'package:opencode_mobile/api2/gateway.dart';
import 'package:opencode_mobile/api2/memory.dart';
import 'package:opencode_mobile/domain/long_term_memory.dart';

void main() {
  test('memory synchronization precedes prompt; only its own entry is replaced/removed', () async {
    final calls = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? entry;
    var rejectMemory = false;
    final sub = server.listen((r) async {
      calls.add('${r.method} ${r.uri.path}');
      r.response.headers.contentType = ContentType.json;
      if (r.uri.path.endsWith(
        '/instructions/entries/${MemoryPromptContext.key}',
      )) {
        expect(
          r.uri.queryParameters.keys.any((key) => key.startsWith('location')),
          isFalse,
        );
        if (rejectMemory) {
          r.response.statusCode = 501;
        } else if (r.method == 'DELETE') {
          entry = null;
          r.response.statusCode = 204;
        } else {
          final body = jsonDecode(await utf8.decoder.bind(r).join());
          entry = body['value'];
          r.response.statusCode = 204;
        }
      } else if (r.uri.path.endsWith('/session/s')) {
        r.response.write(
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
      } else if (r.uri.path.endsWith('/agent/build')) {
        r.response.write(
          jsonEncode({
            'data': {'id': 'build', 'permissions': []},
          }),
        );
      } else if (r.uri.path.endsWith('/prompt')) {
        final body = jsonDecode(await utf8.decoder.bind(r).join());
        expect(body['text'], 'Original user text');
        expect(entry, 'Only approved memory');
        r.response.write(
          jsonEncode({
            'data': {
              'id': 'inbox-1',
              'sessionID': 's',
              'type': 'user',
              'delivery': 'queue',
              'status': 'pending',
              'time': {'created': 1},
              'payload': {'text': 'Original user text'},
            },
          }),
        );
      } else {
        r.response.statusCode = 404;
      }
      await r.response.close();
    });
    final client = Api2Client.connect(
      baseUrl: 'http://127.0.0.1:${server.port}',
      password: '',
      directory: '/unrelated',
    );
    client.transport.settleDialect(Api2Dialect.stable);
    addTearDown(() async {
      client.close();
      await sub.cancel();
      await server.close(force: true);
    });
    final gateway = Api2Gateway(client: client);
    var acknowledged = 0;
    gateway.onPromptDispatched = (_, _, _, _) => acknowledged++;
    gateway.serverRunsTools = (_) => true;
    gateway.memoryContext = (_) async => MemoryPromptContext(
      value: 'Only approved memory',
      isCurrent: () => true,
    );
    await gateway.promptAsync('s', text: 'Original user text');
    expect(acknowledged, 1);
    expect(
      calls.indexOf(
        'PUT /api/experimental/session/s/instructions/entries/${MemoryPromptContext.key}',
      ),
      lessThan(calls.indexOf('POST /api/session/s/prompt')),
    );
    expect(calls.any((c) => c.contains('mobile.note')), isFalse);
    await Api2Memory(client).sync(
      's',
      (_) async => MemoryPromptContext(value: null, isCurrent: () => true),
    );
    expect(entry, isNull);
    rejectMemory = true;
    final sent = calls.where((c) => c.endsWith('/prompt')).length;
    await expectLater(
      gateway.promptAsync('s', text: 'Original user text'),
      throwsA(isA<MemoryException>()),
    );
    expect(calls.where((c) => c.endsWith('/prompt')).length, sent);
    expect(acknowledged, 1, reason: 'Failed preflight is not a sent request');
  });

  test('changing memory during synchronization is reconciled before sending', () async {
    final calls = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var revision = 1;
    final sub = server.listen((r) async {
      calls.add(r.method);
      expect(
        r.uri.path,
        '/api/experimental/session/s/instructions/entries/${MemoryPromptContext.key}',
      );
      if (r.method == 'PUT') {
        revision = 2;
      }
      r.response.statusCode = 204;
      await r.response.close();
    });
    final client = Api2Client.connect(
      baseUrl: 'http://127.0.0.1:${server.port}',
      password: '',
    );
    client.transport.settleDialect(Api2Dialect.stable);
    addTearDown(() async {
      client.close();
      await sub.cancel();
      await server.close(force: true);
    });
    await Api2Memory(client).sync('s', (_) async {
      final captured = revision;
      return MemoryPromptContext(
        value: captured == 1 ? 'Old memory' : null,
        isCurrent: () => captured == revision,
      );
    });
    expect(calls, ['PUT', 'DELETE']);
  });
}
