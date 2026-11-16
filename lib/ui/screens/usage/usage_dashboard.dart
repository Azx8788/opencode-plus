part of '../usage_screen.dart';

/// The real local-usage page and the screenshot/test host share this widget.
/// No colors, fonts or background are copied from the design reference.
class UsageDashboard extends StatelessWidget {
  const UsageDashboard({
    super.key,
    required this.snapshot,
    required this.lifetime,
    required this.range,
    required this.now,
    required this.trend,
    this.launches,
    this.trendPlan,
    this.trendLoading = false,
    this.trendFinished = 0,
    this.lifetimeLoading = false,
    this.lifetimeFailed = false,
    this.unavailable = false,
    this.onRange,
    this.onRetryTrend,
    this.onDetails,
  });

  final UsageSnapshot? snapshot, lifetime;
  final UsageRange range;
  final DateTime now;
  final AppLaunchStatistics? launches;
  final List<UsageTrendPoint> trend;
  final UsageTrendPlan? trendPlan;
  final bool trendLoading, lifetimeLoading, lifetimeFailed;
  final bool unavailable;
  final int trendFinished;
  final ValueChanged<UsageRange>? onRange;
  final VoidCallback? onRetryTrend, onDetails;

  @override
  Widget build(BuildContext context) {
    final l = _strings(context);
    final t = KitTokens.of(context);
    final stats = snapshot?.statistics;
    final all = lifetime?.statistics;
    final launch = launches;
    String count(int? value) => value == null ? '—' : compactUsageCount(value);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final period = snapshot == null
        ? null
        : spentDays(
            SpentPeriod.fromUsage(
              query: snapshot!.query,
              statistics: stats!,
              requestedRange: snapshot!.range,
            ),
            locale,
            l,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _UsageActivityHeatmap(
          snapshot: lifetime,
          now: now,
          loading: lifetimeLoading,
          failed: lifetimeFailed,
        ),
        SizedBox(height: t.space2),
        _DashboardMetrics(
          items: [
            _DashboardMetric(
              id: 'sessions',
              icon: AppIconography.chat,
              label: l.statsConversations,
              value: count(all?.sessions),
              detail: l.statsAllRecorded,
            ),
            _DashboardMetric(
              id: 'steps',
              icon: AppIconography.timeline,
              label: l.statsModelRequests,
              value: count(all?.steps),
              detail: l.statsStepsNotMessages,
            ),
            _DashboardMetric(
              id: 'launches',
              icon: AppIconography.launch,
              label: l.statsLaunches,
              value: count(launch?.count),
              detail: launch == null
                  ? l.statsNotRecorded
                  : l.statsSince(DateFormat.yMMMd(locale).format(launch.since)),
            ),
          ],
        ),
        SizedBox(height: t.sectionGap),
        _Label(l.statsTokenUsage),
        KitSegmented<UsageRange>(
          semanticsLabel: l.usageRangeLabel,
          fitLabels: true,
          selected: dashboardRanges.contains(range)
              ? range
              : UsageRange.thirtyDays,
          onChanged: onRange,
          disabledReason: onRange == null ? l.usageLoading : null,
          segments: [
            for (final value in dashboardRanges)
              KitSegment(
                key: ValueKey('usage-range-${value.name}'),
                value: value,
                label: switch (value) {
                  UsageRange.sevenDays => l.statsSevenDays,
                  UsageRange.thirtyDays => l.usageThirtyDays,
                  UsageRange.ninetyDays => l.statsNinetyDays,
                  _ => l.usageAllTime,
                },
              ),
          ],
        ),
        if (period != null) ...[
          SizedBox(height: t.space2),
          KitText(
            '$period · ${snapshot!.query.timezone}',
            key: const ValueKey('stats-covered-period'),
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
        ],
        SizedBox(height: t.space3),
        if (stats == null)
          KitSurface.panel(
            child: KitText(unavailable ? l.statsNotRecorded : l.usageLoading),
          )
        else ...[
          _DashboardMetrics(
            items: [
              _DashboardMetric(
                id: 'input',
                icon: AppIconography.upload,
                label: l.statsInputTokens,
                value: compactUsageCount(stats.tokens.prompt),
              ),
              _DashboardMetric(
                id: 'output',
                icon: AppIconography.download,
                label: l.statsOutputTokens,
                value: compactUsageCount(stats.tokens.completion),
              ),
              _DashboardMetric(
                id: 'cached',
                icon: AppIconography.lightning,
                label: l.statsCachedTokens,
                value: compactUsageCount(stats.tokens.cacheRead),
              ),
              _DashboardMetric(
                id: 'cache-rate',
                icon: AppIconography.usageRing,
                label: l.statsCacheRate,
                value: stats.tokens.cacheHitRate == null
                    ? '—'
                    : '${(stats.tokens.cacheHitRate! * 100).toStringAsFixed(1)}%',
              ),
            ],
          ),
          SizedBox(height: t.space2),
          _UsageTrendCard(
            snapshot: snapshot!,
            plan: trendPlan,
            points: trend,
            loading: trendLoading,
            finished: trendFinished,
            onRetry: onRetryTrend,
          ),
          SizedBox(height: t.space2),
          _UsageRankingCard(
            title: l.statsByModel,
            total: stats.tokens.total,
            rows: usageModelRanking(stats.models),
            empty: l.usageNoModels,
          ),
          SizedBox(height: t.space2),
          // The server aggregates usage but does not expose the source of a
          // model request. Do not relabel token categories as chat/title/etc.
          KitSurface.panel(
            key: const ValueKey('stats-sources'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                KitText(l.statsBySource, role: KitTextRole.headline),
                SizedBox(height: t.space3),
                KitText(
                  l.statsSourcesUnavailable,
                  role: KitTextRole.secondary,
                  tone: KitTextTone.secondary,
                ),
              ],
            ),
          ),
          SizedBox(height: t.space2),
          KitText(
            l.statsTokenExplanation,
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
          if (onDetails != null) ...[
            SizedBox(height: t.space3),
            KitButton.tertiary(
              key: const ValueKey('stats-advanced'),
              icon: AppIconography.settingsAdvanced,
              label: l.statsDetails,
              onPressed: onDetails,
            ),
          ],
        ],
      ],
    );
  }
}

class _DashboardMetric {
  const _DashboardMetric({
    required this.id,
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
  });
  final String id, label, value;
  final IconData icon;
  final String? detail;
}

class _DashboardMetrics extends StatelessWidget {
  const _DashboardMetrics({required this.items});
  final List<_DashboardMetric> items;

  @override
  Widget build(BuildContext context) {
    final t = KitTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final columns =
            box.maxWidth < 280 ||
                MediaQuery.textScalerOf(context).scale(1) >= 1.5
            ? 1
            : 2;
        final width = (box.maxWidth - t.space2 * (columns - 1)) / columns;
        Widget tile(_DashboardMetric item, double width) => SizedBox(
          width: width,
          child: KitSurface.panel(
            key: ValueKey('stats-metric-${item.id}'),
            child: Semantics(
              container: true,
              label: '${item.label}: ${item.value}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(item.icon, size: t.smallIconSize, color: t.roles.accent),
                  SizedBox(height: t.space3),
                  KitText(
                    item.value,
                    key: ValueKey('stats-value-${item.id}'),
                    role: KitTextRole.title,
                    tabular: true,
                  ),
                  SizedBox(height: t.space1),
                  KitText(
                    item.label,
                    role: KitTextRole.secondary,
                    tone: KitTextTone.secondary,
                  ),
                  if (item.detail != null) ...[
                    SizedBox(height: t.space1),
                    KitText(
                      item.detail!,
                      role: KitTextRole.caption,
                      tone: KitTextTone.tertiary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
        return Wrap(
          spacing: t.space2,
          runSpacing: t.space2,
          children: [
            for (var index = 0; index < items.length; index++)
              tile(
                items[index],
                items.length.isOdd && index == items.length - 1
                    ? box.maxWidth
                    : width,
              ),
          ],
        );
      },
    );
  }
}

class _UsageRankingCard extends StatelessWidget {
  const _UsageRankingCard({
    required this.title,
    required this.total,
    required this.rows,
    required this.empty,
  });
  final String title, empty;
  final int total;
  final List<UsageRanking> rows;

  @override
  Widget build(BuildContext context) {
    final t = KitTokens.of(context);
    final l = _strings(context);
    return KitSurface.panel(
      key: const ValueKey('stats-model-ranking'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          KitText(title, role: KitTextRole.headline),
          if (rows.isEmpty) ...[SizedBox(height: t.space3), KitText(empty)],
          for (final row in rows) ...[
            SizedBox(height: t.space4),
            KitTappable(
              tappableKey: ValueKey('stats-model-${row.id}'),
              onTap: () => showKitSheet<void>(
                context,
                title: row.other ? l.statsOther : row.label,
                body: (context) => KitKeyValue(
                  rows: [
                    if (row.detail.isNotEmpty)
                      KitKeyValueRow(
                        label: l.usageProviders,
                        value: row.detail,
                      ),
                    KitKeyValueRow(
                      label: l.usageTotalTokens,
                      value: '${row.tokens}',
                    ),
                    if (total > 0)
                      KitKeyValueRow(
                        label: l.statsShare,
                        value:
                            '${(row.tokens / total * 100).toStringAsFixed(1)}%',
                      ),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: t.space2,
                    runSpacing: t.space1,
                    children: [
                      KitText(
                        row.other ? l.statsOther : row.label,
                        role: KitTextRole.secondary,
                      ),
                      KitText(
                        '${compactUsageCount(row.tokens)}${total > 0 ? ' · ${(row.tokens / total * 100).toStringAsFixed(0)}%' : ''}',
                        role: KitTextRole.caption,
                        tabular: true,
                        tone: KitTextTone.secondary,
                      ),
                    ],
                  ),
                  if (row.detail.isNotEmpty)
                    KitText(
                      row.detail,
                      role: KitTextRole.caption,
                      tone: KitTextTone.tertiary,
                    ),
                  SizedBox(height: t.space2),
                  SizedBox(
                    height: t.space1 * 1.5,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(t.codeRadius),
                      child: LinearProgressIndicator(
                        value: total <= 0
                            ? 0
                            : (row.tokens / total).clamp(0, 1).toDouble(),
                        color: t.roles.accent,
                        backgroundColor: t.roles.surface3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
