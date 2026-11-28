import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/channels/providers/snowluma_local_probe.dart';

void main() {
  test('recognizes the published WebUI title and a TCP listener', () async {
    final webUi = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => webUi.close(force: true));
    webUi.listen((request) async {
      expect(request.uri.path, '/');
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      request.response.headers.contentType = ContentType.html;
      request.response.write('<html><title>SnowLuma 控制台</title></html>');
      await request.response.close();
    });
    final oneBot = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(oneBot.close);
    oneBot.listen((peer) => peer.destroy());

    final result = await SnowLumaLocalProbe(
      consolePort: webUi.port,
      oneBotPort: oneBot.port,
    ).check();

    expect(result.consoleRecognized, isTrue);
    expect(result.oneBotPortOpen, isTrue);
    expect(result.canSuggestAddress, isTrue);
  });

  test('unrelated HTML or redirects never suggest a OneBot address', () async {
    final webUi = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => webUi.close(force: true));
    final requested = <String>[];
    var redirect = false;
    webUi.listen((request) async {
      requested.add(request.uri.path);
      if (request.uri.path == '/' && redirect) {
        await request.response.redirect(Uri(path: '/snowluma'));
        return;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        request.uri.path == '/'
            ? '<title>Something else</title>'
            : '<title>SnowLuma 控制台</title>',
      );
      await request.response.close();
    });
    final probe = SnowLumaLocalProbe(
      consolePort: webUi.port,
      oneBotPort: webUi.port,
    );

    final unrelated = await probe.check();
    redirect = true;
    final redirected = await probe.check();

    expect(unrelated.oneBotPortOpen, isTrue);
    expect(redirected.oneBotPortOpen, isTrue);
    expect(unrelated.canSuggestAddress, isFalse);
    expect(redirected.canSuggestAddress, isFalse);
    expect(requested, ['/', '/']);
  });
}
