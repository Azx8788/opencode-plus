import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../api2/gateway.dart';
import '../../../domain/task_trace.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../../state/task_trace.dart';
import '../../kit/kit.dart';
import '../../app_iconography.dart';
import '../../widgets/product_states.dart';

/// Task-first, shared by the chat and cross-session Usage entries. Tree
/// expansion affects presentation only; dragging never changes recorded time.
class TaskTimelineScreen extends StatefulWidget {
  const TaskTimelineScreen({
    super.key,
    required this.controller,
    this.sessionID,
    this.store,
  });
  final ConnectionController controller;
  final String? sessionID;
  final TaskTraceStore? store;
  @override
  State<TaskTimelineScreen> createState() => _TaskTimelineScreenState();
}

class _TaskTimelineScreenState extends State<TaskTimelineScreen>
    with WidgetsBindingObserver {
  late final String _profile = widget.controller.profile?.id ?? '';
  late final String _origin = widget.controller.profile?.baseUrl ?? '';
  late final TaskTraceStore _store =
      widget.store ??
      TaskTraceStore.shared(widget.controller.store.prefs, _profile, _origin);
  final _expanded = <String>{};
  final _horizontal = ScrollController();
  StreamSubscription<Object?>? _events;
  Timer? _tick;
  Duration _window = const Duration(hours: 6);
  int? _anchor;
  double _zoom = 1;
  bool _loading = false;
  Object? _error;
  String? _model;
  TraceTaskStatus? _status;
  bool get _current =>
      widget.store != null ||
      (widget.controller.profile?.id == _profile &&
          widget.controller.profile?.baseUrl == _origin);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _events = widget.controller.events.listen((event) {
      if (event.type == 'rpc.mobile-insights.changed') unawaited(_refresh());
    });
    unawaited(_refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clock(TickerMode.valuesOf(context).enabled);
  }

  void _clock(bool active) {
    _tick?.cancel();
    _tick = null;
    if (active) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted &&
            (ModalRoute.of(context)?.isCurrent ?? true) &&
            _store.graph.tasks.values.any(
              (t) =>
                  t.status == TraceTaskStatus.running ||
                  t.status == TraceTaskStatus.queued,
            )) {
          setState(() {});
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _clock(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_events?.cancel());
    _horizontal.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading || !_current) return;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      await _store.load();
      if (widget.store == null) {
        final api = await widget.controller.prepareActionTransport();
        if (api is! Api2Gateway || api.refreshTaskTrace == null) {
          throw const FormatException('Task recording needs OpenCode V2');
        }
        await api.refreshTaskTrace!();
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _belongs(TraceTask task, TaskTraceGraph graph) {
    if (widget.sessionID == null || task.sessionID == widget.sessionID) {
      return true;
    }
    final seen = <String>{task.id};
    TraceTask? ancestor = graph.tasks[task.parentID];
    while (ancestor != null && seen.add(ancestor.id)) {
      if (ancestor.sessionID == widget.sessionID) return true;
      ancestor = graph.tasks[ancestor.parentID];
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) {
      final l = AppLocalizations.of(context), t = KitTokens.of(context);
      final graph = _store.graph;
      final now =
          _anchor ?? _store.serverNow ?? DateTime.now().millisecondsSinceEpoch;
      final from = now - _window.inMilliseconds;
      final candidates = _current
          ? graph.tasks.values.where((task) {
              if (!_belongs(task, graph)) return false;
              final start = task.submitted ?? task.started;
              final end = task.ended ?? _store.serverNow;
              return start == null ||
                  end == null ||
                  (start <= now && end >= from);
            }).toList()
          : <TraceTask>[];
      final ids = candidates.map((task) => task.id).toSet();
      final rows = <({TraceTask task, int depth})>[];
      final visited = <String>{};
      void walk(TraceTask task, int depth) {
        if (!visited.add(task.id)) return;
        final taskRequests = task.requestIDs
            .map((id) => graph.requests[id])
            .nonNulls;
        if ((_status == null || task.status == _status) &&
            (_model == null ||
                taskRequests.any(
                  (r) => '${r.providerID}/${r.modelID}' == _model,
                ))) {
          rows.add((task: task, depth: depth));
        }
        if (_expanded.contains(task.id)) {
          for (final child in candidates.where((c) => c.parentID == task.id)) {
            walk(child, depth + 1);
          }
        }
      }

      final roots =
          candidates
              .where(
                (task) => task.parentID == null || !ids.contains(task.parentID),
              )
              .toList()
            ..sort(
              (a, b) => (b.submitted ?? b.started ?? 0).compareTo(
                a.submitted ?? a.started ?? 0,
              ),
            );
      for (final root in roots) {
        walk(root, 0);
      }
      final requestIDs = {for (final task in candidates) ...task.requestIDs};
      final requests = requestIDs
          .map((id) => graph.requests[id])
          .nonNulls
          .where(
            (r) =>
                r.start == null ||
                (r.start! <= now && (r.end ?? _store.serverNow ?? now) >= from),
          )
          .toList();
      final modelUsage = graph.modelUsage(requests);
      final rootCount = candidates
          .where(
            (task) =>
                task.userTask && task.association == TaskAssociation.confirmed,
          )
          .length;
      final children = candidates
          .where((task) => !task.userTask && task.id.startsWith('agent:'))
          .length;
      return KitScreen(
        topBar: KitTopBar(
          title: l.insightsTitle,
          actions: [
            KitAction(
              label: l.commonRetry,
              icon: AppIconography.retry,
              onPressed: _loading ? null : _refresh,
            ),
          ],
        ),
        width: KitScreenWidth.reading,
        body: ListView(
          padding: KitScreen.padding(context),
          children: [
            KitText(l.insightsExplanation, role: KitTextRole.secondary),
            SizedBox(height: t.space3),
            if (!_current) KitNotice(message: l.usageLocationChanged),
            if (_error != null || _store.error != null)
              KitNotice.error(
                message:
                    '${productErrorText(_error ?? _store.error!, l10n: l)}\n${l.insightsUnavailable}',
                retry: KitAction(label: l.commonRetry, onPressed: _refresh),
              ),
            if (_store.truncated) KitNotice(message: l.insightsPartial),
            KitPickerRow<Duration>(
              rowKey: const ValueKey('task-time-window'),
              sheetKey: const ValueKey('task-time-window-choices'),
              title: l.requestTimelineWindow,
              selected: _window,
              onSelected: (value) => setState(() {
                _window = value;
                _anchor = null;
              }),
              choices: [
                KitChoice(
                  value: const Duration(minutes: 15),
                  title: l.requestTimeline15m,
                ),
                KitChoice(
                  value: const Duration(hours: 1),
                  title: l.requestTimeline1h,
                ),
                KitChoice(
                  value: const Duration(hours: 6),
                  title: l.requestTimeline6h,
                ),
                KitChoice(value: const Duration(days: 1), title: '24 h'),
                KitChoice(value: const Duration(days: 7), title: '7 d'),
              ],
            ),
            SizedBox(height: t.space3),
            KitKeyValue(
              rows: [
                KitKeyValueRow(label: l.insightsTask, value: '$rootCount'),
                KitKeyValueRow(label: l.insightsSubagent, value: '$children'),
                KitKeyValueRow(
                  label: l.insightsCalls,
                  value: '${requests.length}',
                ),
                KitKeyValueRow(
                  label: l.insightsPending,
                  value:
                      '${candidates.where((task) => task.association == TaskAssociation.pending).length}',
                ),
              ],
            ),
            SizedBox(height: t.space3),
            Wrap(
              spacing: t.space2,
              children: [
                KitButton.tertiary(
                  label: l.insightsPrevious,
                  onPressed: () =>
                      setState(() => _anchor = now - _window.inMilliseconds),
                ),
                KitButton.tertiary(
                  label: l.insightsNow,
                  onPressed: () => setState(() => _anchor = null),
                ),
                KitButton.tertiary(
                  label: l.insightsNext,
                  onPressed: () =>
                      setState(() => _anchor = now + _window.inMilliseconds),
                ),
                KitButton.tertiary(
                  label: '−',
                  onPressed: () =>
                      setState(() => _zoom = math.max(1, _zoom / 2)),
                ),
                KitButton.tertiary(
                  label: '+',
                  onPressed: () =>
                      setState(() => _zoom = math.min(16, _zoom * 2)),
                ),
              ],
            ),
            Wrap(
              spacing: t.space2,
              children: [
                KitButton.tertiary(
                  label: _model ?? l.requestTimelineUnknownModel,
                  onPressed: () async {
                    final value = await showKitChoiceSheet<String>(
                      context,
                      title: l.chatStatsContextLabel,
                      selected: _model ?? '',
                      choices: [
                        KitChoice(value: '', title: l.insightsAll),
                        for (final model in modelUsage)
                          KitChoice(
                            value: '${model.providerID}/${model.modelID}',
                            title: '${model.providerID}/${model.modelID}',
                          ),
                      ],
                    );
                    if (value != null && mounted) {
                      setState(() => _model = value.isEmpty ? null : value);
                    }
                  },
                ),
                KitButton.tertiary(
                  label: _status == null
                      ? l.insightsAll
                      : _statusLabel(l, _status!),
                  onPressed: () async {
                    final value = await showKitChoiceSheet<String>(
                      context,
                      title: l.insightsState,
                      selected: _status?.name ?? '',
                      choices: [
                        KitChoice(value: '', title: l.insightsAll),
                        for (final status in TraceTaskStatus.values)
                          KitChoice(
                            value: status.name,
                            title: _statusLabel(l, status),
                          ),
                      ],
                    );
                    if (value != null && mounted) {
                      setState(
                        () => _status = value.isEmpty
                            ? null
                            : TraceTaskStatus.values.byName(value),
                      );
                    }
                  },
                ),
              ],
            ),
            SizedBox(height: t.space2),
            Wrap(
              spacing: t.space3,
              children: [
                for (final status in [
                  TraceTaskStatus.succeeded,
                  TraceTaskStatus.failed,
                  TraceTaskStatus.running,
                  TraceTaskStatus.queued,
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: _statusColor(context, status),
                      ),
                      SizedBox(width: t.space1),
                      KitText(
                        _statusLabel(l, status),
                        role: KitTextRole.caption,
                      ),
                    ],
                  ),
              ],
            ),
            SizedBox(height: t.space3),
            if (rows.isEmpty)
              KitText(l.requestTimelineEmpty, role: KitTextRole.secondary)
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final rowHeight = math.max(
                    76.0,
                    MediaQuery.textScalerOf(context).scale(16) * 3 + 16,
                  );
                  final labelWidth = math.min(
                    160.0,
                    constraints.maxWidth * .42,
                  );
                  final chartWidth =
                      math.max(600.0, constraints.maxWidth - labelWidth) *
                      _zoom;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: labelWidth,
                        child: Column(
                          children: [
                            SizedBox(height: 32),
                            for (final row in rows)
                              SizedBox(
                                height: rowHeight,
                                child: Padding(
                                  padding: EdgeInsetsDirectional.only(
                                    start: math.min(row.depth, 4) * 10.0,
                                  ),
                                  child: KitTappable(
                                    label: row.task.id,
                                    onTap: () => _detail(row.task.id),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Row(
                                          children: [
                                            if (candidates.any(
                                              (c) => c.parentID == row.task.id,
                                            ))
                                              GestureDetector(
                                                key: ValueKey(
                                                  'task-expand-${row.task.id}',
                                                ),
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: () => setState(() {
                                                  _expanded.contains(
                                                        row.task.id,
                                                      )
                                                      ? _expanded.remove(
                                                          row.task.id,
                                                        )
                                                      : _expanded.add(
                                                          row.task.id,
                                                        );
                                                }),
                                                child: Padding(
                                                  padding: const EdgeInsets.all(
                                                    8,
                                                  ),
                                                  child: Icon(
                                                    _expanded.contains(
                                                          row.task.id,
                                                        )
                                                        ? Icons.expand_less
                                                        : Icons.expand_more,
                                                    size: 18,
                                                  ),
                                                ),
                                              ),
                                            Expanded(
                                              child: KitText(
                                                '${row.task.userTask
                                                    ? l.insightsTask
                                                    : row.task.id.startsWith('agent:')
                                                    ? l.insightsSubagent
                                                    : l.insightsPending} ${graph.tasks.keys.toList().indexOf(row.task.id) + 1}',
                                                maxLines: 1,
                                                role: KitTextRole.caption,
                                              ),
                                            ),
                                          ],
                                        ),
                                        KitText(
                                          row.task.association ==
                                                  TaskAssociation.pending
                                              ? l.insightsPending
                                              : _statusLabel(
                                                  l,
                                                  row.task.status,
                                                ),
                                          maxLines: 1,
                                          role: KitTextRole.caption,
                                          tone: KitTextTone.secondary,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _horizontal,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: chartWidth,
                            child: Column(
                              children: [
                                SizedBox(
                                  height: 32,
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      for (var i = 0; i <= 4; i++)
                                        Flexible(
                                          child: KitText(
                                            DateFormat('MM-dd HH:mm').format(
                                              DateTime.fromMillisecondsSinceEpoch(
                                                from +
                                                    _window.inMilliseconds *
                                                        i ~/
                                                        4,
                                              ),
                                            ),
                                            role: KitTextRole.caption,
                                            maxLines: 1,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                for (final row in rows)
                                  GestureDetector(
                                    key: ValueKey('task-bar-${row.task.id}'),
                                    onTap: () => _detail(row.task.id),
                                    child: CustomPaint(
                                      size: Size(chartWidth, rowHeight),
                                      painter: _TaskPainter(
                                        row.task,
                                        from,
                                        now,
                                        _store.serverNow,
                                        _statusColor(context, row.task.status),
                                        t.roles.surface3,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            SizedBox(height: t.space4),
            KitText(l.insightsModels, role: KitTextRole.headline),
            for (final usage in modelUsage)
              KitSurface.panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KitText(
                      '${usage.providerID ?? l.requestTimelineUnknownModel}/${usage.modelID ?? l.requestTimelineUnknownModel}',
                      role: KitTextRole.rowTitle,
                    ),
                    KitKeyValue(
                      rows: [
                        KitKeyValueRow(
                          label: l.insightsCalls,
                          value: '${usage.calls}',
                        ),
                        KitKeyValueRow(
                          label: l.insightsSuccess,
                          value: '${usage.succeeded}',
                        ),
                        KitKeyValueRow(
                          label: l.insightsFailed,
                          value: '${usage.failed}',
                        ),
                        KitKeyValueRow(
                          label: l.insightsSuccessRate,
                          value: usage.successRate == null
                              ? l.chatStatsNotReported
                              : '${(usage.successRate! * 100).toStringAsFixed(1)}%',
                        ),
                        KitKeyValueRow(
                          label: l.chatStatsInputLabel,
                          value: usage.usageMissing == usage.calls
                              ? l.chatStatsNotReported
                              : '${usage.input + usage.cacheRead + usage.cacheWrite}',
                        ),
                        KitKeyValueRow(
                          label: l.chatStatsOutputLabel,
                          value: usage.usageMissing == usage.calls
                              ? l.chatStatsNotReported
                              : '${usage.output}',
                        ),
                        KitKeyValueRow(
                          label: l.chatStatsReasoningLabel,
                          value: usage.usageMissing == usage.calls
                              ? l.chatStatsNotReported
                              : '${usage.reasoning}',
                        ),
                        if (usage.usageMissing > 0)
                          KitKeyValueRow(
                            label: l.insightsMissingUsage,
                            value: '${usage.usageMissing}',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );

  void _detail(String id) => unawaited(
    pushKitPage<void>(context, (_) => _TaskDetail(store: _store, id: id)),
  );
}

String _statusLabel(AppLocalizations l, TraceTaskStatus status) =>
    switch (status) {
      TraceTaskStatus.queued => l.insightsQueue,
      TraceTaskStatus.running => l.insightsLive,
      TraceTaskStatus.succeeded => l.insightsSuccess,
      TraceTaskStatus.failed => l.insightsFailed,
      TraceTaskStatus.cancelled => l.insightsCancelled,
      TraceTaskStatus.unknown => l.chatStatsNotReported,
    };
Color _statusColor(BuildContext context, TraceTaskStatus status) =>
    switch (status) {
      TraceTaskStatus.succeeded => Colors.green.shade600,
      TraceTaskStatus.failed => Colors.red.shade600,
      TraceTaskStatus.running => Colors.blue.shade600,
      TraceTaskStatus.queued => Colors.amber.shade600,
      _ => KitTokens.of(context).roles.text3,
    };

class _TaskPainter extends CustomPainter {
  _TaskPainter(this.task, this.from, this.to, this.now, this.color, this.track);
  final TraceTask task;
  final int from, to;
  final int? now;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final range = to - from;
    if (range <= 0) return;
    final grid = Paint()
      ..color = track
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      canvas.drawLine(
        Offset(size.width * i / 4, 0),
        Offset(size.width * i / 4, size.height),
        grid,
      );
    }
    void span(int? start, int? end, Color tint, double height) {
      if (start == null ||
          end == null ||
          end < start ||
          start > to ||
          end < from) {
        return;
      }
      final x = ((math.max(start, from) - from) / range * size.width).clamp(
        0.0,
        size.width,
      );
      final right = ((math.min(end, to) - from) / range * size.width).clamp(
        0.0,
        size.width,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x,
            (size.height - height) / 2,
            math.max(2.0, right - x),
            height,
          ),
          const Radius.circular(4),
        ),
        Paint()..color = tint,
      );
    }

    span(
      task.submitted,
      task.started ?? (task.status == TraceTaskStatus.queued ? now : null),
      Colors.amber.shade600,
      16,
    );
    span(
      task.started,
      task.ended ?? (task.status == TraceTaskStatus.running ? now : null),
      color,
      22,
    );
  }

  @override
  bool shouldRepaint(_TaskPainter old) =>
      old.task != task ||
      old.from != from ||
      old.to != to ||
      old.now != now ||
      old.color != color;
}

class _TaskDetail extends StatelessWidget {
  const _TaskDetail({required this.store, required this.id});
  final TaskTraceStore store;
  final String id;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final l = AppLocalizations.of(context), t = KitTokens.of(context);
      final task = store.graph.tasks[id];
      return KitScreen(
        topBar: KitTopBar(title: l.insightsDetails),
        width: KitScreenWidth.reading,
        body: ListView(
          padding: KitScreen.padding(context),
          children: [
            if (task == null)
              KitText(l.requestTimelineEmpty)
            else ...[
              KitKeyValue(
                rows: [
                  KitKeyValueRow(
                    label: l.insightsState,
                    value: _statusLabel(l, task.status),
                  ),
                  KitKeyValueRow(
                    label: l.insightsCalls,
                    value: '${task.requestIDs.length}',
                  ),
                  KitKeyValueRow(
                    label: l.insightsMessages,
                    value: '${task.messageIDs.length}',
                  ),
                ],
              ),
              if (task.association == TaskAssociation.pending)
                KitNotice(message: l.insightsPendingExplanation),
              for (final r
                  in task.requestIDs
                      .map((key) => store.graph.requests[key])
                      .nonNulls) ...[
                SizedBox(height: t.space3),
                KitSurface.panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      KitText(
                        '${r.providerID ?? l.requestTimelineUnknownModel}/${r.modelID ?? l.requestTimelineUnknownModel}',
                        role: KitTextRole.rowTitle,
                      ),
                      KitKeyValue(
                        rows: [
                          KitKeyValueRow(
                            label: l.insightsState,
                            value: _statusLabel(l, r.status),
                          ),
                          KitKeyValueRow(
                            label: l.chatStatsSpeedLabel,
                            value: r.speed == null
                                ? l.insightsWaitingToken
                                : l.chatStatsSpeed(r.speed!.toStringAsFixed(1)),
                          ),
                          if (r.errorType != null)
                            KitKeyValueRow(
                              label: l.insightsError,
                              value:
                                  '${r.errorType}${r.errorStatus == null ? '' : ' · HTTP ${r.errorStatus}'}',
                            ),
                          KitKeyValueRow(
                            label: l.insightsRetries,
                            value: '${r.retryCount}',
                          ),
                        ],
                      ),
                      for (final span in r.spans)
                        KitKeyValue(
                          rows: [
                            KitKeyValueRow(
                              label: switch (span.phase) {
                                'thinking' => l.sessionElapsedThinking,
                                'output' => l.sessionElapsedOutput,
                                'tool' => l.sessionElapsedTool,
                                'provider-rate-limit' => l.insightsRateLimit,
                                _ => l.insightsRetries,
                              },
                              value: span.end == null
                                  ? l.insightsLive
                                  : l.chatStatsSeconds(
                                      ((span.end! - span.start) / 1000)
                                          .toStringAsFixed(1),
                                    ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      );
    },
  );
}
