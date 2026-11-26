import 'package:flutter/foundation.dart';

/// Where a conversation lives, in terms this app can act on without knowing
/// which platform delivered it.
///
/// The values are deliberately coarse: a channel adapter decides which of its
/// own scopes maps here, and nothing above this layer branches on a platform
/// name.
enum ChannelConversationKind {
  /// One person talking to the bot alone: Telegram private chat, QQ C2C, a
  /// OneBot `private` message.
  direct,

  /// A group of people: QQ group, Telegram group or supergroup, OneBot `group`.
  group,

  /// A broadcast-style channel (QQ 频道子频道). Kept separate from [group]
  /// because its permissions and reply rules are different.
  channel,

  /// A scope the adapter could not classify. Messages still flow, but group
  /// policy treats them as closed.
  unknown,
}

/// One piece of a message, normalised away from any platform's wire format.
enum ChannelSegmentType {
  text,
  mention,
  image,
  file,
  voice,
  reply,
  face,

  /// A segment this build does not understand. Preserved rather than dropped
  /// so a future adapter can still see it in [ChannelMessage.extensions].
  unknown,
}

@immutable
class ChannelSegment {
  const ChannelSegment({
    required this.type,
    this.text = '',
    this.targetId,
    this.extra = const {},
  });

  const ChannelSegment.text(String value)
    : type = ChannelSegmentType.text,
      text = value,
      targetId = null,
      extra = const {};

  const ChannelSegment.mention(String id)
    : type = ChannelSegmentType.mention,
      text = '',
      targetId = id,
      extra = const {};

  final ChannelSegmentType type;

  /// The segment's own text, when it has one. Mentions and images carry none:
  /// their meaning is in [targetId] or [extra].
  final String text;

  /// Who or what the segment points at: a mentioned user, a replied-to
  /// message, a media id.
  final String? targetId;

  /// Channel-specific extras for this segment (image URL, file name, the raw
  /// segment map). Only the adapter that produced the message reads them.
  final Map<String, Object?> extra;

  @override
  String toString() =>
      'ChannelSegment(${type.name}${targetId == null ? '' : ':$targetId'})';
}

/// A channel-neutral inbound message.
///
/// Everything above the adapter layer sees this type. OneBot's JSON, Telegram
/// updates and the official QQ payloads stop at the provider; if a field is
/// missing here it is because the shared layers do not need it, not because
/// the platform lacked it — the raw shape stays in [extensions] for the
/// adapter that owns it.
@immutable
class ChannelMessage {
  const ChannelMessage({
    required this.providerId,
    required this.accountId,
    required this.conversationId,
    required this.conversationType,
    required this.senderId,
    required this.messageId,
    required this.receivedAt,
    this.text = '',
    this.segments = const [],
    this.replyToMessageId,
    this.senderName,
    this.conversationTitle,
    this.mentionsAccount = false,
    this.extensions = const {},
  });

  /// Which provider class produced this message (`telegram`, `qq-official`,
  /// `onebot11`).
  final String providerId;

  /// Which bot account received it. Two bots of the same provider must never
  /// share identities or sessions.
  final String accountId;

  /// The platform's conversation id, as a string. Telegram chat ids and QQ
  /// openids are not numbers this app may assume anything about.
  final String conversationId;

  final ChannelConversationKind conversationType;

  /// The platform's id for the human who sent it, as a string.
  final String senderId;

  final String? senderName;
  final String? conversationTitle;

  /// The platform's message id. Empty only when the platform genuinely has
  /// none; the inbox then falls back to a scoped fingerprint.
  final String messageId;

  /// The plain text of the message with mentions stripped of their markup.
  /// Empty for media-only messages.
  final String text;

  final List<ChannelSegment> segments;

  /// Set when the platform says this message replies to another one.
  final String? replyToMessageId;

  /// True when the platform already told us the bot was addressed (a QQ
  /// `GROUP_AT_MESSAGE_CREATE`, a OneBot `at` segment naming the bot).
  final bool mentionsAccount;

  final DateTime receivedAt;

  /// Adapter-owned extras. Never passed to the agent core; used for things
  /// like the passive-reply `msg_id` that the outbox needs to answer at all.
  final Map<String, Object?> extensions;

  /// The text segments joined, for prompts. Falls back to [text] when the
  /// message carried no structured segments.
  String get promptText {
    final joined = segments
        .where((segment) => segment.type == ChannelSegmentType.text)
        .map((segment) => segment.text)
        .join()
        .trim();
    return joined.isNotEmpty ? joined : text.trim();
  }

  /// True when the message carries nothing an agent could act on.
  bool get isEmpty => promptText.isEmpty && segments.isEmpty;

  ChannelMessage copyWith({
    String? text,
    List<ChannelSegment>? segments,
    String? replyToMessageId,
    Map<String, Object?>? extensions,
    bool? mentionsAccount,
  }) => ChannelMessage(
    providerId: providerId,
    accountId: accountId,
    conversationId: conversationId,
    conversationType: conversationType,
    senderId: senderId,
    senderName: senderName,
    conversationTitle: conversationTitle,
    messageId: messageId,
    text: text ?? this.text,
    segments: segments ?? this.segments,
    replyToMessageId: replyToMessageId ?? this.replyToMessageId,
    mentionsAccount: mentionsAccount ?? this.mentionsAccount,
    receivedAt: receivedAt,
    extensions: extensions ?? this.extensions,
  );

  @override
  String toString() =>
      'ChannelMessage($providerId/$accountId '
      '${conversationType.name}:$conversationId from $senderId #$messageId)';
}

/// Where an outbound message must go, plus what the platform needs to accept
/// it as an answer rather than a cold push.
@immutable
class ChannelAddress {
  const ChannelAddress({
    required this.providerId,
    required this.accountId,
    required this.conversationId,
    required this.conversationType,
    this.replyToMessageId,
    this.extensions = const {},
  });

  factory ChannelAddress.of(ChannelMessage message) => ChannelAddress(
    providerId: message.providerId,
    accountId: message.accountId,
    conversationId: message.conversationId,
    conversationType: message.conversationType,
    replyToMessageId: message.messageId.isEmpty ? null : message.messageId,
    extensions: message.extensions,
  );

  final String providerId;
  final String accountId;
  final String conversationId;
  final ChannelConversationKind conversationType;

  /// The inbound message this answers, when the platform requires one for a
  /// reply to be allowed at all.
  final String? replyToMessageId;

  /// Adapter-owned extras needed to address the reply (a passive `msg_id`,
  /// an `event_id`, a group openid).
  final Map<String, Object?> extensions;

  ChannelAddress copyWith({
    String? replyToMessageId,
    Map<String, Object?>? extensions,
  }) => ChannelAddress(
    providerId: providerId,
    accountId: accountId,
    conversationId: conversationId,
    conversationType: conversationType,
    replyToMessageId: replyToMessageId ?? this.replyToMessageId,
    extensions: extensions ?? this.extensions,
  );

  @override
  String toString() =>
      'ChannelAddress($providerId/$accountId '
      '${conversationType.name}:$conversationId)';
}
