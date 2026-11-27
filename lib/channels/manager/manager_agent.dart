/// The manager agent: the only thing allowed to decide what the person reads.
///
/// The engine used to decide that by watching events — "the session went idle,
/// so the last assistant message must be the answer" — which is why a turn
/// starting at the wrong moment could swallow the answer, and why a model that
/// wanted to stay quiet could not. Here the model is given a small, explicit
/// set of tools and one rule: nothing reaches the chat except through
/// `send_message`. The executor's own words are never relayed on their own.
library;

import 'dart:async';
import 'dart:convert';

import '../channel_tasks.dart';
import 'manager_client.dart';

/// What the manager may do to the app, and nothing more.
///
/// Implemented by the conversation that received the message, so a manager
/// instance cannot address another chat even if the model asks it to: the
/// tools have no "to" parameter.
abstract class ManagerHost {
  /// "QQ 群 123456" / "Telegram 私聊" — what the manager tells the person it is.
  String get channelLabel;

  /// The project the executor runs in, for context.
  String get projectLabel;

  /// Submits [text] to the executor. Returns the task id, or null when the
  /// agent is not connected.
  Future<String?> submitTask(String text);

  /// Sends [text] to this conversation. False when the platform refused it.
  Future<bool> sendMessage(String text);

  ChannelTaskRecord? taskById(String id);

  List<ChannelTaskRecord> recentTasks({int limit = 10});

  Future<bool> cancelTask(String id);
}

/// What one manager run produced. The engine uses [spoke] to decide whether a
/// fallback is needed.
class ManagerOutcome {
  const ManagerOutcome({
    required this.spoke,
    this.silentByChoice = false,
    this.reason,
    this.steps = 0,
  });

  /// True when at least one `send_message` reached the chat.
  final bool spoke;

  /// The model asked to stay quiet. A deliberate silence is an answer: the
  /// engine must not fill it with a fallback.
  final bool silentByChoice;

  /// Why the run ended without speaking, when it did.
  final String? reason;

  final int steps;

  static const silent = ManagerOutcome(spoke: false, reason: '没有发送任何消息');
}

class ChannelManagerAgent {
  ChannelManagerAgent({
    required this.client,
    this.maxSteps = 6,
    this.historyLimit = 16,
    this.clock,
  });

  final ManagerModelClient client;
  final int maxSteps;
  final int historyLimit;
  final DateTime Function()? clock;

  /// Conversation key → recent (role, content) pairs. Bounded, in memory: a
  /// restart loses the small talk, not the tasks.
  final Map<String, List<Map<String, Object?>>> _history = {};

  static const _tools = <Map<String, Object?>>[
    {
      'type': 'function',
      'function': {
        'name': 'submit_task',
        'description': '把一项工作交给执行 Agent。返回 task_id。提交成功不代表任务完成。',
        'parameters': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string', 'description': '完整的任务描述'},
          },
          'required': ['text'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'send_message',
        'description': '向当前用户发送一条消息。这是唯一能让用户看到内容的工具。',
        'parameters': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string', 'description': '要发送的正文'},
          },
          'required': ['text'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'get_task_status',
        'description':
            '查询任务状态：submitted/running/waiting_permission/completed/failed/cancelled。',
        'parameters': {
          'type': 'object',
          'properties': {
            'task_id': {'type': 'string'},
          },
          'required': ['task_id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'get_task_result',
        'description': '取任务的结果正文。任务未完成时返回空。',
        'parameters': {
          'type': 'object',
          'properties': {
            'task_id': {'type': 'string'},
          },
          'required': ['task_id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'cancel_task',
        'description': '取消一个任务。已进入执行队列的补充消息不一定能撤回。',
        'parameters': {
          'type': 'object',
          'properties': {
            'task_id': {'type': 'string'},
          },
          'required': ['task_id'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'stay_silent',
        'description': '明确决定本次不回复用户（例如重复消息、无意义的寒暄）。调用后不要再调用 send_message。',
        'parameters': {
          'type': 'object',
          'properties': {
            'reason': {'type': 'string', 'description': '不回复的原因'},
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_tasks',
        'description': '列出本会话最近的任务。',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
  ];

  String _systemPrompt(ManagerHost host) =>
      '你是 OpenCode Plus 的消息管理员，负责通过${host.channelLabel}与用户交流。'
      '当前项目：${host.projectLabel}。\n'
      '你的职责：理解用户请求、决定是否提交给执行 Agent、跟踪进度、把结果整理后交给用户。\n'
      '规则：\n'
      '1. 所有对外发言必须调用 send_message；你的普通回复用户看不到。\n'
      '2. 提交成功不等于执行成功。没有拿到真实结果前，不得声称任务完成。\n'
      '3. 不得编造进度、结果或错误信息。\n'
      '4. 执行中只有收到具体补充要求才再次 submit_task；如果只是问进度，查一次 get_task_status，再用 send_message 回答。\n'
      '5. 任务失败或等待权限时，如实说明，并说明用户需要在 App 中处理什么。\n'
      '6. 只谈论本会话的任务，不要提及其它会话、账号或用户。\n'
      '7. 回复要适合聊天窗口：简短、少用表格和 Markdown。\n'
      '8. 拿不准时先问清楚，不要猜。\n'
      '9. 不要反复查询同一任务；拿到状态就回答。';

  /// Runs the manager for one inbound message.
  Future<ManagerOutcome> handleUserMessage({
    required String conversationKey,
    required String text,
    required ManagerHost host,
  }) {
    final history = _history.putIfAbsent(conversationKey, () => []);
    return _run(
      conversationKey: conversationKey,
      host: host,
      seed: {'role': 'user', 'content': text},
      history: history,
    );
  }

  /// Runs the manager after the executor finished, so it can decide what (if
  /// anything) the person should read.
  Future<ManagerOutcome> handleTaskFinished({
    required String conversationKey,
    required ChannelTaskRecord task,
    required ManagerHost host,
  }) {
    final history = _history.putIfAbsent(conversationKey, () => []);
    final result = task.result?.trim();
    final summary = StringBuffer()
      ..write('[系统事件] 任务 ${task.id} 状态：${task.status.name}。');
    if (result != null && result.isNotEmpty) {
      summary.write('\n执行结果：\n$result');
    }
    if (task.error != null && task.error!.isNotEmpty) {
      summary.write('\n错误：${task.error}');
    }
    summary.write('\n请用 send_message 把结果交付给用户；若没有可交付的内容，也要说明原因。');
    return _run(
      conversationKey: conversationKey,
      host: host,
      seed: {'role': 'user', 'content': summary.toString()},
      history: history,
    );
  }

  Future<ManagerOutcome> _run({
    required String conversationKey,
    required ManagerHost host,
    required Map<String, Object?> seed,
    required List<Map<String, Object?>> history,
  }) async {
    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': _systemPrompt(host)},
      ...history,
      seed,
    ];
    var spoke = false;
    var silent = false;
    String? reason;

    for (var step = 0; step < maxSteps; step++) {
      final ManagerModelReply reply;
      try {
        reply = await client.complete(messages: messages, tools: _tools);
      } on ManagerModelError catch (error) {
        return ManagerOutcome(
          spoke: spoke,
          silentByChoice: silent && !spoke,
          reason: error.message,
          steps: step + 1,
        );
      }

      if (!reply.hasToolCalls) {
        // A model that answers without send_message has said nothing to the
        // person. That is a rule violation, not a message.
        reason ??= '管理模型没有调用 send_message';
        break;
      }

      messages.add({
        'role': 'assistant',
        'content': reply.content ?? '',
        'tool_calls': [
          for (final call in reply.toolCalls)
            {
              'id': call.id,
              'type': 'function',
              'function': {
                'name': call.name,
                'arguments': jsonEncode(call.arguments),
              },
            },
        ],
      });

      for (final call in reply.toolCalls) {
        final result = await _execute(call, host);
        if (call.name == 'send_message' && result['sent'] == true) {
          spoke = true;
        }
        if (call.name == 'stay_silent') {
          silent = true;
          reason = call.arguments['reason']?.toString();
        }
        messages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': jsonEncode(result),
        });
      }

      // Nothing left to ask the model: it spoke and asked for nothing else.
      if (!reply.hasToolCalls) break;
    }

    // Keep only the person's words and the manager's spoken ones.
    history.add(seed);
    if (messages.isNotEmpty) {
      final lastAssistant = messages.lastWhere(
        (message) => message['role'] == 'assistant',
        orElse: () => const {},
      );
      final said = lastAssistant['content']?.toString().trim() ?? '';
      if (said.isNotEmpty) {
        history.add({'role': 'assistant', 'content': said});
      }
    }
    while (history.length > historyLimit) {
      history.removeAt(0);
    }
    return ManagerOutcome(
      spoke: spoke,
      silentByChoice: silent && !spoke,
      reason: spoke ? null : reason,
    );
  }

  Future<Map<String, Object?>> _execute(
    ManagerToolCall call,
    ManagerHost host,
  ) async {
    switch (call.name) {
      case 'send_message':
        final text = call.arguments['text']?.toString().trim() ?? '';
        if (text.isEmpty) return {'sent': false, 'error': '正文为空'};
        final sent = await host.sendMessage(text);
        return {'sent': sent};
      case 'submit_task':
        final text = call.arguments['text']?.toString().trim() ?? '';
        if (text.isEmpty) return {'error': '任务描述为空'};
        final taskID = await host.submitTask(text);
        if (taskID == null) {
          return {'error': '执行 Agent 未连接，任务没有提交'};
        }
        return {'task_id': taskID, 'status': 'submitted'};
      case 'get_task_status':
        final id = call.arguments['task_id']?.toString() ?? '';
        final task = host.taskById(id);
        if (task == null) return {'error': '没有这个任务'};
        return {
          'task_id': task.id,
          'status': task.status.name,
          'delivery': task.delivery.name,
        };
      case 'get_task_result':
        final id = call.arguments['task_id']?.toString() ?? '';
        final task = host.taskById(id);
        if (task == null) return {'error': '没有这个任务'};
        return {
          'task_id': task.id,
          'status': task.status.name,
          'result': task.result ?? '',
          'error': task.error ?? '',
        };
      case 'cancel_task':
        final id = call.arguments['task_id']?.toString() ?? '';
        final cancelled = await host.cancelTask(id);
        return {'cancelled': cancelled};
      case 'stay_silent':
        return {'acknowledged': true};
      case 'list_tasks':
        return {
          'tasks': [
            for (final task in host.recentTasks())
              {
                'task_id': task.id,
                'status': task.status.name,
                'prompt': task.prompt,
              },
          ],
        };
      default:
        return {'error': '未知工具：${call.name}'};
    }
  }
}
