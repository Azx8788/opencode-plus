import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/domain/server_gateway.dart';
import 'package:opencode_mobile/state/app_launch_statistics.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/state/usage_overview.dart';

import 'usage_dashboard_test.dart' show usageStats;

class _StatsRepository
    implements ServerOperationsGateway, UsageStatisticsGateway {
  final calls = <UsageQuery>[];
  bool failBucket = false;
  Completer<void>? hold;
  int activeBuckets = 0, maxBuckets = 0;
  @override
  bool get usageStatisticsSupported => true;
  @override
  Future<WorkspaceProject?> loadCurrentProject() async =>
      const WorkspaceProject(
        id: 'project-a',
        directory: '/root/projects/a',
        name: 'Project A',
        worktrees: [],
        updatedAt: 1,
      );

  @override
  Future<UsageStatistics> loadUsageStatistics(UsageQuery query) async {
    calls.add(query);
    final small =
        query.from != null && query.to - query.from! <= 3 * 86400000 + 1;
    if (small) {
      activeBuckets++;
      if (activeBuckets > maxBuckets) maxBuckets = activeBuckets;
      try {
        if (hold != null) await hold!.future;
        await Future<void>.delayed(Duration.zero);
        if (failBucket) throw StateError('Fixture bucket read failed');
      } finally {
        activeBuckets--;
      }
    }
    return usageStats(
      from: query.from ?? DateTime(2026, 1, 1).millisecondsSinceEpoch,
      to: query.to,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConnectionController connection;
  late SharedPreferences prefs;
  late _StatsRepository repository;
  late UsageOverview overview;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    repository = _StatsRepository();
    connection = ConnectionController(
      ProfileStore(prefs: prefs),
      isIsolated: true,
      backgroundLive: BackgroundLiveController(
        preferences: prefs,
        invoke: (method, [arguments]) async => const {},
      ),
    )..repository = repository;
    overview = UsageOverview(
      connection,
      clock: () => DateTime(2026, 11, 16, 19),
      timezoneLoader: () async => 'Asia/Shanghai',
    );
  });
  tearDown(() {
    overview.dispose();
    connection.dispose();
  });

  Future<void> finishTrend() async {
    for (var i = 0; i < 500 && overview.trendLoading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(overview.trendLoading, isFalse);
  }

  test(
    'dashboard reads one lifetime summary and at most two buckets concurrently',
    () async {
      await overview.refresh();
      await finishTrend();
      expect(overview.snapshot, isNotNull);
      expect(overview.lifetime, isNotNull);
      expect(repository.calls.where((q) => q.from == null).length, 1);
      expect(overview.trend.length, 30);
      expect(repository.maxBuckets, lessThanOrEqualTo(2));
      expect(overview.trend.every((point) => point.total != null), isTrue);
      expect(
        repository.calls.every((q) => q.timezone == 'Asia/Shanghai'),
        isTrue,
      );
    },
  );

  test(
    'switching ranges reuses full-day cache; refresh re-reads recorded days',
    () async {
      await overview.refresh();
      await finishTrend();
      repository.calls.clear();
      await overview.setRange(UsageRange.sevenDays);
      await finishTrend();
      expect(
        repository.calls.length,
        1,
        reason: 'only the new aggregate query, seven buckets are cached',
      );
      await overview.refresh();
      await finishTrend();
      expect(repository.calls.length, greaterThan(7));
    },
  );

  test(
    'scope change never reuses another project’s summary or buckets',
    () async {
      await overview.refresh();
      await finishTrend();
      repository.calls.clear();
      await overview.setScope(UsageScope.currentProject);
      await finishTrend();
      expect(repository.calls.every((q) => q.projectID == 'project-a'), isTrue);
      expect(overview.lifetime!.query.projectID, 'project-a');
      expect(overview.snapshot!.projectName, 'Project A');
    },
  );

  test('failed buckets stay unknown and explicit retry can recover', () async {
    repository.failBucket = true;
    await overview.refresh();
    await finishTrend();
    expect(
      overview.trend.every((point) => point.failed && point.total == null),
      isTrue,
    );
    expect(overview.snapshot!.statistics.tokens.total, greaterThan(0));
    repository.failBucket = false;
    await overview.loadTrend();
    expect(
      overview.trend.every((point) => !point.failed && point.total != null),
      isTrue,
    );
  });

  test('superseded reads do not populate a new range or dispatch unbounded workers', () async {
    repository.hold = Completer<void>();
    await overview.refresh();
    await Future<void>.delayed(Duration.zero);
    await overview.setRange(UsageRange.sevenDays);
    repository.hold!.complete();
    repository.hold = null;
    await finishTrend();
    expect(overview.range, UsageRange.sevenDays);
    expect(overview.trend.length, 7);
    expect(repository.maxBuckets, lessThanOrEqualTo(2));
    expect(overview.trend.first.bucket.from, DateTime(2026, 11, 10));
  });

  test(
    'changing location discards the whole page and ignores outstanding reads',
    () async {
      repository.hold = Completer<void>();
      await overview.refresh();
      connection.locationRevision++;
      connection.locationNotice = 'fixture location changed';
      connection.dismissLocationNotice();
      expect(overview.detached, isTrue);
      expect(overview.snapshot, isNull);
      expect(overview.lifetime, isNull);
      expect(overview.trend, isEmpty);
      repository.hold!.complete();
      repository.hold = null;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(overview.trend, isEmpty);
      expect(overview.lifetime, isNull);
    },
  );

  test('corrupt optional launch metadata cannot break the dashboard', () async {
    await prefs.setString('oc.appLaunchStatistics.v1', 'not a list');
    expect(AppLaunchStatistics.read(prefs), isNull);
    await prefs.setStringList('oc.appLaunchStatistics.v1', [
      '5',
      '999999999999999999',
    ]);
    expect(AppLaunchStatistics.read(prefs), isNull);
  });

  test(
    'main-app launch is counted once per process, with an honest start date',
    () async {
      final date = DateTime(2026, 11, 16, 19);
      expect(AppLaunchStatistics.read(prefs), isNull);
      expect(
        await AppLaunchStatistics.recordMainLaunch(prefs, now: date),
        isTrue,
      );
      expect(
        await AppLaunchStatistics.recordMainLaunch(prefs, now: date),
        isTrue,
      );
      expect(AppLaunchStatistics.read(prefs)!.count, 1);
      expect(AppLaunchStatistics.read(prefs)!.since, date);
    },
  );
}
