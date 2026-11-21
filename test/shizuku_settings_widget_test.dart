import 'dart:async';

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
  var operationHistoryFull = false;
  var incompleteLoad = false;
  String? permissionReason;
  String? availabilityReason;
  String permissionState = 'granted';
  String provider = 'shizuku';
  String? applicationId;
  Object? shizukuRegistrationValid;
  Object? shizukuProviderValid;
  late List<Completer<Map<String, Object?>>> executionReplies;
  Completer<bool>? cancellationReply;
  var statusRevision = 0;

  setUp(() {
    failSave = failLoad = false;
    incompleteLoad = false;
    failedBinding = false;
    operationHistoryFull = false;
    permissionReason = null;
    availabilityReason = null;
    permissionState = 'granted';
    provider = 'shizuku';
    applicationId = null;
    shizukuRegistrationValid = null;
    shizukuProviderValid = null;
    executionReplies = [];
    cancellationReply = null;
    statusRevision = 0;
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
            'permission': permissionState,
            'binding': failedBinding ? 'failed' : 'connected',
            'bindingReason': failedBinding ? 'bind_timeout' : null,
            'executionReady': !failedBinding,
            'overlayAllowed': false,
            'backend': 'adb',
            'uid': failedBinding ? null : 2000,
            'serverUid': 0,
            'serverVersion': 13,
            'aiBridgeReady': false,
            'provider': provider,
            'statusRevision': ++statusRevision,
            'operationStorageReady': true,
            'operationHistoryFull': operationHistoryFull,
            'permissionRequestState': 'not_requested',
            'permissionRequestReason': permissionReason,
            'availabilityReason': availabilityReason,
            'applicationId': applicationId,
            'shizukuRegistrationValid': shizukuRegistrationValid,
            'shizukuProviderValid': shizukuProviderValid,
          };
        case 'settings':
          if (failLoad) throw PlatformException(code: 'load_failed');
          if (incompleteLoad) return {'direct_read_only': false};
          return Map<String, Object?>.from(stored);
        case 'saveSettings':
          if (failSave) throw PlatformException(code: 'save_failed');
          stored = Map<String, Object?>.from(call.arguments as Map);
          return stored;
        case 'execute':
          if (executionReplies.isNotEmpty) {
            return executionReplies.removeAt(0).future;
          }
          return {'state': 'succeeded', 'stdout': 'read-result', 'exitCode': 0};
        case 'cancel':
          return cancellationReply?.future ?? true;
        case 'requestPermission':
          return true;
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

  testWidgets('Sui authorization uses its SystemUI confirmation flow', (
    tester,
  ) async {
    provider = 'sui';
    permissionState = 'requestable';
    await mount(tester);
    expect(
      find.text('Sui displays its authorization prompt through SystemUI.'),
      findsOneWidget,
    );
    final request = find.byKey(const ValueKey('shizuku-request-permission'));
    expect(tester.widget<FilledButton>(request).onPressed, isNotNull);
    await tester.tap(request);
    await tester.pumpAndSettle();
    expect(calls.any((call) => call.method == 'requestPermission'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an unregistered Shizuku package is not shown as authorized', (
    tester,
  ) async {
    availabilityReason = 'shizuku_app_not_listable';
    permissionState = 'not_registered';
    await mount(tester);
    expect(find.text('App not registered'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shizuku-registration-reason')),
      findsOneWidget,
    );
    expect(
      find.textContaining('cannot list this installed package'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a denied live permission check never renders as granted', (
    tester,
  ) async {
    permissionState = 'denied';
    permissionReason = 'permission_denied';
    await mount(tester);
    expect(find.text('Denied'), findsOneWidget);
    expect(find.text('Granted'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a full history disables new commands with an explanation', (
    tester,
  ) async {
    operationHistoryFull = true;
    await mount(tester);
    await reveal(tester, 'shizuku-operation-history-full');
    expect(
      find.byKey(const ValueKey('shizuku-operation-history-full')),
      findsOneWidget,
    );
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
  });

  testWidgets(
    'direct read-only check does not enable unsafe no-overlay controls',
    (tester) async {
      await mount(tester);
      await reveal(tester, 'shizuku-diagnostic');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('shizuku-diagnostic')),
            )
            .onPressed,
        isNotNull,
      );
      final cancelTest = find.byKey(
        const ValueKey('shizuku-cancellation-test'),
      );
      expect(tester.widget<OutlinedButton>(cancelTest).onPressed, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late cancellation reply cannot mark a different command stopped',
    (tester) async {
      final firstExecution = Completer<Map<String, Object?>>();
      final secondExecution = Completer<Map<String, Object?>>();
      cancellationReply = Completer<bool>();
      executionReplies.addAll([firstExecution, secondExecution]);
      await mount(tester);
      await reveal(tester, 'shizuku-diagnostic');
      final diagnostic = find.byKey(const ValueKey('shizuku-diagnostic'));

      await tester.tap(diagnostic);
      await tester.pump();
      await tester.tap(find.text('Stop current command'));
      await tester.pump();

      firstExecution.complete({
        'state': 'cancelled',
        'stdout': '',
        'stderr': '',
        'truncated': false,
      });
      await tester.pumpAndSettle();

      await tester.tap(diagnostic);
      await tester.pump();
      cancellationReply!.complete(false);
      await tester.pumpAndSettle();
      expect(find.textContaining('Stop requested.'), findsNothing);

      secondExecution.complete({
        'state': 'succeeded',
        'stdout': 'read-result',
        'exitCode': 0,
      });
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('partial settings response never enables edits with defaults', (
    tester,
  ) async {
    incompleteLoad = true;
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
    await reveal(tester, 'shizuku-error');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('shizuku-error')),
        matching: find.textContaining('invalid_shizuku_settings'),
      ),
      findsOneWidget,
    );
    expect(calls.where((call) => call.method == 'saveSettings'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an unverifiable permission check stays unknown, never granted', (
    tester,
  ) async {
    permissionState = 'unknown';
    availabilityReason = 'shizuku_permission_unverified';
    await mount(tester);
    final permissionStatus = find.byKey(
      const ValueKey('shizuku-permission-status'),
    );
    expect(
      find.descendant(of: permissionStatus, matching: find.text('Unknown')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: permissionStatus, matching: find.text('Granted')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('shizuku-permission-unverified')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a lost decision is not displayed as a grant', (tester) async {
    permissionState = 'requestable';
    permissionReason = 'permission_callback_missing';
    await mount(tester);
    expect(find.textContaining('returned no decision'), findsOneWidget);
    expect(find.text('Not authorized'), findsOneWidget);
    expect(find.text('Granted'), findsNothing);
    expect(find.textContaining('Authorization request status'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
