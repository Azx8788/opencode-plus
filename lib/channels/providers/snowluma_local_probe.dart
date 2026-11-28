import 'dart:convert';
import 'dart:io';

/// Local reachability only. Neither result verifies QQ sign-in or OneBot auth.
class SnowLumaLocalAvailability {
  const SnowLumaLocalAvailability({
    required this.consoleRecognized,
    required this.oneBotPortOpen,
  });

  final bool consoleRecognized;
  final bool oneBotPortOpen;

  bool get canSuggestAddress => consoleRecognized && oneBotPortOpen;
}

/// Checks the default ports of an independently started SnowLuma. This does
/// not install, start or configure any service, nor read login files or tokens.
class SnowLumaLocalProbe {
  const SnowLumaLocalProbe({
    this.consolePort = 5099,
    this.oneBotPort = 3001,
    this.timeout = const Duration(seconds: 2),
  });

  static const defaultWebSocketUrl = 'ws://127.0.0.1:3001/';
  static const _loopback = '127.0.0.1';
  static const _maxPageBytes = 8192;

  final int consolePort;
  final int oneBotPort;
  final Duration timeout;

  Future<SnowLumaLocalAvailability> check() async {
    final (console, port) = await (_recognizeConsole(), _checkPort()).wait;
    return SnowLumaLocalAvailability(
      consoleRecognized: console,
      oneBotPortOpen: port,
    );
  }

  Future<bool> _recognizeConsole() async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      final uri = Uri(
        scheme: 'http',
        host: _loopback,
        port: consolePort,
        path: '/',
      );
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok ||
          response.headers.contentType?.mimeType != 'text/html') {
        return false;
      }
      final page = await _pagePrefix(response).timeout(timeout);
      return RegExp(
        r'<title>\s*SnowLuma(?:\s+(?:控制台|WebUI))?\s*</title>',
        caseSensitive: false,
      ).hasMatch(page);
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _pagePrefix(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk.take(_maxPageBytes - bytes.length));
      if (bytes.length >= _maxPageBytes) break;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<bool> _checkPort() async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        oneBotPort,
        timeout: timeout,
      );
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }
}
