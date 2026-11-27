/// One execution turn: a prompt that was submitted, the session it runs in,
/// and the answer that is owed to the chat.
///
/// The engine used to decide "should I send the final answer" by reading a
/// mutable `running` flag twice, 350 ms and 500 ms after the session went
/// idle. A queued prompt that started the next turn in between flipped that
/// flag, so both callbacks returned early and the answer was dropped. The flag
/// described the *session*; the question was about the *turn*. This type is
/// the turn: it carries its own identity, its own session, its own delivered
/// message ids, and its own outcome, so a late callback reads the turn it was
/// scheduled for and nothing else.
library;

import 'channel_agent_port.dart';
import 'channel_message.dart';
import 'channel_sessions.dart';

enum TurnPhase {
  /// Submitted to the agent; the session may or may not be executing yet.
  running,

  /// The session reported idle. The answer is being collected.
  finishing,

  /// Execution ended and the answer, if any, was handed to the delivery path.
  /// Platform acknowledgement is tracked independently in the ledger.
  closed,

  /// `/stop` was asked for. Nothing from this turn is delivered afterwards.
  cancelled,
}

/// One turn of one conversation.
///
/// A turn is created per submitted prompt — a supplement joins the open turn
/// instead of creating a second one — and it is never reused. Identity is what
/// makes delivery safe: two turns of the same session in a row cannot deliver
/// each other's answer, because each only accepts a message id it has not
/// already delivered.
class ChannelTurn {
  ChannelTurn({
    required this.id,
    required this.conversationKey,
    required this.prompt,
    required this.startedAt,
  }) : lastPrompt = prompt;

  /// Stable for the life of the turn; also the task id the outbox records.
  final String id;

  final String conversationKey;
  final String prompt;
  String lastPrompt;
  final DateTime startedAt;

  /// The OpenCode session this turn will be submitted to. Known before POST
  /// in ports that resolve the session first.
  String? sessionID;
  ChannelSessionBinding? binding;
  ChannelMessage? request;
  bool promptAccepted = false;
  bool executionObserved = false;

  DateTime? finishedAt;

  TurnPhase phase = TurnPhase.running;

  /// How many corrections the person added to this turn while it ran.
  int supplements = 0;

  bool waitingPermission = false;

  /// Assistant message ids already delivered for this turn. A turn never
  /// delivers the same message twice, and a message delivered as an
  /// intermediate update is not repeated as the final answer.
  final List<String> deliveredMessageIds = [];

  /// The last assistant message this turn saw complete, whether or not it has
  /// been sent yet.
  String? lastSeenMessageId;

  String? _textMessageId;
  final _textParts = <String, String>{};

  void rememberText(String messageId, String partId, String text) {
    if (_textMessageId != messageId) _textParts.clear();
    _textMessageId = messageId;
    _textParts[partId] = text;
  }

  ChannelAgentReply? get streamedReply {
    final id = _textMessageId;
    if (id == null) return null;
    return ChannelAgentReply(text: _textParts.values.join('\n'), messageId: id);
  }

  bool get isOpen => phase == TurnPhase.running;
  bool get isCancelled => phase == TurnPhase.cancelled;
  bool get isFinished =>
      phase == TurnPhase.finishing ||
      phase == TurnPhase.closed ||
      phase == TurnPhase.cancelled;

  bool hasDelivered(String? messageId) =>
      messageId != null && deliveredMessageIds.contains(messageId);

  void remember(String? messageId) {
    if (messageId == null || messageId.isEmpty) return;
    lastSeenMessageId = messageId;
  }

  void markDelivered(String? messageId) {
    if (messageId != null && messageId.isNotEmpty) {
      deliveredMessageIds.add(messageId);
    }
  }

  @override
  String toString() =>
      'ChannelTurn($id, ${phase.name}, session=$sessionID, '
      'delivered=${deliveredMessageIds.length})';
}
