import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../channel_capabilities.dart';
import '../channel_message.dart';
import '../channel_provider.dart';

/// Telegram's Bot API transport, with no opinion about agents.
///
/// Long polling is the only receive mechanism here: it needs no public HTTPS
/// endpoint, which is the whole reason the relay works from a phone. The
/// provider's job ends at "an update arrived" and "send this text".
class TelegramProvider extends ChannelProviderBase {
  TelegramProvider({
    required super.accountId,
    required this.token,
    required this.chatId,
    required String Function() apiOrigin,
    this.onOffset,
    this.pollTimeout = const Duration(seconds: 25),
    this.maxBackoff = const Duration(seconds: 60),
  }) : _apiOrigin = apiOrigin,
       super(providerId: ChannelProviderIds.telegram);

  final String token;
  final String chatId;
  final String Function() _apiOrigin;
  final Future<void> Function(int offset)? onOffset;
  final Duration pollTimeout;
  final Duration maxBackoff;

  static const declaredCapabilities = ChannelCapabilities({
    ChannelCapability.directMessage: CapabilitySpec(
      CapabilityStatus.native,
      note: '私聊由 Bot API 原生支持；机器人不能主动发起会话。',
    ),
    ChannelCapability.groupMessage: CapabilitySpec(
      CapabilityStatus.unverified,
      note: '本渠道当前只配置一个私聊会话，群聊未启用。',
    ),
    ChannelCapability.activeMessage: CapabilitySpec(
      CapabilityStatus.unsupported,
      note: 'Telegram 禁止机器人主动向未开始的私聊发消息。',
    ),
    ChannelCapability.passiveReply: CapabilitySpec(CapabilityStatus.native),
    ChannelCapability.image: CapabilitySpec(
      CapabilityStatus.application,
      note: '当前只发送纯文本。',
    ),
    ChannelCapability.file: CapabilitySpec.unsupported('当前只发送纯文本。'),
    ChannelCapability.voice: CapabilitySpec.unsupported('当前只发送纯文本。'),
    ChannelCapability.messageReply: CapabilitySpec(CapabilityStatus.native),
    ChannelCapability.messageEdit: CapabilitySpec(
      CapabilityStatus.unverified,
      note: '进度更新以新消息发送，不编辑旧消息。',
    ),
    ChannelCapability.messageRecall: CapabilitySpec.unsupported(),
    ChannelCapability.messageQuery: CapabilitySpec(CapabilityStatus.native),
    ChannelCapability.longText: CapabilitySpec(
      CapabilityStatus.application,
      note: '按 3500 UTF-16 单元分段发送。',
      limit: '每段 3500 个 UTF-16 单元（平台上限 4096）',
    ),
  });

  @override
  ChannelCapabilities get capabilities => declaredCapabilities;

  bool _running = false;
  int _generation = 0;
  HttpClient? _http;
  int _consecutiveFailures = 0;
  String? _botUsername;

  /// The bot's @username once `getMe` has answered, used to recognise a
  /// mention in group text.
  String? get botUsername => _botUsername;

  /// The last long-poll offset. The bridge persists it so a restart does not
  /// replay an update whose prompt may already have been sent.
  int? offset;

  @override
  Future<void> connect() async {
    if (isClosed) return;
    if (token.isEmpty || chatId.isEmpty) {
      publishStatus(
        ProviderState.needsSetup,
        detail: '缺少 Bot Token 或用户 ID',
        clearError: true,
      );
      return;
    }
    if (_running) return;
    _running = true;
    final generation = ++_generation;
    unawaited(_pollLoop(generation));
  }

  @override
  Future<void> disconnect() async {
    _running = false;
    _generation++;
    _http?.close(force: true);
    _http = null;
    if (!isClosed) {
      publishStatus(ProviderState.disabled, detail: '已断开');
    }
  }

  Future<void> _pollLoop(int generation) async {
    publishStatus(ProviderState.connecting, clearError: true);
    final setup = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    _http = setup;
    try {
      await _prepareBot(setup, generation);
    } finally {
      if (identical(_http, setup)) _http = null;
      setup.close(force: true);
    }
    while (_running && generation == _generation && !isClosed) {
      final http = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      _http = http;
      try {
        final updates = await readUpdates(
          client: http,
          offset: offset,
          wait: pollTimeout,
        );
        if (!_running || generation != _generation) break;
        if (status.state != ProviderState.online) {
          publishStatus(ProviderState.online, clearError: true);
        }
        _consecutiveFailures = 0;
        for (final (updateID, message) in updates) {
          if (offset != null && updateID < offset!) continue;
          // Advance before dispatch: a process death cannot replay a prompt
          // whose delivery to OpenCode may already have succeeded.
          await onOffset?.call(updateID + 1);
          if (!_running || generation != _generation) break;
          offset = updateID + 1;
          if (message != null &&
              message.conversationType == ChannelConversationKind.direct &&
              message.conversationId == chatId &&
              message.senderId == chatId &&
              message.extensions['sender_is_bot'] != true) {
            emitMessage(message);
          }
        }
      } on Object catch (error) {
        if (!_running || generation != _generation || isClosed) break;
        _consecutiveFailures = (_consecutiveFailures + 1).clamp(1, 6);
        final text = error is TelegramFailure
            ? error.message
            : '与 Telegram 的连接中断，正在重试。';
        publishStatus(
          ProviderState.reconnecting,
          lastError: text,
          consecutiveFailures: _consecutiveFailures,
        );
        final seconds = (1 << _consecutiveFailures).clamp(
          5,
          maxBackoff.inSeconds,
        );
        await Future<void>.delayed(Duration(seconds: seconds));
      } finally {
        if (identical(_http, http)) _http = null;
        http.close(force: true);
      }
    }
    if (generation == _generation && !isClosed) {
      publishStatus(ProviderState.disabled, detail: '已停止轮询');
    }
  }

  /// Claims the bot for long polling and gives it a visible command menu.
  ///
  /// A webhook left behind by another setup answers `getUpdates` with 409 and
  /// the relay would look "connected but deaf", so removing it is part of
  /// starting up. Both calls are best-effort: a network hiccup here must not
  /// stop the poll loop, which reports its own failures.
  Future<void> _prepareBot(HttpClient client, int generation) async {
    try {
      await _request('deleteWebhook', const {
        'drop_pending_updates': false,
      }, client: client);
    } on Object {
      // getUpdates still reports 409 if a webhook really is in the way.
    }
    if (!_running || generation != _generation) return;
    try {
      await _request('setMyCommands', const {
        'commands': [
          {'command': 'status', 'description': '查看连接与会话状态'},
          {'command': 'stop', 'description': '停止当前 Agent 任务'},
          {'command': 'new', 'description': '开始新的 Agent 会话'},
          {'command': 'queue', 'description': '排队下一条 Agent 指令'},
          {'command': 'help', 'description': '显示使用说明'},
        ],
      }, client: client);
    } on Object {
      // The menu is a convenience; commands work when typed.
    }
  }

  /// A bounded getUpdates call. Setup uses this without starting the relay or
  /// deleting a webhook, and handles only the expected pairing command.
  Future<List<(int, ChannelMessage?)>> readUpdates({
    required HttpClient client,
    required Duration wait,
    int? offset,
  }) async {
    final result = await _request(
      'getUpdates',
      {
        'timeout': '${wait.inSeconds}',
        'allowed_updates': '["message"]',
        if (offset != null) 'offset': '$offset',
      },
      get: true,
      timeout: wait + const Duration(seconds: 10),
      client: client,
    );
    final items = result['result'];
    if (items is! List) {
      throw const TelegramFailure('Telegram 返回了无法识别的消息格式。');
    }
    return [
      for (final raw in items)
        if (raw is Map && raw['update_id'] is int)
          (
            raw['update_id'] as int,
            normalizeUpdate(
              Map<String, dynamic>.from(raw),
              accountId: accountId,
              botUsername: _botUsername,
            ),
          ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
  }

  Future<String> pairingUsername(HttpClient client) async {
    final me = await _request('getMe', const {}, client: client);
    final bot = me['result'];
    final username = bot is Map ? bot['username'] : null;
    if (bot is! Map ||
        bot['is_bot'] != true ||
        username is! String ||
        !RegExp(r'^[A-Za-z0-9_]{5,32}$').hasMatch(username)) {
      throw const TelegramFailure('Telegram 未返回有效的机器人用户名。');
    }
    return username;
  }

  /// Verifies the credential and whether the owner can be written to.
  ///
  /// Returns a notice for the settings page. A missing private chat is not an
  /// error: Telegram forbids a bot from writing first, so the relay can still
  /// be enabled and starts working the moment the owner sends `/start`.
  Future<String> probe({String? replacementToken, String? chatID}) async {
    final useToken = replacementToken?.trim().isNotEmpty == true
        ? replacementToken!.trim()
        : token;
    final chat = chatID?.trim().isNotEmpty == true ? chatID!.trim() : chatId;
    if (useToken.isEmpty || chat.isEmpty) {
      throw const FormatException(
        'Save a bot token and Telegram user ID first.',
      );
    }
    final Map<String, dynamic> me;
    try {
      me = await _request(
        'getMe',
        const {},
        timeout: const Duration(seconds: 12),
        overrideToken: useToken,
      );
    } on TelegramFailure catch (error) {
      throw FormatException(error.message);
    }
    final result = me['result'];
    final username = result is Map ? result['username']?.toString() ?? '' : '';
    final botName = username.isEmpty ? '该机器人' : '@$username';
    try {
      await _request(
        'getChat',
        {'chat_id': chat},
        timeout: const Duration(seconds: 12),
        overrideToken: useToken,
      );
    } on TelegramFailure {
      return 'Token 验证成功（$botName），但还没有与该用户的私聊。'
          '请先在 Telegram 中打开机器人私聊并发送 /start，再回来启用。';
    }
    return 'Token 验证成功（$botName），可以与该用户私聊。';
  }

  /// Fetches the bot identity, caching the username for mention detection.
  Future<String?> resolveUsername() async {
    try {
      final me = await _request('getMe', const {});
      final result = me['result'];
      _botUsername = result is Map ? result['username']?.toString() : null;
      return _botUsername;
    } on Object {
      return null;
    }
  }

  @override
  Future<DeliveryReceipt> send(
    RenderedChannelMessage message,
    DeliveryContext context,
  ) async {
    if (isClosed) {
      return const DeliveryReceipt.failed('渠道已关闭');
    }
    if (context.address.conversationType != ChannelConversationKind.direct ||
        context.address.conversationId != chatId) {
      return const DeliveryReceipt.failed('Telegram 私聊绑定已变更，本条消息未发送。');
    }
    if (message.text.trim().isEmpty) {
      return const DeliveryReceipt.failed('空消息未发送');
    }
    try {
      final payload = await _request('sendMessage', {
        'chat_id': context.address.conversationId,
        'text': message.text,
        'disable_web_page_preview': true,
      });
      final result = payload['result'];
      final messageID = result is Map ? result['message_id']?.toString() : null;
      if (messageID == null || messageID.isEmpty) {
        return const DeliveryReceipt.unknown('Telegram 未返回发送回执。');
      }
      return DeliveryReceipt.delivered(messageId: messageID);
    } on TelegramFailure catch (error) {
      final retryable = error.retryable;
      return retryable
          ? DeliveryReceipt.deferred(
              error.message,
              retryAfter: error.retryAfter,
            )
          : DeliveryReceipt.failed(error.message);
    } on Object {
      return const DeliveryReceipt.unknown('发送结果不确定');
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> values, {
    bool get = false,
    Duration timeout = const Duration(seconds: 15),
    HttpClient? client,
    String? overrideToken,
  }) async {
    final http =
        client ??
        (HttpClient()..connectionTimeout = const Duration(seconds: 10));
    final ownsClient = client == null;
    final useToken = overrideToken ?? token;
    try {
      var uri = Uri.parse('${_apiOrigin()}/bot$useToken/$method');
      if (get) {
        uri = uri.replace(
          queryParameters: {
            for (final entry in values.entries) entry.key: '${entry.value}',
          },
        );
      }
      final request = get
          ? await http.getUrl(uri).timeout(const Duration(seconds: 12))
          : await http.postUrl(uri).timeout(const Duration(seconds: 12));
      request.followRedirects = false;
      if (!get) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(values));
      }
      final httpResponse = await request.close().timeout(timeout);
      final body = await httpResponse
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      final payload = _payload(body);
      if (method == 'sendMessage' &&
          payload?['ok'] != false &&
          (httpResponse.statusCode != HttpStatus.ok ||
              payload?['ok'] != true)) {
        throw const HttpException('No definitive Telegram acknowledgement');
      }
      if (httpResponse.statusCode != HttpStatus.ok || payload?['ok'] != true) {
        throw _failure(payload, httpResponse.statusCode);
      }
      return payload!;
    } on TelegramFailure {
      rethrow;
    } on Object {
      if (method == 'sendMessage') rethrow; // The platform may already have it.
      throw const TelegramFailure('无法连接 Telegram，请检查网络后重试。');
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  static Map<String, dynamic>? _payload(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// Telegram's own words when it gives any, plus the failures people
  /// actually hit: a second poller, a revoked token, a rate limit.
  static TelegramFailure _failure(
    Map<String, dynamic>? payload,
    int statusCode,
  ) {
    final raw = payload?['error_code'];
    final code = raw is int ? raw : statusCode;
    final description = payload?['description']?.toString().trim() ?? '';
    return switch (code) {
      401 || 404 => const TelegramFailure('Bot Token 无效或已被撤销，请重新生成。'),
      409 => const TelegramFailure('该 Bot 已被其他程序或 Webhook 占用，无法同时接收消息。'),
      429 => const TelegramFailure(
        'Telegram 请求过于频繁，稍后会自动重试。',
        retryable: true,
        retryAfter: Duration(seconds: 5),
      ),
      _ when description.isNotEmpty => TelegramFailure(
        'Telegram 返回错误：$description',
        retryable: code >= 500,
      ),
      _ => TelegramFailure(
        'Telegram 请求失败（HTTP $statusCode）。',
        retryable: statusCode >= 500,
      ),
    };
  }

  /// Turns a Bot API update into the shared message model.
  ///
  /// Only `message` updates are requested. Media-only messages arrive with no
  /// text and are still delivered, so the pipeline can answer "text only"
  /// instead of going silent.
  @visibleForTesting
  static ChannelMessage? normalizeUpdate(
    Map<String, dynamic> update, {
    required String accountId,
    String? botUsername,
  }) {
    final message = update['message'];
    if (message is! Map) return null;
    final chat = message['chat'];
    final from = message['from'];
    if (chat is! Map || from is! Map) return null;
    final chatType = chat['type']?.toString() ?? '';
    final kind = switch (chatType) {
      'private' => ChannelConversationKind.direct,
      'group' || 'supergroup' => ChannelConversationKind.group,
      'channel' => ChannelConversationKind.channel,
      _ => ChannelConversationKind.unknown,
    };
    final text = message['text']?.toString() ?? '';
    final segments = <ChannelSegment>[];
    if (text.isNotEmpty) segments.add(ChannelSegment.text(text));
    final mentionsAccount =
        botUsername != null &&
        botUsername.isNotEmpty &&
        text.toLowerCase().contains('@${botUsername.toLowerCase()}');
    return ChannelMessage(
      providerId: ChannelProviderIds.telegram,
      accountId: accountId,
      conversationId: chat['id']?.toString() ?? '',
      conversationType: kind,
      senderId: from['id']?.toString() ?? '',
      senderName: from['username']?.toString(),
      conversationTitle: chat['title']?.toString(),
      messageId: message['message_id']?.toString() ?? '',
      text: text,
      segments: segments,
      replyToMessageId: message['reply_to_message'] is Map
          ? (message['reply_to_message'] as Map)['message_id']?.toString()
          : null,
      mentionsAccount: mentionsAccount,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        ((message['date'] as num?)?.toInt() ?? 0) * 1000,
      ),
      extensions: {
        'update_id': update['update_id'],
        'chat_type': chatType,
        if (from['is_bot'] is bool) 'sender_is_bot': from['is_bot'],
      },
    );
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await closeEvents();
  }
}

/// A Telegram failure with the two facts the pipeline needs: whether trying
/// again could work, and when.
class TelegramFailure implements Exception {
  const TelegramFailure(
    this.message, {
    this.retryable = false,
    this.retryAfter,
  });

  final String message;
  final bool retryable;
  final Duration? retryAfter;

  @override
  String toString() => message;
}
