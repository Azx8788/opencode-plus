import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/ui/app_theme.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/kit/style/kit_style_theme.dart';
import 'package:opencode_mobile/ui/screens/chat/session_elapsed_screen.dart';
import 'package:opencode_mobile/ui/screens/chat/session_request_timeline_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in const {
      'AppSans': 'assets/fonts/geist/Geist-Variable.ttf',
      'AppMono': 'assets/fonts/geist/GeistMono-Variable.ttf',
      'AppPhosphorRegular': 'assets/fonts/phosphor/Phosphor.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
    final cjk = File('build/qa-fonts/NotoSansSC.ttf');
    if (cjk.existsSync()) {
      await (FontLoader(
        'QaCjkFallback',
      )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  List<MessageWithParts> messages() => [
    MessageWithParts(
      info: MessageInfo(id: 'u1', sessionID: 's', role: 'user'),
    ),
    MessageWithParts(
      info: MessageInfo(
        id: 'a1',
        sessionID: 's',
        role: 'assistant',
        providerID: 'gateway',
        modelID: 'gpt-6-estra',
        time: MsgTime(
          created: 1000,
          firstToken: 1500,
          streamed: 3500,
          completed: 8000,
        ),
      ),
      parts: [
        Part(
          type: 'reasoning',
          text: 'thought',
          startedAt: DateTime.fromMillisecondsSinceEpoch(1500),
          completedAt: DateTime.fromMillisecondsSinceEpoch(2500),
        ),
        Part(
          type: 'tool',
          callID: 'c1',
          toolState: ToolState(
            status: 'completed',
            startedAt: DateTime.fromMillisecondsSinceEpoch(4000),
            completedAt: DateTime.fromMillisecondsSinceEpoch(7000),
          ),
        ),
      ],
    ),
  ];

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    bool dark = false,
    double width = 390,
    double scale = 1,
  }) async {
    final base = dark ? AppTheme.dark() : AppTheme.light();
    final theme = base.copyWith(
      textTheme: base.textTheme.copyWith(
        bodyLarge: base.textTheme.bodyLarge!.copyWith(
          fontFamilyFallback: const ['QaCjkFallback'],
        ),
      ),
    );
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: kitStyleTheme(
            child: KitEffectsScope(
              effects: KitEffects.defaults.copyWith(
                motion: KitMotionLevel.off,
                haptics: false,
              ),
              child: child!,
            ),
          ),
        ),
        home: RepaintBoundary(
          key: const ValueKey('stats-capture'),
          child: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final dark in [false, true]) {
    testWidgets('elapsed screen shows recorded stages, dark=$dark', (
      tester,
    ) async {
      await mount(
        tester,
        SessionElapsedScreen(messages: messages()),
        dark: dark,
      );
      expect(find.byKey(const ValueKey('elapsed-ring')), findsOneWidget);
      expect(find.byKey(const ValueKey('elapsed-turn-0')), findsOneWidget);
      expect(find.textContaining('模型等待'), findsOneWidget);
      expect(find.textContaining('工具执行'), findsOneWidget);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('stats-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/qa/elapsed-${dark ? 'dark' : 'light'}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('request timeline draws recorded lanes, dark=$dark', (
      tester,
    ) async {
      await mount(
        tester,
        SessionRequestTimelineScreen(messages: messages()),
        dark: dark,
      );
      expect(
        find.byKey(const ValueKey('request-lane-gateway/gpt-6-estra')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('request-bars-gateway/gpt-6-estra')),
        findsOneWidget,
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('stats-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/qa/request-timeline-${dark ? 'dark' : 'light'}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('both screens fit 320dp at maximum text scale', (tester) async {
    await mount(
      tester,
      SessionElapsedScreen(messages: messages()),
      width: 320,
      scale: AppTheme.maxTextScale,
    );
    expect(tester.takeException(), isNull);
    await mount(
      tester,
      SessionRequestTimelineScreen(messages: messages()),
      width: 320,
      scale: AppTheme.maxTextScale,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
