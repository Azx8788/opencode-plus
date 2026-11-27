import '../channels/channel_agent_port.dart';
import 'client.dart';
import 'models.dart';

/// Read-only reply lookup for the on-phone message channels. Operation gates
/// and account/profile checks stay with the connection controller.
class Api2ChannelReplies {
  const Api2ChannelReplies(this.client);

  final Api2Client client;
  static const _limit = 30;
  static const _recoveryTimeout = Duration(seconds: 5);

  Future<ChannelAgentReply?> byId(String sessionID, String messageID) async {
    if (messageID.isEmpty || messageID.contains('/')) return null;
    final message = await client.message(sessionID, messageID);
    return message.id == messageID ? _reply(message) : null;
  }

  Future<ChannelAgentReply?> latest(String sessionID) async {
    final page = await client.messages(sessionID, order: 'desc', limit: _limit);
    for (final message in page.data) {
      if (message is Api2UserMessage) break;
      if (message is! Api2AssistantMessage) continue;
      if (message.time.completed == null || message.error != null) return null;
      final reply = _reply(message);
      if (reply != null) return reply;
    }
    return null;
  }

  /// A missing SSE event is not proof of success. Require a matching durable
  /// idle row, a completed answer, and the prompt that actually came from chat.
  Future<ChannelAgentReply?> recover(
    String sessionID,
    DateTime startedAt,
    String prompt, {
    String? observedMessageId,
  }) async {
    final since = startedAt.millisecondsSinceEpoch;
    final session = await client.session(sessionID).timeout(_recoveryTimeout);
    final idle = session.time.idle;
    if (session.id != sessionID ||
        session.outcome != Api2SessionOutcome.succeeded ||
        idle == null ||
        idle < since) {
      return null;
    }
    final page = await client
        .messages(sessionID, order: 'desc', limit: _limit)
        .timeout(_recoveryTimeout);
    var sawIdle = false;
    var matchesObservation = observedMessageId == null;
    ChannelAgentReply? answer;
    for (final message in page.data) {
      final created = message.time.created;
      if (message.type == 'idle') {
        if (sawIdle ||
            created != idle ||
            message.raw['outcome'] != 'succeeded') {
          return null;
        }
        sawIdle = true;
      } else if (message is Api2UserMessage) {
        if (!sawIdle ||
            !matchesObservation ||
            answer == null ||
            created == null ||
            created < since ||
            created > idle ||
            message.text.trim() != prompt.trim()) {
          return null;
        }
        final active = await client.activeSessions().timeout(_recoveryTimeout);
        return active.containsKey(sessionID) ? null : answer;
      } else if (message is Api2AssistantMessage) {
        final completed = message.time.completed;
        if (!sawIdle ||
            completed == null ||
            completed > idle ||
            created == null ||
            created < since ||
            message.error != null) {
          return null;
        }
        if (message.id == observedMessageId) matchesObservation = true;
        answer ??= _reply(message);
      }
    }
    return null;
  }

  static ChannelAgentReply? _reply(Api2Message message) {
    if (message is! Api2AssistantMessage ||
        (message.time.completed ?? 0) <= 0 ||
        message.error != null) {
      return null;
    }
    final text = message.content
        .whereType<Api2TextContent>()
        .map((part) => part.text)
        .where((text) => text.trim().isNotEmpty)
        .join('\n')
        .trim();
    return text.isEmpty
        ? null
        : ChannelAgentReply(
            text: text,
            messageId: message.id,
            created: message.time.created,
          );
  }
}
