import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/ui/screens/settings/shizuku_screen.dart';

/// The settings page must show what the native side reported and nothing more:
/// no local switch is turned into "authorized", and no connected service is
/// turned into "ready to execute".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('oc/shizuku');
  const events = MethodChannel('oc/shizuku/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Map<String, Object?> status;
  late Map<String, Object?> policy;

  Map<String, Object?> snapshot({
    bool enabled = true,
    String manager = 'installed',
    bool listed = true,
    bool providerConfigured = true,
    String binder = 'alive',
    String authorization = 'granted',
    String evidence = 'server',
    String? authorizationReason,
    String requestPhase = 'idle',
    String? requestReason,
    int? uid = 2000,
    int? apiVersion = 13,
    String session = 'ready',
    String? sessionReason,
    bool storageReady = true,
    bool bridgeReady = true,
    bool admitted = true,
    String? blockedBy,
  }) => <String, Object?>{
    'contractVersion': 2,
    'observedAt': 1000,
    'feature': {'enabled': enabled},
    'manager': {'state': manager},
    'registration': {
      'applicationId': 'com.azx8788.opencode.mini',
      'listed': listed,
      'permissionDeclared': true,
      'v3Support': true,
      'providerConfigured': providerConfigured,
      'providerAuthority': 'com.azx8788.opencode.mini.shizuku',
    },
    'binder': {'state': binder, 'generation': 1, 'provider': 'shizuku'},
    'authorization': {
      'state': authorization,
      'evidence': evidence,
      'reason': authorizationReason,
      'observedAt': 1000,
      'ageMs': 0,
    },
    'request': {
      'phase': requestPhase,
      'reason': requestReason,
      'requestCode': null,
      'attempts': 0,
      'startedAt': null,
    },
    'identity': {
      'uid': uid,
      'backend': uid == 0 ? 'root' : (uid == 2000 ? 'adb' : 'unknown'),
      'apiVersion': apiVersion,
      'patchVersion': 6,
      'selinuxContext': null,
      'supported': uid == 0 || uid == 2000,
    },
    'session': {
      'phase': session,
      'reason': sessionReason,
      'instance': session == 'ready' ? 'svc-1' : null,
      'uid': session == 'ready' ? uid : null,
      'serviceVersion': 4,
    },
    'storage': {'ready': storageReady, 'reason': null},
    'bridge': {'ready': bridgeReady, 'reason': null},
    'overlay': {'allowed': true},
    'execution': {'admitted': admitted, 'blockedBy': blockedBy},
  };

  setUp(() {
    calls = [];
    status = snapshot();
    policy = {
      'direct_read_only': true,
      'advanced_mode': false,
      'allow_delay_seconds': 10,
      'overlay_timeout_seconds': 30,
      'command_timeout_seconds': 30,
      'max_output_kib': 64,
    };
    messenger.setMockMethodCallHandler(events, (call) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'snapshot':
        case 'diagnostics':
          return status;
        case 'policy.read':
        case 'policy.write':
          return policy;
        case 'feature.setEnabled':
          status = snapshot(enabled: call.arguments['enabled'] == true);
          return status;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: ShizukuScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('an unconfirmed authorization is not shown as granted', (
    tester,
  ) async {
    status = snapshot(
      authorization: 'unknown',
      evidence: 'none',
      authorizationReason: 'client_not_attached',
      requestPhase: 'unconfirmed',
      requestReason: 'callback_missing',
      session: 'stopped',
      sessionReason: 'bind_timeout',
      admitted: false,
      blockedBy: 'authorization_unknown',
    );
    await pump(tester);

    expect(
      find.byKey(const ValueKey('shizuku-permission-unverified')),
      findsOne,
    );
    expect(find.textContaining('Unknown · none'), findsOne);
    expect(find.textContaining('unconfirmed'), findsOne);
    // The check button needs an admitted execution, so it stays disabled.
    final diagnostic = tester.widget<FilledButton>(
      find.byKey(const ValueKey('shizuku-diagnostic')),
    );
    expect(diagnostic.onPressed, isNull);
    // The request button stays available: this is not a denial.
    final request = tester.widget<FilledButton>(
      find.byKey(const ValueKey('shizuku-request-permission')),
    );
    expect(request.onPressed, isNotNull);
  });

  testWidgets('every fact is reported separately', (tester) async {
    status = snapshot(
      manager: 'not_installed',
      listed: false,
      providerConfigured: false,
      binder: 'absent',
      authorization: 'unknown',
      evidence: 'none',
      session: 'stopped',
      storageReady: false,
      bridgeReady: false,
      admitted: false,
      blockedBy: 'app_not_listed',
    );
    await pump(tester);

    expect(find.text('No'), findsWidgets); // manager not installed
    expect(find.text('Not received'), findsOne);
    expect(find.text('stopped'), findsOne);
    expect(
      find.byKey(const ValueKey('shizuku-permission-unverified')),
      findsOne,
    );
  });

  testWidgets('requesting authorization calls the native side once', (
    tester,
  ) async {
    status = snapshot(
      authorization: 'denied',
      admitted: false,
      blockedBy: 'authorization_denied',
    );
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('shizuku-request-permission')));
    await tester.pumpAndSettle();

    expect(
      calls.where((call) => call.method == 'authorization.request'),
      hasLength(1),
    );
  });

  testWidgets('the enable switch is a local gate and is sent as such', (
    tester,
  ) async {
    status = snapshot(
      enabled: false,
      admitted: false,
      blockedBy: 'feature_disabled',
    );
    await pump(tester);

    await tester.tap(find.text('Enable Shizuku commands'));
    await tester.pumpAndSettle();

    final call = calls.singleWhere(
      (call) => call.method == 'feature.setEnabled',
    );
    expect(call.arguments, {'enabled': true});
  });

  testWidgets('saving the policy sends every bounded value', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('shizuku-direct-read')));
    await tester.pumpAndSettle();

    final call = calls.singleWhere((call) => call.method == 'policy.write');
    expect(call.arguments, {
      'direct_read_only': false,
      'advanced_mode': false,
      'allow_delay_seconds': 10,
      'overlay_timeout_seconds': 30,
      'command_timeout_seconds': 30,
      'max_output_kib': 64,
    });
  });
}
