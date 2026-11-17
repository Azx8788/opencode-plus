import 'models.dart';

/// Task identity is explicit admission metadata plus execution context. It is
/// not a message turn, a model request, or a guess from two nearby timestamps.
enum TaskAssociation { confirmed, pending }

enum TraceTaskStatus { queued, running, succeeded, failed, cancelled, unknown }

enum TaskPromptIntent { independent, supplement, pending }

/// Explicit queue delivery wins. Otherwise an active execution plus its known
/// task identity is required for a default supplement. Conflicts stay pending.
TaskPromptIntent taskPromptIntent({
  required bool? running,
  required bool queued,
  required bool knownTask,
  required String text,
}) {
  if (queued || running == false) return TaskPromptIntent.independent;
  if (running != true || !knownTask) return TaskPromptIntent.pending;
  if (RegExp(
    r'新的?独立(请求|任务)|另一个任务|新任务|\b(new|separate|independent) task\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    return TaskPromptIntent.pending;
  }
  return TaskPromptIntent.supplement;
}

class TraceTask {
  TraceTask({
    required this.id,
    required this.sessionID,
    required this.userTask,
    this.parentID,
    this.association = TaskAssociation.confirmed,
  });
  final String id, sessionID;
  final bool userTask;
  String? parentID;
  TaskAssociation association;
  TraceTaskStatus status = TraceTaskStatus.unknown;
  int? submitted, started, ended;
  final messageIDs = <String>{};
  final requestIDs = <String>{};
  final spans = <TraceSpan>[];
}

class TraceSpan {
  TraceSpan(this.phase, this.start, {this.end, this.partID});
  final String phase;
  final int start;
  int? end;
  final String? partID;
}

class TraceRequest {
  TraceRequest({
    required this.id,
    required this.sessionID,
    required this.taskID,
  });
  final String id, sessionID;
  String taskID;
  String? providerID, modelID;
  int? start, firstToken, streamed, end;
  TraceTaskStatus status = TraceTaskStatus.running;
  Tokens? tokens;
  String? errorType;
  int? errorStatus;
  int retryCount = 0;
  final spans = <TraceSpan>[];
  final openParts = <String, TraceSpan>{};

  Duration? get generationDuration =>
      firstToken != null && streamed != null && streamed! > firstToken!
      ? Duration(milliseconds: streamed! - firstToken!)
      : null;
  double? get speed {
    final duration = generationDuration?.inMicroseconds;
    final usage = tokens;
    if (duration == null ||
        duration <= 0 ||
        usage == null ||
        usage.output + usage.reasoning <= 0) {
      return null;
    }
    return (usage.output + usage.reasoning) *
        Duration.microsecondsPerSecond /
        duration;
  }
}

class TraceModelUsage {
  TraceModelUsage(this.providerID, this.modelID);
  final String? providerID, modelID;
  int calls = 0, succeeded = 0, failed = 0, pending = 0, usageMissing = 0;
  int input = 0, output = 0, reasoning = 0, cacheRead = 0, cacheWrite = 0;
  int retries = 0;
  double? get successRate =>
      succeeded + failed == 0 ? null : succeeded / (succeeded + failed);
}

/// Rebuildable projection of a durable, de-duplicated event log. Unknown
/// origins remain inspectable but never inflate the user-task count.
class TaskTraceGraph {
  final tasks = <String, TraceTask>{};
  final requests = <String, TraceRequest>{};
  final messageTasks = <String, String>{};
  final activeTasks = <String, String>{};
  final _childTasks = <String, String>{};
  final _delivered = <String, String>{};
  final _seen = <String>{};
  int? lastRecordedAt;

  int get userTasks => tasks.values
      .where((t) => t.userTask && t.association == TaskAssociation.confirmed)
      .length;
  int get subagents => tasks.values
      .where((t) => !t.userTask && _childTasks[t.sessionID] == t.id)
      .length;
  int get pendingAssociations => tasks.values
      .where((t) => t.association == TaskAssociation.pending)
      .length;

  String _unassigned(String sessionID) {
    final child = _childTasks[sessionID];
    if (child != null) return child;
    final id = 'pending:$sessionID';
    tasks.putIfAbsent(
      id,
      () => TraceTask(
        id: id,
        sessionID: sessionID,
        userTask: false,
        association: TaskAssociation.pending,
      ),
    );
    return id;
  }

  void add(Map<String, dynamic> event) {
    final type = event['type'], session = event['sessionID'];
    if (type is! String || session is! String || session.isEmpty) {
      throw const FormatException('Invalid task event');
    }
    final eventID = event['id'];
    if (eventID is String && !_seen.add(eventID)) return;
    final at = event['at'] is int && event['at'] > 0
        ? event['at'] as int
        : null;
    if (at != null && (lastRecordedAt == null || at > lastRecordedAt!)) {
      lastRecordedAt = at;
    }
    final message = event['inboxID'];
    final identity = event['task'];
    if (type == 'task.admitted' ||
        type == 'session.inbox.enqueued' ||
        type == 'session.inbox.delivered') {
      if (identity is Map && identity['id'] is String && message is String) {
        final id = identity['id'] as String;
        final intent = identity['intent'];
        final existing = tasks[id];
        // A supplement with no known origin must not silently create a root.
        final association =
            intent == 'independent' ||
                (intent == 'supplement' && existing != null)
            ? TaskAssociation.confirmed
            : TaskAssociation.pending;
        final task = tasks.putIfAbsent(
          id,
          () => TraceTask(
            id: id,
            sessionID: session,
            userTask: intent == 'independent',
            association: association,
          ),
        );
        if (task.sessionID != session) {
          throw const FormatException('Task scope mismatch');
        }
        task.messageIDs.add(message);
        messageTasks[message] = id;
        task.submitted ??= at;
        if (task.status == TraceTaskStatus.unknown) {
          task.status = TraceTaskStatus.queued;
        }
      }
      if (type == 'session.inbox.delivered' && message is String) {
        final id =
            messageTasks[message] ??
            _childTasks[session] ??
            _unassigned(session);
        _delivered[session] = id;
        activeTasks[session] = id;
        tasks[id]!.status = TraceTaskStatus.running;
      }
      return;
    }
    if (type == 'session.created' && event['parentID'] is String) {
      final id = 'agent:$session';
      _childTasks[session] = id;
      tasks.putIfAbsent(
        id,
        () => TraceTask(
          id: id,
          sessionID: session,
          userTask: false,
          association: TaskAssociation.pending,
        ),
      );
      return;
    }
    if (type == 'session.execution.started') {
      final id =
          _delivered[session] ?? _childTasks[session] ?? _unassigned(session);
      activeTasks[session] = id;
      final task = tasks[id]!;
      task.status = TraceTaskStatus.running;
      task.started ??= at;
      task.ended = null;
      if (at != null) task.spans.add(TraceSpan('execution', at));
      return;
    }
    if (type.startsWith('session.execution.') ||
        type == 'session.inbox.cancelled') {
      final id = type == 'session.inbox.cancelled'
          ? messageTasks[message]
          : activeTasks[session];
      final task = tasks[id];
      if (task == null) return;
      task.status = switch (type) {
        'session.execution.succeeded' => TraceTaskStatus.succeeded,
        'session.execution.failed' => TraceTaskStatus.failed,
        'session.execution.interrupted' ||
        'session.inbox.cancelled' => TraceTaskStatus.cancelled,
        _ => TraceTaskStatus.unknown,
      };
      task.ended = at;
      for (final span in task.spans.where((s) => s.end == null)) {
        span.end = at;
      }
      if (type != 'session.inbox.cancelled') {
        activeTasks.remove(session);
        _delivered.remove(session);
      }
      return;
    }
    final requestID = event['assistantMessageID'];
    if (requestID is! String) return;
    final request = requests.putIfAbsent(requestID, () {
      final id =
          activeTasks[session] ?? _childTasks[session] ?? _unassigned(session);
      tasks[id]!.requestIDs.add(requestID);
      return TraceRequest(id: requestID, sessionID: session, taskID: id);
    });
    if (request.sessionID != session) {
      throw const FormatException('Request scope mismatch');
    }
    final model = event['model'];
    if (model is Map) {
      request.providerID = model['providerID'];
      request.modelID = model['id'];
    }
    if (event['tokens'] is Map) {
      request.tokens = Tokens.fromJson(
        Map<String, dynamic>.from(event['tokens']),
      );
    }
    final error = event['error'];
    if (error is Map) {
      request.errorType = error['type'];
      request.errorStatus = error['status'];
    }
    switch (type) {
      case 'session.step.started':
        request.start ??= at;
      case 'session.step.first-token':
        request.firstToken ??= at;
      case 'session.step.streamed':
        request.streamed = at;
      case 'session.step.ended':
        request.end = at;
        request.status = TraceTaskStatus.succeeded;
      case 'session.step.failed':
        request.end = at;
        request.status = TraceTaskStatus.failed;
      case 'session.retry.scheduled':
        request.retryCount++;
        if (at != null) {
          request.spans.add(
            TraceSpan(
              error is Map && error['status'] == 429
                  ? 'provider-rate-limit'
                  : 'retry',
              at,
              end: event['retryAt'] as int?,
            ),
          );
        }
    }
    final phase = type.startsWith('session.reasoning.')
        ? 'thinking'
        : type.startsWith('session.text.')
        ? 'output'
        : type.startsWith('session.tool.')
        ? 'tool'
        : null;
    final ordinal = event['ordinal'] ?? event['callID'];
    if (phase != null && ordinal != null && at != null) {
      final key = '$phase:$ordinal';
      if (type.endsWith('.started') || type == 'session.tool.called') {
        final span = TraceSpan(
          phase,
          at,
          partID: phase == 'output'
              ? 'text-$ordinal'
              : phase == 'thinking'
              ? 'reasoning-$ordinal'
              : ordinal.toString(),
        );
        request.openParts[key] = span;
        request.spans.add(span);
      } else if (type.endsWith('.ended') ||
          type.endsWith('.success') ||
          type.endsWith('.failed')) {
        request.openParts.remove(key)?.end = at;
      }
    }
    final child = event['childSessionID'];
    if (child is String && child != session) {
      final id = _childTasks.putIfAbsent(child, () => 'agent:$child');
      final task = tasks.putIfAbsent(
        id,
        () => TraceTask(id: id, sessionID: child, userTask: false),
      );
      if (task.parentID == null) {
        task.parentID = request.taskID;
        task.association = TaskAssociation.confirmed;
      } else if (task.parentID != request.taskID) {
        task.association = TaskAssociation.pending;
      }
    }
  }

  /// Manual confirmation changes identity only, never server timestamps or
  /// execution outcomes. Rejects cycles and cross-session message guesses.
  void confirmParent(String childID, String parentID) {
    final child = tasks[childID], parent = tasks[parentID];
    if (child == null ||
        parent == null ||
        childID == parentID ||
        child.userTask) {
      throw const FormatException('Invalid task link');
    }
    final visited = <String>{childID};
    TraceTask? current = parent;
    while (current != null) {
      if (!visited.add(current.id)) throw const FormatException('Task cycle');
      current = tasks[current.parentID];
    }
    child.parentID = parentID;
    child.association = TaskAssociation.confirmed;
  }

  List<TraceModelUsage> modelUsage(Iterable<TraceRequest> source) {
    final groups = <String, TraceModelUsage>{};
    for (final r in source) {
      final key = '${r.providerID}/${r.modelID}';
      final item = groups.putIfAbsent(
        key,
        () => TraceModelUsage(r.providerID, r.modelID),
      );
      item.calls++;
      item.retries += r.retryCount;
      switch (r.status) {
        case TraceTaskStatus.succeeded:
          item.succeeded++;
        case TraceTaskStatus.failed:
          item.failed++;
        default:
          item.pending++;
      }
      final usage = r.tokens;
      if (usage == null) {
        item.usageMissing++;
        continue;
      }
      item.input += usage.input;
      item.output += usage.output;
      item.reasoning += usage.reasoning;
      item.cacheRead += usage.cacheRead;
      item.cacheWrite += usage.cacheWrite;
    }
    return groups.values.toList();
  }

  List<MessageWithParts> decorate(List<MessageWithParts> messages) => [
    for (final message in messages) _decorate(message),
  ];
  MessageWithParts _decorate(MessageWithParts message) {
    final r = requests[message.info.id];
    if (r == null || r.sessionID != message.info.sessionID) return message;
    final time = message.info.time;
    final parts = [
      for (final p in message.parts)
        () {
          final spans = r.spans.where((s) => s.partID == p.id);
          return spans.isEmpty || (p.type != 'text' && p.type != 'reasoning')
              ? p
              : p.withRecordedTime(spans.first.start, spans.first.end);
        }(),
    ];
    return MessageWithParts(
      info: message.info.withTime(
        MsgTime(
          created: time?.recorded == true ? time?.created ?? r.start : r.start,
          firstToken: time?.firstToken ?? r.firstToken,
          streamed: time?.streamed ?? r.streamed,
          completed: time?.recorded == true ? time?.completed ?? r.end : r.end,
          recorded: time?.recorded == true || r.start != null,
        ),
      ),
      parts: parts,
    );
  }
}
