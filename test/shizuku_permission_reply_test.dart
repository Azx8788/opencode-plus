import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/client.dart';
import 'package:opencode_mobile/api2/dialect.dart';
import 'package:opencode_mobile/api2/gateway.dart';
import 'package:opencode_mobile/domain/models.dart';

void main() {
  for (final dialect in Api2Dialect.values) {
    test('Shizuku rejection feedback (${dialect.name})', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final calls = <({String method, String path, Object? body})>[];
      final sub = server.listen((request) async {
        final raw = await utf8.decoder.bind(request).join();
        calls.add((
          method: request.method,
          path: request.uri.path,
          body: raw.isEmpty ? null : jsonDecode(raw),
        ));
        request.response.statusCode = 204;
        await request.response.close();
      });
      final client = Api2Client.connect(
        baseUrl: 'http://127.0.0.1:${server.port}',
        password: '',
      );
      client.transport.settleDialect(dialect);
      addTearDown(() async {
        client.close();
        await sub.cancel();
        await server.close(force: true);
      });
      final gateway = Api2Gateway(client: client);
      final replyKey = dialect == Api2Dialect.stable ? 'decision' : 'reply';
      const defaultFeedback =
          'The user declined this Android shell request. Do not retry it '
          'or perform the same action through another channel.';
      final cases = <(String, String, String?, String?)>[
        ('shizuku', 'reject', null, defaultFeedback),
        ('shizuku', 'reject', '  ', defaultFeedback),
        ('shizuku', 'reject', '不要改动那个文件', '不要改动那个文件'),
        ('shizuku', 'once', null, null),
        ('shizuku', 'always', null, null),
        ('shizuku_result', 'reject', null, null),
        ('shell', 'reject', null, null),
      ];
      for (final (index, (action, reply, note, feedback)) in cases.indexed) {
        final permission = PermissionRequest(
          id: 'request-$index',
          sessionID: 'session-1',
          permission: action,
        );
        await gateway.respondToPermissionRequest(
          permission,
          reply,
          message: note,
        );
        expect(calls, hasLength(index + 1));
        expect(calls.last.method, 'POST');
        expect(
          calls.last.path,
          '/api/session/session-1/permission/request-$index/reply',
        );
        expect(calls.last.body, {replyKey: reply, 'message': ?feedback});
      }
    });
  }
}
