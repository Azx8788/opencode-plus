import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/domain/settings_scope.dart';
import 'package:opencode_mobile/domain/subagent_settings.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/state/subagent_settings_controller.dart';
import 'package:opencode_mobile/state/subagent_settings_store.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/screens/settings_screen.dart';
import 'package:opencode_mobile/ui/screens/settings/subagent_settings_screen.dart';
import 'package:opencode_mobile/ui/screens/settings/subagent_model_pool_screen.dart';

import 'fixtures/subagent_settings_fixture.dart';

class _Profiles extends ProfileStore {
  _Profiles(SharedPreferences prefs) : super(prefs: prefs);
  @override
  List<ServerProfile> get profiles => [
    ServerProfile.fromJson(subagentProfile('one')),
    ServerProfile.fromJson(subagentProfile('two')),
  ];
  @override
  String? get activeId => 'one';
}

void main() {
  late SharedPreferences prefs;
  late SubagentSettingsStore store;
  late SubagentSettingsController controller;
  final server = subagentServer('one');
  final high = subagentCandidate('a', variant: 'high');

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'oc.profiles': jsonEncode([
        subagentProfile('one'),
        subagentProfile('two'),
      ]),
    });
    prefs = await SharedPreferences.getInstance();
    store = SubagentSettingsStore.shared(prefs);
    controller = SubagentSettingsController(
      store: store,
      loadCatalog: (_) async => subagentCatalog(),
    );
    controller.updateServers([server, subagentServer('two')]);
    await controller.refresh();
  });
  tearDown(() => controller.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    double width = 460,
    double height = 1100,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: SubagentSettingsPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(WidgetTester tester, String key) async {
    final row = find.byKey(ValueKey(key));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  Future<void> openPool(WidgetTester tester) async {
    await tapRow(tester, 'subagents-pool');
    expect(find.byType(SubagentModelPoolScreen), findsOneWidget);
  }

  testWidgets(
    'settings hub has an independent subagents entry even before a server is saved',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final fresh = await SharedPreferences.getInstance();
      final connection = ConnectionController(
        ProfileStore(prefs: fresh),
        isIsolated: true,
        backgroundLive: BackgroundLiveController(
          preferences: fresh,
          invoke: (method, [arguments]) async => const {},
        ),
      );
      addTearDown(connection.dispose);
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(controller: connection)),
      );
      await tester.pumpAndSettle();
      await tapRow(tester, 'settings-hub-row-ai');
      await tapRow(tester, 'settings-subagents');
      expect(find.byType(SubagentSettingsScreen), findsOneWidget);
      expect(find.text('No saved OpenCode V2 server'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subagents-draft-status')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'model pool is manually selected and save is labelled local, not active',
    (tester) async {
      await mount(tester);
      expect(
        find.text('Local draft — not applied to the engine'),
        findsOneWidget,
      );
      await openPool(tester);
      await tapRow(tester, 'subagents-candidate-${high.key}');
      await tapRow(tester, 'subagents-pool-save');
      expect(find.byType(SubagentModelPoolScreen), findsNothing);
      expect(
        store
            .read(
              const SettingsTarget.connection('one'),
              binding: server.binding,
            )
            .pool
            .candidates,
        [high],
      );
      expect(
        find.byKey(const ValueKey('subagents-local-receipt')),
        findsOneWidget,
      );
      expect(
        find.text('Saved locally; not applied to the engine'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'browsing another saved server never connects it or switches the active profile',
    (tester) async {
      final connection = ConnectionController(
        _Profiles(prefs),
        isIsolated: true,
        backgroundLive: BackgroundLiveController(
          preferences: prefs,
          invoke: (method, [arguments]) async => const {},
        ),
      );
      addTearDown(connection.dispose);
      await tester.pumpWidget(
        MaterialApp(home: SubagentSettingsScreen(controller: connection)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subagents-catalogue-unavailable')),
        findsOneWidget,
      );
      await tapRow(tester, 'subagents-server');
      await tapRow(tester, 'subagents-server-two');
      expect(connection.api, isNull);
      expect(connection.profile!.id, 'one');
      expect(find.text('Server two'), findsOneWidget);
      expect(prefs.containsKey(SubagentSettingsStore.keyFor('two')), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'search filters rows without forgetting selected exact variants',
    (tester) async {
      await mount(tester);
      await openPool(tester);
      await tapRow(tester, 'subagents-candidate-${high.key}');
      await tester.enterText(
        find.byKey(const ValueKey('subagents-pool-search')),
        'does not exist',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching models'), findsOneWidget);
      await tapRow(tester, 'subagents-pool-save');
      expect(controller.snapshot!.pool.candidates, [high]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'catalogue errors do not claim the server is disconnected and refresh recovers',
    (tester) async {
      var readFailed = true;
      controller.dispose();
      controller = SubagentSettingsController(
        store: store,
        loadCatalog: (_) async {
          if (readFailed) {
            throw const FormatException('Invalid project catalogue');
          }
          return subagentCatalog();
        },
      );
      controller.updateServers([server]);
      await controller.refresh();
      await mount(tester, locale: const Locale('zh'), width: 320, scale: 1.5);
      expect(find.textContaining('模型与项目目录读取失败'), findsOneWidget);
      expect(find.textContaining('请先连接这台'), findsNothing);
      expect(tester.takeException(), isNull);
      readFailed = false;
      await tapRow(tester, 'subagents-refresh');
      expect(
        find.byKey(const ValueKey('subagents-catalogue-unavailable')),
        findsNothing,
      );
      expect(controller.catalog, isNotNull);
      await openPool(tester);
      expect(
        find.byKey(ValueKey('subagents-candidate-${high.key}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a project can save an explicit empty pool then restore inheritance',
    (tester) async {
      await store.save(
        store.beginEdit(
          const SettingsTarget.connection('one'),
          binding: server.binding,
        ),
        SubagentModelPool([high]),
      );
      await controller.refresh();
      await mount(tester);
      await tapRow(tester, 'subagents-scope');
      await tapRow(tester, 'subagents-scope-project-one');
      expect(controller.snapshot!.inherited, isTrue);
      await openPool(tester);
      await tapRow(tester, 'subagents-candidate-${high.key}');
      await tapRow(tester, 'subagents-pool-save');
      expect(controller.snapshot!.inherited, isFalse);
      expect(controller.snapshot!.pool.candidates, isEmpty);
      await tapRow(tester, 'subagents-inheritance');
      await tester.tap(find.text('Follow server defaults').last);
      await tester.pumpAndSettle();
      expect(controller.snapshot!.inherited, isTrue);
      expect(controller.snapshot!.pool.candidates, [high]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'server changes invalidate an editor instead of saving to a new server',
    (tester) async {
      await mount(tester);
      await openPool(tester);
      controller.selectServer('two');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subagents-editor-stale')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<KitButton>(
              find.byKey(const ValueKey('subagents-pool-save')),
            )
            .onPressed,
        isNull,
      );
      expect(prefs.containsKey(SubagentSettingsStore.keyFor('two')), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'back asks before discarding changed choices and never saves them',
    (tester) async {
      await mount(tester);
      await openPool(tester);
      await tapRow(tester, 'subagents-candidate-${high.key}');
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      await navigator.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Discard this edit?'), findsOneWidget);
      await tester.tap(find.text('Discard unsaved choices'));
      await tester.pumpAndSettle();
      expect(controller.snapshot!.pool.candidates, isEmpty);
      expect(prefs.containsKey(SubagentSettingsStore.keyFor('one')), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'narrow Chinese large-text layout exposes the draft warning without overflow',
    (tester) async {
      await mount(tester, locale: const Locale('zh'), width: 320, scale: 2);
      expect(find.text('本机草稿，尚未作用于引擎'), findsOneWidget);
      await tapRow(tester, 'subagents-pool');
      expect(find.text('保存本机草稿'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'short large-text editor can scroll its stale notice without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SubagentModelPoolScreen(
            controller: controller,
            edit: controller.beginPoolEdit(),
          ),
        ),
      );
      controller.selectServer('two');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subagents-editor-stale')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
