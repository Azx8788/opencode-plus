import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

  setUp(() {
    failSave = failLoad = false;
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
            'binding': 'connected',
            'overlayAllowed': false,
            'backend': 'adb',
            'uid': 2000,
            'provider': 'shizuku',
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
