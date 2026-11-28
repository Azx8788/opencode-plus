import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/builtin/snowluma_deployment.dart';
import 'package:opencode_mobile/channels/channel_config.dart';
import 'package:opencode_mobile/platform/platform_capabilities.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/screens/settings/channels_screen.dart';
import 'package:opencode_mobile/ui/screens/settings/local_snowluma_screen.dart';
import 'package:opencode_mobile/ui/screens/settings/manager_agent_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ConnectionController> _controller() async {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ConnectionController(
    ProfileStore(prefs: prefs),
    isIsolated: true,
    backgroundLive: BackgroundLiveController(
      preferences: prefs,
      invoke: (method, [arguments]) async => const {},
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(460, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: home));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the hub lists Telegram and both QQ channels', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, ChannelsScreen(controller: controller));

    expect(find.text('Telegram'), findsOneWidget);
    expect(find.text('QQ official bot'), findsOneWidget);
    expect(find.text('QQ personal account'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('channel-accounts-empty')),
      findsOneWidget,
    );
  });

  testWidgets('the channel hub opens a separate Android SnowLuma module', (
    tester,
  ) async {
    final previous = debugPlatformCapabilities;
    debugPlatformCapabilities = const PlatformCapabilities.android();
    addTearDown(() => debugPlatformCapabilities = previous);
    final controller = await _controller();
    final deployment = SnowLumaDeployment(supported: false);
    addTearDown(controller.dispose);
    addTearDown(deployment.dispose);
    await _pump(
      tester,
      ChannelsScreen(controller: controller, snowLumaDeployment: deployment),
    );

    await tester.tap(find.byKey(const ValueKey('channel-local-snowluma')));
    await tester.pumpAndSettle();
    expect(find.byType(LocalSnowLumaScreen), findsOneWidget);
    expect(find.text('Unsupported device'), findsOneWidget);
  });

  testWidgets(
    'only verified accounts get cards, including a stopped connection',
    (tester) async {
      final controller = await _controller();
      addTearDown(controller.dispose);
      const draft = OneBot11Config(
        webSocketUrl: 'ws://127.0.0.1:3001/',
        expectedSelfId: '12345',
      );
      await controller.channels.saveOneBot11(
        draft,
        accessToken: 'fixture-onebot-token',
      );
      await _pump(tester, ChannelsScreen(controller: controller));

      const card = ValueKey('channel-account-onebot11');
      expect(find.byKey(card), findsNothing);
      expect(
        find.byKey(const ValueKey('channel-accounts-empty')),
        findsOneWidget,
      );

      // This is the display metadata a successful, saved test writes.
      await controller.channels.saveOneBot11(draft, verifiedAccountId: '12345');
      await tester.pumpAndSettle();
      expect(find.byKey(card), findsOneWidget);
      expect(find.text('QQ 12345'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(card), matching: find.text('Off')),
        findsOneWidget,
      );
      expect(find.text('fixture-onebot-token'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('channel-edit-onebot11')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('onebot-self-id')), findsOneWidget);
    },
  );

  testWidgets('the official QQ page asks for AppID and a secret', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, OfficialQqScreen(controller: controller));

    expect(find.byKey(const ValueKey('qq-official-app-id')), findsOneWidget);
    expect(find.byKey(const ValueKey('qq-official-secret')), findsOneWidget);
    expect(find.byKey(const ValueKey('qq-official-enabled')), findsOneWidget);

    // The capability table sits below the form, so it is only built once the
    // list scrolls to it. It must still state what the platform will refuse.
    await tester.scrollUntilVisible(
      find.textContaining('Platform limits'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('unsupported'), findsWidgets);
  });

  testWidgets('the OneBot page asks for the address, token and account', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, OneBot11Screen(controller: controller));

    expect(find.byKey(const ValueKey('onebot-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('onebot-token')), findsOneWidget);
    expect(find.byKey(const ValueKey('onebot-self-id')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.textContaining('third-party QQ connection'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('third-party QQ connection'), findsOneWidget);
  });

  testWidgets('saving an invalid AppID reports the field, not a crash', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, OfficialQqScreen(controller: controller));

    await tester.enterText(
      find.byKey(const ValueKey('qq-official-app-id')),
      'abc',
    );
    await tester.tap(find.byKey(const ValueKey('qq-official-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('AppID'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the OneBot page opens a SnowLuma guide and still offers NapCat',
    (tester) async {
      final controller = await _controller();
      addTearDown(controller.dispose);
      await _pump(tester, OneBot11Screen(controller: controller));

      expect(find.text('NapCat'), findsOneWidget);
      expect(find.text('SnowLuma'), findsOneWidget);
      expect(
        tester
            .widget<KitSegmented<OneBotBackend>>(
              find.byKey(const ValueKey('onebot-backend')),
            )
            .selected,
        OneBotBackend.snowLuma,
      );
      await tester.tap(find.byKey(const ValueKey('onebot-snowluma-guide')));
      await tester.pumpAndSettle();
      expect(find.text('Set up SnowLuma'), findsOneWidget);
      expect(find.textContaining('Universal role'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('NapCat'));
      await tester.pumpAndSettle();

      expect(find.textContaining('6099'), findsOneWidget);
      expect(find.byKey(const ValueKey('onebot-snowluma-guide')), findsNothing);
    },
  );

  testWidgets('choosing the reverse direction swaps the address for a port', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, OneBot11Screen(controller: controller));

    expect(find.byKey(const ValueKey('onebot-url')), findsOneWidget);

    await tester.tap(find.text('Bot connects in'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('onebot-listen-port')), findsOneWidget);
    expect(find.byKey(const ValueKey('onebot-url')), findsNothing);
    // A listener without a token is refused, and the page says so.
    expect(find.textContaining('token'), findsWidgets);
  });

  testWidgets('the hub offers the manager agent', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, ChannelsScreen(controller: controller));

    expect(find.text('Manager agent'), findsOneWidget);

    await tester.tap(find.text('Manager agent'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manager-enabled')), findsOneWidget);
    expect(find.byKey(const ValueKey('manager-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('manager-model')), findsOneWidget);
    expect(find.byKey(const ValueKey('manager-key')), findsOneWidget);
  });

  testWidgets('enabling the manager without a model is refused, not saved', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _pump(tester, ManagerAgentScreen(controller: controller));

    await tester.tap(find.byKey(const ValueKey('manager-enabled')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('manager-save')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('manager-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('启用管理代理前需要填写地址和模型名'), findsOneWidget);
  });
}
