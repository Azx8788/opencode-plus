import 'dart:async';

import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import 'channel_agent_port.dart';
import 'channel_identity.dart';
import 'channel_inbox.dart';
import 'channel_message.dart';
import 'channel_outbox.dart';
import 'channel_provider.dart';
import 'channel_sessions.dart';
import 'channel_tasks.dart';
import 'channel_text.dart';
import 'channel_turn.dart';
import 'manager/manager_agent.dart';

/// Every sentence the shared pipeline says back into a chat.
///
/// Kept in one place because three channels must not drift into three
/// personalities, and because these strings are part of the product's
/// behaviour: the regression tests assert them.
class ChannelEngineCopy {
  const ChannelEngineCopy({
    this.channelNoun = '渠道',
    this.forwarded = '已转发给本地 Agent。',
    this.supplemented = '已并入当前任务，Agent 会在下一步看到。',
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
  final String supplemented;
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

class _QueuedPrompt {
  _QueuedPrompt(this.message, this.text);

  final ChannelMessage message;
  final String text;
}

class _ConversationRuntime {
  _ConversationRuntime({required this.key, required this.store});

  final ConversationKey key;
  final ChannelSessionStore store;
  ChannelTurn? turn;
  // Switching the binding changes where the next prompt goes, not where an
  // outstanding answer should be collected from.
  final detached = <String, ChannelTurn>{};
  final List<_QueuedPrompt> queue = [];

  /// Whether the *session* is executing. Kept for `/status` and the channel
  /// card; it never decides whether an answer is delivered — the turn does,
  /// because this flag belongs to whichever turn happens to be current.
  bool running = false;

  /// Whether "the agent started working" has already been said in this chat.
  /// A dispatch marks the conversation running optimistically so a second
  /// message is treated as a supplement; the busy event then supplies the
  /// notice exactly once.
  bool announcedStart = false;
  bool waitingPermission = false;
  ChannelMessage? lastMessage;
  DateTime? lastProgressAt;
  DateTime? lastIntermediateAt;

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
    this.replyRecoveryInterval,
    this.maxTextChunk = 3500,
    this.adoptViewedSession = false,
    this.stateLabel,
    this.onChanged,
    this.ledger = const NoopTaskLedger(),
    this.manager,
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
  final Duration? replyRecoveryInterval;
  final int maxTextChunk;

  /// Whether opening a conversation in the app re-binds this channel's single
  /// session. True only for the Telegram relay, which has one conversation.
  final bool adoptViewedSession;

  /// How the channel's own state is named in `/status`. Telegram keeps its
  /// historical wording; other channels use the shared labels.
  final String Function(ProviderState state)? stateLabel;

  final void Function()? onChanged;

  /// Where the task's life is recorded. The default keeps a channel that has
  /// no store — and every test — working unchanged.
  final ChannelTaskLedger ledger;

  /// The manager model, when the person turned it on. Null means the engine
  /// keeps deciding by itself, exactly as before. Mutable so turning the
  /// manager on does not need every channel to reconnect.
  ChannelManagerAgent? manager;

  final DateTime Function() _clock;

  StreamSubscription<ProviderEvent>? _subscription;
  Timer? _retryTimer;
  Timer? _recoveryTimer;
  bool _recovering = false;
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

  ChannelTurn? get currentTask =>
      _primary?.turn ?? _firstOpenTurn() ?? _lastTurn();

  /// How many requests are waiting, across every conversation this account
  /// serves — not just one arbitrary runtime.
  int get queuedCount =>
      _runtimes.values.fold(0, (sum, runtime) => sum + runtime.queue.length);

  List<String> get queuedPrompts => [
    for (final runtime in _runtimes.values)
      for (final item in runtime.queue) item.text,
  ];

  String? get boundSessionID =>
      _primary?.sessionID ??
      _firstOpenTurn()?.sessionID ??
      _anyRuntime()?.sessionID;

  /// True when any conversation of this account is executing. Reading one
  /// arbitrary runtime showed a channel card the state of somebody else's
  /// conversation.
  bool get isRunning => _runtimes.values.any(
    (runtime) => (runtime.turn?.isOpen ?? false) || runtime.detached.isNotEmpty,
  );

  bool get waitingPermission => _runtimes.values.any(
    (runtime) => runtime.turn?.waitingPermission ?? false,
  );

  ChannelTurn? _firstOpenTurn() {
    for (final runtime in _runtimes.values) {
      final turn = runtime.turn;
      if (turn != null && turn.isOpen) return turn;
    }
    return null;
  }

  ChannelTurn? _lastTurn() {
    for (final runtime in _runtimes.values) {
      final turn = runtime.turn;
      if (turn != null) return turn;
    }
    return null;
  }

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
    if (!_started || _disposed) return;
    _retryTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(drainOutbox());
    });
    if (replyRecoveryInterval case final interval?) {
      _recoveryTimer = Timer.periodic(
        interval,
        (_) => unawaited(_recoverReplies()),
      );
    }
    _notify();
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
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
    if (!_started) return;
    final due = await outbox.due(provider.providerId, provider.accountId);
    for (final entry in due) {
      if (!_started) return;
      await _deliver(entry);
    }
  }

  Future<void> _recoverReplies() async {
    if (!_started || _recovering || !agentReady()) return;
    _recovering = true;
    try {
      for (final runtime in _runtimes.values.toList()) {
        final turns = [?runtime.turn, ...runtime.detached.values];
        for (final turn in turns) {
          if (!_started || !agentReady()) return;
          final id = turn.sessionID;
          if (!turn.isOpen || !turn.promptAccepted || id == null) continue;
          try {
            final reply = await agent.recoverReply(
              id,
              turn.startedAt,
              turn.lastPrompt,
              observedMessageId: turn.lastSeenMessageId,
            );
            if (_started && reply != null && !reply.isEmpty && turn.isOpen) {
              unawaited(_finishTurn(runtime, turn, recoveredReply: reply));
            }
          } on Object {
            // A failed read is not a finished task. Try again on the next tick.
          }
        }
      }
    } finally {
      _recovering = false;
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
      _detachTurn(runtime);
      await runtime.store.bind(null);
      _notify();
      return;
    }
    if (runtime.sessionID != normalized) {
      _detachTurn(runtime);
      runtime.turn = runtime.detached.remove(normalized);
      runtime.running = runtime.turn?.isOpen ?? false;
      runtime.announcedStart = runtime.running;
    }
    await runtime.store.bind(
      ChannelSessionBinding(
        sessionID: normalized,
        directory: directory(),
        workspace: workspace(),
        boundAt: _clock(),
      ),
    );
    if (runtime.turn == null && agent.isBusy(normalized)) {
      runtime.running = true;
      runtime.turn = _newTurn(runtime, '（在 App 中打开的会话）')
        ..sessionID = normalized
        ..executionObserved = true
        ..binding = runtime.store.current;
      runtime.announcedStart = true;
      unawaited(_notifyChat(runtime, copy.started, DeliveryPurpose.notice));
    }
    _notify();
  }

  void _detachTurn(_ConversationRuntime runtime) {
    final turn = runtime.turn;
    final id = turn?.sessionID;
    if (turn != null && id != null && turn.isOpen && turn.request != null) {
      runtime.detached[id] = turn;
    }
    runtime.turn = null;
    runtime.running = false;
    runtime.announcedStart = false;
    runtime.waitingPermission = false;
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
    final props = event.properties;
    final info = props['info'];
    final part = props['part'];
    final sessionID =
        (props['sessionID'] ??
                (info is Map ? info['sessionID'] : null) ??
                (part is Map ? part['sessionID'] : null))
            ?.toString();
    if (sessionID == null || sessionID.isEmpty) return;
    final runtime = _runtimeForSession(sessionID);
    final detached = runtime?.detached[sessionID];
    final binding = event.type == 'session.viewed'
        ? null
        : detached?.binding ?? runtime?.store.current;
    final eventDirectory = event.directory?.trim();
    if (eventDirectory != null &&
        eventDirectory.isNotEmpty &&
        eventDirectory != (binding?.directory ?? directory()).trim()) {
      return;
    }
    final eventWorkspace = event.workspace?.trim();
    if (eventWorkspace != null &&
        eventWorkspace.isNotEmpty &&
        eventWorkspace != (binding?.workspace ?? workspace()).trim()) {
      return;
    }
    if (event.type == 'session.viewed') {
      if (adoptViewedSession) {
        unawaited(bindSession(sessionID).catchError((Object _) {}));
      }
      return;
    }
    if (runtime == null) return;
    final turn = detached ?? runtime.turn;
    if (event.type == 'session.status') {
      final status = event.properties['status'];
      final type = status is Map
          ? status['type']?.toString()
          : status?.toString();
      if (type == 'busy') {
        if (detached == null) _onBusy(runtime);
      } else if (type == 'idle') {
        _onIdle(runtime, turn);
      }
    } else if (event.type == 'session.idle') {
      if (props['interruptReason'] != null && turn != null && turn.isOpen) {
        turn.phase = TurnPhase.cancelled;
        if (identical(runtime.turn, turn)) runtime.running = false;
        ledger.update(turn.id, status: ChannelTaskStatus.cancelled);
        _closeTurn(runtime, turn);
      } else {
        _onIdle(runtime, turn);
      }
    } else if (event.type == 'message.part.updated') {
      _onPartUpdated(runtime, turn, part);
    } else if (event.type == 'message.updated') {
      _onMessageUpdated(turn, info);
    } else if (event.type == 'session.error') {
      if (turn == null || !turn.isOpen) return;
      if (detached == null) {
        runtime.running = false;
        runtime.waitingPermission = false;
      }
      turn.phase = TurnPhase.finishing;
      ledger.update(turn.id, status: ChannelTaskStatus.failed);
      _closeTurn(runtime, turn);
      unawaited(
        _notifyChat(
          runtime,
          copy.agentError,
          DeliveryPurpose.finalAnswer,
          turn: turn,
        ).whenComplete(() => _drainQueue(runtime)),
      );
    } else if (event.type == 'permission.asked' ||
        event.type == 'permission.v2.asked' ||
        event.type == 'question.asked' ||
        event.type == 'question.v2.asked' ||
        event.type == 'form.v2.created') {
      if (detached == null) runtime.waitingPermission = true;
      final waiting = turn;
      if (waiting != null) {
        waiting.waitingPermission = true;
        ledger.update(waiting.id, status: ChannelTaskStatus.waitingPermission);
      }
      unawaited(
        _notifyChat(
          runtime,
          copy.permission,
          DeliveryPurpose.notice,
          turn: turn,
        ),
      );
    } else if (event.type == 'permission.replied' ||
        event.type == 'permission.v2.replied' ||
        event.type == 'question.replied' ||
        event.type == 'question.v2.replied' ||
        event.type == 'form.v2.replied' ||
        event.type == 'form.v2.cancelled') {
      if (detached == null) runtime.waitingPermission = false;
      final resumed = turn;
      if (resumed != null) {
        resumed.waitingPermission = false;
        ledger.update(resumed.id, status: ChannelTaskStatus.running);
      }
    }
  }

  void _onBusy(_ConversationRuntime runtime) {
    runtime.running = true;
    // A turn nobody typed a prompt for: one started in the app, or a queued
    // prompt the server picked up. Its answer still belongs to this
    // conversation, so it gets a turn of its own.
    final current = runtime.turn;
    if (current == null || !current.isOpen) {
      // The session is known even when the prompt was not ours, and the turn
      // needs it to fetch its answer.
      runtime.turn = _newTurn(runtime, '（在 App 中开始的会话）')
        ..sessionID = runtime.sessionID
        ..binding = runtime.store.current;
    }
    final turn = runtime.turn;
    if (turn != null) {
      turn.executionObserved = true;
      if (!turn.waitingPermission) {
        ledger.update(turn.id, status: ChannelTaskStatus.running);
      }
    }
    if (runtime.announcedStart) return;
    runtime.announcedStart = true;
    unawaited(_notifyChat(runtime, copy.started, DeliveryPurpose.notice));
  }

  /// The session went idle: end the turn that was running.
  void _onIdle(_ConversationRuntime runtime, ChannelTurn? turn) {
    if (turn == null || !turn.isOpen) return;
    if (provider.providerId == ChannelProviderIds.telegram &&
        !turn.executionObserved &&
        turn.lastSeenMessageId == null &&
        turn.streamedReply == null) {
      return;
    }
    unawaited(_finishTurn(runtime, turn));
  }

  void _onPartUpdated(
    _ConversationRuntime runtime,
    ChannelTurn? turn,
    Object? part,
  ) {
    if (part is! Map) return;
    if (part['type'] == 'text' &&
        part['ended'] == true &&
        part['synthetic'] != true) {
      final messageId = part['messageID'];
      final partId = part['id'];
      final text = part['text'];
      if (messageId is String &&
          partId is String &&
          text is String &&
          text.trim().isNotEmpty) {
        turn?.rememberText(messageId, partId, text);
      }
      return;
    }
    if (part['type'] != 'tool') return;
    final state = part['state'];
    if (state is! Map || state['status'] != 'running') return;
    turn?.executionObserved = true;
    final now = _clock();

    // A tool started, so the assistant message that completed before it is an
    // intermediate step rather than the answer. This is the only place an
    // "update" comes from now: nothing is decided on a timer.
    if (turn != null &&
        turn.isOpen &&
        provider.providerId != ChannelProviderIds.telegram) {
      final lastUpdate = runtime.lastIntermediateAt;
      if (lastUpdate == null ||
          now.difference(lastUpdate) >= const Duration(seconds: 3)) {
        runtime.lastIntermediateAt = now;
        unawaited(_sendIntermediate(runtime, turn));
      }
    }

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
        turn: turn,
      ),
    );
  }

  void _onMessageUpdated(ChannelTurn? turn, Object? info) {
    if (info is! Map || info['role'] != 'assistant') return;
    final time = info['time'];
    if (time is Map &&
        time['recorded'] == true &&
        time['created'] is num &&
        turn != null &&
        (time['created'] as num) < turn.startedAt.millisecondsSinceEpoch) {
      return;
    }
    turn?.executionObserved = true;
    final completed =
        time is Map && (time['completed'] != null || time['end'] != null);
    if (!completed || info['error'] != null) return;
    // Recorded, not sent: whether this message is an intermediate step or the
    // answer is decided by what happens next (a tool, another message, idle),
    // not by how long ago it arrived.
    turn?.remember(info['id']?.toString());
  }

  /// Sends the message that finished before a tool call, labelled as an
  /// update. Only a tool start proves a message is intermediate, which is why
  /// this is called from there and nowhere else.
  Future<void> _sendIntermediate(
    _ConversationRuntime runtime,
    ChannelTurn turn,
  ) async {
    final sessionID = turn.sessionID;
    if (sessionID == null || !_started) return;
    // A tool can start before any assistant message has finished (the model
    // opens with a call). Nothing completed, so there is nothing to report.
    final seen = turn.lastSeenMessageId;
    if (seen == null || seen.isEmpty) return;
    ChannelAgentReply? reply;
    try {
      reply = await agent.replyForMessage(sessionID, seen);
    } on Object {
      return;
    }
    if (!_started || reply == null || reply.isEmpty) return;
    if (!turn.isOpen || turn.hasDelivered(reply.messageId)) return;
    // Only the message this turn saw complete may be reported as its update;
    // a newer one belongs to whatever comes next.
    if (reply.messageId.isNotEmpty && reply.messageId != seen) return;
    turn.markDelivered(reply.messageId);
    await _notifyChat(
      runtime,
      '${copy.updatePrefix}${reply.text.trim()}',
      DeliveryPurpose.progress,
      turn: turn,
    );
  }

  /// Ends [turn] and hands its answer to the outbox at most once.
  ///
  /// Nothing here reads `runtime.running`. That flag belongs to the session
  /// and describes whichever turn is current; the answer belongs to this turn.
  /// Reading the flag was how a turn starting 350–500 ms after the previous one
  /// ended made both the update and the final answer return early, dropping the
  /// text entirely.
  Future<void> _finishTurn(
    _ConversationRuntime runtime,
    ChannelTurn turn, {
    ChannelAgentReply? recoveredReply,
  }) async {
    if (!turn.isOpen) return;
    turn.sessionID ??= runtime.sessionID;
    turn.phase = TurnPhase.finishing;
    turn.finishedAt = _clock();
    if (identical(runtime.turn, turn)) runtime.running = false;

    final reply = recoveredReply ?? await _awaitAnswer(turn);
    if (!_started) return;
    if (turn.isCancelled) {
      ledger.update(turn.id, status: ChannelTaskStatus.cancelled);
      _closeTurn(runtime, turn);
      return;
    }

    final text = reply?.text.trim() ?? '';
    ledger.update(turn.id, status: ChannelTaskStatus.completed, result: text);

    // The turn is closed before anything speaks, so a manager that submits a
    // follow-up cannot have it overwritten by this turn's bookkeeping.
    final alreadySent = turn.hasDelivered(reply?.messageId);
    if (!alreadySent) turn.markDelivered(reply?.messageId);
    _closeTurn(runtime, turn);

    final activeManager = manager;
    if (activeManager != null && !alreadySent) {
      final host = _ManagerHost(this, runtime, finishedTurn: turn);
      final outcome = await activeManager.handleTaskFinished(
        conversationKey: turn.conversationKey,
        task: ChannelTaskRecord(
          id: turn.id,
          providerId: provider.providerId,
          accountId: provider.accountId,
          conversationId: runtime.key.conversationId,
          userId: runtime.key.ownerActorId,
          workspaceId: workspaceId,
          conversationKey: turn.conversationKey,
          prompt: turn.prompt,
          createdAt: turn.startedAt,
          sessionId: turn.sessionID,
          status: ChannelTaskStatus.completed,
          result: text,
        ),
        host: host,
      );
      if (outcome.spoke || outcome.silentByChoice || host.deliveryInDoubt) {
        await _drainQueue(runtime);
        return;
      }
      // Falling through: the manager did not deliver, so the engine does.
    }

    if (alreadySent) {
      // Already in the chat as an update; the words arrived once.
    } else if (text.isEmpty) {
      await _notifyChat(
        runtime,
        copy.finishedEmpty,
        DeliveryPurpose.finalAnswer,
        turn: turn,
      );
    } else {
      await _notifyChat(runtime, text, DeliveryPurpose.finalAnswer, turn: turn);
    }
    await _drainQueue(runtime);
  }

  /// The answer owed by [turn], waiting briefly for the server to finish
  /// writing it: `session.idle` can arrive before the last `message.updated`.
  /// The wait decides *what* to send, never *whether* to send.
  Future<ChannelAgentReply?> _awaitAnswer(ChannelTurn turn) async {
    final sessionID = turn.sessionID;
    if (sessionID == null) return null;
    for (var attempt = 0; attempt < 8; attempt++) {
      if (!_started || turn.isCancelled) return null;
      final expected = turn.lastSeenMessageId;
      final streamed = turn.streamedReply;
      if (streamed != null && streamed.messageId == expected) {
        return streamed;
      }
      ChannelAgentReply? reply;
      try {
        reply =
            await (expected == null
                    ? agent.latestReplyInfo(sessionID)
                    : agent.replyForMessage(sessionID, expected))
                .timeout(const Duration(seconds: 3));
      } on Object {
        reply = null;
      }
      final created = reply?.created;
      if (reply != null &&
          !reply.isEmpty &&
          (expected != null ||
              created == null ||
              created >= turn.startedAt.millisecondsSinceEpoch)) {
        return reply;
      }
      if (attempt < 7) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    final streamed = turn.streamedReply;
    if (streamed?.messageId == turn.lastSeenMessageId && streamed != null) {
      return streamed;
    }
    final expected = turn.lastSeenMessageId;
    if (provider.providerId == ChannelProviderIds.telegram &&
        turn.promptAccepted &&
        _started &&
        !turn.isCancelled) {
      try {
        return await agent.recoverReply(
          sessionID,
          turn.startedAt,
          turn.lastPrompt,
          observedMessageId: expected,
        );
      } on Object {
        // A transcript that cannot be verified is not a result to forward.
      }
    }
    return null;
  }

  void _closeTurn(_ConversationRuntime runtime, ChannelTurn turn) {
    if (turn.phase == TurnPhase.finishing) turn.phase = TurnPhase.closed;
    if (identical(runtime.detached[turn.sessionID], turn)) {
      runtime.detached.remove(turn.sessionID);
    }
    if (!identical(runtime.turn, turn)) return;
    runtime.turn = null;
    runtime.running = false;
    runtime.announcedStart = false;
    runtime.waitingPermission = false;
  }

  Future<void> _drainQueue(_ConversationRuntime runtime) =>
      _serialize(runtime, () async {
        if (!_started ||
            runtime.queue.isEmpty ||
            runtime.running ||
            runtime.detached.isNotEmpty) {
          return;
        }
        final next = runtime.queue.removeAt(0);
        await _dispatchPrompt(runtime, next.message, next.text);
      });

  // --------------------------------------------------------------- inbound

  Future<void> _handleMessage(ChannelMessage message) async {
    if (!_started) return;
    final key = conversationKeyOf(message);
    final runtime = _runtimeFor(key);
    await _serialize(runtime, () => _handleMessageSerial(runtime, message));
  }

  Future<void> _serialize(
    _ConversationRuntime runtime,
    Future<void> Function() action,
  ) {
    runtime.serial = runtime.serial.then((_) async {
      try {
        await action();
      } on Object {
        // One failed persistence or platform call must not poison the queue.
        _lastNotice = copy.forwardFailed;
        _notify();
      }
    });
    return runtime.serial;
  }

  Future<void> _handleMessageSerial(
    _ConversationRuntime runtime,
    ChannelMessage message,
  ) async {
    if (!_started) return;
    await runtime.store.ready();
    if (!_started) return;
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
    if (!_started) return;
    runtime.lastMessage = message;
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
    final activeManager = manager;
    if (activeManager != null) {
      final host = _ManagerHost(this, runtime, message: message);
      final outcome = await activeManager.handleUserMessage(
        conversationKey: runtime.key.value,
        text: text,
        host: host,
      );
      if (outcome.spoke || outcome.silentByChoice || host.deliveryInDoubt) {
        return;
      }
      if (host.submitted.isNotEmpty) {
        if (!host.sendAttempted) {
          await _replyTo(
            runtime,
            message,
            copy.forwarded,
            purpose: DeliveryPurpose.ack,
            taskId: host.submitted.last,
          );
        }
        return;
      }
      // The manager could not speak (no key, network, a model that ignored
      // the rules). The message still reaches the agent: a broken manager must
      // not become a broken channel.
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
        _detachTurn(runtime);
        await runtime.store.bind(null);
        await _replyTo(runtime, message, copy.newSession);
        return true;
      case ChannelCommand.queue:
        if (command.argument.isEmpty) {
          await _replyTo(runtime, message, copy.queueEmpty);
          return true;
        }
        if (!runtime.running && runtime.detached.isEmpty) {
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
      final turn = runtime.turn;
      final binding = turn?.binding ?? runtime.store.current;
      if (binding != null &&
          !binding.matches(directory: directory(), workspace: workspace())) {
        await _replyTo(runtime, message, copy.stopFailed);
        return;
      }
      runtime.queue.clear();
      await agent.stopTask(turn?.sessionID ?? runtime.sessionID);
      // Do not close a newer turn that started while the stop was on the wire.
      if (turn != null && (turn.isOpen || turn.phase == TurnPhase.finishing)) {
        turn.phase = TurnPhase.cancelled;
        _closeTurn(runtime, turn);
        ledger.update(turn.id, status: ChannelTaskStatus.cancelled);
      }
      await _replyTo(runtime, message, copy.stopRequested);
    } on Object {
      await _replyTo(runtime, message, copy.stopFailed);
    }
  }

  Future<String?> _dispatchPrompt(
    _ConversationRuntime runtime,
    ChannelMessage message,
    String text, {
    bool receipt = true,
  }) async {
    if (!_started) return null;
    if (!agentReady()) {
      if (receipt) await _replyTo(runtime, message, copy.agentOffline);
      return null;
    }
    final open = runtime.turn;
    var isSupplement = open != null && open.isOpen;
    var turn = isSupplement ? open : _newTurn(runtime, text);
    var registered = false;
    Future<void> register(ChannelSessionBinding binding) async {
      if (!_started) throw StateError('Channel stopped before sending');
      if (isSupplement &&
          (turn.sessionID != binding.sessionID || !turn.isOpen)) {
        if (identical(runtime.turn, turn)) _detachTurn(runtime);
        isSupplement = false;
        turn = _newTurn(runtime, text);
      }
      if (!isSupplement &&
          runtime.sessionID != null &&
          runtime.sessionID != binding.sessionID &&
          runtime.turn != null) {
        _detachTurn(runtime);
      }
      if (runtime.store.current?.sessionID != binding.sessionID ||
          runtime.store.current?.directory != binding.directory ||
          runtime.store.current?.workspace != binding.workspace) {
        await runtime.store.bind(binding);
      }
      if (!_started) throw StateError('Channel stopped before sending');
      registered = true;
      if (isSupplement) return;
      final previous = runtime.detached.remove(binding.sessionID);
      if (previous != null && previous.isOpen) {
        // The user reopened the same session while its task was still active.
        turn = previous;
        isSupplement = true;
        runtime.turn = previous;
        runtime.running = true;
        return;
      }
      turn
        ..sessionID = binding.sessionID
        ..binding = binding
        ..request = message;
      runtime.turn = turn;
      runtime.running = true;
      runtime.announcedStart = false;
      ledger.record(
        ChannelTaskRecord(
          id: turn.id,
          providerId: provider.providerId,
          accountId: provider.accountId,
          conversationId: runtime.key.conversationId,
          userId: runtime.key.ownerActorId,
          workspaceId: workspaceId,
          conversationKey: runtime.key.value,
          prompt: text,
          createdAt: turn.startedAt,
          sessionId: binding.sessionID,
          status: ChannelTaskStatus.created,
        ),
      );
    }

    try {
      final sessionID = await agent.sendPrompt(
        ChannelPromptRequest(
          conversation: runtime.key,
          message: message,
          text: text,
          binding: runtime.store.current,
          onSessionReady: register,
        ),
      );
      if (!_started) return null;
      if (!registered) {
        // Ports that cannot register before submitting still work, but cannot
        // observe events for a newly created session before the POST returns.
        await register(
          ChannelSessionBinding(
            sessionID: sessionID,
            directory: directory(),
            workspace: workspace(),
            boundAt: _clock(),
          ),
        );
      }
      turn
        ..promptAccepted = true
        ..lastPrompt = text;
      if (turn.isOpen && !turn.waitingPermission) {
        ledger.update(turn.id, status: ChannelTaskStatus.running);
      }
      if (isSupplement) turn.supplements++;
    } on Object {
      if (registered &&
          (turn.phase == TurnPhase.finishing ||
              turn.phase == TurnPhase.closed)) {
        // A terminal SSE already arrived. Do not re-submit on a lost HTTP ack.
        return turn.id;
      }
      if (!isSupplement && turn.isOpen) {
        ledger.update(turn.id, status: ChannelTaskStatus.failed);
        turn.phase = TurnPhase.finishing;
        if (identical(runtime.turn, turn)) runtime.running = false;
        _closeTurn(runtime, turn);
      }
      if (receipt) {
        await _replyTo(
          runtime,
          message,
          copy.forwardFailed,
          purpose: DeliveryPurpose.notice,
        );
      }
      _notify();
      return null;
    }
    if (receipt) {
      await _replyTo(
        runtime,
        message,
        isSupplement ? copy.supplemented : copy.forwarded,
        purpose: DeliveryPurpose.ack,
        taskId: turn.id,
      );
    }
    _notify();
    return turn.id;
  }

  ChannelTurn _newTurn(_ConversationRuntime runtime, String prompt) {
    return ChannelTurn(
      id: const Uuid().v4(),
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
    taskId: taskId ?? runtime.turn?.id,
  );

  Future<void> _notifyChat(
    _ConversationRuntime runtime,
    String text,
    DeliveryPurpose purpose, {
    ChannelTurn? turn,
  }) {
    final address = _addressFor(runtime, turn: turn);
    if (address == null) return Future<void>.value();
    return _send(
      address,
      text,
      purpose: purpose,
      taskId: (turn ?? runtime.turn)?.id,
    );
  }

  /// The last address seen in a conversation, so an asynchronous notice
  /// (progress, final answer) still knows where to go.
  ChannelAddress? _addressFor(
    _ConversationRuntime runtime, {
    ChannelTurn? turn,
  }) {
    final last = provider.providerId == ChannelProviderIds.telegram
        ? turn?.request ?? runtime.lastMessage
        : runtime.lastMessage;
    return last == null ? null : ChannelAddress.of(last);
  }

  /// Chunks, queues and delivers one message. Returns the last receipt.
  Future<DeliveryReceipt?> _send(
    ChannelAddress address,
    String text, {
    required DeliveryPurpose purpose,
    String? taskId,
  }) async {
    if (!_started) return null;
    final chunks = chunkText(text, maxCodeUnits: maxTextChunk);
    if (chunks.isEmpty) return null;
    DeliveryReceipt? last;
    for (final chunk in chunks) {
      if (!_started) break;
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
    if (!_started) {
      await outbox.settle(
        entry.id,
        const DeliveryReceipt.failed('渠道已关闭，本条消息未发送。'),
      );
      return null;
    }
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
    } on Object {
      receipt = const DeliveryReceipt.unknown('无法确认平台是否收到消息。');
    }
    final settled = await outbox.settle(entry.id, receipt);
    if (settled != null &&
        entry.taskId != null &&
        entry.purpose == DeliveryPurpose.finalAnswer) {
      ledger.update(
        entry.taskId!,
        delivery: _deliveryOf(settled.status),
        deliveryAttempts: settled.attempts,
      );
    }
    if (settled?.status == OutboxStatus.deferred &&
        receipt.status == DeliveryStatus.failed) {
      return DeliveryReceipt.deferred(receipt.error ?? '平台要求稍后再试。');
    }
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
      if (runtime.sessionID == sessionID ||
          runtime.detached.containsKey(sessionID)) {
        return runtime;
      }
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

  static ChannelDeliveryStatus _deliveryOf(OutboxStatus status) =>
      switch (status) {
        OutboxStatus.planned => ChannelDeliveryStatus.pending,
        OutboxStatus.sending => ChannelDeliveryStatus.delivering,
        OutboxStatus.delivered => ChannelDeliveryStatus.delivered,
        OutboxStatus.deferred => ChannelDeliveryStatus.deferred,
        OutboxStatus.failed => ChannelDeliveryStatus.failed,
        OutboxStatus.unknown => ChannelDeliveryStatus.unknown,
      };
}

/// The manager's hands, scoped to one conversation.
///
/// Every tool the model can call lands here, and none of them takes a
/// recipient: the conversation is fixed when the host is built, so a confused
/// model cannot address somebody else's chat.
class _ManagerHost implements ManagerHost {
  _ManagerHost(this._engine, this._runtime, {this.message, this.finishedTurn});

  final ChannelConversationEngine _engine;
  final _ConversationRuntime _runtime;
  final ChannelMessage? message;
  final ChannelTurn? finishedTurn;
  bool sendAttempted = false;
  bool deliveryInDoubt = false;

  /// Tasks this run submitted, in order. The last one is where delivery is
  /// recorded.
  final List<String> submitted = [];

  @override
  String get channelLabel {
    final label = ChannelProviderIds.label(_engine.provider.providerId);
    final kind = _runtime.key.conversationType == ChannelConversationKind.group
        ? '群聊'
        : '私聊';
    return '$label $kind ${_runtime.key.conversationId}';
  }

  @override
  String get projectLabel {
    final workspace = _engine.workspace();
    if (workspace.isNotEmpty) return workspace;
    final directory = _engine.directory();
    if (directory.isEmpty) return '未打开项目';
    final parts = directory
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? directory : parts.last;
  }

  @override
  Future<String?> submitTask(String text) async {
    final message = this.message;
    if (message == null) return null;
    final id = await _engine._dispatchPrompt(
      _runtime,
      message,
      text,
      receipt: false,
    );
    if (id != null) submitted.add(id);
    return id;
  }

  @override
  Future<bool> sendMessage(String text) async {
    final address = message == null
        ? _engine._addressFor(_runtime, turn: finishedTurn)
        : ChannelAddress.of(message!);
    if (address == null) return false;
    // Deferred is already in the outbox; unknown may already have arrived.
    // Neither may be duplicated by another tool call or the raw fallback.
    if (deliveryInDoubt) return false;
    sendAttempted = true;
    final receipt = await _engine._send(
      address,
      text,
      purpose: finishedTurn == null
          ? DeliveryPurpose.ack
          : DeliveryPurpose.finalAnswer,
      taskId: finishedTurn?.id ?? (submitted.isEmpty ? null : submitted.last),
    );
    deliveryInDoubt =
        receipt?.status == DeliveryStatus.unknown ||
        receipt?.status == DeliveryStatus.deferred;
    return receipt?.isSuccess ?? false;
  }

  @override
  ChannelTaskRecord? taskById(String id) {
    for (final record in _engine.ledger.recent(limit: 200)) {
      if (record.id == id && _owns(record)) return record;
    }
    return null;
  }

  @override
  List<ChannelTaskRecord> recentTasks({int limit = 10}) =>
      _engine.ledger.recent(limit: 200).where(_owns).take(limit).toList();

  bool _owns(ChannelTaskRecord record) =>
      _engine.isStarted &&
      record.conversationKey == _runtime.key.value &&
      record.providerId == _runtime.key.providerId &&
      record.accountId == _runtime.key.accountId &&
      record.userId == _runtime.key.ownerActorId &&
      record.workspaceId == _runtime.key.workspaceId;

  @override
  Future<bool> cancelTask(String id) async {
    final turn = _runtime.turn;
    if (turn == null || turn.id != id || !turn.isOpen || !_engine.isStarted) {
      return false;
    }
    final record = taskById(id);
    final session = turn.sessionID;
    if (record == null || session == null || record.sessionId != session) {
      return false;
    }
    try {
      await _engine.agent.stopTask(session);
      turn.phase = TurnPhase.cancelled;
      if (identical(_runtime.turn, turn)) _runtime.running = false;
      _engine._closeTurn(_runtime, turn);
      _engine.ledger.update(id, status: ChannelTaskStatus.cancelled);
      return true;
    } on Object {
      return false;
    }
  }
}
