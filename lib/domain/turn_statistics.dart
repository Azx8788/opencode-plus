import 'models.dart';

/// One reply's measurements. The last model request describes its context;
/// the sum of all requests describes consumption, not the context window.
/// Missing timing/usage is unknown, never estimated from text length or from
/// the phone's clock. Shell notices are not additional model steps.
class TurnStatistics {
  const TurnStatistics({
    required this.steps,
    required this.toolCalls,
    required this.total,
    this.lastUsage,
    this.duration,
    this.generationDuration,
    this.cost,
  });

  final int steps;
  final int toolCalls;
  final Tokens total;
  final Tokens? lastUsage;
  final Duration? duration;
  final Duration? generationDuration;
  final double? cost;

  int? get contextTokens => lastUsage?.total;
  int get generatedTokens => total.output + total.reasoning;

  /// Output and reasoning tokens over recorded provider streaming time.
  /// Tool execution and pauses between model steps are not in this clock.
  double? get tokensPerSecond {
    final elapsed = generationDuration?.inMicroseconds;
    if (elapsed == null || elapsed <= 0 || generatedTokens <= 0) return null;
    final speed = generatedTokens * Duration.microsecondsPerSecond / elapsed;
    return speed.isFinite ? speed : null;
  }

  factory TurnStatistics.fromSteps(Iterable<MessageWithParts> messages) {
    // Replayed events and repeated shells must not inflate the counters.
    final unique = <String, MessageWithParts>{};
    for (final message in messages) {
      if (message.info.role == 'assistant') unique[message.info.id] = message;
    }
    final modelSteps = unique.values.where(_isModelStep).toList();
    final calls = <String>{};
    var anonymousCalls = 0;
    for (final message in unique.values) {
      for (final part in message.parts) {
        if (part.type != 'tool' || !part.toolState.executed) continue;
        final id = part.callID ?? part.id;
        if (id == null) {
          anonymousCalls++;
        } else {
          calls.add(id);
        }
      }
    }
    var input = 0;
    var output = 0;
    var reasoning = 0;
    var cacheRead = 0;
    var cacheWrite = 0;
    var cost = 0.0;
    Tokens? last;
    var generationMicros = 0;
    var timingComplete = true;
    for (final step in modelSteps) {
      final tokens = step.info.tokens;
      input += tokens.input;
      output += tokens.output;
      reasoning += tokens.reasoning;
      cacheRead += tokens.cacheRead;
      cacheWrite += tokens.cacheWrite;
      cost += step.info.cost;
      if (tokens.total <= 0) timingComplete = false;
      if (tokens.output + tokens.reasoning <= 0) continue;
      final span = _generationSpan(step);
      if (span == null || span <= Duration.zero) {
        timingComplete = false;
      } else {
        generationMicros += span.inMicroseconds;
      }
    }
    Duration? duration;
    if (modelSteps.isNotEmpty && modelSteps.last.info.tokens.total > 0) {
      last = modelSteps.last.info.tokens;
    }
    if (modelSteps.isNotEmpty &&
        modelSteps.every(
          (step) => step.info.time?.created != null && step.info.time!.recorded,
        )) {
      final start = modelSteps.first.info.time!.created!;
      final end = modelSteps.last.info.time?.completed;
      if (end != null && start > 0 && end >= start) {
        duration = Duration(milliseconds: end - start);
      }
    }
    return TurnStatistics(
      steps: modelSteps.length,
      toolCalls: calls.length + anonymousCalls,
      total: Tokens(
        input: input,
        output: output,
        reasoning: reasoning,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
      ),
      lastUsage: last,
      duration: duration,
      generationDuration: timingComplete && generationMicros > 0
          ? Duration(microseconds: generationMicros)
          : null,
      cost: cost.isFinite && cost > 0 ? cost : null,
    );
  }

  static bool _isModelStep(MessageWithParts message) =>
      message.info.modelID?.trim().isNotEmpty == true ||
      message.info.tokens.total > 0 ||
      message.parts.any(
        (part) =>
            !part.synthetic &&
            (part.type == 'text' || part.type == 'reasoning') &&
            part.text.trim().isNotEmpty,
      );

  static Duration? _generationSpan(MessageWithParts step) {
    final time = step.info.time;
    final first = time?.firstToken;
    final streamed = time?.streamed;
    if (first != null && streamed != null && first > 0 && streamed > first) {
      return Duration(milliseconds: streamed - first);
    }
    // V1 can report explicit text/thought intervals rather than request
    // streaming timestamps. Only a complete set of intervals is usable.
    final generated = step.parts
        .where(
          (part) =>
              !part.synthetic &&
              (part.type == 'text' || part.type == 'reasoning') &&
              part.text.trim().isNotEmpty,
        )
        .toList();
    if (generated.isEmpty || generated.any((part) => part.duration == null)) {
      return null;
    }
    generated.sort((a, b) => a.startedAt!.compareTo(b.startedAt!));
    var start = generated.first.startedAt!;
    var end = generated.first.completedAt!;
    var micros = 0;
    for (final part in generated.skip(1)) {
      if (part.startedAt!.isAfter(end)) {
        micros += end.difference(start).inMicroseconds;
        start = part.startedAt!;
        end = part.completedAt!;
      } else if (part.completedAt!.isAfter(end)) {
        end = part.completedAt!;
      }
    }
    micros += end.difference(start).inMicroseconds;
    return micros > 0 ? Duration(microseconds: micros) : null;
  }
}
