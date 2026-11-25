import 'package:flutter/foundation.dart';

import 'channel_message.dart';

/// Who a person is on one channel, for one bot account.
///
/// Nicknames and display names never take part: two people called "Alex" are
/// two actors, and the same person on Telegram and on QQ is two actors until
/// they explicitly link the accounts.
@immutable
class ActorKey {
  const ActorKey({
    required this.channel,
    required this.accountId,
    required this.externalUserId,
  });

  /// The provider id, not the platform brand: `qq-official` and `onebot11` are
  /// different channels even though both are QQ.
  final String channel;
  final String accountId;
  final String externalUserId;

  String get value =>
      '${_part(channel)}:${_part(accountId)}:${_part(externalUserId)}';

  @override
  bool operator ==(Object other) => other is ActorKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ActorKey($value)';
}

/// The identity of a conversation, including whose it is.
///
/// [ownerActorId] is part of the key on purpose: in a group, two members
/// talking to the same bot are two conversations with two agent sessions, and
/// neither can read the other's context.
@immutable
class ConversationKey {
  const ConversationKey({
    required this.workspaceId,
    required this.providerId,
    required this.accountId,
    required this.conversationType,
    required this.conversationId,
    required this.ownerActorId,
    this.threadId,
  });

  /// The app workspace (server profile) the agent runs in. Sessions never
  /// cross workspaces.
  final String workspaceId;
  final String providerId;
  final String accountId;
  final ChannelConversationKind conversationType;
  final String conversationId;
  final String ownerActorId;
  final String? threadId;

  String get value => [
    _part(workspaceId),
    _part(providerId),
    _part(accountId),
    conversationType.name,
    _part(conversationId),
    _part(ownerActorId),
    if (threadId != null && threadId!.isNotEmpty) _part(threadId!),
  ].join(':');

  @override
  bool operator ==(Object other) =>
      other is ConversationKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ConversationKey($value)';
}

/// Escapes the separator so a conversation id containing ':' cannot forge a
/// different key. Ids come from platforms; trusting their character set is how
/// two conversations end up sharing one session.
String _part(String raw) => Uri.encodeComponent(raw);

/// Why a message was not handed to the agent.
enum PolicyDenial {
  allowed,
  selfMessage,
  emptyMessage,
  directMessagesDisabled,
  groupMessagesDisabled,
  unknownConversation,
  userNotAllowed,
  groupNotAllowed,
  mentionRequired,
}

@immutable
class PolicyDecision {
  const PolicyDecision.allow() : denial = PolicyDenial.allowed, reason = null;

  const PolicyDecision.deny(this.denial, [this.reason]);

  final PolicyDenial denial;
  final String? reason;

  bool get allowed => denial == PolicyDenial.allowed;

  @override
  String toString() => allowed ? 'allow' : 'deny(${denial.name})';
}

/// Who may drive the agent, and from where.
///
/// Fail-closed by design: an empty allowlist admits nobody. The alternative
/// (empty means everyone) turns a missing setting into a remote shell.
@immutable
class ChannelPolicy {
  const ChannelPolicy({
    this.allowedUsers = const {},
    this.allowedGroups = const {},
    this.requireMentionInGroups = true,
    this.allowDirectMessages = true,
    this.allowGroupMessages = true,
    this.commandPrefixes = const ['/'],
  });

  /// External user ids allowed to send instructions. Empty: nobody.
  final Set<String> allowedUsers;

  /// Conversation ids (QQ group openid, Telegram group chat id) the bot may
  /// answer in. Empty: no group.
  final Set<String> allowedGroups;

  /// Group messages must address the bot, either with a mention or with one of
  /// [commandPrefixes]. Kept on by default so a busy group cannot feed the
  /// agent every line of chatter.
  final bool requireMentionInGroups;

  final bool allowDirectMessages;
  final bool allowGroupMessages;

  /// Prefixes that count as addressing the bot in a group even without a
  /// mention.
  final List<String> commandPrefixes;

  ChannelPolicy copyWith({
    Set<String>? allowedUsers,
    Set<String>? allowedGroups,
    bool? requireMentionInGroups,
    bool? allowDirectMessages,
    bool? allowGroupMessages,
  }) => ChannelPolicy(
    allowedUsers: allowedUsers ?? this.allowedUsers,
    allowedGroups: allowedGroups ?? this.allowedGroups,
    requireMentionInGroups:
        requireMentionInGroups ?? this.requireMentionInGroups,
    allowDirectMessages: allowDirectMessages ?? this.allowDirectMessages,
    allowGroupMessages: allowGroupMessages ?? this.allowGroupMessages,
    commandPrefixes: commandPrefixes,
  );

  bool startsWithCommand(String text) {
    final trimmed = text.trimLeft();
    return commandPrefixes.any(
      (prefix) => prefix.isNotEmpty && trimmed.startsWith(prefix),
    );
  }

  /// Decides whether [message] may reach the agent.
  ///
  /// [botAccountId] is the bot's own platform id, used to drop echoes of its
  /// own messages and to recognise a mention when the adapter could not.
  PolicyDecision evaluate(
    ChannelMessage message, {
    required String botAccountId,
  }) {
    if (message.senderId.isNotEmpty && message.senderId == botAccountId) {
      return const PolicyDecision.deny(PolicyDenial.selfMessage, '机器人自己的消息');
    }
    if (message.isEmpty) {
      return const PolicyDecision.deny(PolicyDenial.emptyMessage, '空消息');
    }
    switch (message.conversationType) {
      case ChannelConversationKind.direct:
        if (!allowDirectMessages) {
          return const PolicyDecision.deny(
            PolicyDenial.directMessagesDisabled,
            '该渠道未开启私聊',
          );
        }
        if (!allowedUsers.contains(message.senderId)) {
          return const PolicyDecision.deny(
            PolicyDenial.userNotAllowed,
            '发送者不在用户白名单',
          );
        }
        return const PolicyDecision.allow();
      case ChannelConversationKind.group:
      case ChannelConversationKind.channel:
        if (!allowGroupMessages) {
          return const PolicyDecision.deny(
            PolicyDenial.groupMessagesDisabled,
            '该渠道未开启群聊',
          );
        }
        if (!allowedGroups.contains(message.conversationId)) {
          return const PolicyDecision.deny(
            PolicyDenial.groupNotAllowed,
            '群不在白名单',
          );
        }
        if (!allowedUsers.contains(message.senderId)) {
          return const PolicyDecision.deny(
            PolicyDenial.userNotAllowed,
            '发送者不在用户白名单',
          );
        }
        final addressed =
            message.mentionsAccount || startsWithCommand(message.promptText);
        if (requireMentionInGroups && !addressed) {
          return const PolicyDecision.deny(
            PolicyDenial.mentionRequired,
            '群聊需要 @机器人 或命令前缀',
          );
        }
        return const PolicyDecision.allow();
      case ChannelConversationKind.unknown:
        return const PolicyDecision.deny(
          PolicyDenial.unknownConversation,
          '无法识别的会话类型',
        );
    }
  }
}
