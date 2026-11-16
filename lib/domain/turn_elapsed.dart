import 'models.dart';

/// Recorded phases of one reply, and of a whole conversation.
///
/// Every duration comes from server-recorded timestamps only. Nothing is
/// estimated from text length, the phone's clock, or a model's claimed
/// behaviour, and a phase the server did not record stays absent rather
/// than zero-filled. Phases may overlap in wall-clock time: the ring on
/// the elapsed screen shows proportions of the recorded phase time, never
/// a promise that the phases partition the reply.
class TurnElapsed {
  const TurnElapsed({
    required this.wait,
    required this.thinking,
    required this.output,
    required this.toolExecution,
    required this.steps,
    required this.toolCalls,
    this.wall,
  });

  /// Time from the model request starting to its first token: recorded as
  /// `created → firstToken` per model step. Tool-argument generation is
  /// part of this window; the server reports no separate clock for it.
  final Duration wait;

  /// Recorded reasoning (thinking) part durations.
  final Duration thinking;

  /// Recorded output streaming time: the per-step generation window
  /// (`firstToken → streamed`, or the union of explicit part intervals)
  /// minus the reasoning inside it, or the text part durations alone when
  /// no generation window was recorded.
  final Duration output;

  /// Recorded tool execution time (`time.start → time.end` of executed
  /// tool calls).
  final Duration toolExecution;

  /// Wall-clock time of the reply: the first model request's start to the
  /// final model request's completion, as the server recorded them. Null
  /// when the server did not record a usable span.
  final Duration? wall;

  final int steps;
  final int toolCalls;

  Duration get recorded => wait + thinking + output + toolExecution;

  bool get isEmpty => recorded == Duration.zero && wall == null;

  static TurnElapsed fromSteps(Iterable<MessageWithParts> messages) {
    final unique = <String, MessageWithParts>{};
    for (final message in messages) {
      if (message.info.role == 'assistant') unique[message.info.id] = message;
    }
    final steps = unique.values
        .where(
          (message) =>
              message.info.modelID?.trim().isNotEmpty == true ||
              message.info.tokens.total > 0 ||
              message.parts.any(
                (part) =>
                    !part.synthetic &&
                    (part.type == 'text' || part.type == 'reasoning') &&
                    part.text.trim().isNotEmpty,
              ),
        )
        .toList();
    var wait = Duration.zero;
    var generation = Duration.zero;
    var thinking = Duration.zero;
    var textOnly = Duration.zero;
    var toolExecution = Duration.zero;
    var windowKnown = false;
    Duration? firstStart;
    Duration? lastEnd;
    final calls = <String>{};
    var anonymousCalls = 0;

    for (final step in steps) {
      final time = step.info.time;
      final created = time?.created;
      final firstToken = time?.firstToken;
      final streamed = time?.streamed;
      final completed = time?.completed;
      if (created != null && firstToken != null && firstToken > created) {
        wait += Duration(milliseconds: firstToken - created);
      }
      if (firstToken != null && streamed != null && streamed > firstToken) {
        generation += Duration(milliseconds: streamed - firstToken);
        windowKnown = true;
      }
      Duration? start;
      Duration? end;
      if (created != null && completed != null && completed >= created) {
        start = Duration(milliseconds: created);
        end = Duration(milliseconds: completed);
      }
      if (start != null && (firstStart == null || start < firstStart)) {
        firstStart = start;
      }
      if (end != null && (lastEnd == null || end > lastEnd)) {
        lastEnd = end;
      }
      for (final part in step.parts) {
        if (part.type == 'reasoning') {
          thinking += part.duration ?? Duration.zero;
        } else if (part.type == 'text') {
          textOnly += part.duration ?? Duration.zero;
        } else if (part.type == 'tool') {
          if (!part.toolState.executed) continue;
          final id = part.callID ?? part.id;
          if (id != null) {
            calls.add(id);
          } else {
            anonymousCalls++;
          }
          toolExecution += part.toolState.duration ?? Duration.zero;
        }
      }
    }
    // The generation window contains the reasoning that streamed inside it;
    // what is left is the output. Without a window, only the text part
    // intervals were recorded.
    final output = windowKnown
        ? (generation - thinking).isNegative
              ? Duration.zero
              : generation - thinking
        : textOnly;
    Duration? wall;
    if (firstStart != null && lastEnd != null && lastEnd >= firstStart) {
      wall = lastEnd - firstStart;
    }
    return TurnElapsed(
      wait: wait,
      thinking: thinking,
      output: output,
      toolExecution: toolExecution,
      steps: steps.length,
      toolCalls: calls.length + anonymousCalls,
      wall: wall,
    );
  }
}

/// Every reply of one conversation, oldest first, plus their totals.
class SessionElapsed {
  const SessionElapsed({required this.turns});
  final List<TurnElapsed> turns;

  Duration get wait =>
      turns.fold(Duration.zero, (sum, turn) => sum + turn.wait);
  Duration get thinking =>
      turns.fold(Duration.zero, (sum, turn) => sum + turn.thinking);
  Duration get output =>
      turns.fold(Duration.zero, (sum, turn) => sum + turn.output);
  Duration get toolExecution =>
      turns.fold(Duration.zero, (sum, turn) => sum + turn.toolExecution);
  Duration get recorded => wait + thinking + output + toolExecution;
  int get steps => turns.fold(0, (sum, turn) => sum + turn.steps);
  int get toolCalls => turns.fold(0, (sum, turn) => sum + turn.toolCalls);

  /// The wall-clock span of the whole conversation is not the sum of its
  /// replies: time between replies belongs to the person, not the model.
  /// What is shown is the sum of recorded reply spans, named as such.
  Duration? get wall {
    var total = Duration.zero;
    var known = false;
    for (final turn in turns) {
      if (turn.wall case final span?) {
        total += span;
        known = true;
      }
    }
    return known ? total : null;
  }

  factory SessionElapsed.fromMessages(List<MessageWithParts> messages) {
    final turns = <TurnElapsed>[];
    var steps = <MessageWithParts>[];
    void close() {
      if (steps.isNotEmpty) turns.add(TurnElapsed.fromSteps(steps));
      steps = <MessageWithParts>[];
    }

    for (final message in messages) {
      if (message.info.role == 'user' &&
          !message.info.id.startsWith('local-')) {
        close();
      } else if (message.info.role == 'assistant') {
        steps.add(message);
      }
    }
    close();
    return SessionElapsed(turns: List.unmodifiable(turns));
  }
}
