import 'dart:async';

import 'package:flutter/foundation.dart';

import 'channel_capabilities.dart';
import 'channel_message.dart';

/// Stable provider identifiers. They are stored with session bindings and
/// inbox keys, so renaming one is a data migration, not a cosmetic change.
abstract final class ChannelProviderIds {
  static const telegram = 'telegram';
  static const officialQq = 'qq-official';
  static const oneBot11 = 'onebot11';

  static const all = [telegram, officialQq, oneBot11];

  static String label(String providerId) => switch (providerId) {
    telegram => 'Telegram',
    officialQq => 'QQ 官方机器人',
    oneBot11 => 'QQ 普通账号（OneBot 11）',
    _ => providerId,
  };
}

/// The lifecycle a provider reports. `needsSetup` is not an error: it is the
/// honest state of a channel whose credentials are missing, or whose platform
/// has not authorised the bot yet.
enum ProviderState {
  disabled,
  needsSetup,
  connecting,
  online,
  reconnecting,
  error,
  closed,
}

@immutable
class ProviderStatus {
  const ProviderStatus({
    required this.state,
    this.detail,
    this.lastError,
    this.changedAt,
    this.consecutiveFailures = 0,
  });

  const ProviderStatus.disabled()
    : state = ProviderState.disabled,
      detail = null,
      lastError = null,
      changedAt = null,
      consecutiveFailures = 0;

  final ProviderState state;

  /// What the provider is doing, in words a settings page can show.
  final String? detail;

  /// The last failure, already stripped of credentials and platform noise.
  final String? lastError;

  final DateTime? changedAt;
  final int consecutiveFailures;

  bool get isOnline => state == ProviderState.online;

  bool get isFailing =>
      state == ProviderState.error || state == ProviderState.reconnecting;

  ProviderStatus copyWith({
    ProviderState? state,
    String? detail,
    String? lastError,
    DateTime? changedAt,
    int? consecutiveFailures,
    bool clearError = false,
  }) => ProviderStatus(
    state: state ?? this.state,
    detail: detail ?? this.detail,
    lastError: clearError ? null : (lastError ?? this.lastError),
    changedAt: changedAt ?? this.changedAt,
    consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
  );
}

sealed class ProviderEvent {
  const ProviderEvent();
}

class ProviderStatusChanged extends ProviderEvent {
  const ProviderStatusChanged(this.status);

  final ProviderStatus status;
}

class InboundChannelMessage extends ProviderEvent {
  const InboundChannelMessage(this.message);

  final ChannelMessage message;
}

/// Something the provider wants the person to know that is not a failure of
/// the connection: a rate limit, a rejected intents mask, a message the
/// platform refused.
class ProviderNotice extends ProviderEvent {
  const ProviderNotice(this.text, {this.isError = false});

  final String text;
  final bool isError;
}

/// A message ready to leave the app: plain text, plus optional structured
/// segments when the channel can carry them.
@immutable
class RenderedChannelMessage {
  const RenderedChannelMessage({
    required this.text,
    this.segments = const [],
    this.replyToMessageId,
    this.extensions = const {},
  });

  final String text;
  final List<ChannelSegment> segments;
  final String? replyToMessageId;
  final Map<String, Object?> extensions;
}

enum DeliveryStatus {
  /// The platform confirmed the message exists.
  delivered,

  /// The platform accepted the request but has not confirmed delivery. This
  /// is what an HTTP 200 from an asynchronous queue means.
  accepted,

  /// Cannot be sent now; may succeed later (rate limit, passive window).
  deferred,

  /// Definitely not sent.
  failed,

  /// The request may have been delivered; the acknowledgement was lost.
  /// Never retried more than once, because a duplicate is worse than a gap.
  unknown,
}

@immutable
class DeliveryReceipt {
  const DeliveryReceipt({
    required this.status,
    this.messageId,
    this.error,
    this.retryable = false,
    this.retryAfter,
  });

  const DeliveryReceipt.delivered({this.messageId})
    : status = DeliveryStatus.delivered,
      error = null,
      retryable = false,
      retryAfter = null;

  const DeliveryReceipt.accepted({this.messageId})
    : status = DeliveryStatus.accepted,
      error = null,
      retryable = false,
      retryAfter = null;

  const DeliveryReceipt.failed(String this.error, {this.retryable = false})
    : status = DeliveryStatus.failed,
      messageId = null,
      retryAfter = null;

  const DeliveryReceipt.deferred(String this.error, {this.retryAfter})
    : status = DeliveryStatus.deferred,
      messageId = null,
      retryable = true;

  const DeliveryReceipt.unknown(String this.error)
    : status = DeliveryStatus.unknown,
      messageId = null,
      retryable = false,
      retryAfter = null;

  final DeliveryStatus status;
  final String? messageId;
  final String? error;
  final bool retryable;
  final Duration? retryAfter;

  bool get isSuccess =>
      status == DeliveryStatus.delivered || status == DeliveryStatus.accepted;
}

/// What a send is for. Kept with the outbox entry so a settings page can say
/// "this was the final answer, that was a progress note" and so a failed
/// progress note is never confused with a failed answer.
enum DeliveryPurpose { ack, progress, finalAnswer, notice, commandReply }

@immutable
class DeliveryContext {
  const DeliveryContext({
    required this.address,
    required this.purpose,
    this.taskId,
  });

  final ChannelAddress address;
  final DeliveryPurpose purpose;
  final String? taskId;
}

/// The contract every channel implements.
///
/// Deliberately small: connection lifecycle, one event stream, one send. All
/// policy, routing, retry and rendering lives above it, so adding Discord or
/// Slack later means writing one of these and nothing else.
abstract interface class ChannelProvider {
  String get providerId;

  /// Which bot account this instance speaks for. Two instances of the same
  /// provider with different accounts are separate objects, never shared.
  String get accountId;

  ChannelCapabilities get capabilities;

  ProviderStatus get status;

  Stream<ProviderEvent> get events;

  Future<void> connect();

  Future<void> disconnect();

  Future<DeliveryReceipt> send(
    RenderedChannelMessage message,
    DeliveryContext context,
  );

  /// Releases sockets, timers and the event stream. After this, [events] is
  /// closed and further [send] calls fail rather than hang.
  Future<void> dispose();
}

/// Shared plumbing for providers: one broadcast stream, one status, one guard
/// against emitting after close.
abstract class ChannelProviderBase implements ChannelProvider {
  ChannelProviderBase({required this.providerId, required this.accountId});

  @override
  final String providerId;

  @override
  final String accountId;

  final StreamController<ProviderEvent> _events =
      StreamController<ProviderEvent>.broadcast();

  ProviderStatus _status = const ProviderStatus.disabled();
  bool _closed = false;

  @override
  ProviderStatus get status => _status;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @protected
  bool get isClosed => _closed;

  /// Publishes a status change. Equal states with equal text are dropped so a
  /// reconnect loop cannot flood listeners.
  @protected
  void publishStatus(
    ProviderState state, {
    String? detail,
    String? lastError,
    bool clearError = false,
    int? consecutiveFailures,
  }) {
    final next = _status.copyWith(
      state: state,
      detail: detail,
      lastError: lastError,
      clearError: clearError,
      consecutiveFailures: consecutiveFailures,
      changedAt: DateTime.now(),
    );
    if (next.state == _status.state &&
        next.detail == _status.detail &&
        next.lastError == _status.lastError) {
      return;
    }
    _status = next;
    emit(ProviderStatusChanged(next));
  }

  @protected
  void emit(ProviderEvent event) {
    if (_closed || _events.isClosed) return;
    _events.add(event);
  }

  @protected
  void emitMessage(ChannelMessage message) {
    emit(InboundChannelMessage(message));
  }

  @protected
  void emitNotice(String text, {bool isError = false}) {
    emit(ProviderNotice(text, isError: isError));
  }

  /// Closes the stream exactly once. Subclasses call this from [dispose] after
  /// they have stopped their own timers and sockets.
  @protected
  Future<void> closeEvents() async {
    if (_closed) return;
    _closed = true;
    if (!_events.isClosed) await _events.close();
  }

  @override
  Future<void> dispose() async {
    await closeEvents();
  }
}
