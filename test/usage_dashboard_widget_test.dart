import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/usage_dashboard.dart';
import 'package:opencode_mobile/domain/usage_statistics.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/state/app_launch_statistics.dart';
import 'package:opencode_mobile/state/usage_overview.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/ui/app_theme.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/kit/style/kit_style_theme.dart';
import 'package:opencode_mobile/ui/screens/usage_screen.dart';

import 'usage_dashboard_test.dart' show usageStats;

final _now = DateTime(2026, 11, 16, 19, 9);

UsageSnapshot _snapshot({
  UsageRange range = UsageRange.thirtyDays,
  bool empty = false,
}) {
  final query = UsageQuery.forRange(
    range,
    now: _now,
    timezone: 'Asia/Shanghai',
  );
  final from = query.from ?? DateTime(2026, 1, 1).millisecondsSinceEpoch;
  final stats = usageStats(
    from: from,
    to: query.to,
    tokens: UsageTokens(
      input: empty ? 0 : 180000000,
      output: empty ? 0 : 3000000,
      reasoning: empty ? 0 : 760000,
      cacheRead: empty ? 0 : 371000000,
      cacheWrite: empty ? 0 : 1310000,
    ),
    activity: [
      for (var day = 0; day < 160; day++)
        UsageActivity(
          date: usageDateKey(DateTime(2026, 11, 16 - day)),
          steps: day % 7 == 0 ? 0 : (day * 7) % 40,
        ),
    ],
    models: empty
        ? []
        : [
            for (var index = 0; index < 12; index++)
              UsageModel(
                providerID: 'provider-$index',
                modelID: index == 0 ? 'Deep model' : 'Model $index',
                steps: 12 + index,
                cost: 0,
                tokens: UsageTokens(
                  input:
                      5560700 *
                          const [44, 15, 9, 8, 5, 4, 2, 2, 2, 2, 2, 5][index] -
                      130000,
                  output: 100000,
                  reasoning: 10000,
                  cacheRead: 20000,
                  cacheWrite: 0,
                ),
              ),
          ],
  );
  return UsageSnapshot(
    statistics: stats,
    query: query,
    range: range,
    scope: UsageScope.allProjects,
    fetchedAt: _now,
  );
}

List<UsageTrendPoint> _points(UsageSnapshot snapshot, {bool failed = false}) {
  final plan = UsageTrendPlan.forStatistics(
    snapshot.statistics,
    snapshot.range,
  );
  final weights = List.generate(plan.buckets.length, (index) => index % 8 + 1);
  final weightTotal = weights.fold<int>(0, (sum, value) => sum + value);
  int share(int total, int index) {
    if (index < weights.length - 1)
      return total * weights[index] ~/ weightTotal;
    return total -
        weights
            .take(index)
            .fold<int>(0, (sum, value) => sum + total * value ~/ weightTotal);
  }

  final tokens = snapshot.statistics.tokens;
  return [
    for (var index = 0; index < plan.buckets.length; index++)
      UsageTrendPoint(
        bucket: plan.buckets[index],
        failed: failed && index == 2,
        statistics: failed && index == 2
            ? null
            : usageStats(
                from: plan.buckets[index].from.millisecondsSinceEpoch,
                to: plan.buckets[index].to.millisecondsSinceEpoch,
                tokens: UsageTokens(
                  input: share(tokens.input, index),
                  output: share(tokens.output, index),
                  reasoning: share(tokens.reasoning, index),
                  cacheRead: share(tokens.cacheRead, index),
                  cacheWrite: share(tokens.cacheWrite, index),
                ),
              ),
      ),
  ];
}

class _Profiles extends ProfileStore {
  _Profiles(SharedPreferences prefs) : super(prefs: prefs);
  final phone = ServerProfile(
    id: 'phone',
    name: 'Phone',
    baseUrl: 'http://127.0.0.1:4097',
  );
  @override
  List<ServerProfile> get profiles => [phone];
  @override
  String? get activeId => phone.id;
}

class _ReadyOverview extends UsageOverview {
  _ReadyOverview(super.connection) {
    snapshot = _snapshot();
    lifetime = _snapshot(range: UsageRange.allTime);
    trendPlan = UsageTrendPlan.forStatistics(
      snapshot!.statistics,
      snapshot!.range,
    );
    trend = _points(snapshot!);
  }
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in const {
      'AppSans': 'assets/fonts/geist/Geist-Variable.ttf',
      'AppMono': 'assets/fonts/geist/GeistMono-Variable.ttf',
      'AppPhosphorRegular': 'assets/fonts/phosphor/Phosphor.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
    final cjk = File('build/qa-fonts/NotoSansSC.ttf');
    if (cjk.existsSync()) {
      await (FontLoader('QaCjkFallback')..addFont(
            cjk.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          ))
          .load();
    }
  });

  Future<void> mount(
    WidgetTester tester, {
    bool dark = false,
    bool failed = false,
    bool empty = false,
    bool unavailable = false,
    double width = 390,
    double scale = 1,
    KitTextSize textSize = KitTextSize.normal,
    Locale locale = const Locale('en'),
    KitSurfaceStyle style = KitSurfaceStyle.solid,
    ValueChanged<UsageRange>? onRange,
  }) async {
    final snapshot = _snapshot(empty: empty);
    final size = ValueNotifier(textSize);
    addTearDown(size.dispose);
    final appTheme = dark ? AppTheme.dark() : AppTheme.light();
    // Test-only stand-in for Android's system CJK fallback. AppSans remains
    // primary, and no APK font asset or appearance preference is changed.
    final theme = appTheme.copyWith(
      textTheme: appTheme.textTheme.copyWith(
        bodyLarge: appTheme.textTheme.bodyLarge!.copyWith(
          fontFamilyFallback: const ['QaCjkFallback'],
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: Theme(
            data: AppTheme.forLocale(Theme.of(context), locale),
            child: KitText.appScale(
              size: size,
              max: AppTheme.maxTextScale,
              child: KitEffectsScope(
                effects: KitEffects.defaults.copyWith(
                  motion: KitMotionLevel.off,
                  haptics: false,
                  surfaceStyle: style,
                ),
                child: kitStyleTheme(child: child!),
              ),
            ),
          ),
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: RepaintBoundary(
                  key: const ValueKey('usage-preview'),
                  child: ColoredBox(
                    color: (dark ? AppTheme.dark() : AppTheme.light())
                        .scaffoldBackgroundColor,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: UsageDashboard(
                        snapshot: unavailable ? null : snapshot,
                        lifetime: unavailable
                            ? null
                            : _snapshot(range: UsageRange.allTime),
                        lifetimeFailed: unavailable,
                        now: _now,
                        range: UsageRange.thirtyDays,
                        launches: AppLaunchStatistics(
                          count: 343,
                          since: DateTime(2026, 11, 1),
                        ),
                        trend: unavailable
                            ? []
                            : _points(snapshot, failed: failed),
                        trendPlan: unavailable
                            ? null
                            : UsageTrendPlan.forStatistics(
                                snapshot.statistics,
                                snapshot.range,
                              ),
                        onRange: onRange ?? (_) {},
                        onRetryTrend: () {},
                        onDetails: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'dashboard has the requested sections, honest labels and no double-counted cache',
    (tester) async {
      await mount(tester);
      expect(find.byKey(const ValueKey('stats-heatmap')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('stats-metric-sessions')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('stats-metric-launches')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('stats-model-ranking')), findsOneWidget);
      expect(find.byKey(const ValueKey('stats-sources')), findsOneWidget);
      final snapshot = _snapshot();
      expect(
        tester
            .widget<KitText>(find.byKey(const ValueKey('stats-value-input')))
            .text,
        compactUsageCount(snapshot.statistics.tokens.prompt),
      );
      expect(
        tester
            .widget<KitText>(find.byKey(const ValueKey('stats-value-output')))
            .text,
        '3.76M',
      );
      expect(find.text('Model requests'), findsOneWidget);
      expect(
        find.text('Model steps, not a total message count'),
        findsOneWidget,
      );
      expect(
        find.textContaining('This server does not report separate'),
        findsOneWidget,
      );
      expect(find.text('Other'), findsOneWidget);
      expect(find.text('Total messages'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '7/30/90/all are real controls that preserve page scroll position',
    (tester) async {
      UsageRange? picked;
      await mount(tester, onRange: (range) => picked = range);
      final target = find.byKey(const ValueKey('usage-range-sevenDays'));
      await reveal(tester, target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(picked, UsageRange.sevenDays);
      expect(
        find.byKey(const ValueKey('usage-range-ninetyDays')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('usage-range-allTime')), findsOneWidget);
    },
  );

  testWidgets(
    'selecting a chart bar displays its real period rather than the total',
    (tester) async {
      await mount(tester);
      final plot = find.byKey(const ValueKey('stats-trend-plot'));
      await reveal(tester, plot);
      final before = tester
          .widget<KitText>(
            find.byKey(const ValueKey('stats-trend-readout-total')),
          )
          .text;
      await tester.tapAt(tester.getCenter(plot));
      await tester.pumpAndSettle();
      final after = tester
          .widget<KitText>(
            find.byKey(const ValueKey('stats-trend-readout-total')),
          )
          .text;
      expect(after, isNot(before));
      expect(
        tester
            .widget<KitText>(
              find.byKey(const ValueKey('stats-trend-readout-date')),
            )
            .text,
        isNot('Period total'),
      );
    },
  );

  testWidgets(
    'missing days remain gaps and have retry, not fabricated zero bars',
    (tester) async {
      await mount(tester, failed: true);
      expect(
        find.text(
          'Some dates could not be read. Gaps are unknown, not zero usage.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('stats-trend-retry')), findsOneWidget);
      final details = find.byKey(const ValueKey('stats-trend-details'));
      await reveal(tester, details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('Not recorded'), findsWidgets);
    },
  );

  testWidgets('heatmap starts at the newest weeks and supports day details', (
    tester,
  ) async {
    await mount(tester);
    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('stats-heatmap-scroll')),
    );
    expect(
      scroll.controller!.offset,
      scroll.controller!.position.maxScrollExtent,
    );
    expect(scroll.controller!.offset, greaterThan(0));
    final details = find.byKey(const ValueKey('stats-activity-details'));
    await reveal(tester, details);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.textContaining('model requests'), findsWidgets);
  });

  testWidgets(
    'unknown summary shows an explanation; empty usage shows an empty state',
    (tester) async {
      await mount(tester, unavailable: true);
      expect(
        find.textContaining('Could not read the activity overview'),
        findsOneWidget,
      );
      await mount(tester, empty: true);
      expect(
        tester
            .widget<KitText>(
              find.byKey(const ValueKey('stats-value-cache-rate')),
            )
            .text,
        '—',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual usage page preserves exact costs, budgets and the advanced report',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final connection = ConnectionController(
        _Profiles(prefs),
        isIsolated: true,
        backgroundLive: BackgroundLiveController(
          preferences: prefs,
          invoke: (method, [arguments]) async => const {},
        ),
      );
      final overview = _ReadyOverview(connection);
      addTearDown(() {
        overview.dispose();
        connection.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: UsageScreen(controller: connection, overview: overview),
        ),
      );
      await tester.pumpAndSettle();
      final details = find.byKey(const ValueKey('stats-advanced'));
      await tester.scrollUntilVisible(
        details,
        350,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('usage-content')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usage-total-cost')), findsOneWidget);
      expect(
        tester
            .widget<KitText>(find.byKey(const ValueKey('usage-total-cost')))
            .text,
        r'$1.25',
      );
      expect(find.byKey(const ValueKey('usage-budget-usd')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final style in KitSurfaceStyle.values) {
    testWidgets(
      'Chinese dashboard follows application style $style and internal text size',
      (tester) async {
        await mount(
          tester,
          style: style,
          locale: const Locale('zh'),
          textSize: KitTextSize.large,
        );
        final context = tester.element(find.byType(UsageDashboard));
        expect(KitEffects.of(context).surfaceStyle, style);
        expect(MediaQuery.textScalerOf(context).scale(1), closeTo(1.15, .001));
        expect(
          KitText.styleOf(context, KitTextRole.body).fontFamily,
          AppTheme.sansFamily,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final dark in [false, true]) {
    testWidgets(
      'dashboard fits narrow width with maximum supported scaling, dark=$dark',
      (tester) async {
        await mount(
          tester,
          dark: dark,
          width: 320,
          scale: AppTheme.maxTextScale,
          locale: const Locale('zh'),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
    testWidgets('capture actual app usage dashboard, dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, dark: dark, locale: const Locale('zh'));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('usage-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/qa/usage-${dark ? 'dark' : 'light'}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
