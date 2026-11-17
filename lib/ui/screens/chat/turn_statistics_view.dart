part of '../chat_screen.dart';

String _replyDuration(BuildContext context, Duration duration) {
  final strings = _chatL10n(context);
  if (duration.inHours >= 1) return KitSince.durationLabel(context, duration);
  if (duration.inMinutes >= 1) {
    return KitTurnLive.elapsedText(strings, duration);
  }
  return strings.chatStatsSeconds(
    (duration.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(
      1,
    ),
  );
}

Widget? _replyStatistics(
  BuildContext context,
  TurnStatistics stats, {
  required String messageID,
  List<MessageWithParts>? liveSteps,
  TaskTraceStore? trace,
}) {
  if (liveSteps != null) {
    return _LiveReplyStatistics(
      steps: liveSteps,
      trace: trace,
      messageID: messageID,
    );
  }
  final strings = _chatL10n(context);
  final duration = stats.duration;
  final speed = stats.tokensPerSecond;
  final contextTokens = stats.contextTokens;
  final cached = stats.lastUsage?.cacheRead ?? 0;
  final hitRate = stats.cacheHitRate;
  final hitPercent = hitRate == null
      ? null
      : '${(hitRate * 100).toStringAsFixed(1)}%';
  String contextText(String count, String cache) => [
    strings.chatStatsContext(count),
    if (cached > 0) strings.chatStatsCached(cache),
    if (hitPercent != null) strings.chatStatsCacheRate(hitPercent),
  ].join(' ');
  final items = <KitTurnStat>[
    if (duration != null)
      KitTurnStat(
        key: ValueKey('reply-duration-$messageID'),
        icon: AppIconography.timer,
        text: _replyDuration(context, duration),
        label: strings.chatStatsDuration(_replyDuration(context, duration)),
      ),
    if (stats.steps > 0)
      KitTurnStat(
        key: ValueKey('reply-steps-$messageID'),
        icon: AppIconography.timeline,
        text: strings.chatStatsSteps(stats.steps),
        label: strings.chatStatsSteps(stats.steps),
      ),
    KitTurnStat(
      key: ValueKey('reply-speed-$messageID'),
      icon: AppIconography.speed,
      text: speed == null
          ? strings.insightsWaitingToken
          : strings.chatStatsSpeed(speed.toStringAsFixed(1)),
      label: speed == null
          ? strings.insightsWaitingToken
          : strings.chatStatsSpeed(speed.toStringAsFixed(1)),
    ),
    if (contextTokens != null)
      KitTurnStat(
        key: ValueKey('reply-context-$messageID'),
        icon: AppIconography.usage,
        text: contextText(
          _MessageView._fmtTokens(contextTokens),
          _MessageView._fmtTokens(cached),
        ),
        label: contextText('$contextTokens', '$cached'),
      ),
  ];
  if (items.isEmpty) return null;
  return KitTurnStatistics(
    rowKey: ValueKey('message-statistics-$messageID'),
    label: strings.chatStatsTitle,
    items: items,
    onTap: () => unawaited(
      showKitSheet<void>(
        context,
        title: strings.chatStatsTitle,
        sheetKey: ValueKey('reply-statistics-details-$messageID'),
        icon: AppIconography.usage,
        body: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: KitTokens.of(context).space3,
          children: [
            KitKeyValue(
              rows: [
                KitKeyValueRow(
                  label: strings.chatStatsDurationLabel,
                  value: duration == null
                      ? strings.chatStatsNotReported
                      : _replyDuration(context, duration),
                ),
                KitKeyValueRow(
                  label: strings.chatStatsStepsLabel,
                  value: '${stats.steps}',
                ),
                KitKeyValueRow(
                  label: strings.chatStatsToolsLabel,
                  value: '${stats.toolCalls}',
                ),
                KitKeyValueRow(
                  label: strings.chatStatsSpeedLabel,
                  value: speed == null
                      ? strings.chatStatsNotReported
                      : strings.chatStatsSpeed(speed.toStringAsFixed(1)),
                ),
                KitKeyValueRow(
                  label: strings.chatStatsContextLabel,
                  value: contextTokens == null
                      ? strings.chatStatsNotReported
                      : '$contextTokens',
                ),
                if (stats.lastUsage != null) ...[
                  KitKeyValueRow(
                    label: strings.chatStatsCachedLabel,
                    value: '$cached',
                  ),
                  KitKeyValueRow(
                    label: strings.chatStatsCacheRateLabel,
                    value: hitPercent ?? strings.chatStatsNotReported,
                  ),
                ],
                KitKeyValueRow(
                  label: strings.chatStatsInputLabel,
                  value: stats.total.total > 0
                      ? '${stats.total.input + stats.total.cache}'
                      : strings.chatStatsNotReported,
                ),
                KitKeyValueRow(
                  label: strings.chatStatsOutputLabel,
                  value: stats.total.total > 0
                      ? '${stats.total.output}'
                      : strings.chatStatsNotReported,
                ),
                KitKeyValueRow(
                  label: strings.chatStatsReasoningLabel,
                  value: stats.total.total > 0
                      ? '${stats.total.reasoning}'
                      : strings.chatStatsNotReported,
                ),
                if (stats.cost != null)
                  KitKeyValueRow(
                    label: strings.chatStatsCostLabel,
                    value: _MessageView._fmtCost(stats.cost!),
                  ),
              ],
            ),
            KitText(
              strings.chatStatsExplanation,
              role: KitTextRole.secondary,
              tone: KitTextTone.secondary,
            ),
          ],
        ),
      ),
    ),
  );
}

class _LiveReplyStatistics extends StatelessWidget {
  const _LiveReplyStatistics({
    required this.steps,
    required this.messageID,
    this.trace,
  });
  final List<MessageWithParts> steps;
  final String messageID;
  final TaskTraceStore? trace;
  @override
  Widget build(BuildContext context) => KitSince(
    since: steps.firstOrNull?.info.time?.created == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(steps.first.info.time!.created!),
    ticks: KitSinceTicks.seconds,
    builder: (context, _) {
      final messages = trace?.graph.decorate(steps) ?? steps;
      final stats = TurnStatistics.fromSteps(
        messages,
        liveNow: trace?.serverNow,
      );
      return _replyStatistics(context, stats, messageID: messageID) ??
          const SizedBox.shrink();
    },
  );
}

/// Tests exercise the real transcript rendering without starting a server,
/// speech service or chat route. The grouping, card and footer are unchanged.
@visibleForTesting
Widget debugConversationTranscript({
  required List<MessageWithParts> messages,
  Map<String, bool>? expansionStore,
  bool running = false,
  bool reasoningExpanded = false,
  bool showTimestamp = false,
}) {
  final display = _timelineDisplayParts(messages, liveTail: running);
  final owners = _turnActionOwners(
    messages,
    display,
    metaAlways: true,
    running: running,
  );
  final expansions = expansionStore ?? <String, bool>{};
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var index = 0; index < messages.length; index++)
        if (!_isFoldedNotice(messages[index]))
          _MessageView(
            key: ValueKey('message-${messages[index].info.id}'),
            m: messages[index],
            transcript: messages,
            workIsRunning: running,
            meta: _messageMeta(messages, index),
            parts: display[index],
            reasoningExpanded: reasoningExpanded,
            expansionStore: expansions,
            showTimestamp: showTimestamp,
            showActions: owners.contains(index),
            contextActions: () => const [],
            filePreviewLoader: (file) async =>
                FilePreviewData(name: file.displayName, text: ''),
            onAttachFile: null,
            onDownloadFile: (file, data) async {},
          ),
    ],
  );
}
