import 'package:flutter/foundation.dart';

import 'channel_identity.dart';
import 'channel_message.dart';
import 'channel_sessions.dart';

/// A prompt on its way to the agent, with the conversation it belongs to.
@immutable
class ChannelPromptRequest {
  const ChannelPromptRequest({
    required this.conversation,
    required this.message,
    required this.text,
    this.binding,
    this.onSessionReady,
  });

  final ConversationKey conversation;
  final ChannelMessage message;
  final String text;

  /// The session this conversation was already bound to, when there is one.
  /// The port reuses it instead of opening a second session for the same chat.
  final ChannelSessionBinding? binding;

  /// The port registers the resolved session before submitting the prompt:
  /// a fast run can emit its completion before the HTTP receipt arrives.
  final Future<void> Function(ChannelSessionBinding binding)? onSessionReady;
}

/// One finished assistant message, with the identity needed to deliver it
/// exactly once.
///
/// The text alone is not enough: the same sentence can be produced by two
/// turns, and a turn that is followed immediately by another must not have its
/// answer mistaken for the next one's. [messageId] is the server's own id; it
/// is empty only on gateways that do not expose one.
@immutable
class ChannelAgentReply {
  const ChannelAgentReply({
    required this.text,
    this.messageId = '',
    this.created,
  });

  final String text;
  final String messageId;
  final int? created;

  bool get isEmpty => text.trim().isEmpty;
}

/// What the channel layer is allowed to ask of the agent.
///
/// This is the only door between messaging and the agent core. It has no
/// method that creates a session out of nothing, no tool access and no way to
/// approve a permission request: those stay in the app, where the person is.
abstract class ChannelAgentPort {
  /// Sends [request] as an ordinary agent prompt and returns the session it
  /// landed in. Throws when the app is not connected or no project is open.
  Future<String> sendPrompt(ChannelPromptRequest request);

  /// Interrupts the task running in [sessionID]. A null session means "stop
  /// whatever this channel is currently driving", which is what a `/stop`
  /// typed before any conversation was bound needs.
  Future<void> stopTask(String? sessionID);

  /// The last finished assistant text of [sessionID], or null when the last
  /// turn produced none.
  Future<String?> latestReply(String sessionID);

  /// The same reply, with the server's message id when the gateway exposes
  /// one. The default keeps gateways that only have text working: they lose
  /// id-based de-duplication, not delivery.
  Future<ChannelAgentReply?> latestReplyInfo(String sessionID) async {
    final text = await latestReply(sessionID);
    return text == null ? null : ChannelAgentReply(text: text);
  }

  /// Looks up the specific assistant message seen in a turn's events.
  Future<ChannelAgentReply?> replyForMessage(
    String sessionID,
    String messageID,
  ) async {
    final reply = await latestReplyInfo(sessionID);
    return reply?.messageId == messageID ? reply : null;
  }

  /// Returns a confirmed result for this prompt if its terminal SSE was lost.
  /// An unknown or still-running task yields null, never a guessed answer.
  Future<ChannelAgentReply?> recoverReply(
    String sessionID,
    DateTime startedAt,
    String prompt, {
    String? observedMessageId,
  }) async => null;

  /// One line describing the local agent, for `/status`.
  String statusText();

  /// Whether [sessionID] is executing a turn right now.
  bool isBusy(String sessionID);

  /// False in this build: approvals happen in the app's own permission UI.
  /// A channel that cannot answer safely must not pretend it can.
  bool get supportsPermissionAnswers => false;

  Future<void> answerPermission(String sessionID, {required bool allow}) async {
    throw UnsupportedError('This app answers permissions in its own UI.');
  }
}
