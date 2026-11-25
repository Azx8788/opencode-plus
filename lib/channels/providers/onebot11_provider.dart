import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import '../channel_capabilities.dart';
import '../channel_message.dart';
import '../channel_provider.dart';

/// The ordinary-QQ channel, as a OneBot 11 client connected to an LLBot that
/// the person runs themselves.
///
/// This is not an official Tencent interface and the code does not pretend
/// otherwise: LLBot logs a real QQ account in and exposes OneBot 11, which is
/// why the settings page says so and why nothing here is bundled into the APK.
///
/// The client speaks the forward-WebSocket half of OneBot 11: events arrive on
/// the socket, API calls go out on the same socket and are correlated by
/// `echo`. Message bodies are structured segment arrays, never CQ strings.
class OneBot11Provider extends ChannelProviderBase {
  OneBot11Provider({
    required super.accountId,
    required this.webSocketUrl,
    this.accessToken = '',
    this.expectedSelfId = '',
    this.actionTimeout = const Duration(seconds: 15),
    this.heartbeatTimeout = const Duration(seconds: 90),
    this.watchdogInterval = const Duration(seconds: 15),
    this.minBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
  }) : super(providerId: ChannelProviderIds.oneBot11);

  final String webSocketUrl;
  final String accessToken;

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
    final uri = Uri.tryParse(webSocketUrl);
    if (uri == null || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      publishStatus(
        ProviderState.needsSetup,
        detail: 'WebSocket 地址无效',
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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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
      _socket = socket;
      _lastHeartbeat = DateTime.now();
      _subscription = socket.listen(
        (frame) => _onFrame(frame, generation),
        onError: (Object error) {
          if (!_running || generation != _generation || isClosed) return;
          _scheduleReconnect(generation, '与 LLBot 的连接中断，正在重连。');
        },
        onDone: () {
          if (!_running || generation != _generation || isClosed) return;
          _scheduleReconnect(generation, 'LLBot 已断开连接，正在重连。');
        },
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
    } on Object {
      if (!_running || generation != _generation || isClosed) return;
      _scheduleReconnect(generation, '无法连接 LLBot，请检查地址、端口和 Access Token。');
    }
  }

  void _startWatchdog(int generation) {
    _heartbeatWatchdog?.cancel();
    _heartbeatWatchdog = Timer.periodic(watchdogInterval, (_) {
      if (!_running || generation != _generation) return;
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
      emitNotice('LLBot 报告的账号与配置不一致，已断开以避免用错账号回复。', isError: true);
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
