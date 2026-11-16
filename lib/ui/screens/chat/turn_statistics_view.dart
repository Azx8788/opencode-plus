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

KitTurnStatistics? _replyStatistics(
  BuildContext context,
  TurnStatistics stats, {
  required String messageID,
}) {
  final strings = _chatL10n(context);
  final duration = stats.duration;
  final speed = stats.tokensPerSecond;
  final contextTokens = stats.contextTokens;
  final cached = stats.lastUsage?.cacheRead ?? 0;
  // Cache hits come from the final request's reported tokens; the rate is
  // that request's hits over its own context total. Missing usage stays
  // unknown instead of becoming a misleading zero percent.
  final hitRate = contextTokens != null && contextTokens > 0 && cached > 0
      ? (cached * 100 / contextTokens).round()
      : null;
  String contextText(String count, String cache) => [
    strings.chatStatsContext(count),
    if (cached > 0) strings.chatStatsCached(cache),
    if (hitRate != null) strings.chatStatsCacheRate('$hitRate%'),
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
    if (speed != null)
      KitTurnStat(
        key: ValueKey('reply-speed-$messageID'),
        icon: AppIconography.speed,
        text: strings.chatStatsSpeed(speed.toStringAsFixed(1)),
        label: strings.chatStatsSpeed(speed.toStringAsFixed(1)),
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
                    value: hitRate == null
                        ? strings.chatStatsNotReported
                        : '$hitRate%',
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
