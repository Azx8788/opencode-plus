import 'dart:async';

import '../domain/models.dart';
import 'channel_agent_port.dart';
import 'channel_identity.dart';
import 'channel_inbox.dart';
import 'channel_message.dart';
import 'channel_outbox.dart';
import 'channel_provider.dart';
import 'channel_sessions.dart';
import 'channel_text.dart';

/// Every sentence the shared pipeline says back into a chat.
///
/// Kept in one place because three channels must not drift into three
/// personalities, and because these strings are part of the product's
/// behaviour: the regression tests assert them.
class ChannelEngineCopy {
  const ChannelEngineCopy({
    this.channelNoun = '渠道',
    this.forwarded = '已转发给本地 Agent。',
    this.forwardFailed = '没有发送成功。请确认 App 已连接到本机 OpenCode、已打开项目，并检查是否有待处理的权限确认。',
    this.agentOffline = '本机 OpenCode 当前未连接，指令没有发送。请先在 App 中连接本机服务器并打开项目。',
    this.started = '本地 Agent 已开始处理任务。',
    this.finishedEmpty = 'Agent 已结束，但没有可显示的文字回复。',
    this.progressPrefix = 'Agent 进度：正在使用 ',
    this.updatePrefix = 'Agent 更新：\n',
    this.agentError = '本地 Agent 遇到错误，请在 OpenCode Plus 中查看详情。',
    this.permission = 'Agent 正在等待权限或问题确认。请在 OpenCode Plus 应用中查看并处理；本渠道不会自动批准。',
    this.stopRequested = '已请求停止当前 Agent 任务。',
    this.stopFailed = '无法停止任务；请检查 App 与本机 Agent 连接。',
    this.newSession = '下条消息将开始一个新的 Agent 会话；已有任务不会被取消。',
    this.queued = '已加入队列，将在当前任务结束后作为新任务开始。',
    this.queueEmpty = '排队指令需要跟在 /queue 后面，例如 /queue 跑一遍测试。',
    this.help =
        '已连接到 OpenCode Plus。直接发送文字即可作为 Agent 指令。\n'
        '/status 查看连接状态 · /stop 停止当前任务 · /new 开始新会话 · '
        '/queue 排队下一条指令。其他文字（含自定义斜杠指令）会发送给 Agent。',
    this.unsupportedMedia = '目前只支持文字消息。',
    this.approveRefused = '本渠道不会代替你在应用中批准权限。请在 OpenCode Plus 中处理待确认请求。',
    this.projectLabel = '项目',
    this.sessionLabel = '会话',
    this.sessionUnbound = '会话：未绑定（发送任意文字会新建会话）',
    this.errorLabel = '错误',
    this.unsupportedCapability = '该渠道不支持这项操作：',
  });

  final String channelNoun;
  final String forwarded;
  final String forwardFailed;
  final String agentOffline;
  final String started;
  final String finishedEmpty;
  final String progressPrefix;
  final String updatePrefix;
  final String agentError;
  final String permission;
  final String stopRequested;
  final String stopFailed;
  final String newSession;
  final String queued;
  final String queueEmpty;
  final String help;
  final String unsupportedMedia;
  final String approveRefused;
  final String projectLabel;
  final String sessionLabel;
  final String sessionUnbound;
  final String errorLabel;
  final String unsupportedCapability;

  static String stateLabel(ProviderState state) => switch (state) {
    ProviderState.disabled => '已关闭',
    ProviderState.needsSetup => '等待配置或授权',
    ProviderState.connecting => '正在连接',
    ProviderState.online => '正在接收消息',
    ProviderState.reconnecting => '连接异常，正在重连',
    ProviderState.error => '连接异常，正在重试',
    ProviderState.closed => '已关闭',
  };
}

/// One main task: one independent user request.
///
/// Supplements and corrections during its run belong to it. A queued request
/// becomes the next task, never a sibling of this one.
class ChannelTask {
  ChannelTask({
    required this.id,
    required this.conversationKey,
    required this.prompt,
    required this.startedAt,
  });

  final String id;
  final String conversationKey;
  final String prompt;
  final DateTime startedAt;

  int supplements = 0;
  bool waitingPermission = false;
  String? sessionID;

  bool get hasSupplements => supplements > 0;
}

class _QueuedPrompt {
  _QueuedPrompt(this.message, this.text);

  final ChannelMessage message;
  final String text;
}

class _ConversationRuntime {
  _ConversationRuntime({required this.key, required this.store});

  final ConversationKey key;
  final ChannelSessionStore store;
  ChannelTask? task;
  final List<_QueuedPrompt> queue = [];
  bool running = false;

  /// Whether "the agent started working" has already been said in this chat.
  /// A dispatch marks the conversation running optimistically so a second
  /// message is treated as a supplement; the busy event then supplies the
  /// notice exactly once.
  bool announcedStart = false;
  bool waitingPermission = false;
  ChannelMessage? lastMessage;
  String? lastSentText;
  DateTime? lastProgressAt;
  int taskSequence = 0;

  /// Handles one message at a time per conversation: two prompts racing to
  /// create the first session would otherwise open two sessions for one chat.
  Future<void> serial = Future<void>.value();

  String? get sessionID => store.current?.sessionID;
}

/// The shared pipeline behind every channel.
///
/// One instance serves one provider account: it normalises nothing (the
/// provider did), decides nothing about identity (the policy did), and owns
/// exactly the parts that must behave identically on Telegram and QQ —
/// de-duplication, conversation routing, task lifecycle, progress and final
/// rendering, and the outbox.
class ChannelConversationEngine {
  ChannelConversationEngine({
    required this.provider,
    required this.policy,
    required this.agent,
    required this.inbox,
    required this.outbox,
    required this.conversationKeyOf,
    required this.workspaceId,
    required this.directory,
    required this.workspace,
    required this.agentReady,
    this.primaryConversation,
    this.copy = const ChannelEngineCopy(),
    this.progressInterval = const Duration(seconds: 25),
    this.maxTextChunk = 3500,
    this.adoptViewedSession = false,
    this.stateLabel,
    this.onChanged,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ChannelProvider provider;
  final ChannelPolicy policy;
  final ChannelAgentPort agent;
  final ChannelInbox inbox;
  final ChannelOutbox outbox;

  /// Turns an inbound message into the conversation that owns its session.
  /// Telegram returns one fixed key (one owner chat, one session); QQ returns
  /// a per-chat, per-member key.
  final ConversationKey Function(ChannelMessage message) conversationKeyOf;

  final String workspaceId;
  final String Function() directory;
  final String Function() workspace;
  final bool Function() agentReady;

  /// Set by single-conversation channels so `/status` and `bindSession` work
  /// before the first inbound message arrives.
  final ConversationKey? primaryConversation;

  final ChannelEngineCopy copy;
  final Duration progressInterval;
  final int maxTextChunk;

  /// Whether opening a conversation in the app re-binds this channel's single
  /// session. True only for the Telegram relay, which has one conversation.
  final bool adoptViewedSession;

  /// How the channel's own state is named in `/status`. Telegram keeps its
  /// historical wording; other channels use the shared labels.
  final String Function(ProviderState state)? stateLabel;

  final void Function()? onChanged;
  final DateTime Function() _clock;

  StreamSubscription<ProviderEvent>? _subscription;
  Timer? _retryTimer;
  final Map<String, _ConversationRuntime> _runtimes = {};
  final Map<String, ChannelSessionStore> _stores = {};
  bool _started = false;
  bool _disposed = false;
  String? _lastNotice;
  PolicyDecision? _lastDenial;
  int _duplicates = 0;

  _ConversationRuntime? _primary;

  bool get isStarted => _started;

  ProviderStatus get providerStatus => provider.status;

  String? get lastNotice => _lastNotice;

  PolicyDecision? get lastDenial => _lastDenial;

  int get duplicateCount => _duplicates;

  ChannelTask? get currentTask => _primary?.task;

  /// How many requests are waiting behind the running task.
  int get queuedCount => _primary?.queue.length ?? 0;

  List<String> get queuedPrompts => [
    for (final item in _primary?.queue ?? const <_QueuedPrompt>[]) item.text,
  ];

  String? get boundSessionID => _primary?.sessionID ?? _anyRuntime()?.sessionID;

  bool get isRunning => _primary?.running ?? _anyRuntime()?.running ?? false;

  bool get waitingPermission =>
      _primary?.waitingPermission ?? _anyRuntime()?.waitingPermission ?? false;

  _ConversationRuntime? _anyRuntime() =>
      _runtimes.values.isEmpty ? null : _runtimes.values.first;

  /// Starts listening. The provider itself is connected by its owner (the
  /// channel hub), so a provider that fails to connect cannot stop the engine
  /// from being ready for the next attempt.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _subscription ??= provider.events.listen(_onProviderEvent);
    final primary = primaryConversation;
    if (primary != null) {
      final runtime = _runtimeFor(primary);
      await runtime.store.ready();
    }
    _retryTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(drainOutbox());
    });
    _notify();
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> shutdown() async {
    await stop();
    _disposed = true;
    await provider.dispose();
    _notify();
  }

  /// Retries whatever the outbox still owes for this account.
  Future<void> drainOutbox() async {
    if (_disposed) return;
    final due = await outbox.due(provider.providerId, provider.accountId);
    for (final entry in due) {
      await _deliver(entry);
    }
  }

  /// Binds (or clears) the session of the primary conversation.
  ///
  /// The Telegram bridge calls this when the app opens a conversation, which
  /// is how "continue in the app, answer in Telegram" keeps working.
  Future<void> bindSession(String? sessionID) async {
    final key = primaryConversation;
    if (key == null && _primary == null) return;
    final runtime = _primary ?? _runtimeFor(key);
    final normalized = sessionID?.trim();
    if (normalized == null || normalized.isEmpty) {
      await runtime.store.bind(null);
      runtime.running = false;
      runtime.task = null;
      runtime.lastSentText = null;
      _notify();
      return;
    }
    if (runtime.sessionID != normalized) {
      runtime.lastSentText = null;
      runtime.running = false;
      runtime.task = null;
    }
    await runtime.store.bind(
      ChannelSessionBinding(
        sessionID: normalized,
        directory: directory(),
        workspace: workspace(),
        boundAt: _clock(),
      ),
    );
    if (!runtime.running && agent.isBusy(normalized)) {
      runtime.running = true;
      runtime.task ??= _newTask(runtime, '（在 App 中打开的会话）');
      runtime.lastSentText = null;
      unawaited(_notifyChat(runtime, copy.started, DeliveryPurpose.notice));
    }
    _notify();
  }

  // ---------------------------------------------------------------- events

  void _onProviderEvent(ProviderEvent event) {
    switch (event) {
      case ProviderStatusChanged():
        _notify();
      case ProviderNotice():
        _lastNotice = event.text;
        _notify();
      case InboundChannelMessage():
        unawaited(_handleMessage(event.message));
    }
  }

  /// Feeds an agent event into the pipeline. The owner of the engine forwards
  /// every envelope here; filtering by conversation happens below, so an event
  /// for another channel's session is ignored rather than answered twice.
  void handleAgentEvent(EventEnvelope event) {
    if (!_started || _disposed) return;
    final eventDirectory = event.directory?.trim();
    if (eventDirectory != null &&
        eventDirectory.isNotEmpty &&
        eventDirectory != directory().trim()) {
      return;
    }
    final eventWorkspace = event.workspace?.trim();
    if (eventWorkspace != null &&
        eventWorkspace.isNotEmpty &&
        eventWorkspace != workspace().trim()) {
      return;
    }
    if (event.type == 'session.viewed') {
      if (!adoptViewedSession) return;
      final viewedID = event.properties['sessionID']?.toString();
      if (viewedID != null && viewedID.isNotEmpty) {
        unawaited(bindSession(viewedID));
      }
      return;
    }
    final sessionID = event.properties['sessionID']?.toString();
    if (sessionID == null || sessionID.isEmpty) return;
    final runtime = _runtimeForSession(sessionID);
    if (runtime == null) return;
    if (event.type == 'session.status') {
      final status = event.properties['status'];
      final type = status is Map
          ? status['type']?.toString()
          : status?.toString();
      if (type == 'busy') {
        _onBusy(runtime);
      } else if (type == 'idle') {
        unawaited(_finishTask(runtime));
      }
    } else if (event.type == 'session.idle') {
      unawaited(_finishTask(runtime));
    } else if (event.type == 'message.part.updated') {
      _onPartUpdated(runtime, event.properties['part']);
    } else if (event.type == 'message.updated') {
      _onMessageUpdated(runtime, event.properties['info']);
    } else if (event.type == 'session.error') {
      runtime.running = false;
      runtime.waitingPermission = false;
      unawaited(_notifyChat(runtime, copy.agentError, DeliveryPurpose.notice));
    } else if (event.type == 'permission.asked' ||
        event.type == 'permission.v2.asked' ||
        event.type == 'question.asked' ||
        event.type == 'question.v2.asked') {
      runtime.waitingPermission = true;
      runtime.task?.waitingPermission = true;
      unawaited(_notifyChat(runtime, copy.permission, DeliveryPurpose.notice));
    } else if (event.type == 'permission.replied' ||
        event.type == 'question.replied' ||
        event.type == 'question.v2.replied') {
      runtime.waitingPermission = false;
      runtime.task?.waitingPermission = false;
    }
  }

  void _onBusy(_ConversationRuntime runtime) {
    final firstNotice = !runtime.announcedStart;
    runtime.running = true;
    runtime.task ??= _newTask(runtime, '（在 App 中开始的会话）');
    if (!firstNotice) return;
    runtime.announcedStart = true;
    runtime.lastSentText = null;
    unawaited(_notifyChat(runtime, copy.started, DeliveryPurpose.notice));
  }

  void _onPartUpdated(_ConversationRuntime runtime, Object? part) {
    if (part is! Map || part['type'] != 'tool') return;
    final state = part['state'];
    if (state is! Map || state['status'] != 'running') return;
    final now = _clock();
    final last = runtime.lastProgressAt;
    if (last != null && now.difference(last) < progressInterval) return;
    runtime.lastProgressAt = now;
    final rawTool = part['tool']?.toString() ?? '';
    final tool = RegExp(r'^[a-zA-Z0-9_-]{1,32}$').hasMatch(rawTool)
        ? rawTool
        : '工具';
    unawaited(
      _notifyChat(
        runtime,
        '${copy.progressPrefix}$tool。',
        DeliveryPurpose.progress,
      ),
    );
  }

  void _onMessageUpdated(_ConversationRuntime runtime, Object? info) {
    if (info is! Map || info['role'] != 'assistant') return;
    final time = info['time'];
    final completed =
        time is Map && (time['completed'] != null || time['end'] != null);
    if (!completed || !runtime.running) return;
    unawaited(_sendMilestone(runtime));
  }

  Future<void> _sendMilestone(_ConversationRuntime runtime) async {
    final sessionID = runtime.sessionID;
    if (sessionID == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (_disposed || !runtime.running || runtime.sessionID != sessionID) return;
    String? reply;
    try {
      reply = await agent.latestReply(sessionID);
    } on Object {
      return;
    }
    if (_disposed || !runtime.running || runtime.sessionID != sessionID) {
      return;
    }
    final text = reply?.trim() ?? '';
    if (text.isEmpty || text == runtime.lastSentText) return;
    runtime.lastSentText = text;
    await _notifyChat(
      runtime,
      '${copy.updatePrefix}$text',
      DeliveryPurpose.progress,
    );
  }

  Future<void> _finishTask(_ConversationRuntime runtime) async {
    if (!runtime.running) return;
    final sessionID = runtime.sessionID;
    runtime.running = false;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_disposed || runtime.running || runtime.sessionID != sessionID) {
      return;
    }
    if (sessionID != null) {
      String? reply;
      try {
        reply = await agent.latestReply(sessionID);
      } on Object {
        reply = null;
      }
      if (_disposed || runtime.running || runtime.sessionID != sessionID) {
        return;
      }
      final text = reply?.trim() ?? '';
      if (text.isEmpty) {
        await _notifyChat(
          runtime,
          copy.finishedEmpty,
          DeliveryPurpose.finalAnswer,
        );
      } else if (text != runtime.lastSentText) {
        runtime.lastSentText = text;
        await _notifyChat(runtime, text, DeliveryPurpose.finalAnswer);
      }
    } else {
      await _notifyChat(
        runtime,
        copy.finishedEmpty,
        DeliveryPurpose.finalAnswer,
      );
    }
    runtime.task = null;
    runtime.announcedStart = false;
    await _drainQueue(runtime);
  }

  Future<void> _drainQueue(_ConversationRuntime runtime) async {
    if (runtime.queue.isEmpty || runtime.running) return;
    final next = runtime.queue.removeAt(0);
    await _dispatchPrompt(runtime, next.message, next.text);
  }

  // --------------------------------------------------------------- inbound

  Future<void> _handleMessage(ChannelMessage message) async {
    if (_disposed) return;
    final key = conversationKeyOf(message);
    final runtime = _runtimeFor(key);
    runtime.lastMessage = message;
    runtime.serial = runtime.serial.then(
      (_) => _handleMessageSerial(runtime, message),
    );
    await runtime.serial;
  }

  Future<void> _handleMessageSerial(
    _ConversationRuntime runtime,
    ChannelMessage message,
  ) async {
    if (_disposed) return;
    await runtime.store.ready();
    final decision = policy.evaluate(message, botAccountId: provider.accountId);
    if (!decision.allowed) {
      _lastDenial = decision;
      _notify();
      return;
    }
    if (!await inbox.admit(message)) {
      _duplicates++;
      _notify();
      return;
    }
    final text = stripLeadingMention(message.promptText);
    if (text.isEmpty) {
      await _replyTo(runtime, message, copy.unsupportedMedia);
      return;
    }
    final command = ChannelCommand.parse(
      text,
      prefixes: policy.commandPrefixes,
    );
    if (command != null) {
      final handled = await _handleCommand(runtime, message, command);
      if (handled) return;
    }
    await _dispatchPrompt(runtime, message, text);
  }

  Future<bool> _handleCommand(
    _ConversationRuntime runtime,
    ChannelMessage message,
    ChannelCommand command,
  ) async {
    switch (command.name) {
      case ChannelCommand.start:
      case ChannelCommand.help:
        await _replyTo(runtime, message, copy.help);
        return true;
      case ChannelCommand.status:
        await _replyTo(runtime, message, _statusFor(runtime));
        return true;
      case ChannelCommand.stop:
        await _stop(runtime, message);
        return true;
      case ChannelCommand.newSession:
        await runtime.store.bind(null);
        runtime.running = false;
        runtime.task = null;
        runtime.lastSentText = null;
        await _replyTo(runtime, message, copy.newSession);
        return true;
      case ChannelCommand.queue:
        if (command.argument.isEmpty) {
          await _replyTo(runtime, message, copy.queueEmpty);
          return true;
        }
        if (!runtime.running) {
          await _dispatchPrompt(runtime, message, command.argument);
          return true;
        }
        runtime.queue.add(_QueuedPrompt(message, command.argument));
        await _replyTo(runtime, message, copy.queued);
        return true;
      case 'approve':
      case 'deny':
        await _replyTo(runtime, message, copy.approveRefused);
        return true;
      default:
        return false;
    }
  }

  Future<void> _stop(
    _ConversationRuntime runtime,
    ChannelMessage message,
  ) async {
    try {
      await agent.stopTask(runtime.sessionID);
      runtime.running = false;
      runtime.queue.clear();
      await _replyTo(runtime, message, copy.stopRequested);
    } on Object {
      await _replyTo(runtime, message, copy.stopFailed);
    }
  }

  Future<void> _dispatchPrompt(
    _ConversationRuntime runtime,
    ChannelMessage message,
    String text,
  ) async {
    if (!agentReady()) {
      await _replyTo(runtime, message, copy.agentOffline);
      return;
    }
    final isSupplement = runtime.running;
    final task = isSupplement
        ? (runtime.task ??= _newTask(runtime, text))
        : _newTask(runtime, text);
    try {
      final sessionID = await agent.sendPrompt(
        ChannelPromptRequest(
          conversation: runtime.key,
          message: message,
          text: text,
          binding: runtime.store.current,
        ),
      );
      if (runtime.store.current?.sessionID != sessionID) {
        await runtime.store.bind(
          ChannelSessionBinding(
            sessionID: sessionID,
            directory: directory(),
            workspace: workspace(),
            boundAt: _clock(),
          ),
        );
      }
      task.sessionID = sessionID;
      runtime.task = task;
      runtime.running = true;
      if (!isSupplement) runtime.announcedStart = false;
      if (isSupplement) task.supplements++;
      await _replyTo(runtime, message, copy.forwarded, taskId: task.id);
    } on Object {
      if (!isSupplement) runtime.task = null;
      await _replyTo(
        runtime,
        message,
        copy.forwardFailed,
        purpose: DeliveryPurpose.notice,
      );
    }
    _notify();
  }

  ChannelTask _newTask(_ConversationRuntime runtime, String prompt) {
    runtime.taskSequence++;
    return ChannelTask(
      id: '${runtime.key.conversationId}#${runtime.taskSequence}',
      conversationKey: runtime.key.value,
      prompt: prompt,
      startedAt: _clock(),
    );
  }

  // --------------------------------------------------------------- outbound

  Future<void> _replyTo(
    _ConversationRuntime runtime,
    ChannelMessage message,
    String text, {
    DeliveryPurpose purpose = DeliveryPurpose.commandReply,
    String? taskId,
  }) => _send(
    ChannelAddress.of(message),
    text,
    purpose: purpose,
    taskId: taskId ?? runtime.task?.id,
  );

  Future<void> _notifyChat(
    _ConversationRuntime runtime,
    String text,
    DeliveryPurpose purpose,
  ) {
    final address = _addressFor(runtime);
    if (address == null) return Future<void>.value();
    return _send(address, text, purpose: purpose, taskId: runtime.task?.id);
  }

  /// The last address seen in a conversation, so an asynchronous notice
  /// (progress, final answer) still knows where to go.
  ChannelAddress? _addressFor(_ConversationRuntime runtime) {
    final last = runtime.lastMessage;
    return last == null ? null : ChannelAddress.of(last);
  }

  /// Chunks, queues and delivers one message. Returns the last receipt.
  Future<DeliveryReceipt?> _send(
    ChannelAddress address,
    String text, {
    required DeliveryPurpose purpose,
    String? taskId,
  }) async {
    final chunks = chunkText(text, maxCodeUnits: maxTextChunk);
    if (chunks.isEmpty) return null;
    DeliveryReceipt? last;
    for (final chunk in chunks) {
      final entry = await outbox.enqueue(
        providerId: provider.providerId,
        accountId: provider.accountId,
        address: address,
        text: chunk,
        purpose: purpose,
        taskId: taskId,
      );
      last = await _deliver(entry);
      if (last != null &&
          (last.status == DeliveryStatus.failed ||
              last.status == DeliveryStatus.unknown)) {
        // Sending the rest of a message whose first chunk the platform refused
        // would deliver a fragment with no beginning.
        break;
      }
    }
    return last;
  }

  Future<DeliveryReceipt?> _deliver(OutboxEntry entry) async {
    final sending = await outbox.markSending(entry.id);
    if (sending == null) return null;
    DeliveryReceipt receipt;
    try {
      receipt = await provider.send(
        RenderedChannelMessage(
          text: sending.text,
          replyToMessageId: sending.address.replyToMessageId,
        ),
        DeliveryContext(
          address: sending.address,
          purpose: sending.purpose,
          taskId: sending.taskId,
        ),
      );
    } on Object catch (error) {
      receipt = DeliveryReceipt.failed(_describe(error), retryable: true);
    }
    await outbox.settle(entry.id, receipt);
    return receipt;
  }

  /// The chat-facing status: what the app is doing, which project, which
  /// session, and how the channel itself is.
  String statusText() => _statusFor(_primary ?? _anyRuntime());

  String _statusFor(_ConversationRuntime? active) {
    final buffer = StringBuffer(agent.statusText());
    final currentDirectory = directory();
    if (currentDirectory.isNotEmpty) {
      final parts = currentDirectory
          .split(RegExp(r'[\\/]'))
          .where((part) => part.isNotEmpty)
          .toList();
      if (parts.isNotEmpty) {
        buffer.write('\n${copy.projectLabel}：${parts.last}');
      }
    }
    final sessionID = active?.sessionID;
    buffer.write(
      sessionID == null || sessionID.isEmpty
          ? '\n${copy.sessionUnbound}'
          : '\n${copy.sessionLabel}：'
                '${sessionID.length > 12 ? sessionID.substring(0, 12) : sessionID}',
    );
    buffer.write(
      '\n${copy.channelNoun}：'
      '${(stateLabel ?? ChannelEngineCopy.stateLabel)(provider.status.state)}',
    );
    final error = provider.status.lastError;
    if (error != null && provider.status.state != ProviderState.online) {
      buffer.write('\n${copy.errorLabel}：$error');
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------- routing

  _ConversationRuntime? _runtimeForSession(String sessionID) {
    for (final runtime in _runtimes.values) {
      if (runtime.sessionID == sessionID) return runtime;
    }
    return null;
  }

  _ConversationRuntime _runtimeFor(ConversationKey? key) {
    if (key == null) {
      throw StateError('This channel has no conversation to route to.');
    }
    final existing = _runtimes[key.value];
    if (existing != null) return existing;
    final store = _stores[key.value] ??= _storeFactory(key);
    final runtime = _ConversationRuntime(key: key, store: store);
    _runtimes[key.value] = runtime;
    if (key == primaryConversation) _primary = runtime;
    return runtime;
  }

  /// Set by the owner when the channel needs a store per conversation.
  ChannelSessionStore Function(ConversationKey key) _storeFactory = (key) =>
      EphemeralChannelSessionStore();

  /// Replaces how conversation bindings are persisted. Must be called before
  /// [start].
  void useSessionStores(
    ChannelSessionStore Function(ConversationKey key) factory,
  ) {
    _storeFactory = factory;
    _stores.clear();
  }

  void _notify() {
    if (!_disposed) onChanged?.call();
  }

  static String _describe(Object error) {
    final text = error.toString();
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}
