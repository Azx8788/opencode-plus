import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/api2/server_config_reload.dart';

void main() {
  test('reload is scoped to the active directory and workspace', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Uri>();
    final subscription = server.listen((request) async {
      received.complete(request.uri);
      request.response.statusCode = 204;
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });
    expect(await reloadServerConfig(
      baseUrl: 'http://127.0.0.1:${server.port}', password: '',
      directory: '/root/projects/my project', workspace: 'workspace-123',
    ), isTrue);
    final uri = await received.future;
    expect(uri.path, '/api/location/reload');
    expect(uri.queryParameters['location[directory]'], '/root/projects/my project');
    expect(uri.queryParameters['location[workspace]'], 'workspace-123');
  });
}
