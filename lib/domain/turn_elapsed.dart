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
    this.unclassified = Duration.zero,
    this.wall,
  });

  /// Time from the model request starting to its first token: recorded as
  /// `created → firstToken` per model step.
  final Duration wait;

  /// Recorded reasoning (thinking) part durations.
  final Duration thinking;

  /// Union of explicit output text intervals only. A generation window
  /// without text boundaries cannot distinguish output from tool arguments.
  final Duration output;

  /// The server recorded a streaming window but not its text/argument phases.
  /// Do not label the remainder as output: it may include tool arguments.
  final Duration unclassified;

  /// Recorded tool execution time (`time.start → time.end` of executed
  /// tool calls).
  final Duration toolExecution;

  /// Wall-clock time of the reply: the first model request's start to the
  /// final model request's completion, as the server recorded them. Null
  /// when the server did not record a usable span.
  final Duration? wall;

  final int steps;
  final int toolCalls;

  Duration get recorded =>
      wait + thinking + output + toolExecution + unclassified;

  bool get isEmpty => recorded == Duration.zero && wall == null;

  static TurnElapsed fromSteps(
    Iterable<MessageWithParts> messages, {
    int? liveNow,
  }) {
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
    var unclassified = Duration.zero;
    var thinking = Duration.zero;
    var output = Duration.zero;
    var toolExecution = Duration.zero;
    Duration? firstStart;
    Duration? lastEnd;
    final calls = <String>{};
    var anonymousCalls = 0;

    for (final step in steps) {
      final time = step.info.time;
      final created = time?.created;
      final firstToken = time?.firstToken;
      final streamed = time?.streamed;
      final live = identical(step, steps.last) && time?.completed == null
          ? liveNow
          : null;
      final completed = time?.completed ?? live;
      if (time?.recorded == false) {
        continue;
      }
      if (created != null &&
          created > 0 &&
          firstToken != null &&
          firstToken > created) {
        wait += Duration(milliseconds: firstToken - created);
      }
      Duration? start;
      Duration? end;
      if (created != null &&
          created > 0 &&
          completed != null &&
          completed >= created) {
        start = Duration(milliseconds: created);
        end = Duration(milliseconds: completed);
      }
      if (start != null && (firstStart == null || start < firstStart)) {
        firstStart = start;
      }
      if (end != null && (lastEnd == null || end > lastEnd)) {
        lastEnd = end;
      }
      final prose = step.parts
          .where(
            (p) =>
                !p.synthetic &&
                (p.duration != null ||
                    (live != null && !p.ended && p.startedAt != null)) &&
                (p.type == 'text' || p.type == 'reasoning'),
          )
          .toList();
      thinking += _union(
        prose.where((p) => p.type == 'reasoning'),
        liveNow: live,
      );
      output += _union(prose.where((p) => p.type == 'text'), liveNow: live);
      if (firstToken != null &&
          firstToken > 0 &&
          streamed != null &&
          streamed > firstToken) {
        final covered = _union(
          prose,
          from: firstToken,
          to: streamed,
          liveNow: live,
        );
        unclassified += Duration(milliseconds: streamed - firstToken) - covered;
      }
    }
    for (final message in unique.values) {
      for (final part in message.parts) {
        if (part.synthetic || part.type != 'tool' || !part.toolState.executed) {
          continue;
        }
        final id = part.callID ?? part.id;
        if (id != null) {
          if (!calls.add(id)) continue;
        } else {
          anonymousCalls++;
        }
        final state = part.toolState;
        final liveTool =
            steps.isNotEmpty &&
            identical(message, steps.last) &&
            liveNow != null &&
            state.startedAt != null &&
            state.completedAt == null &&
            state.status == 'running' &&
            liveNow >= state.startedAt!.millisecondsSinceEpoch;
        toolExecution +=
            state.duration ??
            (liveTool
                ? Duration(
                    milliseconds:
                        liveNow - state.startedAt!.millisecondsSinceEpoch,
                  )
                : Duration.zero);
      }
    }
    Duration? wall;
    if (firstStart != null && lastEnd != null && lastEnd >= firstStart) {
      wall = lastEnd - firstStart;
    }
    return TurnElapsed(
      wait: wait,
      thinking: thinking,
      output: output,
      unclassified: unclassified,
      toolExecution: toolExecution,
      steps: steps.length,
      toolCalls: calls.length + anonymousCalls,
      wall: wall,
    );
  }

  static Duration _union(
    Iterable<Part> parts, {
    int? from,
    int? to,
    int? liveNow,
  }) {
    final spans = <(int, int)>[];
    for (final p in parts) {
      var a = p.startedAt!.millisecondsSinceEpoch;
      var b = p.completedAt?.millisecondsSinceEpoch ?? liveNow;
      if (b == null) continue;
      if (from != null && a < from) a = from;
      if (to != null && b > to) b = to;
      if (a > 0 && b > a) spans.add((a, b));
    }
    spans.sort((a, b) => a.$1.compareTo(b.$1));
    var total = 0, start = 0, end = 0;
    for (final span in spans) {
      if (span.$1 > end) {
        total += end - start;
        start = span.$1;
        end = span.$2;
      } else if (span.$2 > end) {
        end = span.$2;
      }
    }
    return Duration(milliseconds: total + end - start);
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
  Duration get unclassified =>
      turns.fold(Duration.zero, (sum, turn) => sum + turn.unclassified);
  Duration get recorded =>
      wait + thinking + output + toolExecution + unclassified;
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

  factory SessionElapsed.fromMessages(
    List<MessageWithParts> messages, {
    int? liveNow,
  }) {
    final turns = <TurnElapsed>[];
    var steps = <MessageWithParts>[];
    void close() {
      if (steps.isNotEmpty) {
        turns.add(
          TurnElapsed.fromSteps(
            steps,
            liveNow: identical(steps.last, messages.last) ? liveNow : null,
          ),
        );
      }
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
