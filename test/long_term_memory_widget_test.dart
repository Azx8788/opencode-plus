import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/domain/long_term_memory.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/long_term_memory.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/ui/app_theme.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/kit/style/kit_style_theme.dart';
import 'package:opencode_mobile/ui/screens/memory/memory_editor.dart';
import 'package:opencode_mobile/ui/screens/memory/memory_proposal_card.dart';
import 'package:opencode_mobile/ui/screens/memory/memory_review_screen.dart';
import 'package:opencode_mobile/ui/screens/memory/memory_screen.dart';

import 'fixtures/memory_secure.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late MemoryTestSecure secure;
  late LongTermMemoryStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secure = MemoryTestSecure();
    store = LongTermMemoryStore(preferences: prefs, secure: secure);
    await store.load();
  });
  tearDown(() => store.dispose());
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
      await (FontLoader(
        'QaCjkFallback',
      )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  Future<void> mount(
    WidgetTester tester,
    Widget home, {
    bool dark = false,
    double scale = 1,
    Locale locale = const Locale('en'),
    KitSurfaceStyle style = KitSurfaceStyle.solid,
    KitTextSize textSize = KitTextSize.normal,
  }) async {
    final size = ValueNotifier(textSize);
    addTearDown(size.dispose);
    final base = dark ? AppTheme.dark() : AppTheme.light();
    final theme = base.copyWith(
      textTheme: base.textTheme.copyWith(
        bodyLarge: base.textTheme.bodyLarge!.copyWith(
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
        home: RepaintBoundary(
          key: const ValueKey('memory-capture'),
          child: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  MemoryReviewScreen review({bool project = false, bool Function()? current}) =>
      MemoryReviewScreen(
        store: store,
        request: MemoryWriteRequest(
          memories: const ['请用中文简洁回答', '项目使用 Flutter'],
          projectScoped: project,
        ),
        sessionID: 'session',
        proposalID: 'proposal',
        isCurrent: current ?? () => true,
      );

  Future<void> selectFirst(WidgetTester tester) async {
    final first = find.byKey(const ValueKey('memory-candidate-0'));
    await tester.ensureVisible(first);
    tester.widget<KitSwitchRow>(first).onChanged!(true);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'AI proposal never writes on display or review; only selected entries save',
    (tester) async {
      await mount(
        tester,
        Scaffold(
          body: MemoryProposalCard(
            request: const MemoryWriteRequest(
              memories: ['中文回答'],
              projectScoped: false,
            ),
            store: store,
            proposalID: 'proposal',
            onReview: () {},
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('memory-proposal-review')),
        findsOneWidget,
      );
      expect(secure.writes, 0);
      await mount(tester, review());
      expect(secure.writes, 0);
      expect(
        tester
            .widget<KitButton>(find.byKey(const ValueKey('memory-review-save')))
            .onPressed,
        isNull,
      );
      await selectFirst(tester);
      await tester.tap(find.byKey(const ValueKey('memory-review-save')));
      await tester.pumpAndSettle();
      expect(store.snapshot.entries.single.text, '请用中文简洁回答');
      expect(store.snapshot.entries.single.sourceCallID, 'proposal');
      expect(find.byKey(const ValueKey('memory-review-saved')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('closing review leaves no memory or pending background write', (
    tester,
  ) async {
    await mount(tester, review());
    await selectFirst(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(store.snapshot.entries, isEmpty);
    expect(secure.writes, 0);
  });

  testWidgets(
    'requested project scope never silently becomes global when project is unknown',
    (tester) async {
      await mount(tester, review(project: true));
      await selectFirst(tester);
      expect(
        tester
            .widget<KitButton>(find.byKey(const ValueKey('memory-review-save')))
            .onPressed,
        isNull,
      );
      expect(secure.writes, 0);
      final scope = tester.widget<KitSegmented<String>>(
        find.byType(KitSegmented<String>),
      );
      scope.onChanged!('global');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('memory-review-save')));
      await tester.pumpAndSettle();
      expect(store.snapshot.entries.single.project, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'secure storage failure keeps candidates available and retry saves once',
    (tester) async {
      secure.failWrite = true;
      await mount(tester, review());
      await selectFirst(tester);
      await tester.tap(find.byKey(const ValueKey('memory-review-save')));
      await tester.pumpAndSettle();
      expect(store.snapshot.entries, isEmpty);
      expect(
        find.textContaining('Memory storage could not be read or written'),
        findsOneWidget,
      );
      secure.failWrite = false;
      await tester.tap(find.byKey(const ValueKey('memory-review-save')));
      await tester.pumpAndSettle();
      expect(store.snapshot.entries.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'manual editor saves in same store; deletion needs confirmation',
    (tester) async {
      final profiles = ProfileStore(prefs: prefs, secure: secure);
      final connection = ConnectionController(
        profiles,
        isIsolated: true,
        backgroundLive: BackgroundLiveController(
          preferences: prefs,
          invoke: (method, [args]) async => const {},
        ),
      );
      addTearDown(connection.dispose);
      final shared = profiles.longTermMemory;
      await mount(tester, MemoryScreen(controller: connection));
      await tester.tap(find.byKey(const ValueKey('memory-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('memory-text')),
        'Use concise replies',
      );
      await tester.tap(find.byKey(const ValueKey('memory-save')));
      await tester.pumpAndSettle();
      expect(shared.snapshot.entries.single.text, 'Use concise replies');
      final entry = find.byKey(
        ValueKey('memory-entry-${shared.snapshot.entries.single.id}'),
      );
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('memory-delete')));
      await tester.pumpAndSettle();
      expect(shared.snapshot.entries.length, 1);
      expect(
        find.textContaining('Remove this saved memory from this device?'),
        findsOneWidget,
      );
      // Canceling is deliberately exercised without touching the vault.
      Navigator.of(tester.element(find.byType(MemoryEditor))).pop();
      await tester.pumpAndSettle();
      expect(shared.snapshot.entries.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final style in KitSurfaceStyle.values) {
    testWidgets(
      'memory review follows $style and the application font/text size',
      (tester) async {
        await mount(
          tester,
          review(),
          style: style,
          textSize: KitTextSize.large,
          locale: const Locale('zh'),
        );
        final context = tester.element(find.byType(MemoryReviewScreen));
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
      'capture memory review and fit 320px maximum text scale, dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await mount(tester, review(), dark: dark, locale: const Locale('zh'));
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('memory-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/qa/memory-review-${dark ? 'dark' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.physicalSize = const Size(320, 844);
        await mount(
          tester,
          review(),
          dark: dark,
          scale: AppTheme.maxTextScale,
          locale: const Locale('zh'),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
