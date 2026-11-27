/// The manager model, spoken to over the OpenAI-compatible Chat Completions
/// wire format.
///
/// This is deliberately the smallest client that can do tool calls: one POST,
/// no streaming, one retry for transient failures. The manager is not on the
/// hot path of a conversation — a slow or failed call falls back to the plain
/// relay, which is what the app did before the manager existed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One tool call the model asked for.
class ManagerToolCall {
  const ManagerToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, Object?> arguments;
}

/// One assistant turn: what it said, and what it wants run.
class ManagerModelReply {
  const ManagerModelReply({this.content, this.toolCalls = const []});

  final String? content;
  final List<ManagerToolCall> toolCalls;

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// A call that did not produce a reply, with a message a person can read.
class ManagerModelError implements Exception {
  const ManagerModelError(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

class ManagerModelClient {
  ManagerModelClient({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 60),
    this.maxTokens,
    this.temperature,
    this.retryDelay = const Duration(milliseconds: 600),
    HttpClient? httpClient,
  }) : _client = httpClient ?? HttpClient();

  /// Either `https://host/v1` or the full `…/chat/completions` URL.
  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;
  final int? maxTokens;
  final double? temperature;
  final Duration retryDelay;

  final HttpClient _client;

  Uri get endpoint {
    final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.endsWith('/chat/completions')) return Uri.parse(trimmed);
    return Uri.parse('$trimmed/chat/completions');
  }

  Future<ManagerModelReply> complete({
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>> tools,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const ManagerModelError('管理模型还没有配置 API Key。');
    }
    final body = jsonEncode({
      'model': model,
      'messages': messages,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (temperature != null) 'temperature': temperature,
    });

    for (var attempt = 0; ; attempt++) {
      try {
        return await _post(body);
      } on ManagerModelError catch (error) {
        if (!error.retryable || attempt != 0) rethrow;
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  Future<ManagerModelReply> _post(String body) async {
    final deadline = Stopwatch()..start();
    Duration remaining() => timeout - deadline.elapsed;
    HttpClientRequest? request;
    try {
      request = await _client.postUrl(endpoint).timeout(timeout);
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..contentType = ContentType.json;
      request.write(body);
      final response = await request.close().timeout(remaining());
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(remaining());
      final status = response.statusCode;
      if (status < 200 || status >= 300) {
        throw ManagerModelError(
          '管理模型返回 $status：${_short(text)}',
          retryable: status == 429 || status >= 500,
        );
      }
      return _parse(text);
    } on TimeoutException {
      request?.abort();
      throw const ManagerModelError('管理模型响应超时。');
    } on ManagerModelError {
      rethrow;
    } on SocketException catch (error) {
      throw ManagerModelError('无法连接管理模型：${error.message}', retryable: true);
    } on HttpException catch (error) {
      throw ManagerModelError('管理模型连接中断：${error.message}', retryable: true);
    } on Object catch (error) {
      throw ManagerModelError('管理模型请求失败：$error');
    }
  }

  ManagerModelReply _parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw ManagerModelError('管理模型返回的不是 JSON：${_short(text)}');
    }
    if (decoded is! Map) {
      throw const ManagerModelError('管理模型返回的结构无法识别。');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const ManagerModelError('管理模型没有返回任何候选结果。');
    }
    final first = choices.first;
    final message = first is Map ? first['message'] : null;
    if (message is! Map) {
      throw const ManagerModelError('管理模型返回里没有 message。');
    }
    final content = message['content']?.toString();
    final calls = <ManagerToolCall>[];
    final rawCalls = message['tool_calls'];
    if (rawCalls is List) {
      for (final raw in rawCalls) {
        if (raw is! Map) continue;
        final function = raw['function'];
        if (function is! Map) continue;
        final name = function['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final arguments = function['arguments'];
        Map<String, Object?> parsed = const {};
        if (arguments is String && arguments.trim().isNotEmpty) {
          try {
            final value = jsonDecode(arguments);
            if (value is Map) parsed = Map<String, Object?>.from(value);
          } on FormatException {
            parsed = const {};
          }
        } else if (arguments is Map) {
          parsed = Map<String, Object?>.from(arguments);
        }
        calls.add(
          ManagerToolCall(
            id: raw['id']?.toString() ?? 'call-${calls.length}',
            name: name,
            arguments: parsed,
          ),
        );
      }
    }
    if ((content == null || content.trim().isEmpty) && calls.isEmpty) {
      throw const ManagerModelError('管理模型返回了空回复。');
    }
    return ManagerModelReply(content: content?.trim(), toolCalls: calls);
  }

  void close() => _client.close(force: true);

  static String _short(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';
}
