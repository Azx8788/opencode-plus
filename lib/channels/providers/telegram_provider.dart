import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../telegram/telegram_identity.dart';
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
    required String chatId,
    required String Function() apiOrigin,
    this.onOffset,
    this.onBindPrivateUser,
    this.pollTimeout = const Duration(seconds: 25),
    this.maxBackoff = const Duration(seconds: 60),
  }) : _chatId = chatId,
       _apiOrigin = apiOrigin,
       super(providerId: ChannelProviderIds.telegram);

  final String token;
  String _chatId;
  String get chatId => _chatId;
  final String Function() _apiOrigin;
  final Future<void> Function(int offset)? onOffset;

  /// Called only for a human private message. True means the app saved this
  /// sender's numeric ID and subscribed its channel engine to this provider.
  final Future<bool> Function(ChannelMessage message)? onBindPrivateUser;
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
  Completer<void>? _retryWait;
  Future<void>? _offsetWrite;
  int _consecutiveFailures = 0;
  late Duration _receiveWait = pollTimeout;
  String? _botUsername;

  /// The bot's @username once `getMe` has answered, used to recognise a
  /// mention in group text.
  String? get botUsername => _botUsername;

  /// The last long-poll offset. The bridge persists it so a restart does not
  /// replay an update whose prompt may already have been sent.
  int? offset;

  @override
  Future<void> connect() async => _startReceiving(prepareBot: true);

  /// Reopens an already configured receiver without changing its webhook,
  /// command menu, offset or adapted polling wait.
  void resumeReceiving() => _startReceiving(prepareBot: false);

  void _startReceiving({required bool prepareBot}) {
    if (isClosed) return;
    if (token.isEmpty || (chatId.isEmpty && onBindPrivateUser == null)) {
      publishStatus(
        ProviderState.needsSetup,
        detail: '缺少 Bot Token 或用户 ID',
        clearError: true,
      );
      return;
    }
    if (_running) return;
    _running = true;
    // A manual reconnect must not inherit the previous attempt's backoff.
    _consecutiveFailures = 0;
    if (prepareBot) _receiveWait = pollTimeout;
    final generation = ++_generation;
    unawaited(_pollLoop(generation, prepareBot: prepareBot));
  }

  @override
  Future<void> disconnect() async {
    _running = false;
    _generation++;
    _http?.close(force: true);
    _http = null;
    final retry = _retryWait;
    if (retry != null && !retry.isCompleted) retry.complete();
    try {
      await _offsetWrite;
    } on Object {
      // A refused write is handled by the poll generation that attempted it.
    }
    if (!isClosed) {
      publishStatus(ProviderState.disabled, detail: '已断开');
    }
  }

  Future<void> _pollLoop(int generation, {required bool prepareBot}) async {
    publishStatus(
      ProviderState.connecting,
      clearError: true,
      consecutiveFailures: 0,
    );
    if (prepareBot) {
      final setup = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      _http = setup;
      try {
        await _prepareBot(setup, generation);
      } finally {
        if (identical(_http, setup)) _http = null;
        setup.close(force: true);
      }
    }
    // Keep a healthy TLS connection between polls. Some mobile gateways cut
    // off a quiet long poll even while getMe/getChat continue to work. Retain
    // a shorter positive wait after a transport failure, without resetting
    // the offset or introducing a second receiver.
    HttpClient? pollingClient;
    try {
      while (_running && generation == _generation && !isClosed) {
        final http = pollingClient ??= HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        _http = http;
        try {
          final updates = await readUpdates(
            client: http,
            offset: offset,
            wait: _receiveWait,
          );
          if (!_running || generation != _generation) break;
          if (status.state != ProviderState.online) {
            publishStatus(
              ProviderState.online,
              clearError: true,
              consecutiveFailures: 0,
            );
          }
          _consecutiveFailures = 0;
          for (final (updateID, message) in updates) {
            if (!_running || generation != _generation) break;
            if (offset != null && updateID < offset!) continue;
            // Advance before dispatch: a process death cannot replay a prompt
            // whose delivery to OpenCode may already have succeeded.
            final write = _offsetWrite = onOffset?.call(updateID + 1);
            try {
              await write;
            } finally {
              if (identical(_offsetWrite, write)) _offsetWrite = null;
            }
            if (!_running || generation != _generation) break;
            offset = updateID + 1;
            if (message == null ||
                !telegramPrivateMessageAllowed(
                  allowedUserID: chatId.isEmpty ? message.senderId : chatId,
                  chatType: message.extensions['chat_type'],
                  senderID: message.senderId,
                  chatID: message.conversationId,
                  senderIsBot: message.extensions['sender_is_bot'] != false,
                )) {
              continue;
            }
            if (chatId.isEmpty) {
              if (await onBindPrivateUser?.call(message) != true) {
                continue;
              }
              if (!_running || generation != _generation) break;
              _chatId = message.senderId;
            }
            emitMessage(message);
          }
        } on Object catch (error) {
          if (!_running || generation != _generation || isClosed) break;
          _consecutiveFailures = (_consecutiveFailures + 1).clamp(1, 6);
          var text = error is TelegramFailure
              ? error.message
              : '处理 Telegram 接收消息时失败，正在重试。';
          if (error is TelegramFailure && error.canShortenPoll) {
            final wait = _receiveWait;
            final shorter = wait > const Duration(seconds: 10)
                ? const Duration(seconds: 10)
                : wait > const Duration(seconds: 5)
                ? const Duration(seconds: 5)
                : wait;
            if (shorter < wait) {
              _receiveWait = shorter;
              text += ' 将改用 ${shorter.inSeconds} 秒等待重试接收。';
            }
          }
          publishStatus(
            ProviderState.reconnecting,
            lastError: text,
            consecutiveFailures: _consecutiveFailures,
          );
          // Release the failed socket before waiting. Disabling/reconnecting
          // wakes this wait so an old generation cannot wake up and poll again.
          if (identical(_http, http)) _http = null;
          http.close(force: true);
          pollingClient = null;
          final milliseconds = ((1 << _consecutiveFailures).clamp(5, 60) * 1000)
              .clamp(0, maxBackoff.inMilliseconds);
          await _waitToRetry(Duration(milliseconds: milliseconds));
        }
      }
    } finally {
      if (identical(_http, pollingClient)) _http = null;
      pollingClient?.close(force: true);
    }
    if (generation == _generation && !isClosed) {
      publishStatus(ProviderState.disabled, detail: '已停止轮询');
    }
  }

  Future<void> _waitToRetry(Duration duration) async {
    final done = Completer<void>();
    _retryWait = done;
    final timer = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      timer.cancel();
      if (identical(_retryWait, done)) _retryWait = null;
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
        'timeout': wait.inSeconds,
        'allowed_updates': ['message'],
        'offset': ?offset,
      },
      timeout: wait + const Duration(seconds: 10),
      client: client,
    );
    final items = result['result'];
    if (items is! List) {
      throw const TelegramFailure('Telegram getUpdates：返回了无法识别的消息格式。');
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
  Future<String> probe({
    String? replacementToken,
    String? chatID,
    String? pendingUsername,
  }) async {
    final useToken = replacementToken?.trim().isNotEmpty == true
        ? replacementToken!.trim()
        : token;
    final chat = chatID?.trim().isNotEmpty == true ? chatID!.trim() : chatId;
    if (useToken.isEmpty || (chat.isEmpty && pendingUsername == null)) {
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
    if (pendingUsername != null) {
      return 'Token 验证成功（$botName）。请启用转发，再用 @$pendingUsername '
          '私聊机器人发送 /start，以绑定该账号的数字 ID。';
    }
    try {
      await _request(
        'getChat',
        {'chat_id': chat},
        timeout: const Duration(seconds: 12),
        overrideToken: useToken,
      );
    } on TelegramFailure catch (error) {
      if (!error.chatMissing) {
        throw FormatException('Token 验证成功（$botName），但私聊检查失败：${error.message}');
      }
      return 'Token 验证成功（$botName），但还没有与该用户的私聊。'
          '请先在 Telegram 中打开机器人私聊并发送 /start，再回来启用。';
    }
    return 'Token 验证成功（$botName），可以与该用户私聊。'
        '此检查不验证消息接收，请以上方接收状态为准。';
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
    if (chatId.isEmpty ||
        context.address.conversationType != ChannelConversationKind.direct ||
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
    Duration timeout = const Duration(seconds: 15),
    HttpClient? client,
    String? overrideToken,
  }) async {
    final http =
        client ??
        (HttpClient()..connectionTimeout = const Duration(seconds: 10));
    final ownsClient = client == null;
    final useToken = overrideToken ?? token;
    HttpClientRequest? request;
    var connected = false;
    var readingBody = false;
    try {
      final uri = Uri.parse('${_apiOrigin()}/bot$useToken/$method');
      request = await http.postUrl(uri).timeout(const Duration(seconds: 12));
      connected = true;
      request.followRedirects = false;
      // Use the same non-cacheable JSON POST for verification and receiving.
      final bytes = utf8.encode(jsonEncode(values));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
      final httpResponse = await request.close().timeout(timeout);
      readingBody = true;
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
        throw _failure(payload, httpResponse.statusCode, method);
      }
      return payload!;
    } on TelegramFailure {
      rethrow;
    } on Object catch (error) {
      request?.abort();
      if (method == 'sendMessage') rethrow; // The platform may already have it.
      final reason = switch (error) {
        TimeoutException() =>
          !connected
              ? '建立连接超时。'
              : readingBody
              ? '读取响应超时。'
              : '等待响应超时。',
        TlsException() => 'TLS 安全连接失败，请检查系统时间及代理的证书设置。',
        SocketException() when _isDnsFailure(error) =>
          '无法解析 api.telegram.org，请检查 DNS 或代理分流。',
        SocketException() || HttpException() =>
          connected ? '接收响应时连接中断。' : '无法建立连接，请检查 OpenCode Plus 的网络或代理分流。',
        FormatException() => '响应内容无法解析。',
        _ => '请求未能完成，请重试。',
      };
      throw TelegramFailure(
        'Telegram $method：$reason',
        canShortenPoll:
            method == 'getUpdates' &&
            connected &&
            (error is TimeoutException ||
                error is HttpException ||
                (error is SocketException && !_isDnsFailure(error))),
      );
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  static bool _isDnsFailure(SocketException error) {
    final message = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    return message.contains('failed host lookup') ||
        message.contains('no address associated with hostname') ||
        message.contains('name or service not known') ||
        message.contains('nodename nor servname') ||
        message.contains('temporary failure in name resolution');
  }

  static Map<String, dynamic>? _payload(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// Expose only known reasons and numeric codes. A gateway or an error
  /// description could include the credential-bearing request URL.
  static TelegramFailure _failure(
    Map<String, dynamic>? payload,
    int statusCode,
    String method,
  ) {
    final apiError = payload?['ok'] == false;
    final raw = payload?['error_code'];
    final code = apiError && raw is int && raw >= 400 && raw <= 599
        ? raw
        : statusCode;
    final description = payload?['description'];
    if (statusCode == HttpStatus.ok && payload?['ok'] != false) {
      return TelegramFailure('Telegram $method：返回了无法识别的 API 响应。');
    }
    return switch (code) {
      401 || 404 when apiError => TelegramFailure(
        'Telegram $method：Bot Token 无效或已被撤销。',
      ),
      409 when apiError && method == 'getUpdates' => const TelegramFailure(
        'Telegram getUpdates：该 Bot 已被其他程序或 Webhook 占用，无法同时接收消息。',
      ),
      429 => TelegramFailure(
        'Telegram $method：请求过于频繁（429），稍后重试。',
        retryable: true,
        retryAfter: Duration(seconds: 5),
      ),
      400
          when method == 'getChat' &&
              description is String &&
              description.toLowerCase().contains('chat not found') =>
        const TelegramFailure('尚未建立机器人私聊，请先发送 /start。', chatMissing: true),
      403 when method == 'sendMessage' => const TelegramFailure(
        'Telegram sendMessage：无权发送到该私聊（403），请确认未屏蔽机器人。',
      ),
      _ => TelegramFailure(
        'Telegram $method 请求失败（${apiError ? 'API' : 'HTTP'} $code）。',
        retryable: code >= 500,
        canShortenPoll: method == 'getUpdates' && (code == 502 || code == 504),
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
    final text = message['text'] is String ? message['text'] as String : '';
    final username = from['username'];
    final date = message['date'];
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
      senderName: username is String ? username : null,
      conversationTitle: chat['title']?.toString(),
      messageId: message['message_id']?.toString() ?? '',
      text: text,
      segments: segments,
      replyToMessageId: message['reply_to_message'] is Map
          ? (message['reply_to_message'] as Map)['message_id']?.toString()
          : null,
      mentionsAccount: mentionsAccount,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        (date is int && date >= 0 && date <= 253402300799 ? date : 0) * 1000,
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
    this.canShortenPoll = false,
    this.chatMissing = false,
  });

  final String message;
  final bool retryable;
  final Duration? retryAfter;

  /// Only a timed-out/interrupted receive request can adapt its polling wait.
  /// API authentication, conflict and rate-limit failures must stay visible.
  final bool canShortenPoll;
  final bool chatMissing;

  @override
  String toString() => message;
}
