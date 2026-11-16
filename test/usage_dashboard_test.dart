import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/usage_dashboard.dart';
import 'package:opencode_mobile/domain/usage_statistics.dart';

UsageStatistics usageStats({
  required int from,
  required int to,
  UsageTokens tokens = const UsageTokens(
    input: 100,
    output: 10,
    reasoning: 5,
    cacheRead: 400,
    cacheWrite: 20,
  ),
  List<UsageModel> models = const [],
  List<UsageActivity> activity = const [],
}) => UsageStatistics(
  from: from,
  to: to,
  sessions: 85,
  subagents: 2,
  prompts: 120,
  steps: 240,
  activeDays: activity.length,
  streak: 2,
  cost: 1.25,
  tokens: tokens,
  models: models,
  activity: activity,
);

void main() {
  test(
    'input, output and cache use OpenCode disjoint token fields exactly once',
    () {
      const tokens = UsageTokens(
        input: 100,
        output: 10,
        reasoning: 5,
        cacheRead: 400,
        cacheWrite: 20,
      );
      expect(tokens.prompt, 520);
      expect(tokens.completion, 15);
      expect(tokens.total, 535);
      expect(tokens.prompt + tokens.completion, tokens.total);
      expect(tokens.cacheHitRate, closeTo(400 / 520, .0001));
      expect(
        const UsageTokens(
          input: 0,
          output: 0,
          reasoning: 0,
          cacheRead: 0,
          cacheWrite: 0,
        ).cacheHitRate,
        isNull,
      );
    },
  );

  test('7 and 90 days include today and use local calendar boundaries', () {
    final now = DateTime(2026, 11, 16, 19, 9);
    final week = UsageQuery.forRange(
      UsageRange.sevenDays,
      now: now,
      timezone: 'Asia/Shanghai',
    );
    final quarter = UsageQuery.forRange(
      UsageRange.ninetyDays,
      now: now,
      timezone: 'Asia/Shanghai',
    );
    expect(week.from, DateTime(2026, 11, 10).millisecondsSinceEpoch);
    expect(quarter.from, DateTime(2026, 8, 19).millisecondsSinceEpoch);
    expect(week.to, now.millisecondsSinceEpoch + 1);
    expect(week.toQuery()['timezone'], 'Asia/Shanghai');
  });

  for (final entry in [
    (UsageRange.sevenDays, 7, 1),
    (UsageRange.thirtyDays, 30, 1),
    (UsageRange.ninetyDays, 30, 3),
  ]) {
    test(
      'trend ${entry.$1} is bounded, contiguous and exactly covers the server interval',
      () {
        final query = UsageQuery.forRange(
          entry.$1,
          now: DateTime(2026, 11, 16, 19),
          timezone: 'Asia/Shanghai',
          projectID: 'project',
        );
        final stats = usageStats(from: query.from!, to: query.to);
        final plan = UsageTrendPlan.forStatistics(stats, entry.$1);
        expect(plan.buckets.length, entry.$2);
        expect(plan.days, entry.$3);
        expect(plan.buckets.first.from.millisecondsSinceEpoch, stats.from);
        expect(plan.buckets.last.to.millisecondsSinceEpoch, stats.to);
        for (var index = 1; index < plan.buckets.length; index++) {
          expect(plan.buckets[index].from, plan.buckets[index - 1].to);
        }
        expect(plan.buckets.first.query(query).projectID, 'project');
        expect(plan.buckets.first.query(query).timezone, 'Asia/Shanghai');
      },
    );
  }

  test('all time groups calendar months, at most 30 for long histories', () {
    final stats = usageStats(
      from: DateTime(2020, 3, 12, 5).millisecondsSinceEpoch,
      to: DateTime(2026, 11, 16, 19).millisecondsSinceEpoch,
    );
    final plan = UsageTrendPlan.forStatistics(stats, UsageRange.allTime);
    expect(plan.monthly, isTrue);
    expect(plan.months, 3);
    expect(plan.buckets.length, lessThanOrEqualTo(30));
    expect(plan.buckets.first.from.millisecondsSinceEpoch, stats.from);
    expect(plan.buckets.first.to, DateTime(2020, 6));
    expect(plan.buckets.last.to.millisecondsSinceEpoch, stats.to);
  });

  test('empty usage does not issue 30 pointless bucket reads', () {
    final stats = usageStats(
      from: 0,
      to: DateTime(2026, 11, 16).millisecondsSinceEpoch,
      tokens: const UsageTokens(
        input: 0,
        output: 0,
        reasoning: 0,
        cacheRead: 0,
        cacheWrite: 0,
      ),
    );
    expect(
      UsageTrendPlan.forStatistics(stats, UsageRange.allTime).buckets,
      isEmpty,
    );
  });

  test('ranking counts all tokens and preserves provider/variant identity plus Other', () {
    UsageModel model(
      String provider,
      String id,
      int input, {
      String? variant,
    }) => UsageModel(
      providerID: provider,
      modelID: id,
      variant: variant,
      steps: 1,
      cost: 0,
      tokens: UsageTokens(
        input: input,
        output: 10,
        reasoning: 5,
        cacheRead: 20,
        cacheWrite: 0,
      ),
    );
    final models = [
      model('a', 'same', 200),
      model('b', 'same', 150),
      model('a', 'same', 50),
      model('a', 'same', 100, variant: 'max'),
      for (var i = 0; i < 12; i++) model('a', 'm$i', i),
    ];
    final rows = usageModelRanking(models);
    expect(rows.first.tokens, 320);
    expect(rows.where((row) => row.label == 'same').length, 3);
    expect(rows.last.other, isTrue);
    expect(rows.length, 9);
    expect(
      rows.fold<int>(0, (sum, row) => sum + row.tokens),
      models.fold<int>(0, (sum, row) => sum + row.tokens.total),
    );
  });

  test('missing buckets are unknown, not zeros', () {
    final point = UsageTrendPoint(
      bucket: UsageBucket(
        from: DateTime(2026, 11, 16),
        to: DateTime(2026, 11, 17),
      ),
      failed: true,
    );
    expect(point.total, isNull);
  });

  test('heatmap is a 53-week Monday-first calendar with distinct dates', () {
    final days = usageHeatmapDays(DateTime(2026, 11, 16, 19));
    expect(days.length, 371);
    expect(days.first.weekday, DateTime.monday);
    expect(days.map(usageDateKey).toSet().length, 371);
    expect(days, contains(DateTime(2026, 11, 16)));
  });
}
