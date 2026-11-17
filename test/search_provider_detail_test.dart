import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/search_settings.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/ui/app_theme.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/kit/style/kit_style_theme.dart';
import 'package:opencode_mobile/ui/screens/settings/search_provider_detail_screen.dart';

SearchProviderSettings settings({
  bool connected = false,
  bool selected = false,
}) => SearchProviderSettings(
  selected: selected ? 'parallel' : null,
  enabled: selected,
  providers: [
    SearchProviderOption(
      id: 'parallel',
      name: 'Parallel',
      connected: connected,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in const {
      'AppSans': 'assets/fonts/geist/Geist-Variable.ttf',
      'AppMono': 'assets/fonts/geist/GeistMono-Variable.ttf',
      'AppPhosphorRegular': 'assets/fonts/phosphor/Phosphor.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  Future<void> mount(
    WidgetTester tester,
    Widget screen, {
    bool dark = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => kitStyleTheme(
          child: KitEffectsScope(
            effects: KitEffects.defaults.copyWith(
              motion: KitMotionLevel.off,
              haptics: false,
            ),
            child: child!,
          ),
        ),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final dark in [false, true]) {
    testWidgets(
      'search provider uses a full detail page and explicit activation, dark=$dark',
      (tester) async {
        var saves = 0, selections = 0, searches = 0;
        await mount(
          tester,
          SearchProviderDetailScreen(
            provider: settings().providers.single,
            settings: settings(),
            saveKey: (key) async {
              expect(key.isNotEmpty, isTrue);
              saves++;
              return settings(connected: true);
            },
            select: () async {
              selections++;
              return settings(connected: true, selected: true);
            },
            test: () async {
              searches++;
            },
          ),
          dark: dark,
        );
        expect(
          find.byKey(const ValueKey('search-provider-detail')),
          findsOneWidget,
        );
        expect(find.text('Providers and MCP'), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('search-provider-key')),
          'test-only-not-a-real-key',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('search-provider-save')),
        );
        await tester.tap(find.byKey(const ValueKey('search-provider-save')));
        await tester.pumpAndSettle();
        expect(saves, 1);
        expect(
          selections,
          0,
        ); // Saving a key is not selecting a search provider.
        expect(find.text('test-only-not-a-real-key'), findsNothing);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('search-provider-select')),
          200,
        );
        await tester.tap(find.byKey(const ValueKey('search-provider-select')));
        await tester.pumpAndSettle();
        expect(selections, 1);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('search-provider-test')),
          150,
        );
        await tester.tap(find.byKey(const ValueKey('search-provider-test')));
        await tester.pumpAndSettle();
        expect(searches, 1);
        expect(
          find.text('The selected provider returned real web sources.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'failed credential save never displays server error or activates provider',
    (tester) async {
      var selections = 0;
      await mount(
        tester,
        SearchProviderDetailScreen(
          provider: settings().providers.single,
          settings: settings(),
          saveKey: (_) async => throw StateError('sensitive-server-error'),
          select: () async {
            selections++;
            return settings();
          },
          test: () async => fail('Unauthorized provider must not be tested'),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('search-provider-key')),
        'test-only-not-a-real-key',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('search-provider-save')),
      );
      await tester.tap(find.byKey(const ValueKey('search-provider-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('sensitive-server-error'), findsNothing);
      expect(find.text('The last action failed'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('search-provider-select')),
        200,
      );
      final selectButton = tester.widget<KitButton>(
        find.byKey(const ValueKey('search-provider-select')),
      );
      expect(selectButton.onPressed, isNull);
      expect(selections, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
