import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/ui/screens/settings_screen.dart';
import 'package:opencode_mobile/ui/screens/settings/shizuku_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('oc/shizuku');
  const events = MethodChannel('oc/shizuku/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, Object?> stored;
  late List<MethodCall> calls;
  var failSave = false;
  var failLoad = false;
  var failedBinding = false;
  String? permissionReason;

  setUp(() {
    failSave = failLoad = false;
    failedBinding = false;
    permissionReason = null;
    stored = {
      'direct_read_only': true,
      'advanced_mode': false,
      'allow_delay_seconds': 10,
      'overlay_timeout_seconds': 30,
      'command_timeout_seconds': 30,
      'max_output_kib': 64,
    };
    calls = [];
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'status':
          return {
            'enabled': true,
            'binderAlive': true,
            'permission': 'granted',
            'binding': failedBinding ? 'failed' : 'connected',
            'bindingReason': failedBinding ? 'bind_timeout' : null,
            'executionReady': !failedBinding,
            'overlayAllowed': false,
            'backend': 'adb',
            'uid': failedBinding ? null : 2000,
            'serverUid': 0,
            'serverVersion': 13,
            'aiBridgeReady': false,
            'provider': 'shizuku',
            'permissionRequestState': 'not_requested',
            'permissionRequestReason': permissionReason,
          };
        case 'settings':
          if (failLoad) throw PlatformException(code: 'load_failed');
          return Map<String, Object?>.from(stored);
        case 'saveSettings':
          if (failSave) throw PlatformException(code: 'save_failed');
          stored = Map<String, Object?>.from(call.arguments as Map);
          return stored;
        case 'execute':
          return {'state': 'succeeded', 'stdout': 'read-result', 'exitCode': 0};
        default:
          return null;
      }
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(460, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: ShizukuScreen()));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(
      find.byKey(ValueKey(key)),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('actual Settings hub and Agent list open the Shizuku screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
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
    tester.view.physicalSize = const Size(460, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-hub-row-ai')));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('settings-shizuku'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(ShizukuScreen), findsOneWidget);
    expect(calls.any((call) => call.method == 'status'), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'bind timeout is distinct from permission and an unverified UID stays unknown',
    (tester) async {
      failedBinding = true;
      await mount(tester);
      expect(
        find.byKey(const ValueKey('shizuku-binding-reason')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Authorization alone is not execution readiness.'),
        findsOneWidget,
      );
      expect(find.textContaining('ROOT (UID 0)'), findsNothing);
      await reveal(tester, 'shizuku-diagnostic');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('shizuku-diagnostic')),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a Sui-owned authorization is explained instead of being retried blindly',
    (tester) async {
      permissionReason = 'sui_managed_authorization';
      await mount(tester);
      expect(
        find.textContaining('Sui owns authorization here'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('shizuku-request-permission')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a lost decision is not displayed as a grant',
    (tester) async {
      permissionReason = 'permission_callback_missing';
      await mount(tester);
      expect(find.textContaining('returned no decision'), findsOneWidget);
      expect(find.textContaining('Authorization request status'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'advanced mode is off by default and requires explicit confirmation',
    (tester) async {
      await mount(tester);
      await reveal(tester, 'shizuku-advanced');
      final row = find.byKey(const ValueKey('shizuku-advanced'));
      expect(tester.widget<SwitchListTile>(row).value, isFalse);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(calls.where((call) => call.method == 'saveSettings'), isEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(stored['advanced_mode'], isFalse);

      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
      await tester.pumpAndSettle();
      expect(stored['advanced_mode'], isTrue);
      expect(stored['direct_read_only'], isTrue);
      expect(stored['allow_delay_seconds'], 10);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('failed save does not display advanced mode as enabled', (
    tester,
  ) async {
    await mount(tester);
    await reveal(tester, 'shizuku-advanced');
    failSave = true;
    await tester.tap(find.byKey(const ValueKey('shizuku-advanced')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();
    expect(stored['advanced_mode'], isFalse);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('shizuku-advanced')),
          )
          .value,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'direct-read diagnostic remains available without overlay permission',
    (tester) async {
      await mount(tester);
      await reveal(tester, 'shizuku-diagnostic');
      final button = find.byKey(const ValueKey('shizuku-diagnostic'));
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'execute'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'settings read error disables edits rather than saving defaults',
    (tester) async {
      failLoad = true;
      await mount(tester);
      await reveal(tester, 'shizuku-advanced');
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('shizuku-advanced')),
            )
            .onChanged,
        isNull,
      );
      expect(calls.where((call) => call.method == 'saveSettings'), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
