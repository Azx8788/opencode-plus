import 'package:flutter/material.dart';
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
  testWidgets(
    'task tree expands, opens actual details and zooms without changing data',
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
            'id': 'done',
            'type': 'session.execution.succeeded',
            'sessionID': 's',
            'at': 2000,
          },
        ]),
      );
      store.anchor(10000);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
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
          home: TaskTimelineScreen(controller: controller, store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('task-bar-root')), findsOneWidget);
      expect(find.byKey(const ValueKey('task-bar-agent:c')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('task-expand-root')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('task-bar-agent:c')), findsOneWidget);
      final before = store.graph.userTasks;
      await tester.tap(find.text('+'));
      await tester.pumpAndSettle();
      expect(store.graph.userTasks, before);
      await tester.tap(find.byKey(const ValueKey('task-bar-root')));
      await tester.pumpAndSettle();
      expect(find.text('Task details'), findsOneWidget);
      expect(find.text('Message turns'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
