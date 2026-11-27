import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/channels/channel_config.dart';
import 'package:opencode_mobile/domain/dev_preview.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/platform/platform_capabilities.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/ui/kit/kit_web_preview.dart';
import 'package:opencode_mobile/ui/screens/settings/channels_screen.dart';
import 'package:opencode_mobile/ui/screens/settings/local_llbot_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _entry = ValueKey('onebot-local-llbot');

Future<ConnectionController> _pumpSettings(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final controller = ConnectionController(
    ProfileStore(prefs: prefs),
    isIsolated: true,
    backgroundLive: BackgroundLiveController(
      preferences: prefs,
      invoke: (method, [arguments]) async => const {},
    ),
  );
  addTearDown(controller.dispose);
  await controller.channels.config.saveOneBot11(
    const OneBot11Config(
      backend: OneBotBackend.napcat,
      webSocketUrl: 'wss://existing-bot.invalid/onebot',
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: OneBot11Screen(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  test('the strict console policy accepts only this HTTP origin', () {
    final origin = Uri.parse('http://127.0.0.1:3080/');
    bool allows(String url) =>
        devPreviewMayLoad(Uri.parse(url), origin, strictOrigin: true);

    expect(allows('http://127.0.0.1:3080/login?step=setup'), isTrue);
    for (final url in [
      'https://127.0.0.1:3080/',
      'http://127.0.0.1:13001/',
      'http://localhost:3080/',
      'https://example.invalid/',
      'http://user@127.0.0.1:3080/',
      'file:///local',
    ]) {
      expect(allows(url), isFalse, reason: url);
    }
    expect(
      devPreviewMayLoad(Uri.parse('https://127.0.0.1:3080/'), origin),
      isTrue,
    );
  });

  testWidgets('opens an internal console without changing the saved service', (
    tester,
  ) async {
    final oldPlatform = debugDefaultTargetPlatformOverride;
    final oldCapabilities = debugPlatformCapabilities;
    // Exercise the Android entry but do not start a native platform view.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    debugPlatformCapabilities = const PlatformCapabilities.android();
    try {
      final controller = await _pumpSettings(tester);
      final entry = find.byKey(_entry);
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.byType(LocalLlbotScreen), findsOneWidget);
      final preview = tester.widget<KitWebPreview>(find.byType(KitWebPreview));
      expect(preview.origin, Uri.parse('http://127.0.0.1:3080/'));
      expect(preview.strictOrigin, isTrue);
      expect(preview.unsupportedAction, isNull);
      expect(
        find.text('This device cannot display the built-in LLBot console.'),
        findsOneWidget,
      );
      expect(preview.failureBody, contains('Start LLBot'));

      preview.onLeave(Uri.parse('https://example.invalid/?token=not-for-ui'));
      await tester.pumpAndSettle();
      expect(find.byType(LocalLlbotScreen), findsOneWidget);
      expect(
        find.text('The local console does not open external links.'),
        findsOneWidget,
      );
      expect(find.textContaining('not-for-ui'), findsNothing);

      final saved = controller.channels.config.loadOneBot11();
      expect(saved.backend, OneBotBackend.napcat);
      expect(saved.webSocketUrl, 'wss://existing-bot.invalid/onebot');
      expect(saved.enabled, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = oldPlatform;
      debugPlatformCapabilities = oldCapabilities;
    }
  });

  testWidgets('does not show the local Android console entry on desktop', (
    tester,
  ) async {
    final old = debugPlatformCapabilities;
    debugPlatformCapabilities = const PlatformCapabilities.linuxDesktop();
    try {
      await _pumpSettings(tester);
      expect(find.byKey(_entry), findsNothing);
    } finally {
      debugPlatformCapabilities = old;
    }
  });
}
