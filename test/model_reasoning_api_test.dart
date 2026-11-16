import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/gateway.dart';
import 'package:opencode_mobile/domain/models.dart';

void main() {
  test('selected Max is actually sent to the server session-model endpoint', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Map<String, dynamic>>();
    final subscription = server.listen((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/session/session-123/model');
      received.complete(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response.statusCode = 204;
      await request.response.close();
    });
    final gateway = Api2Gateway.connect(
      baseUrl: 'http://127.0.0.1:${server.port}',
      password: '',
    );
    addTearDown(() async {
      gateway.close();
      await subscription.cancel();
      await server.close(force: true);
    });
    await gateway.setSessionModel(
      'session-123',
      ModelRef(providerID: 'new-proxy', modelID: 'opaque-model'),
      'max',
    );
    expect(await received.future, {
      'model': {'id': 'opaque-model', 'providerID': 'new-proxy', 'variant': 'max'},
    });
  });
}
