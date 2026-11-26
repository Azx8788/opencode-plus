import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import '../channel_capabilities.dart';
import '../channel_message.dart';
import '../channel_provider.dart';

/// Which side of the WebSocket this app is.
///
/// NapCat, SnowLuma and LLBot all offer a WebSocket server (we dial them) and
/// most also offer a client that dials a URL we host. The second direction is
/// what makes a phone usable as the bot: the PC running the QQ client does not
/// need an inbound port, only a route to the phone.
enum OneBot11Transport {
  /// The app dials `webSocketUrl`. The protocol implementation listens.
  forward,

  /// The app listens on `listenPort`; the protocol implementation dials it.
  reverse,
}

/// One group the account is in, as `get_group_list` reports it.
class OneBotGroup {
  const OneBotGroup({
    required this.id,
    required this.name,
    this.memberCount,
    this.maxMemberCount,
  });

  final String id;
  final String name;
  final int? memberCount;
  final int? maxMemberCount;

  @override
  String toString() => 'OneBotGroup($id, $name)';
}

/// The account the implementation says it is logged in as.
class OneBotLogin {
  const OneBotLogin({required this.id, required this.nickname});

  final String id;
  final String nickname;
}

/// The ordinary-QQ channel, as a OneBot 11 client connected to a protocol
/// implementation the person runs themselves — LLBot, NapCat or SnowLuma.
///
/// This is not an official Tencent interface and the code does not pretend
/// otherwise: LLBot logs a real QQ account in and exposes OneBot 11, which is
/// why the settings page says so and why nothing here is bundled into the APK.
///
/// The client speaks OneBot 11 over a WebSocket, in whichever direction the
/// deployment needs: [OneBot11Transport.forward] dials the protocol
/// implementation, [OneBot11Transport.reverse] listens and lets it dial us.
/// Events arrive on the socket, API calls go out on the same socket and are
/// correlated by `echo`. Message bodies are structured segment arrays, never
/// CQ strings.
class OneBot11Provider extends ChannelProviderBase {
  OneBot11Provider({
    required super.accountId,
    required this.webSocketUrl,
    this.accessToken = '',
    this.expectedSelfId = '',
    this.transport = OneBot11Transport.forward,
    this.listenHost = '0.0.0.0',
    this.listenPort = 8082,
    this.actionTimeout = const Duration(seconds: 15),
    this.heartbeatTimeout = const Duration(seconds: 90),
    this.watchdogInterval = const Duration(seconds: 15),
    this.minBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
  }) : super(providerId: ChannelProviderIds.oneBot11);

  final String webSocketUrl;
  final String accessToken;

  /// Which side opens the socket.
  final OneBot11Transport transport;

  /// Where [OneBot11Transport.reverse] binds. The default matches the address
  /// NapCat's WebSocket client ships with, so a fresh NapCat needs only the
  /// phone's IP.
  final String listenHost;
  final int listenPort;

  /// The QQ number the implementation must report. Empty means "accept what
  /// the first lifecycle event says", which the settings page discourages.
  final String expectedSelfId;

  final Duration actionTimeout;
  final Duration heartbeatTimeout;

  /// How often the heartbeat watchdog looks at the clock. Tests shorten it;
  /// production does not need to.
  final Duration watchdogInterval;
  final Duration minBackoff;
  final Duration maxBackoff;

  static const declaredCapabilities = ChannelCapabilities({
    ChannelCapability.directMessage: CapabilitySpec(
      CapabilityStatus.native,
      note: '私聊消息通过 send_private_msg 发送。',
    ),
    ChannelCapability.groupMessage: CapabilitySpec(
      CapabilityStatus.native,
      note: '群聊需要把机器人账号加入群，并按白名单放行。',
    ),
    ChannelCapability.activeMessage: CapabilitySpec(
      CapabilityStatus.extension,
      note: 'OneBot 没有平台级主动消息限制，但账号被风控时发送会失败。',
    ),
    ChannelCapability.passiveReply: CapabilitySpec(
      CapabilityStatus.application,
      note: '通过 reply 消息段引用原消息，是否生效取决于实现。',
    ),
    ChannelCapability.image: CapabilitySpec(
      CapabilityStatus.extension,
      note: '本版本只发送文本，图片接收会被记录但不转给 Agent。',
    ),
    ChannelCapability.file: CapabilitySpec.unverified('未在真实账号上验证文件发送。'),
    ChannelCapability.voice: CapabilitySpec.unverified('未在真实账号上验证语音。'),
    ChannelCapability.messageReply: CapabilitySpec(
      CapabilityStatus.native,
      note: '通过 reply 消息段引用。',
    ),
    ChannelCapability.messageEdit: CapabilitySpec.unsupported(
      'OneBot 11 无消息编辑动作。',
    ),
    ChannelCapability.messageRecall: CapabilitySpec(
      CapabilityStatus.unverified,
      note: 'delete_msg 未在本版本实现。',
    ),
    ChannelCapability.messageQuery: CapabilitySpec(
      CapabilityStatus.unverified,
      note: 'get_msg 未在本版本实现。',
    ),
    ChannelCapability.longText: CapabilitySpec(
      CapabilityStatus.application,
      note: '按 3000 UTF-16 单元分段发送，每段一次 API 调用。',
      limit: '每段 3000 个 UTF-16 单元',
    ),
  });

  @override
  ChannelCapabilities get capabilities => declaredCapabilities;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSubscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatWatchdog;
  bool _running = false;
  int _generation = 0;
  int _consecutiveFailures = 0;
  int _echoSequence = 0;
  String? _selfId;
  DateTime? _lastHeartbeat;
  Duration? _heartbeatInterval;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final _random = Random();

  /// The QQ number the socket reported, once known.
  String? get selfId => _selfId;

  @override
  Future<void> connect() async {
    if (isClosed || _running) return;
    switch (transport) {
      case OneBot11Transport.forward:
        final uri = Uri.tryParse(webSocketUrl);
        if (uri == null || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
          publishStatus(
            ProviderState.needsSetup,
            detail: 'WebSocket 地址无效',
            clearError: true,
          );
          return;
        }
      case OneBot11Transport.reverse:
        // A listener without a token is an open door to the agent for everyone
        // on the same network. Refused, not warned about.
        if (accessToken.trim().isEmpty) {
          publishStatus(
            ProviderState.needsSetup,
            detail: '反向连接必须设置 Access Token',
            clearError: true,
          );
          return;
        }
        if (listenPort <= 0 || listenPort > 65535) {
          publishStatus(
            ProviderState.needsSetup,
            detail: '监听端口无效',
            clearError: true,
          );
          return;
        }
    }
    _running = true;
    _generation++;
    unawaited(
      transport == OneBot11Transport.forward
          ? _connectOnce(_generation)
          : _listenOnce(_generation),
    );
  }

  @override
  Future<void> disconnect() async {
    _running = false;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _stopListening();
    await _closeSocket();
    if (!isClosed) publishStatus(ProviderState.disabled, detail: '已断开');
  }

  Future<void> _connectOnce(int generation) async {
    publishStatus(ProviderState.connecting, clearError: true);
    // The account is only known again once this connection's lifecycle event
    // arrives; keeping the old value would let a probe pass on a stale id.
    _selfId = null;
    try {
      final socket = await WebSocket.connect(
        webSocketUrl,
        headers: accessToken.isEmpty
            ? null
            : {'Authorization': 'Bearer $accessToken'},
      ).timeout(const Duration(seconds: 15));
      if (!_running || generation != _generation) {
        await socket.close();
        return;
      }
      _attachSocket(socket, generation);
    } on Object {
      if (!_running || generation != _generation || isClosed) return;
      _scheduleReconnect(generation, '无法连接 QQ 协议端，请检查地址、端口和 Access Token。');
    }
  }

  /// Binds the reverse-WebSocket port and waits. Nothing is reported online
  /// until a peer connects and sends a lifecycle event carrying its `self_id`.
  Future<void> _listenOnce(int generation) async {
    publishStatus(
      ProviderState.connecting,
      detail: '正在监听 $listenHost:$listenPort，等待协议端连接',
      clearError: true,
    );
    _selfId = null;
    try {
      final server = await HttpServer.bind(listenHost, listenPort);
      if (!_running || generation != _generation) {
        await server.close(force: true);
        return;
      }
      _server = server;
      _serverSubscription = server.listen(
        (request) => unawaited(_onReverseRequest(request, generation)),
        onError: (Object _) {},
        cancelOnError: false,
      );
      publishStatus(
        ProviderState.connecting,
        detail: '已监听 $listenHost:$listenPort，等待 OneBot 连接',
      );
    } on Object catch (error) {
      if (!_running || generation != _generation || isClosed) return;
      publishStatus(
        ProviderState.error,
        lastError: '无法监听端口 $listenPort：$error',
      );
      _running = false;
    }
  }

  Future<void> _onReverseRequest(HttpRequest request, int generation) async {
    if (!_running || generation != _generation || isClosed) {
      await _refuse(request, 503, 'channel closed');
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await _refuse(request, 426, 'websocket upgrade required');
      return;
    }
    if (!_authorized(request)) {
      await _refuse(request, 401, 'unauthorized');
      return;
    }
    final WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } on Object {
      return;
    }
    if (!_running || generation != _generation) {
      await socket.close();
      return;
    }
    // A peer that reconnects leaves its old socket to die on its own; the
    // newest connection is the one that answers.
    await _closeSocket();
    _attachSocket(socket, generation);
  }

  static Future<void> _refuse(
    HttpRequest request,
    int status,
    String reason,
  ) async {
    request.response
      ..statusCode = status
      ..write(reason);
    await request.response.close();
  }

  bool _authorized(HttpRequest request) {
    final expected = accessToken.trim();
    if (expected.isEmpty) return false;
    final header =
        request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final bearer = header.toLowerCase().startsWith('bearer ')
        ? header.substring(7).trim()
        : '';
    final query = request.uri.queryParameters['access_token'] ?? '';
    return _sameSecret(bearer, expected) || _sameSecret(query, expected);
  }

  /// Length-independent comparison: a wrong token must not be distinguishable
  /// from a shorter one by how long the answer takes.
  static bool _sameSecret(String given, String expected) {
    if (given.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < given.length; i++) {
      diff |= given.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }

  void _attachSocket(WebSocket socket, int generation) {
    _socket = socket;
    _lastHeartbeat = DateTime.now();
    _subscription = socket.listen(
      (frame) => _onFrame(frame, generation),
      onError: (Object error) => _onSocketGone(generation, '与 OneBot 的连接中断。'),
      onDone: () => _onSocketGone(generation, 'OneBot 已断开连接。'),
      cancelOnError: true,
    );
    _startWatchdog(generation);
    // The socket is up but not yet authenticated for our purposes: the
    // lifecycle event carries self_id, and that is what proves which QQ
    // account is on the other end.
    publishStatus(
      ProviderState.connecting,
      detail: '已连接，等待 OneBot 生命周期事件',
      clearError: true,
    );
  }

  void _onSocketGone(int generation, String reason) {
    if (!_running || generation != _generation || isClosed) return;
    if (transport == OneBot11Transport.forward) {
      _scheduleReconnect(generation, reason);
      return;
    }
    // Reverse mode keeps the listener up: the peer reconnects to us, so there
    // is nothing to redial and no backoff to apply.
    unawaited(_closeSocket());
    publishStatus(ProviderState.reconnecting, lastError: reason);
  }

  Future<void> _stopListening() async {
    final subscription = _serverSubscription;
    _serverSubscription = null;
    final server = _server;
    _server = null;
    await subscription?.cancel();
    try {
      await server?.close(force: true);
    } on Object {
      // Already closed.
    }
  }

  void _startWatchdog(int generation) {
    _heartbeatWatchdog?.cancel();
    _heartbeatWatchdog = Timer.periodic(watchdogInterval, (_) {
      if (!_running || generation != _generation) return;
      // In reverse mode the listener is up while nobody is connected; silence
      // there is waiting, not a dead socket.
      if (_socket == null) return;
      final last = _lastHeartbeat;
      if (last == null) return;
      final interval = _heartbeatInterval;
      // An implementation that announced its own interval is allowed three of
      // them; one that never did gets the configured grace period.
      final deadline = interval == null
          ? heartbeatTimeout
          : (interval * 3 > heartbeatTimeout ? interval * 3 : heartbeatTimeout);
      if (DateTime.now().difference(last) > deadline) {
        _scheduleReconnect(generation, '心跳超时，LLBot 可能已离线。');
      }
    });
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
      // A frame we cannot read is not a reason to drop a working connection.
      return;
    }
    final echo = payload['echo']?.toString();
    if (echo != null && _pending.containsKey(echo)) {
      final completer = _pending.remove(echo);
      if (completer != null && !completer.isCompleted) {
        completer.complete(payload);
      }
      return;
    }
    final postType = payload['post_type']?.toString() ?? '';
    switch (postType) {
      case 'meta_event':
        _onMeta(payload, generation);
      case 'message':
        _onMessage(payload);
      case 'message_sent':
        // Our own message echoed back: never feed it to the agent.
        break;
      default:
        // notice / request / unknown post types are ignored on purpose. A new
        // event type must not be able to break the connection.
        break;
    }
  }

  void _onMeta(Map<String, dynamic> payload, int generation) {
    final metaType = payload['meta_event_type']?.toString() ?? '';
    if (metaType == 'heartbeat') {
      _lastHeartbeat = DateTime.now();
      final interval = payload['interval'];
      if (interval is num) {
        _heartbeatInterval = Duration(milliseconds: interval.toInt());
      }
      return;
    }
    if (metaType != 'lifecycle') return;
    final subType = payload['sub_type']?.toString() ?? '';
    if (subType != 'connect' && subType != 'enable') return;
    final reported = payload['self_id']?.toString() ?? '';
    if (reported.isEmpty) {
      publishStatus(
        ProviderState.error,
        lastError: 'OneBot 没有报告 self_id，无法确认账号身份。',
      );
      unawaited(_stopForIdentityFailure(generation));
      return;
    }
    if (expectedSelfId.isNotEmpty && reported != expectedSelfId) {
      publishStatus(
        ProviderState.error,
        lastError: 'self_id 不匹配：配置为 $expectedSelfId，实际为 $reported。',
      );
      emitNotice('协议端报告的账号与配置不一致，已断开以避免用错账号回复。', isError: true);
      unawaited(_stopForIdentityFailure(generation));
      return;
    }
    _selfId = reported;
    _consecutiveFailures = 0;
    publishStatus(
      ProviderState.online,
      detail: '已连接 QQ $reported',
      clearError: true,
    );
  }

  Future<void> _stopForIdentityFailure(int generation) async {
    if (generation != _generation) return;
    _running = false;
    await _stopListening();
    await _closeSocket();
  }

  void _onMessage(Map<String, dynamic> payload) {
    final reported = payload['self_id']?.toString() ?? '';
    if (expectedSelfId.isNotEmpty &&
        reported.isNotEmpty &&
        reported != expectedSelfId) {
      // Defence in depth: even if the lifecycle check was skipped, an event
      // from another account is not ours to answer.
      return;
    }
    final message = normalizeEvent(
      payload,
      accountId: accountId,
      selfId: _selfId ?? expectedSelfId,
    );
    if (message != null) emitMessage(message);
  }

  void _scheduleReconnect(int generation, String reason) {
    if (!_running || generation != _generation || isClosed) return;
    unawaited(_closeSocket());
    _consecutiveFailures++;
    publishStatus(
      ProviderState.reconnecting,
      lastError: reason,
      consecutiveFailures: _consecutiveFailures,
    );
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

  Future<void> _closeSocket() async {
    _heartbeatWatchdog?.cancel();
    _heartbeatWatchdog = null;
    final subscription = _subscription;
    _subscription = null;
    final socket = _socket;
    _socket = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const OneBotFailure('连接已关闭，请求未完成。'));
      }
    }
    _pending.clear();
    await subscription?.cancel();
    try {
      await socket?.close();
    } on Object {
      // Closing an already-dead socket throws; nothing to do.
    }
  }

  /// Sends one action and waits for its echo-correlated response.
  ///
  /// The echo is a correlation id, never a task id: it is consumed the moment
  /// the response arrives and means nothing after that.
  Future<Map<String, dynamic>> call(
    String action,
    Map<String, Object?> params,
  ) async {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw const OneBotFailure('OneBot 连接未建立。');
    }
    final echo =
        'oc-${DateTime.now().microsecondsSinceEpoch}-${_echoSequence++}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[echo] = completer;
    socket.add(jsonEncode({'action': action, 'params': params, 'echo': echo}));
    try {
      return await completer.future.timeout(actionTimeout);
    } on TimeoutException {
      _pending.remove(echo);
      throw const OneBotFailure('OneBot 未在超时时间内返回结果。', unknown: true);
    } finally {
      _pending.remove(echo);
    }
  }

  @override
  Future<DeliveryReceipt> send(
    RenderedChannelMessage message,
    DeliveryContext context,
  ) async {
    if (isClosed) return const DeliveryReceipt.failed('渠道已关闭');
    final text = message.text.trim();
    if (text.isEmpty) return const DeliveryReceipt.failed('空消息未发送');
    final address = context.address;
    final segments = <Map<String, Object?>>[];
    final replyTo = address.replyToMessageId;
    if (replyTo != null && replyTo.isNotEmpty) {
      segments.add({
        'type': 'reply',
        'data': {'id': replyTo},
      });
    }
    segments.add({
      'type': 'text',
      'data': {'text': text},
    });
    final (action, params) = switch (address.conversationType) {
      ChannelConversationKind.direct => (
        'send_private_msg',
        <String, Object?>{
          'user_id': _asId(address.conversationId),
          'message': segments,
        },
      ),
      ChannelConversationKind.group => (
        'send_group_msg',
        <String, Object?>{
          'group_id': _asId(address.conversationId),
          'message': segments,
        },
      ),
      _ => ('', <String, Object?>{}),
    };
    if (action.isEmpty) {
      return const DeliveryReceipt.failed('OneBot 11 不支持该会话类型。');
    }
    try {
      final response = await call(action, params);
      final failure = _failureOf(response);
      if (failure != null) {
        return failure.retryable
            ? DeliveryReceipt.deferred(failure.message)
            : DeliveryReceipt.failed(failure.message);
      }
      final data = response['data'];
      final messageID = data is Map ? data['message_id']?.toString() : null;
      return DeliveryReceipt.delivered(messageId: messageID);
    } on OneBotFailure catch (error) {
      return error.unknown
          ? DeliveryReceipt.unknown(error.message)
          : DeliveryReceipt.failed(error.message, retryable: true);
    } on Object {
      return const DeliveryReceipt.unknown('发送结果不确定');
    }
  }

  /// OneBot answers `status` and `retcode` inside a 200-shaped payload; a
  /// socket that accepted the bytes proves nothing about delivery.
  static OneBotFailure? _failureOf(Map<String, dynamic> response) {
    final status = response['status']?.toString() ?? '';
    final retcode = (response['retcode'] as num?)?.toInt() ?? -1;
    if (status == 'ok' && retcode == 0) return null;
    final wording = response['wording']?.toString().trim();
    final message = wording != null && wording.isNotEmpty
        ? wording
        : response['message']?.toString().trim();
    final detail = message != null && message.isNotEmpty
        ? message
        : 'OneBot 返回 status=$status retcode=$retcode';
    return OneBotFailure(
      'OneBot 发送失败（$retcode）：$detail',
      retryable: retcode >= 1000 || retcode < 0,
    );
  }

  /// OneBot ids are numbers on the wire; the app keeps them as strings.
  static Object _asId(String raw) => int.tryParse(raw) ?? raw;

  /// Verifies the socket, the token and the reported account without sending a
  /// message to anybody.
  Future<String> probe() async {
    final previous = _running;
    if (!previous) {
      await connect();
    }
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (_selfId == null && DateTime.now().isBefore(deadline)) {
        if (status.state == ProviderState.error) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final selfId = _selfId;
      if (selfId == null) {
        final error = status.lastError ?? '未收到生命周期事件';
        throw OneBotFailure('连接失败：$error');
      }
      final version = await call('get_version_info', const {});
      final data = version['data'];
      final appName = data is Map ? data['app_name']?.toString() : null;
      final appVersion = data is Map ? data['app_version']?.toString() : null;
      final implementation = [
        if (appName != null && appName.isNotEmpty) appName,
        if (appVersion != null && appVersion.isNotEmpty) appVersion,
      ].join(' ');
      return '已连接 QQ $selfId'
          '${implementation.isEmpty ? '' : '（$implementation）'}。'
          '发送权限取决于该账号本身。';
    } finally {
      if (!previous) await disconnect();
    }
  }

  /// Asks the implementation which account is really logged in.
  ///
  /// The lifecycle event already carries `self_id`; this adds the nickname the
  /// person recognises, and proves the action channel works before a message is
  /// sent anywhere.
  Future<OneBotLogin> fetchLoginInfo() async {
    final response = await call('get_login_info', const {});
    final failure = _failureOf(response);
    if (failure != null) throw OneBotFailure(failure.message);
    final data = response['data'];
    final map = data is Map ? data : const {};
    final id = map['user_id']?.toString() ?? _selfId ?? '';
    if (id.isEmpty) throw const OneBotFailure('OneBot 未返回登录账号。');
    return OneBotLogin(id: id, nickname: map['nickname']?.toString() ?? '');
  }

  /// Asks the implementation for the groups this account is in.
  ///
  /// A group number is nine or ten digits and easy to mistype; choosing from
  /// the real list is the difference between an allowlist that works and one
  /// that silently answers nobody.
  Future<List<OneBotGroup>> fetchGroupList() async {
    final response = await call('get_group_list', const {});
    final failure = _failureOf(response);
    if (failure != null) throw OneBotFailure(failure.message);
    final data = response['data'];
    if (data is! List) return const [];
    final groups = <OneBotGroup>[];
    for (final entry in data) {
      if (entry is! Map) continue;
      final id = entry['group_id']?.toString() ?? '';
      if (id.isEmpty) continue;
      groups.add(
        OneBotGroup(
          id: id,
          name: entry['group_name']?.toString() ?? id,
          memberCount: (entry['member_count'] as num?)?.toInt(),
          maxMemberCount: (entry['max_member_count'] as num?)?.toInt(),
        ),
      );
    }
    groups.sort((a, b) => a.name.compareTo(b.name));
    return groups;
  }

  /// Turns one OneBot message event into the shared model.
  ///
  /// Unknown segment types become [ChannelSegmentType.unknown] with their raw
  /// data kept, so an implementation that sends something new does not make
  /// the message disappear.
  static ChannelMessage? normalizeEvent(
    Map<String, dynamic> payload, {
    required String accountId,
    required String selfId,
  }) {
    if (payload['post_type']?.toString() != 'message') return null;
    final messageType = payload['message_type']?.toString() ?? '';
    final sender = payload['sender'];
    final senderId =
        payload['user_id']?.toString() ??
        (sender is Map ? sender['user_id']?.toString() : null) ??
        '';
    if (senderId.isEmpty) return null;
    final kind = switch (messageType) {
      'private' => ChannelConversationKind.direct,
      'group' => ChannelConversationKind.group,
      _ => ChannelConversationKind.unknown,
    };
    final conversationId = kind == ChannelConversationKind.group
        ? payload['group_id']?.toString() ?? ''
        : senderId;
    if (conversationId.isEmpty) return null;

    final segments = <ChannelSegment>[];
    var mentionsAccount = false;
    String? replyTo;
    final rawMessage = payload['message'];
    if (rawMessage is List) {
      for (final raw in rawMessage) {
        if (raw is! Map) continue;
        final type = raw['type']?.toString() ?? '';
        final data = raw['data'];
        final fields = data is Map
            ? Map<String, Object?>.from(data)
            : const <String, Object?>{};
        switch (type) {
          case 'text':
            segments.add(ChannelSegment.text(fields['text']?.toString() ?? ''));
          case 'at':
            final target = fields['qq']?.toString() ?? '';
            segments.add(ChannelSegment.mention(target));
            if (target.isNotEmpty && target == selfId) mentionsAccount = true;
          case 'reply':
            replyTo = fields['id']?.toString();
            segments.add(
              ChannelSegment(
                type: ChannelSegmentType.reply,
                targetId: replyTo,
                extra: fields,
              ),
            );
          case 'image':
            segments.add(
              ChannelSegment(
                type: ChannelSegmentType.image,
                targetId: fields['file']?.toString(),
                extra: fields,
              ),
            );
          case 'file':
            segments.add(
              ChannelSegment(
                type: ChannelSegmentType.file,
                targetId: fields['file']?.toString(),
                extra: fields,
              ),
            );
          case 'record':
          case 'voice':
            segments.add(
              ChannelSegment(
                type: ChannelSegmentType.voice,
                targetId: fields['file']?.toString(),
                extra: fields,
              ),
            );
          case 'face':
            segments.add(
              ChannelSegment(type: ChannelSegmentType.face, extra: fields),
            );
          default:
            segments.add(
              ChannelSegment(
                type: ChannelSegmentType.unknown,
                extra: {'segment_type': type, ...fields},
              ),
            );
        }
      }
    } else if (rawMessage is String) {
      // Some implementations still report CQ strings. They are read, not
      // written: text is extracted and the raw string is kept for the adapter.
      final text = rawMessage.replaceAll(RegExp(r'\[CQ:[^\]]+\]'), '').trim();
      if (text.isNotEmpty) segments.add(ChannelSegment.text(text));
      if (rawMessage.contains('[CQ:at,') && selfId.isNotEmpty) {
        mentionsAccount = rawMessage.contains('qq=$selfId');
      }
    }

    final text = segments
        .where((segment) => segment.type == ChannelSegmentType.text)
        .map((segment) => segment.text)
        .join()
        .trim();
    return ChannelMessage(
      providerId: ChannelProviderIds.oneBot11,
      accountId: accountId,
      conversationId: conversationId,
      conversationType: kind,
      senderId: senderId,
      senderName: sender is Map ? sender['nickname']?.toString() : null,
      conversationTitle: payload['group_id']?.toString(),
      messageId: payload['message_id']?.toString() ?? '',
      text: text,
      segments: segments,
      replyToMessageId: replyTo,
      mentionsAccount: mentionsAccount,
      receivedAt: _receivedAt(payload['time']),
      extensions: {
        'message_type': messageType,
        'self_id': payload['self_id']?.toString(),
        if (payload['group_id'] != null)
          'group_id': payload['group_id']?.toString(),
        'raw_message': payload['raw_message']?.toString(),
      },
    );
  }

  static DateTime _receivedAt(Object? raw) {
    final seconds = (raw as num?)?.toInt() ?? 0;
    if (seconds <= 0) return DateTime.now();
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await closeEvents();
  }
}

class OneBotFailure implements Exception {
  const OneBotFailure(
    this.message, {
    this.retryable = false,
    this.unknown = false,
  });

  final String message;
  final bool retryable;

  /// True when the request may have been executed even though no answer came
  /// back, which is the one case that must not be retried blindly.
  final bool unknown;

  @override
  String toString() => message;
}
