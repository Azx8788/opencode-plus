import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/builtin/llbot_deployment.dart';
import 'package:opencode_mobile/channels/channel_config.dart';
import 'package:opencode_mobile/domain/dev_preview.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/platform/platform_capabilities.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/screens/settings/channels_screen.dart';
import 'package:opencode_mobile/ui/screens/settings/local_llbot_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _entry = ValueKey('onebot-local-llbot');
const _savedToken = 'existing-remote-access-token';
const _savedConfig = OneBot11Config(
  backend: OneBotBackend.napcat,
  webSocketUrl: 'wss://existing-bot.invalid/onebot',
  expectedSelfId: '54321',
  allowedUsers: {'12345'},
  allowedGroups: {'67890'},
  allowDirect: false,
);
const _replacementHint =
    'Enter a token for this connection, or import the local connection again.';

class _DeferredTokenStorage extends FlutterSecureStorage {
  final tokenRead = Completer<String?>();
  bool tokenReadPending = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (key == ChannelConfigStore.oneBotTokenKey && !tokenReadPending) {
      tokenReadPending = true;
      return tokenRead.future;
    }
    return super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

class _FakeDeployment extends LlbotDeployment {
  _FakeDeployment({
    LlbotDeploymentPhase phase = LlbotDeploymentPhase.notInstalled,
  }) : _phase = phase;

  LlbotDeploymentPhase _phase;
  bool _busy = false;
  String? _stage;
  String? _failure;
  int refreshCalls = 0;
  int deployCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int connectionCalls = 0;
  bool disposed = false;
  bool failNextDeploy = false;
  Completer<void>? deployGate;

  final local = LlbotLocalConnection(
    webSocketUrl: 'ws://127.0.0.1:3001/',
    accessToken: 'test-only-generated-onebot-token',
    webUiPassword: 'test-only-generated-WebUI-password',
    accountId: '10001',
  );

  @override
  LlbotDeploymentPhase get phase => _phase;
  @override
  bool get busy => _busy;
  @override
  String? get stage => _stage;
  @override
  String? get failure => _failure;
  @override
  Uri get consoleUri => Uri.parse('http://127.0.0.1:3080/');

  @override
  Future<void> refresh() async {
    refreshCalls++;
    notifyListeners();
  }

  @override
  Future<void> deploy() async {
    deployCalls++;
    _busy = true;
    _phase = LlbotDeploymentPhase.installing;
    _stage = 'download';
    notifyListeners();
    await deployGate?.future;
    _busy = false;
    if (failNextDeploy) {
      failNextDeploy = false;
      _phase = LlbotDeploymentPhase.failed;
      _stage = null;
      _failure = 'download_failed';
    } else {
      _phase = LlbotDeploymentPhase.running;
      _stage = null;
      _failure = null;
    }
    notifyListeners();
  }

  @override
  Future<void> start() async {
    startCalls++;
    _phase = LlbotDeploymentPhase.running;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _phase = LlbotDeploymentPhase.stopped;
    notifyListeners();
  }

  @override
  Future<LlbotLocalConnection> connection() async {
    connectionCalls++;
    return local;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(460, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
    ),
  );
  await tester.pumpAndSettle();
}

Future<ConnectionController> _pumpSettings(
  WidgetTester tester,
  _FakeDeployment deployment, {
  OneBot11Config saved = _savedConfig,
  FlutterSecureStorage? secure,
}) async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final controller = ConnectionController(
    ProfileStore(prefs: prefs, secure: secure),
    isIsolated: true,
    backgroundLive: BackgroundLiveController(
      preferences: prefs,
      invoke: (method, [arguments]) async => const {},
    ),
  );
  addTearDown(controller.dispose);
  await controller.channels.config.saveOneBot11(
    saved,
    accessToken: _savedToken,
  );
  await _pump(
    tester,
    OneBot11Screen(controller: controller, llbotDeployment: deployment),
  );
  return controller;
}

Future<void> _show(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    300,
    scrollable: find.byType(Scrollable).first,
  );
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await _show(tester, key);
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> _openLlbot(WidgetTester tester) async {
  await tester.ensureVisible(find.text('LLBot'));
  await tester.tap(find.text('LLBot'));
  await tester.pumpAndSettle();
  await _tap(tester, _entry);
}

Future<void> _expectSavedUnchanged(ConnectionController controller) async {
  expect(
    controller.channels.config.loadOneBot11().toJson(),
    _savedConfig.toJson(),
  );
  expect(await controller.channels.config.readOneBot11Token(), _savedToken);
}

Future<void> _returnLocalConnection(
  WidgetTester tester,
  _FakeDeployment deployment,
) async {
  await _openLlbot(tester);
  // Exercise the handoff independently of the deployment page's secret reads.
  Navigator.of(
    tester.element(find.byType(LocalLlbotScreen)),
  ).pop(deployment.local);
  await tester.pumpAndSettle();
}

Future<void> _expectTestBlockedBeforeNetwork(WidgetTester tester) async {
  var clientsCreated = 0;
  await HttpOverrides.runZoned(
    () => _tap(tester, const ValueKey('onebot-test')),
    createHttpClient: (_) {
      clientsCreated++;
      throw StateError(
        'A changed credential target must not reach the network',
      );
    },
  );
  expect(clientsCreated, 0);
  await _expectReplacementError(tester);
}

Future<void> _expectReplacementError(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('onebot-error')),
    -200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  expect(find.text(_replacementHint), findsWidgets);
}

void _testWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    final previous = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await callback(tester);
    } finally {
      // Restore before Flutter checks its per-test foundation invariants.
      debugDefaultTargetPlatformOverride = previous;
    }
  });
}

void main() {
  setUp(() {
    final oldCapabilities = debugPlatformCapabilities;
    // Show the Android entry without creating a native WebView or deployment.
    debugPlatformCapabilities = const PlatformCapabilities.android();
    addTearDown(() {
      debugPlatformCapabilities = oldCapabilities;
      KitRedact.clearKnownSecrets();
    });
  });

  test('the strict console policy accepts only this HTTP origin', () {
    final origin = Uri.parse('http://127.0.0.1:3080/');
    bool allows(String url) =>
        devPreviewMayLoad(Uri.parse(url), origin, strictOrigin: true);

    expect(allows('http://127.0.0.1:3080/login?step=setup'), isTrue);
    for (final url in [
      'https://127.0.0.1:3080/',
      'http://127.0.0.1:3001/',
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

  _testWidgets(
    'opening deployment checks status without installing or changing saved QQ settings',
    (tester) async {
      final deployment = _FakeDeployment();
      addTearDown(deployment.dispose);
      final controller = await _pumpSettings(tester, deployment);
      await _openLlbot(tester);

      expect(deployment.refreshCalls, 1);
      expect(deployment.deployCalls, 0);
      expect(deployment.startCalls, 0);
      expect(deployment.connectionCalls, 0);
      expect(find.byKey(const ValueKey('llbot-deploy')), findsOneWidget);
      expect(find.byType(KitWebPreview), findsNothing);
      await _expectSavedUnchanged(controller);

      Navigator.of(tester.element(find.byType(LocalLlbotScreen))).pop();
      await tester.pumpAndSettle();
      expect(deployment.disposed, isFalse);
      await _show(tester, const ValueKey('onebot-url'));
      expect(
        tester
            .widget<KitField>(find.byKey(const ValueKey('onebot-url')))
            .controller!
            .text,
        _savedConfig.webSocketUrl,
      );
    },
  );

  _testWidgets(
    'deploy invokes the controller and continues after leaving the page',
    (tester) async {
      final gate = Completer<void>();
      final deployment = _FakeDeployment()..deployGate = gate;
      addTearDown(deployment.dispose);
      await _pumpSettings(tester, deployment);
      await _openLlbot(tester);
      await tester.tap(find.byKey(const ValueKey('llbot-deploy')));
      await tester.pump();

      expect(deployment.deployCalls, 1);
      expect(find.text('Downloading LLBot and its runtime'), findsOneWidget);
      expect(find.byType(KitWebPreview), findsNothing);
      expect(
        tester
            .widget<KitButton>(find.byKey(const ValueKey('llbot-deploy')))
            .onPressed,
        isNull,
      );

      Navigator.of(tester.element(find.byType(LocalLlbotScreen))).pop();
      await tester.pumpAndSettle();
      expect(deployment.disposed, isFalse);
      expect(deployment.stopCalls, 0);
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await _tap(tester, _entry);
      expect(deployment.deployCalls, 1);
      expect(find.text('Local console ready'), findsOneWidget);
      expect(find.byKey(const ValueKey('llbot-open-console')), findsOneWidget);
    },
  );

  _testWidgets('a deployment failure is visible and retry calls deploy again', (
    tester,
  ) async {
    final deployment = _FakeDeployment()..failNextDeploy = true;
    addTearDown(deployment.dispose);
    await _pump(tester, LocalLlbotScreen(deployment: deployment));
    await _tap(tester, const ValueKey('llbot-deploy'));
    expect(find.byKey(const ValueKey('llbot-failure')), findsOneWidget);
    expect(
      find.text('Download failed. Check the network, then retry.'),
      findsOneWidget,
    );
    expect(find.byType(KitWebPreview), findsNothing);

    await _tap(tester, const ValueKey('llbot-retry'));
    expect(deployment.deployCalls, 2);
    expect(find.byKey(const ValueKey('llbot-failure')), findsNothing);
    expect(find.text('Local console ready'), findsOneWidget);
  });

  _testWidgets(
    'only a ready service opens the embedded strict-origin console; back does not import',
    (tester) async {
      final deployment = _FakeDeployment(phase: LlbotDeploymentPhase.running);
      addTearDown(deployment.dispose);
      final controller = await _pumpSettings(tester, deployment);
      await _openLlbot(tester);
      expect(find.byType(KitWebPreview), findsNothing);
      await _tap(tester, const ValueKey('llbot-open-console'));

      final preview = tester.widget<KitWebPreview>(find.byType(KitWebPreview));
      expect(preview.origin, deployment.consoleUri);
      expect(preview.strictOrigin, isTrue);
      expect(preview.unsupportedAction, isNull);
      expect(
        find.text('This device cannot display the built-in LLBot console.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Console readiness does not mean QQ is online.'),
        findsOneWidget,
      );
      preview.onLeave(Uri.parse('https://example.invalid/?token=not-for-ui'));
      await tester.pumpAndSettle();
      expect(
        find.text('The local console does not open external links.'),
        findsOneWidget,
      );
      expect(find.textContaining('not-for-ui'), findsNothing);

      Navigator.of(tester.element(find.byType(KitWebPreview))).pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(LocalLlbotScreen))).pop();
      await tester.pumpAndSettle();
      await _expectSavedUnchanged(controller);
      await _show(tester, const ValueKey('onebot-url'));
      expect(
        tester
            .widget<KitField>(find.byKey(const ValueKey('onebot-url')))
            .controller!
            .text,
        _savedConfig.webSocketUrl,
      );
      expect(find.byKey(const ValueKey('onebot-local-token')), findsNothing);
    },
  );

  _testWidgets(
    'explicit local import changes only the draft until normal Save and retains restrictions',
    (tester) async {
      final deployment = _FakeDeployment(phase: LlbotDeploymentPhase.running);
      addTearDown(deployment.dispose);
      final controller = await _pumpSettings(tester, deployment);
      await _openLlbot(tester);
      await _expectSavedUnchanged(controller);
      await _tap(tester, const ValueKey('llbot-use-connection'));

      expect(find.byType(LocalLlbotScreen), findsNothing);
      await _expectSavedUnchanged(controller);
      await _show(tester, const ValueKey('onebot-url'));
      expect(
        tester
            .widget<KitField>(find.byKey(const ValueKey('onebot-url')))
            .controller!
            .text,
        deployment.local.webSocketUrl,
      );
      await _show(tester, const ValueKey('onebot-local-token'));
      expect(find.text('Generated local token · pending save'), findsOneWidget);
      expect(find.text(deployment.local.accessToken), findsNothing);
      await _show(tester, const ValueKey('onebot-users'));
      expect(
        tester
            .widget<KitField>(find.byKey(const ValueKey('onebot-users')))
            .controller!
            .text,
        '12345',
      );
      await _show(tester, const ValueKey('onebot-groups'));
      expect(
        tester
            .widget<KitField>(find.byKey(const ValueKey('onebot-groups')))
            .controller!
            .text,
        '67890',
      );
      await _show(tester, const ValueKey('onebot-enabled'));
      expect(
        tester
            .widget<KitSwitchRow>(find.byKey(const ValueKey('onebot-enabled')))
            .value,
        isFalse,
      );

      await _tap(tester, const ValueKey('onebot-save'));
      final saved = controller.channels.config.loadOneBot11();
      expect(saved.backend, OneBotBackend.llbot);
      expect(saved.transport, OneBotTransport.forward);
      expect(saved.webSocketUrl, 'ws://127.0.0.1:3001/');
      expect(saved.expectedSelfId, '10001');
      expect(saved.enabled, isFalse);
      expect(saved.allowedUsers, _savedConfig.allowedUsers);
      expect(saved.allowedGroups, _savedConfig.allowedGroups);
      expect(saved.allowDirect, _savedConfig.allowDirect);
      expect(saved.allowGroup, _savedConfig.allowGroup);
      expect(saved.requireMentionInGroups, _savedConfig.requireMentionInGroups);
      expect(
        await controller.channels.config.readOneBot11Token(),
        deployment.local.accessToken,
      );
      expect(tester.takeException(), isNull);
    },
  );

  _testWidgets(
    'standalone deployment shows and copies the generated WebUI password and controls the service',
    (tester) async {
      final deployment = _FakeDeployment(phase: LlbotDeploymentPhase.running);
      addTearDown(deployment.dispose);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pump(tester, LocalLlbotScreen(deployment: deployment));
      await _show(tester, const ValueKey('llbot-webui-password'));
      expect(find.text(deployment.local.webUiPassword), findsNothing);
      await _tap(tester, const ValueKey('llbot-reveal-password'));
      expect(find.text(deployment.local.webUiPassword), findsOneWidget);
      await _tap(tester, const ValueKey('llbot-copy-password'));
      expect(copied, deployment.local.webUiPassword);
      await _show(tester, const ValueKey('llbot-stop'));
      expect(find.byKey(const ValueKey('llbot-use-connection')), findsNothing);
      await _tap(tester, const ValueKey('llbot-stop'));
      expect(deployment.stopCalls, 1);

      // Scroll back up after the lower portion of the running view disappears.
      await tester.drag(find.byType(ListView).first, const Offset(0, 1500));
      await tester.pumpAndSettle();
      await _tap(tester, const ValueKey('llbot-start'));
      expect(deployment.startCalls, 1);
      final previousRefreshes = deployment.refreshCalls;
      await tester.tap(find.byKey(const ValueKey('llbot-refresh')));
      await tester.pumpAndSettle();
      expect(deployment.refreshCalls, previousRefreshes + 1);
      expect(deployment.deployCalls, 0);
    },
  );

  for (final change in ['URL', 'backend', 'direction']) {
    _testWidgets(
      'changing the $change after local import blocks Test and Save until credentials are replaced',
      (tester) async {
        final deployment = _FakeDeployment();
        addTearDown(deployment.dispose);
        final controller = await _pumpSettings(tester, deployment);
        await _returnLocalConnection(tester, deployment);

        switch (change) {
          case 'URL':
            await _show(tester, const ValueKey('onebot-url'));
            await tester.enterText(
              find.byKey(const ValueKey('onebot-url')),
              'wss://different-bot.invalid/onebot',
            );
            tester.testTextInput.hide();
          case 'backend':
            final scroll = tester.state<ScrollableState>(
              find.byType(Scrollable).first,
            );
            scroll.position.jumpTo(scroll.position.minScrollExtent);
            await tester.pumpAndSettle();
            await tester.tap(find.text('NapCat').hitTestable());
          case 'direction':
            await _show(tester, const ValueKey('onebot-transport'));
            await tester.tap(find.text('Bot connects in'));
        }
        await tester.pumpAndSettle();
        await _show(tester, const ValueKey('onebot-token'));
        expect(find.byKey(const ValueKey('onebot-local-token')), findsNothing);
        final field = tester.widget<KitField>(
          find.byKey(const ValueKey('onebot-token')),
        );
        expect(field.saved, isFalse);
        expect(field.controller!.text, isEmpty);

        await _tap(tester, const ValueKey('onebot-save'));
        await _expectReplacementError(tester);
        await _expectSavedUnchanged(controller);
        await _expectTestBlockedBeforeNetwork(tester);
        await _expectSavedUnchanged(controller);

        if (change == 'URL') {
          await tester.drag(find.byType(ListView).first, const Offset(0, 2500));
          await tester.pumpAndSettle();
          await _show(tester, const ValueKey('onebot-token'));
          await tester.enterText(
            find.byKey(const ValueKey('onebot-token')),
            'replacement-remote-access-token',
          );
          tester.testTextInput.hide();
          await _tap(tester, const ValueKey('onebot-save'));
          expect(
            controller.channels.config.loadOneBot11().webSocketUrl,
            'wss://different-bot.invalid/onebot',
          );
          expect(
            await controller.channels.config.readOneBot11Token(),
            'replacement-remote-access-token',
          );
        }
      },
    );
  }

  _testWidgets(
    'a saved local token stays bound to its endpoint when the form is edited again',
    (tester) async {
      final deployment = _FakeDeployment();
      addTearDown(deployment.dispose);
      final controller = await _pumpSettings(tester, deployment);
      await _returnLocalConnection(tester, deployment);
      await _tap(tester, const ValueKey('onebot-save'));
      final saved = controller.channels.config.loadOneBot11().toJson();

      await tester.drag(find.byType(ListView).first, const Offset(0, 2500));
      await tester.pumpAndSettle();
      await _show(tester, const ValueKey('onebot-url'));
      await tester.enterText(
        find.byKey(const ValueKey('onebot-url')),
        'wss://different-bot.invalid/onebot',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await _tap(tester, const ValueKey('onebot-save'));
      expect(controller.channels.config.loadOneBot11().toJson(), saved);
      expect(
        await controller.channels.config.readOneBot11Token(),
        deployment.local.accessToken,
      );
      await _expectTestBlockedBeforeNetwork(tester);
    },
  );

  _testWidgets(
    'direct import registers secrets and a late saved-token read cannot replace its credential draft',
    (tester) async {
      final deployment = _FakeDeployment();
      addTearDown(deployment.dispose);
      final storage = _DeferredTokenStorage();
      final controller = await _pumpSettings(
        tester,
        deployment,
        secure: storage,
      );
      expect(storage.tokenReadPending, isTrue);
      KitRedact.clearKnownSecrets();
      await _returnLocalConnection(tester, deployment);
      expect(KitRedact.text(deployment.local.accessToken), KitRedact.mask);
      expect(KitRedact.text(deployment.local.webUiPassword), KitRedact.mask);

      storage.tokenRead.complete(_savedToken);
      await tester.pumpAndSettle();
      await _show(tester, const ValueKey('onebot-local-token'));
      expect(find.text('Generated local token · pending save'), findsOneWidget);
      await _tap(tester, const ValueKey('onebot-replace-local-token'));
      final field = tester.widget<KitField>(
        find.byKey(const ValueKey('onebot-token')),
      );
      expect(field.saved, isFalse);
      expect(field.controller!.text, isEmpty);

      // Empty Replace must not use the old remote token for the local service.
      await _tap(tester, const ValueKey('onebot-save'));
      await _expectReplacementError(tester);
      await _expectSavedUnchanged(controller);
      await _expectTestBlockedBeforeNetwork(tester);
    },
  );

  _testWidgets(
    'loading manual reverse settings preserves the selected backend and port',
    (tester) async {
      final deployment = _FakeDeployment();
      addTearDown(deployment.dispose);
      await _pumpSettings(
        tester,
        deployment,
        saved: _savedConfig.copyWith(
          transport: OneBotTransport.reverse,
          listenPort: 8089,
        ),
      );
      await _show(tester, const ValueKey('onebot-backend'));
      expect(
        tester
            .widget<KitSegmented<OneBotBackend>>(
              find.byKey(const ValueKey('onebot-backend')),
            )
            .selected,
        OneBotBackend.napcat,
      );
      await _show(tester, const ValueKey('onebot-listen-port'));
      expect(
        tester
            .widget<KitField>(find.byKey(const ValueKey('onebot-listen-port')))
            .controller!
            .text,
        '8089',
      );
      expect(find.byKey(const ValueKey('onebot-url')), findsNothing);
    },
  );

  _testWidgets('does not show the Android deployment entry on desktop', (
    tester,
  ) async {
    debugPlatformCapabilities = const PlatformCapabilities.linuxDesktop();
    final deployment = _FakeDeployment();
    addTearDown(deployment.dispose);
    await _pumpSettings(tester, deployment);
    expect(find.byKey(_entry), findsNothing);
    expect(deployment.refreshCalls, 0);
  });
}
