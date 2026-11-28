import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/builtin_linux.dart';
import 'package:opencode_mobile/builtin/snowluma_release.dart';
import 'package:opencode_mobile/channels/providers/snowluma_local_probe.dart';
import 'package:opencode_mobile/platform/platform_capabilities.dart';
import 'package:opencode_mobile/ui/screens/settings/snowluma_setup_screen.dart';

const _check = ValueKey('snowluma-check-local');
const _fill = ValueKey('snowluma-use-local-address');
const _verify = ValueKey('snowluma-verify-archive');

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(460, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: home));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    final previous = debugPlatformCapabilities;
    debugPlatformCapabilities = const PlatformCapabilities.android();
    addTearDown(() => debugPlatformCapabilities = previous);
  });

  testWidgets(
    'a ready WebUI without a OneBot listener cannot fill the address',
    (tester) async {
      await _pump(
        tester,
        SnowLumaSetupScreen(
          linuxStatus: () async => const BuiltinLinuxStatus.absent(),
          localProbe: () async => const SnowLumaLocalAvailability(
            consoleRecognized: true,
            oneBotPortOpen: false,
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(_check));
      await tester.tap(find.byKey(_check));
      await tester.pumpAndSettle();

      expect(find.textContaining('WebUI detected'), findsOneWidget);
      expect(find.textContaining('Port 3001 is not accepting'), findsOneWidget);
      expect(find.byKey(_fill), findsNothing);
    },
  );

  testWidgets('both local checks allow explicit handoff of the address only', (
    tester,
  ) async {
    String? returned;
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            returned = await Navigator.of(context).push<String>(
              MaterialPageRoute<String>(
                builder: (_) => SnowLumaSetupScreen(
                  linuxStatus: () async => const BuiltinLinuxStatus(
                    installed: true,
                    phase: BuiltinLinuxPhase.ready,
                    abi: 'arm64-v8a',
                  ),
                  localProbe: () async => const SnowLumaLocalAvailability(
                    consoleRecognized: true,
                    oneBotPortOpen: true,
                  ),
                ),
              ),
            );
          },
          child: const Text('Guide'),
        ),
      ),
    );
    await tester.tap(find.text('Guide'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(_check));
    await tester.tap(find.byKey(_check));
    await tester.pumpAndSettle();
    expect(returned, isNull);
    expect(
      find.textContaining('Test OneBot to verify the account'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.byKey(_fill).hitTestable(),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_fill));
    await tester.pumpAndSettle();
    expect(returned, SnowLumaLocalProbe.defaultWebSocketUrl);
  });

  testWidgets('a source archive cannot be mistaken for a verified release', (
    tester,
  ) async {
    await _pump(
      tester,
      SnowLumaSetupScreen(
        pickArchive: () async => SnowLumaArchive(
          length: () async => 5,
          read: () => throw StateError('unrecognized archive must not be read'),
        ),
      ),
    );
    await tester.tap(find.byKey(_verify));
    await tester.pumpAndSettle();

    expect(find.textContaining('does not match a supported'), findsOneWidget);
    expect(find.textContaining('matches the published SHA-256'), findsNothing);
  });
}
