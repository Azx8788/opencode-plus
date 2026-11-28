import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/snowluma_deployment.dart';
import 'package:opencode_mobile/builtin/snowluma_release.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/screens/settings/local_snowluma_screen.dart';

const _pick = ValueKey('snowluma-verify-archive');
const _import = ValueKey('snowluma-import-start');
const _copy = ValueKey('snowluma-copy-webui-token');
const _restart = ValueKey('snowluma-restart-token');
const _fixtureToken = 'abcdef0123456789';

class _Deployment extends SnowLumaDeployment {
  _Deployment({this.current = SnowLumaDeploymentPhase.notInstalled});

  SnowLumaDeploymentPhase current;
  SnowLumaWebUiAccess access = SnowLumaWebUiAccess.initialToken;
  int imports = 0;
  int restarts = 0;
  int tokenReads = 0;

  @override
  SnowLumaDeploymentPhase get phase => current;

  @override
  SnowLumaArm64Release? get installedRelease =>
      current == SnowLumaDeploymentPhase.running
      ? SnowLumaArm64Release.lite
      : null;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> importAndStart(
    SnowLumaArm64Release release,
    SnowLumaArchive source,
  ) async {
    imports++;
    current = SnowLumaDeploymentPhase.running;
    notifyListeners();
  }

  @override
  Future<void> restart() async {
    restarts++;
    access = SnowLumaWebUiAccess.initialToken;
    current = SnowLumaDeploymentPhase.starting;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    current = SnowLumaDeploymentPhase.running;
    notifyListeners();
  }

  @override
  Future<SnowLumaWebUiAccess> webUiAccess() async => access;

  @override
  Future<String?> readInitialWebUiToken() async {
    tokenReads++;
    return access == SnowLumaWebUiAccess.initialToken ? _fixtureToken : null;
  }
}

class _VerifiedArchive extends SnowLumaArchive {
  _VerifiedArchive()
    : super(length: () async => 0, read: () => const Stream.empty());

  @override
  Future<SnowLumaArm64Release> verify() async => SnowLumaArm64Release.lite;
}

Future<void> _pump(WidgetTester tester, LocalSnowLumaScreen screen) async {
  tester.view.physicalSize = const Size(350, 1050);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: screen,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a source archive is rejected in the local runtime module', (
    tester,
  ) async {
    final deployment = _Deployment();
    addTearDown(deployment.dispose);
    await _pump(
      tester,
      LocalSnowLumaScreen(
        deployment: deployment,
        pickArchive: () async => SnowLumaArchive(
          length: () async => 5,
          read: () => throw StateError('an unknown archive must not be read'),
        ),
      ),
    );
    await tester.tap(find.byKey(_pick));
    await tester.pumpAndSettle();
    expect(find.textContaining('does not match a supported'), findsOneWidget);
    expect(find.byKey(_import), findsNothing);
    expect(
      find.byKey(const ValueKey('snowluma-policy-issues')),
      findsOneWidget,
    );
    expect(deployment.imports, 0);
  });

  testWidgets('a verified release still needs explicit import confirmation', (
    tester,
  ) async {
    final deployment = _Deployment();
    addTearDown(deployment.dispose);
    await _pump(
      tester,
      LocalSnowLumaScreen(
        deployment: deployment,
        pickArchive: () async => _VerifiedArchive(),
      ),
    );
    await tester.tap(find.byKey(_pick));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_import));
    await tester.pumpAndSettle();
    expect(deployment.imports, 0);
    expect(find.textContaining('§5.4'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('snowluma-confirm-import')));
    await tester.pumpAndSettle();
    expect(deployment.imports, 1);
    expect(find.byKey(_copy), findsOneWidget);
  });

  testWidgets('access token is copied only after a tap, never rendered', (
    tester,
  ) async {
    final deployment = _Deployment(current: SnowLumaDeploymentPhase.running);
    addTearDown(deployment.dispose);
    final clipboard = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add(call.arguments['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _pump(tester, LocalSnowLumaScreen(deployment: deployment));
    expect(deployment.tokenReads, 0);
    expect(clipboard, isEmpty);
    expect(find.text(_fixtureToken), findsNothing);
    await tester.tap(find.byKey(_copy));
    await tester.pumpAndSettle();
    expect(clipboard, [_fixtureToken]);
    expect(find.text(_fixtureToken), findsNothing);

    // A previously visible control must not copy a rotated token.
    deployment.access = SnowLumaWebUiAccess.ownPassword;
    await tester.tap(find.byKey(_copy));
    await tester.pumpAndSettle();
    expect(clipboard, hasLength(1));
    expect(find.byKey(_copy), findsNothing);
    expect(find.textContaining('password you set'), findsOneWidget);
  });

  testWidgets('a legacy running instance can restart without reimporting', (
    tester,
  ) async {
    final deployment = _Deployment(current: SnowLumaDeploymentPhase.running)
      ..access = SnowLumaWebUiAccess.restartRequired;
    addTearDown(deployment.dispose);
    await _pump(tester, LocalSnowLumaScreen(deployment: deployment));
    expect(find.byKey(_copy), findsNothing);
    await tester.tap(find.byKey(_restart));
    await tester.pumpAndSettle();
    expect(deployment.restarts, 0);
    await tester.tap(find.byKey(const ValueKey('snowluma-confirm-restart')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(deployment.restarts, 1);
    expect(deployment.imports, 0);
    expect(find.byKey(_copy), findsOneWidget);
  });

  testWidgets(
    'the management page keeps the copy action above a local-only preview',
    (tester) async {
      final deployment = _Deployment(current: SnowLumaDeploymentPhase.running);
      addTearDown(deployment.dispose);
      await _pump(tester, LocalSnowLumaScreen(deployment: deployment));
      await tester.tap(find.byKey(const ValueKey('snowluma-open-webui')));
      await tester.pumpAndSettle();

      final preview = tester.widget<KitWebPreview>(find.byType(KitWebPreview));
      expect(preview.origin.toString(), 'http://127.0.0.1:5099/');
      expect(preview.strictOrigin, isTrue);
      expect(find.byKey(_copy), findsOneWidget);
      expect(deployment.tokenReads, 0);
      expect(find.text(_fixtureToken), findsNothing);
    },
    variant: const TargetPlatformVariant({TargetPlatform.linux}),
  );
}
