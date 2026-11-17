import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/task_trace.dart';

void main() {
  test('task intent needs execution context, never send-time proximity', () {
    expect(
      taskPromptIntent(
        running: true,
        queued: false,
        knownTask: true,
        text: '补充：保留字体',
      ),
      TaskPromptIntent.supplement,
    );
    expect(
      taskPromptIntent(
        running: true,
        queued: true,
        knownTask: true,
        text: 'next task',
      ),
      TaskPromptIntent.independent,
    );
    expect(
      taskPromptIntent(
        running: false,
        queued: false,
        knownTask: false,
        text: '再来一个',
      ),
      TaskPromptIntent.independent,
    );
    expect(
      taskPromptIntent(
        running: true,
        queued: false,
        knownTask: false,
        text: '修改',
      ),
      TaskPromptIntent.pending,
    );
    expect(
      taskPromptIntent(
        running: true,
        queued: false,
        knownTask: true,
        text: '新的独立任务',
      ),
      TaskPromptIntent.pending,
    );
    expect(
      taskPromptIntent(
        running: null,
        queued: false,
        knownTask: true,
        text: '补充',
      ),
      TaskPromptIntent.pending,
    );
  });

  test('supplements and children do not increase user-task count', () {
    final graph = TaskTraceGraph();
    var serial = 0;
    void event(String type, String session, Map<String, dynamic> data) =>
        graph.add({
          'id': 'event-${serial++}',
          'type': type,
          'sessionID': session,
          'at': 1000 + serial * 100,
          ...data,
        });
    event('task.admitted', 'parent', {
      'inboxID': 'm1',
      'task': {'id': 't1', 'intent': 'independent'},
    });
    event('session.inbox.delivered', 'parent', {'inboxID': 'm1'});
    event('session.execution.started', 'parent', {});
    event('task.admitted', 'parent', {
      'inboxID': 'm2',
      'task': {'id': 't1', 'intent': 'supplement'},
    });
    event('session.inbox.delivered', 'parent', {'inboxID': 'm2'});
    event('session.step.started', 'parent', {
      'assistantMessageID': 'a1',
      'model': {'providerID': 'p', 'id': 'model'},
    });
    event('session.created', 'child', {'parentID': 'parent'});
    event('session.tool.success', 'parent', {
      'assistantMessageID': 'a1',
      'callID': 'call1',
      'childSessionID': 'child',
    });
    event('session.execution.started', 'child', {});
    event('session.step.started', 'child', {'assistantMessageID': 'a2'});
    event('session.step.failed', 'child', {
      'assistantMessageID': 'a2',
      'error': {'type': 'provider.error', 'status': 429},
    });
    event('session.execution.failed', 'child', {});
    event('session.step.ended', 'parent', {
      'assistantMessageID': 'a1',
      'tokens': {'input': 20, 'output': 5},
    });
    event('session.execution.succeeded', 'parent', {});
    expect(graph.userTasks, 1);
    expect(graph.subagents, 1);
    expect(graph.requests.length, 2);
    expect(graph.tasks['t1']!.messageIDs, {'m1', 'm2'});
    expect(graph.tasks['t1']!.status, TraceTaskStatus.succeeded);
    expect(graph.tasks['agent:child']!.status, TraceTaskStatus.failed);
    expect(graph.tasks['agent:child']!.parentID, 't1');
    expect(graph.requests['a2']!.taskID, 'agent:child');
  });

  test('unidentified origin remains pending and replay is idempotent', () {
    final graph = TaskTraceGraph();
    final event = {
      'id': 'one',
      'type': 'session.step.started',
      'sessionID': 's',
      'assistantMessageID': 'a',
      'at': 1000,
    };
    graph.add(event);
    graph.add(event);
    expect(graph.userTasks, 0);
    expect(graph.pendingAssociations, 1);
    expect(graph.requests.length, 1);
    expect(graph.requests['a']!.speed, isNull);
  });

  test('missing usage does not turn into a zero-token successful report', () {
    final graph = TaskTraceGraph();
    graph.add({
      'id': 'a',
      'type': 'session.step.started',
      'sessionID': 's',
      'assistantMessageID': 'a',
      'at': 1000,
    });
    graph.add({
      'id': 'b',
      'type': 'session.step.failed',
      'sessionID': 's',
      'assistantMessageID': 'a',
      'at': 2000,
    });
    final usage = graph.modelUsage(graph.requests.values).single;
    expect(usage.calls, 1);
    expect(usage.failed, 1);
    expect(usage.usageMissing, 1);
    expect(usage.successRate, 0);
  });
}
