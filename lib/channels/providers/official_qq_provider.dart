import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import '../channel_capabilities.dart';
import '../channel_message.dart';
import '../channel_provider.dart';

/// The official QQ bot channel, over Tencent's v2 API and WebSocket gateway.
///
/// This talks to the platform the way the platform documents it: an access
/// token from `getAppAccessToken`, a gateway URL from `/gateway`, identify /
/// heartbeat / resume over the socket, and messages sent through the HTTPS
/// OpenAPI. It deliberately does not reuse botgo's older socket framing: the
/// opcodes are implemented here so the resume and heartbeat rules are visible
/// and testable.
///
/// What this provider cannot do is decide that the bot has permission to be
/// somewhere. Private chat, group chat and 频道 are separate console
/// authorisations; without them the platform answers with an error, and that
/// error is surfaced rather than retried forever.
class OfficialQqProvider extends ChannelProviderBase {
  OfficialQqProvider({
    required super.accountId,
    required this.appId,
    required this.clientSecret,
    this.sandbox = false,
    this.intents = defaultIntents,
    String? apiBase,
    String? tokenBase,
    this.gatewayPath = '/gateway',
    this.heartbeatTolerance = 2,
    this.minBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _apiBase = apiBase ?? (sandbox ? sandboxBase : productionBase),
       _tokenBase = tokenBase ?? (sandbox ? sandboxBase : productionBase),
       super(providerId: ChannelProviderIds.officialQq);

  static const productionBase = 'https://api.bot.qq.com';
  static const sandboxBase = 'https://sandbox.api.sgroup.qq.com';

  /// `GROUP_AND_C2C_EVENT` (1 << 25) plus `PUBLIC_GUILD_MESSAGES` (1 << 30).
  static const defaultIntents = (1 << 25) | (1 << 30);

  final String appId;
  final String clientSecret;
  final bool sandbox;
  final int intents;
  final String gatewayPath;

  /// How many heartbeat intervals may pass without an ACK before the socket is
  /// considered dead. Two is the platform's own guidance.
  final int heartbeatTolerance;
  final Duration minBackoff;
  final Duration maxBackoff;

  /// Reads the clock for the passive-reply window. Injectable so the window's
  /// boundary is tested rather than assumed.
  final DateTime Function() _clock;

  final String _apiBase;
  final String _tokenBase;

  static const declaredCapabilities = ChannelCapabilities({
    ChannelCapability.directMessage: CapabilitySpec(
      CapabilityStatus.native,
      note: 'QQ 单聊（C2C）能力需要在开放平台为机器人开通，个人主体与企业主体权限不同。',
      requiresPermission: true,
    ),
    ChannelCapability.groupMessage: CapabilitySpec(
      CapabilityStatus.native,
      note: 'QQ 群需要把机器人加入群，并在控制台获得群聊权限。',
      requiresPermission: true,
    ),
    ChannelCapability.activeMessage: CapabilitySpec(
      CapabilityStatus.extension,
      note: '主动消息受平台场景与频次限制，需要单独申请；未获授权时发送会失败。',
      requiresPermission: true,
    ),
    ChannelCapability.passiveReply: CapabilitySpec(
      CapabilityStatus.native,
      note: '被动回复需要在收到消息后 5 分钟内、针对该消息发送。',
      limit: '每条消息最多 5 次回复，5 分钟内有效',
    ),
    ChannelCapability.image: CapabilitySpec(
      CapabilityStatus.extension,
      note: '需要先上传富媒体再引用 file_info；本版本未启用。',
      requiresPermission: true,
    ),
    ChannelCapability.file: CapabilitySpec(
      CapabilityStatus.unverified,
      note: '文件上传接口未在真实机器人上验证。',
    ),
    ChannelCapability.voice: CapabilitySpec(
      CapabilityStatus.unverified,
      note: '语音需要平台审核的媒体能力。',
    ),
    ChannelCapability.messageReply: CapabilitySpec(
      CapabilityStatus.native,
      note: '通过 msg_id 引用原消息。',
    ),
    ChannelCapability.messageEdit: CapabilitySpec.unsupported(
      '官方 API 不提供消息编辑。',
    ),
    ChannelCapability.messageRecall: CapabilitySpec.unsupported(
      '官方 API 不提供撤回。',
    ),
    ChannelCapability.messageQuery: CapabilitySpec.unverified('消息查询接口未验证。'),
    ChannelCapability.longText: CapabilitySpec(
      CapabilityStatus.application,
      note: '超长文本分段发送，每段独立计数。',
      limit: '每段 1500 字符',
    ),
  });

  @override
  ChannelCapabilities get capabilities => declaredCapabilities;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _running = false;
  int _generation = 0;
  String? _sessionId;
  int? _lastSeq;
  int _missedAcks = 0;
  int _consecutiveFailures = 0;
  String? _accessToken;
  DateTime? _tokenExpiry;
  bool _identifying = false;
  final _random = Random();

  /// Per inbound message: how many passive replies have been used and when the
  /// window closes. The platform counts replies per `msg_id`, so this map is
  /// the only way to know before sending that the sixth one will be refused.
  final Map<String, _PassiveWindow> _passive = {};

  static const _passiveWindow = Duration(minutes: 5);
  static const _passiveReplyLimit = 5;

  String get apiBase => _apiBase;

  bool get isSandbox => sandbox;

  @override
  Future<void> connect() async {
    if (isClosed || _running) return;
    if (appId.isEmpty || clientSecret.isEmpty) {
      publishStatus(
        ProviderState.needsSetup,
        detail: '缺少 AppID 或 ClientSecret',
        clearError: true,
      );
      return;
    }
    _running = true;
    _generation++;
    unawaited(_connectOnce(_generation));
  }

  @override
  Future<void> disconnect() async {
    _running = false;
    _generation++;
    // An explicit disconnect is not a network blip: the next connect starts a
    // fresh session instead of resuming one the platform may have dropped.
    _sessionId = null;
    _lastSeq = null;
    await _closeSocket();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (!isClosed) publishStatus(ProviderState.disabled, detail: '已断开');
  }

  Future<void> _connectOnce(int generation) async {
    publishStatus(ProviderState.connecting, clearError: true);
    try {
      final token = await _ensureToken();
      if (!_running || generation != _generation) return;
      final gateway = await _fetchGateway(token);
      if (!_running || generation != _generation) return;
      await _openSocket(gateway, token, generation);
    } on _QqFailure catch (error) {
      if (!_running || generation != _generation || isClosed) return;
      _scheduleReconnect(generation, error.message, retryable: error.retryable);
    } on Object {
      if (!_running || generation != _generation || isClosed) return;
      _scheduleReconnect(generation, '无法连接 QQ 开放平台，请检查网络后重试。');
    }
  }

  Future<void> _openSocket(String url, String token, int generation) async {
    final socket = await WebSocket.connect(url);
    if (!_running || generation != _generation) {
      await socket.close();
      return;
    }
    _socket = socket;
    _socketSubscription = socket.listen(
      (frame) => _onFrame(frame, generation),
      onError: (Object error) {
        if (!_running || generation != _generation || isClosed) return;
        _scheduleReconnect(generation, '与 QQ 网关的连接中断，正在重连。');
      },
      onDone: () {
        if (!_running || generation != _generation || isClosed) return;
        _scheduleReconnect(generation, 'QQ 网关已断开，正在重连。');
      },
      cancelOnError: true,
    );
  }

  void _onFrame(Object? frame, int generation) {
    if (!_running || generation != _generation || isClosed) return;
    if (frame is! String) return;
    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(frame);
      if (decoded is! Map) return;
      payload = Map<String, dynamic>.from(decoded);
    } on FormatException {
      return;
    }
    final op = (payload['op'] as num?)?.toInt();
    switch (op) {
      case 10:
        _onHello(payload, generation);
      case 11:
        _missedAcks = 0;
      case 7:
        unawaited(_reconnectNow(generation, '网关要求重新连接。'));
      case 9:
        _sessionId = null;
        _lastSeq = null;
        unawaited(_reconnectNow(generation, '登录态失效，正在重新鉴权。'));
      case 0:
        _onDispatch(payload);
      default:
        // Unknown opcodes are ignored: a new one must not kill the socket.
        break;
    }
  }

  void _onHello(Map<String, dynamic> payload, int generation) {
    final data = payload['d'];
    final intervalMs = data is Map
        ? (data['heartbeat_interval'] as num?)?.toInt() ?? 45000
        : 45000;
    _startHeartbeat(Duration(milliseconds: intervalMs), generation);
    final sessionId = _sessionId;
    if (sessionId != null && _lastSeq != null) {
      _send({
        'op': 6,
        'd': {
          'token': 'QQBot $_accessToken',
          'session_id': sessionId,
          'seq': _lastSeq,
        },
      });
      return;
    }
    _identify();
  }

  void _identify() {
    if (_identifying) return;
    _identifying = true;
    _send({
      'op': 2,
      'd': {
        'token': 'QQBot $_accessToken',
        'intents': intents,
        'shard': [0, 1],
        'properties': {
          '\$os': 'android',
          '\$browser': 'opencode-plus',
          '\$device': 'opencode-plus',
        },
      },
    });
  }

  void _startHeartbeat(Duration interval, int generation) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(interval, (_) {
      if (!_running || generation != _generation) return;
      if (_missedAcks >= heartbeatTolerance) {
        unawaited(_reconnectNow(generation, '心跳超时，正在重连。'));
        return;
      }
      _missedAcks++;
      _send({'op': 1, 'd': _lastSeq});
    });
  }

  void _onDispatch(Map<String, dynamic> payload) {
    final seq = (payload['s'] as num?)?.toInt();
    if (seq != null) _lastSeq = seq;
    final type = payload['t']?.toString() ?? '';
    final data = payload['d'];
    switch (type) {
      case 'READY':
        _identifying = false;
        _consecutiveFailures = 0;
        _missedAcks = 0;
        if (data is Map) _sessionId = data['session_id']?.toString();
        publishStatus(ProviderState.online, clearError: true);
      case 'RESUMED':
        _identifying = false;
        _consecutiveFailures = 0;
        publishStatus(ProviderState.online, clearError: true);
      default:
        if (data is Map) {
          final message = normalizeEvent(
            type,
            Map<String, dynamic>.from(data),
            accountId: accountId,
          );
          if (message != null) {
            if (message.replyToMessageId != null) {
              _registerPassive(message.replyToMessageId!);
            }
            emitMessage(message);
          }
        }
    }
  }

  void _registerPassive(String messageId) {
    _passive[messageId] = _PassiveWindow(_clock(), _clock);
    if (_passive.length > 40) {
      final oldest = _passive.keys.first;
      _passive.remove(oldest);
    }
  }

  void _scheduleReconnect(
    int generation,
    String reason, {
    bool retryable = true,
  }) {
    if (!_running || generation != _generation || isClosed) return;
    unawaited(_closeSocket());
    _consecutiveFailures++;
    publishStatus(
      ProviderState.reconnecting,
      lastError: reason,
      consecutiveFailures: _consecutiveFailures,
    );
    if (!retryable) {
      publishStatus(
        ProviderState.error,
        lastError: reason,
        consecutiveFailures: _consecutiveFailures,
      );
    }
    final computed = Duration(
      seconds: (1 << _consecutiveFailures.clamp(1, 6)) + _random.nextInt(3),
    );
    final delay = computed < minBackoff
        ? minBackoff
        : (computed > maxBackoff ? maxBackoff : computed);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_running || generation != _generation || isClosed) return;
      unawaited(_connectOnce(_generation));
    });
  }

  Future<void> _reconnectNow(int generation, String reason) async {
    if (!_running || generation != _generation || isClosed) return;
    await _closeSocket();
    if (!_running || generation != _generation) return;
    _scheduleReconnect(generation, reason);
  }

  Future<void> _closeSocket() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // A socket that died between identify and READY must be allowed to
    // identify again on the next attempt.
    _identifying = false;
    final subscription = _socketSubscription;
    _socketSubscription = null;
    final socket = _socket;
    _socket = null;
    await subscription?.cancel();
    try {
      await socket?.close();
    } on Object {
      // Closing a dead socket throws; nothing to do about it.
    }
  }

  void _send(Map<String, Object?> payload) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(payload));
  }

  // ------------------------------------------------------------------ token

  Future<String> _ensureToken({bool force = false}) async {
    final token = _accessToken;
    final expiry = _tokenExpiry;
    if (!force &&
        token != null &&
        expiry != null &&
        DateTime.now().isBefore(expiry.subtract(const Duration(seconds: 60)))) {
      return token;
    }
    final response = await _httpJson(
      'POST',
      Uri.parse('$_tokenBase/app/getAppAccessToken'),
      body: {'appId': appId, 'clientSecret': clientSecret},
      token: null,
    );
    final value = response['access_token']?.toString();
    if (value == null || value.isEmpty) {
      throw const _QqFailure('QQ 开放平台没有返回 access_token。');
    }
    final expiresIn = int.tryParse(response['expires_in']?.toString() ?? '');
    _accessToken = value;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn ?? 7200));
    return value;
  }

  Future<String> _fetchGateway(String token) async {
    final response = await _httpJson(
      'GET',
      Uri.parse('$_apiBase$gatewayPath'),
      token: token,
    );
    final url = response['url']?.toString();
    if (url == null || url.isEmpty) {
      throw const _QqFailure('QQ 开放平台没有返回网关地址。');
    }
    return url;
  }

  Future<Map<String, dynamic>> _httpJson(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    String? token,
    bool retryOnAuth = true,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 12));
      request.headers.contentType = ContentType.json;
      if (token != null) request.headers.set('Authorization', 'QQBot $token');
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final text = await response.transform(utf8.decoder).join();
      Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(text);
        payload = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
      } on FormatException {
        payload = {};
      }
      if (response.statusCode == HttpStatus.unauthorized && retryOnAuth) {
        // A revoked or expired token is recoverable exactly once: fetch a new
        // one and repeat. A second 401 is a credential problem, not a clock.
        await _ensureToken(force: true);
        final retried = await _httpJson(
          method,
          uri,
          body: body,
          token: _accessToken,
          retryOnAuth: false,
        );
        return retried;
      }
      if (response.statusCode == 429) {
        throw _QqFailure(
          'QQ 开放平台限流，稍后自动重试。',
          retryable: true,
          retryAfter: const Duration(seconds: 5),
        );
      }
      if (response.statusCode >= 400) {
        throw _QqFailure(
          _errorText(payload, response.statusCode),
          retryable: response.statusCode >= 500,
        );
      }
      return payload;
    } on _QqFailure {
      rethrow;
    } on Object {
      throw const _QqFailure('无法连接 QQ 开放平台，请检查网络后重试。', retryable: true);
    } finally {
      client.close(force: true);
    }
  }

  static String _errorText(Map<String, dynamic> payload, int statusCode) {
    final message = payload['message']?.toString().trim() ?? '';
    final code = payload['code']?.toString() ?? '';
    if (message.isEmpty) return 'QQ 开放平台返回 HTTP $statusCode。';
    return code.isEmpty ? 'QQ 返回错误：$message' : 'QQ 返回错误（$code）：$message';
  }

  // -------------------------------------------------------------------- send

  @override
  Future<DeliveryReceipt> send(
    RenderedChannelMessage message,
    DeliveryContext context,
  ) async {
    if (isClosed) return const DeliveryReceipt.failed('渠道已关闭');
    final text = message.text.trim();
    if (text.isEmpty) return const DeliveryReceipt.failed('空消息未发送');
    final address = context.address;
    final replyTo = address.replyToMessageId ?? message.replyToMessageId;
    _PassiveWindow? window;
    if (replyTo != null && replyTo.isNotEmpty) {
      window = _passive[replyTo];
      if (window == null) {
        // An unknown msg_id cannot be used passively; sending without it would
        // be an active message the bot may not be allowed to send.
        return const DeliveryReceipt.failed('找不到原消息的被动回复记录，本条消息未发送。');
      }
      if (window.isExpired) {
        return const DeliveryReceipt.failed('被动回复窗口已过期（5 分钟），本条消息未发送。');
      }
      if (!window.hasBudget) {
        emitNotice('被动回复次数已用尽（每条消息最多 5 次），本条消息未发送。', isError: true);
        return const DeliveryReceipt.failed('被动回复次数已用尽（每条消息最多 5 次）。');
      }
      if (context.purpose == DeliveryPurpose.progress &&
          window.remaining <= 1) {
        emitNotice('为保证最终结果可发送，已省略一条进度消息。');
        return const DeliveryReceipt.failed('被动回复额度保留给最终结果，本条进度未发送。');
      }
    } else if (!capabilities.supports(ChannelCapability.activeMessage)) {
      return const DeliveryReceipt.failed('该渠道没有可用的主动消息权限。');
    }

    final path = _pathFor(address);
    if (path == null) {
      return const DeliveryReceipt.failed('无法识别的 QQ 会话类型。');
    }
    try {
      final token = await _ensureToken();
      final payload = await _httpJson(
        'POST',
        Uri.parse('$_apiBase$path'),
        token: token,
        body: {
          'content': text,
          'msg_type': 0,
          if (replyTo != null && replyTo.isNotEmpty) ...{
            'msg_id': replyTo,
            'msg_seq': window?.nextSequence() ?? 1,
          },
          if (address.extensions['event_id'] != null)
            'event_id': address.extensions['event_id'],
        },
      );
      final id = payload['id']?.toString();
      return DeliveryReceipt.delivered(messageId: id);
    } on _QqFailure catch (error) {
      if (error.retryable) {
        return DeliveryReceipt.deferred(
          error.message,
          retryAfter: error.retryAfter,
        );
      }
      return DeliveryReceipt.failed(error.message);
    } on Object {
      return const DeliveryReceipt.unknown('发送结果不确定');
    }
  }

  String? _pathFor(ChannelAddress address) {
    switch (address.conversationType) {
      case ChannelConversationKind.direct:
        final openid = address.extensions['user_openid']?.toString();
        return '/v2/users/${openid ?? address.conversationId}/messages';
      case ChannelConversationKind.group:
        final groupOpenid = address.extensions['group_openid']?.toString();
        return '/v2/groups/${groupOpenid ?? address.conversationId}/messages';
      case ChannelConversationKind.channel:
        return '/channels/${address.conversationId}/messages';
      case ChannelConversationKind.unknown:
        return null;
    }
  }

  /// Verifies the credentials and the gateway, without sending anything to a
  /// person. Used by the settings page's "test" button.
  Future<String> probe() async {
    final token = await _ensureToken(force: true);
    await _fetchGateway(token);
    final masked = appId.length <= 4
        ? appId
        : '${appId.substring(0, 2)}***${appId.substring(appId.length - 2)}';
    return '鉴权成功（AppID $masked），网关地址已获取。'
        '实际能否收发消息取决于该机器人已开通的场景权限。';
  }

  /// Turns one gateway dispatch into the shared message model.
  ///
  /// Returns null for event types that carry no user message (friend adds,
  /// rejections, audit results), so the pipeline never sees a pseudo-message.
  static ChannelMessage? normalizeEvent(
    String type,
    Map<String, dynamic> data, {
    required String accountId,
  }) {
    final receivedAt = DateTime.now();
    switch (type) {
      case 'C2C_MESSAGE_CREATE':
        final author = data['author'];
        final openid = author is Map
            ? author['user_openid']?.toString() ??
                  author['id']?.toString() ??
                  ''
            : '';
        if (openid.isEmpty) return null;
        final content = _content(data);
        return ChannelMessage(
          providerId: ChannelProviderIds.officialQq,
          accountId: accountId,
          conversationId: openid,
          conversationType: ChannelConversationKind.direct,
          senderId: openid,
          messageId: data['id']?.toString() ?? '',
          text: content,
          segments: content.isEmpty ? const [] : [ChannelSegment.text(content)],
          replyToMessageId: data['id']?.toString(),
          receivedAt: receivedAt,
          extensions: {
            'user_openid': openid,
            'event_id': data['id']?.toString(),
          },
        );
      case 'GROUP_AT_MESSAGE_CREATE':
        final groupOpenid = data['group_openid']?.toString() ?? '';
        final author = data['author'];
        final memberOpenid = author is Map
            ? author['member_openid']?.toString() ??
                  author['id']?.toString() ??
                  ''
            : '';
        if (groupOpenid.isEmpty || memberOpenid.isEmpty) return null;
        final content = _content(data);
        return ChannelMessage(
          providerId: ChannelProviderIds.officialQq,
          accountId: accountId,
          conversationId: groupOpenid,
          conversationType: ChannelConversationKind.group,
          senderId: memberOpenid,
          messageId: data['id']?.toString() ?? '',
          text: content,
          segments: content.isEmpty ? const [] : [ChannelSegment.text(content)],
          replyToMessageId: data['id']?.toString(),
          mentionsAccount: true,
          receivedAt: receivedAt,
          extensions: {
            'group_openid': groupOpenid,
            'event_id': data['id']?.toString(),
          },
        );
      case 'AT_MESSAGE_CREATE':
      case 'DIRECT_MESSAGE_CREATE':
        final channelId = data['channel_id']?.toString() ?? '';
        final author = data['author'];
        final userId = author is Map ? author['id']?.toString() ?? '' : '';
        if (channelId.isEmpty || userId.isEmpty) return null;
        final content = _content(data);
        return ChannelMessage(
          providerId: ChannelProviderIds.officialQq,
          accountId: accountId,
          conversationId: channelId,
          conversationType: ChannelConversationKind.channel,
          senderId: userId,
          messageId: data['id']?.toString() ?? '',
          text: content,
          segments: content.isEmpty ? const [] : [ChannelSegment.text(content)],
          replyToMessageId: data['id']?.toString(),
          mentionsAccount: type == 'AT_MESSAGE_CREATE',
          receivedAt: receivedAt,
          extensions: {
            'guild_id': data['guild_id']?.toString(),
            'channel_id': channelId,
          },
        );
      default:
        return null;
    }
  }

  static String _content(Map<String, dynamic> data) {
    final raw = data['content']?.toString() ?? '';
    return raw.trim();
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await closeEvents();
  }
}

class _PassiveWindow {
  _PassiveWindow(this.openedAt, this.clock);

  final DateTime openedAt;
  final DateTime Function() clock;
  int used = 0;

  bool get isExpired =>
      clock().difference(openedAt) > OfficialQqProvider._passiveWindow;

  bool get hasBudget => used < OfficialQqProvider._passiveReplyLimit;

  int get remaining => OfficialQqProvider._passiveReplyLimit - used;

  int nextSequence() {
    used++;
    return used;
  }
}

class _QqFailure implements Exception {
  const _QqFailure(this.message, {this.retryable = false, this.retryAfter});

  final String message;
  final bool retryable;
  final Duration? retryAfter;

  @override
  String toString() => message;
}
