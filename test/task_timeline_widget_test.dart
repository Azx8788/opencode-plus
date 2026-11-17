import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/state/task_trace.dart';
import 'package:opencode_mobile/ui/app_theme.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/kit/style/kit_style_theme.dart';
import 'package:opencode_mobile/ui/screens/chat/task_timeline_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in const {
      'AppSans': 'assets/fonts/geist/Geist-Variable.ttf',
      'AppMono': 'assets/fonts/geist/GeistMono-Variable.ttf',
      'AppPhosphorRegular': 'assets/fonts/phosphor/Phosphor.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });
  for (final dark in [false, true]) {
    testWidgets(
      'task tree expands, opens details and zooms without changing data, dark=$dark',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final controller = ConnectionController(
          ProfileStore(prefs: prefs),
          isIsolated: true,
          backgroundLive: BackgroundLiveController(
            preferences: prefs,
            invoke: (method, [args]) async => const {},
          ),
        );
        addTearDown(controller.dispose);
        final store = TaskTraceStore(prefs, 'test');
        addTearDown(store.dispose);
        await tester.runAsync(
          () => store.append([
            {
              'id': 'm',
              'type': 'task.admitted',
              'sessionID': 's',
              'inboxID': 'm',
              'task': {'id': 'root', 'intent': 'independent'},
              'at': 1000,
            },
            {
              'id': 'delivered',
              'type': 'session.inbox.delivered',
              'sessionID': 's',
              'inboxID': 'm',
              'at': 1100,
            },
            {
              'id': 'started',
              'type': 'session.execution.started',
              'sessionID': 's',
              'at': 1100,
            },
            {
              'id': 'step',
              'type': 'session.step.started',
              'sessionID': 's',
              'assistantMessageID': 'a',
              'model': {'providerID': 'provider', 'id': 'model'},
              'at': 1200,
            },
            {
              'id': 'child',
              'type': 'session.created',
              'sessionID': 'c',
              'parentID': 's',
              'at': 1300,
            },
            {
              'id': 'linked',
              'type': 'session.tool.success',
              'sessionID': 's',
              'assistantMessageID': 'a',
              'callID': 'call',
              'childSessionID': 'c',
              'at': 1400,
            },
            {
              'id': 'child-start',
              'type': 'session.execution.started',
              'sessionID': 'c',
              'at': 1500,
            },
            {
              'id': 'child-step',
              'type': 'session.step.started',
              'sessionID': 'c',
              'assistantMessageID': 'b',
              'model': {'providerID': 'provider', 'id': 'child-model'},
              'at': 1500,
            },
            {
              'id': 'child-error',
              'type': 'session.step.failed',
              'sessionID': 'c',
              'assistantMessageID': 'b',
              'error': {'type': 'provider.rate-limit', 'status': 429},
              'at': 1800,
            },
            {
              'id': 'child-failed',
              'type': 'session.execution.failed',
              'sessionID': 'c',
              'at': 1800,
            },
            {
              'id': 'root-step-end',
              'type': 'session.step.ended',
              'sessionID': 's',
              'assistantMessageID': 'a',
              'tokens': {'input': 20, 'output': 5},
              'at': 1900,
            },
            {
              'id': 'done',
              'type': 'session.execution.succeeded',
              'sessionID': 's',
              'at': 2000,
            },
          ]),
        );
        store.anchor(10000);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => kitStyleTheme(
              child: KitEffectsScope(
                effects: KitEffects.defaults.copyWith(
                  motion: KitMotionLevel.off,
                  haptics: false,
                ),
                child: child!,
              ),
            ),
            home: RepaintBoundary(
              key: const ValueKey('task-tree-capture'),
              child: TaskTimelineScreen(controller: controller, store: store),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Zoom and history controls change presentation only. Verify a real
        // tap before any sheet or screenshot changes the widget hierarchy.
        final before = store.graph.userTasks;
        expect(find.byKey(const ValueKey('task-zoom-in')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('task-zoom-in')));
        await tester.pumpAndSettle();
        expect(store.graph.userTasks, before);
        expect(find.byKey(const ValueKey('task-time-window')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('task-time-window')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('task-time-window-choices')),
          findsOneWidget,
        );
        await tester.tap(find.text('15 min'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('task-bar-root')), findsOneWidget);
        expect(find.byKey(const ValueKey('task-bar-agent:c')), findsNothing);
        await tester.ensureVisible(
          find.byKey(const ValueKey('task-expand-root')),
        );
        await tester.tap(find.byKey(const ValueKey('task-expand-root')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('task-bar-agent:c')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('task-bar-root')));
        await tester.tap(find.byKey(const ValueKey('task-bar-root')));
        await tester.pumpAndSettle();
        expect(find.text('Task details'), findsOneWidget);
        expect(find.text('Message turns'), findsOneWidget);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('task-tree-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/qa/request-timeline-task-tree-${dark ? 'dark' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
