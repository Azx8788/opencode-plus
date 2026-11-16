import 'dart:math' as math;

import 'usage_statistics.dart';

const dashboardRanges = [
  UsageRange.sevenDays,
  UsageRange.thirtyDays,
  UsageRange.ninetyDays,
  UsageRange.allTime,
];

/// A real half-open server interval. At most 30 aggregate reads are needed
/// for a trend; 90 days is grouped by three days, all-time by calendar months
/// (or a disclosed group of months for very long histories).
class UsageBucket {
  const UsageBucket({required this.from, required this.to});
  final DateTime from;
  final DateTime to;

  UsageQuery query(UsageQuery parent) => UsageQuery(
    from: from.millisecondsSinceEpoch,
    to: to.millisecondsSinceEpoch,
    timezone: parent.timezone,
    projectID: parent.projectID,
  );
}

class UsageTrendPlan {
  const UsageTrendPlan({required this.buckets, this.days = 1, this.months = 0});
  final List<UsageBucket> buckets;
  final int days;
  final int months;
  bool get monthly => months > 0;

  factory UsageTrendPlan.forStatistics(
    UsageStatistics stats,
    UsageRange range,
  ) {
    final from = DateTime.fromMillisecondsSinceEpoch(stats.from).toLocal();
    final to = DateTime.fromMillisecondsSinceEpoch(stats.to).toLocal();
    if (!to.isAfter(from) || stats.tokens.total == 0)
      return const UsageTrendPlan(buckets: []);
    final last = to.subtract(const Duration(milliseconds: 1));
    final buckets = <UsageBucket>[];
    final monthly = range == UsageRange.allTime;
    final monthCount =
        (last.year - from.year) * 12 + last.month - from.month + 1;
    final months = monthly ? math.max(1, (monthCount / 30).ceil()) : 0;
    final dayCount =
        DateTime.utc(
          last.year,
          last.month,
          last.day,
        ).difference(DateTime.utc(from.year, from.month, from.day)).inDays +
        1;
    final days = monthly ? 0 : math.max(1, (dayCount / 30).ceil());
    var cursor = monthly
        ? DateTime(from.year, from.month)
        : DateTime(from.year, from.month, from.day);
    while (cursor.isBefore(to) && buckets.length < 30) {
      final next = monthly
          ? DateTime(cursor.year, cursor.month + months)
          : DateTime(cursor.year, cursor.month, cursor.day + days);
      buckets.add(
        UsageBucket(
          from: cursor.isBefore(from) ? from : cursor,
          to: next.isAfter(to) ? to : next,
        ),
      );
      cursor = next;
    }
    return UsageTrendPlan(
      buckets: List.unmodifiable(buckets),
      days: days,
      months: months,
    );
  }
}

class UsageTrendPoint {
  const UsageTrendPoint({
    required this.bucket,
    this.statistics,
    this.failed = false,
  });
  final UsageBucket bucket;
  final UsageStatistics? statistics;
  final bool failed;
  int? get total => statistics?.tokens.total;
}

/// A model identity includes provider and variant. Equal display names from
/// different providers must never silently merge into the same record.
class UsageRanking {
  const UsageRanking({
    required this.id,
    required this.label,
    required this.detail,
    required this.tokens,
    this.other = false,
  });
  final String id;
  final String label;
  final String detail;
  final int tokens;
  final bool other;
}

List<UsageRanking> usageModelRanking(List<UsageModel> models, {int limit = 8}) {
  final grouped = <(String, String, String?), int>{};
  for (final model in models) {
    final key = (model.providerID, model.modelID, model.variant);
    grouped.update(
      key,
      (value) => value + model.tokens.total,
      ifAbsent: () => model.tokens.total,
    );
  }
  final rows =
      [
        for (final entry in grouped.entries)
          UsageRanking(
            id: '${entry.key.$1}/${entry.key.$2}/${entry.key.$3 ?? ''}',
            label: entry.key.$2,
            detail: [
              entry.key.$1,
              if (entry.key.$3?.isNotEmpty == true) entry.key.$3!,
            ].join(' · '),
            tokens: entry.value,
          ),
      ]..sort((a, b) {
        final byTokens = b.tokens.compareTo(a.tokens);
        return byTokens == 0 ? a.id.compareTo(b.id) : byTokens;
      });
  if (rows.length <= limit) return rows;
  return [
    ...rows.take(limit),
    UsageRanking(
      id: 'other',
      label: '',
      detail: '',
      other: true,
      tokens: rows.skip(limit).fold<int>(0, (sum, row) => sum + row.tokens),
    ),
  ];
}

/// The heatmap is calendar-based, not 24-hour-based, including DST boundaries.
List<DateTime> usageHeatmapDays(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final start = DateTime(
    today.year,
    today.month,
    today.day - today.weekday + 1 - 52 * 7,
  );
  return [
    for (var day = 0; day < 53 * 7; day++)
      DateTime(start.year, start.month, start.day + day),
  ];
}

String usageDateKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

String compactUsageCount(int count) {
  for (final unit in const [(1000000000, 'B'), (1000000, 'M'), (1000, 'K')]) {
    if (count >= unit.$1) {
      final number = count / unit.$1;
      return '${number.toStringAsFixed(number < 10
          ? 2
          : number < 100
          ? 1
          : 0)}${unit.$2}';
    }
  }
  return '$count';
}
