import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/builtin/builtin_linux.dart';
import 'package:opencode_mobile/builtin/provider_key_ring_store.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/custom_provider_record.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/screens/custom_provider_screen.dart';
import 'package:opencode_mobile/ui/screens/custom_providers_screen.dart';

class _Profiles extends ProfileStore {
  _Profiles(SharedPreferences prefs) : super(prefs: prefs);

  final phone = ServerProfile(id: 'phone', name: 'Phone', baseUrl: 'http://127.0.0.1:4097');
  @override
  List<ServerProfile> get profiles => [phone];
  @override
  String? get activeId => phone.id;
}

class _Linux extends BuiltinLinux {
  final files = <String, String>{};
  final writes = <String>[];

  _Linux() {
    files['.oc-opencode2/config/opencode/opencode.json'] = jsonEncode({
      'providers': {
        'gateway': {
          'name': 'Gateway',
          'package': 'aisdk:@ai-sdk/openai-compatible',
          'settings': {'baseURL': 'https://fixture.test/v1', 'apiKey': '{file:/root/.secrets/opencode-plus/gateway/work.key}'},
          'models': {'opaque-model': {'variants': [{'id': 'max', 'settings': {'reasoningEffort': 'max'}}]}},
        },
      },
    });
    files['.secrets/opencode-plus/gateway/work.key'] = 'fixture-work-key';
    files['.secrets/opencode-plus/gateway/backup.key'] = 'fixture-backup-key';
  }

  @override
  Future<BuiltinLinuxRunResult> run(String script, {Duration timeout = const Duration(minutes: 2)}) async {
    if (script.contains("printf 'KEY:'")) {
      final path = RegExp(r"f='([^']*)'").firstMatch(script)?.group(1);
      final value = path == null ? null : files[path.replaceFirst('/root/', '')];
      return BuiltinLinuxRunResult(exitCode: 0, output: value == null ? 'MISSING:' : 'KEY:${base64Encode(utf8.encode(value))}');
    }
    if (script.contains('base64')) {
      return BuiltinLinuxRunResult(exitCode: 0, output: 'JSON:${base64Encode(utf8.encode(files['.oc-opencode2/config/opencode/opencode.json']!))}');
    }
    return const BuiltinLinuxRunResult(exitCode: 0, output: 'JSON:/root/.oc-opencode2/config/opencode/opencode.json');
  }

  @override
  Future<void> writeServerFile({required String relativePath, required String content}) async {
    writes.add(relativePath);
    files[relativePath] = content;
  }

  @override
  Future<void> deleteServerProviderKey({required String relativePath}) async {
    files.remove(relativePath);
  }
}

void main() {
  late ConnectionController controller;
  late _Linux linux;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    controller = ConnectionController(
      _Profiles(prefs), isIsolated: true,
      backgroundLive: BackgroundLiveController(preferences: prefs, invoke: (method, [arguments]) async => const {}),
    );
    linux = _Linux();
    await ProviderKeyRingStore(prefs).save(
      profileID: 'phone', providerID: 'gateway', activeID: 'work', keys: const [
        ProviderKeyRecord(id: 'work', name: 'Work', filePath: '/root/.secrets/opencode-plus/gateway/work.key'),
        ProviderKeyRecord(id: 'backup', name: 'Backup', filePath: '/root/.secrets/opencode-plus/gateway/backup.key'),
      ],
    );
  });
  tearDown(() => controller.dispose());

  Future<void> openEditor(WidgetTester tester) async {
    final document = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    final record = readCustomProviders(document.cast<String, Object?>(), ProviderConfigFormat.v2).records.single;
    await tester.pumpWidget(MaterialApp(home: CustomProviderScreen(controller: controller, linux: linux, editing: record)));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(
    WidgetTester tester,
    Finder target, {
    String list = 'provider-config-list',
    double delta = 240,
  }) async {
    await tester.scrollUntilVisible(
      target,
      delta,
      scrollable: find.descendant(
        of: find.byKey(ValueKey(list)),
        matching: find.byType(Scrollable),
      ).first,
      maxScrolls: 40,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('provider actions are visible without long press; templates can hide and restore', (tester) async {
    await tester.pumpWidget(MaterialApp(home: CustomProvidersScreen(controller: controller, linux: linux)));
    await tester.pumpAndSettle();
    final actions = find.byKey(const ValueKey('provider-actions-openai'));
    await tester.ensureVisible(actions);
    await tester.tap(actions);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('provider-setup-openai')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('provider-hide-openai')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('provider-row-openai')), findsNothing);
    final restore = find.byKey(const ValueKey('providers-restore-hidden'));
    await reveal(tester, restore, list: 'custom-providers-list');
    await tester.tap(restore);
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('provider-row-openai')),
        list: 'custom-providers-list', delta: -240);
    expect(find.byKey(const ValueKey('provider-row-openai')), findsOneWidget);
  });

  testWidgets('named keys render without an unlabelled replacement field', (tester) async {
    await openEditor(tester);
    await reveal(tester, find.byKey(const ValueKey('provider-key-work')));
    expect(find.byKey(const ValueKey('provider-key-work')), findsOneWidget);
    expect(find.byKey(const ValueKey('provider-key-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('custom-provider-api-key')), findsNothing);
    expect(linux.writes, isEmpty);
    expect(find.text('fixture-work-key'), findsNothing);
  });

  testWidgets('renaming changes only metadata and survives reopening the editor', (tester) async {
    await openEditor(tester);
    final row = find.byKey(const ValueKey('provider-key-work'));
    await reveal(tester, row);
    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('provider-key-rename-work')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('provider-key-rename-field')), 'Personal');
    await tester.tap(find.byKey(const ValueKey('provider-key-rename-confirm')));
    await tester.pumpAndSettle();
    expect(linux.writes, isEmpty, reason: 'renaming must never rewrite config or secret files');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await openEditor(tester);
    await reveal(tester, find.text('Personal'));
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Backup'), findsOneWidget);
  });

  testWidgets('a plaintext legacy key is offered as a named key without writing on read', (tester) async {
    final document = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    document['providers']['gateway']['settings']['apiKey'] = 'fixture-legacy-key';
    linux.files['.oc-opencode2/config/opencode/opencode.json'] = jsonEncode(document);
    await openEditor(tester);
    await reveal(tester, find.text('Default'));
    final rows = tester.widgetList<KitRow>(find.byType(KitRow));
    expect(rows.where((row) => row.title == 'Default'), hasLength(1));
    expect(linux.writes, isEmpty);
    expect(find.text('fixture-legacy-key'), findsNothing);
  });

  testWidgets('adding a second key preserves the old plaintext key and reasoning variants', (tester) async {
    final document = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    document['providers']['gateway']['settings']['apiKey'] = 'fixture-legacy-key';
    linux.files['.oc-opencode2/config/opencode/opencode.json'] = jsonEncode(document);
    await openEditor(tester);
    final add = find.byKey(const ValueKey('provider-key-add'));
    await reveal(tester, add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('provider-key-name-field')), 'Personal');
    await tester.tap(find.byKey(const ValueKey('provider-key-name-confirm')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('provider-key-secret-field')), 'fixture-new-personal-key');
    await tester.tap(find.byKey(const ValueKey('provider-key-secret-confirm')));
    await tester.pumpAndSettle();
    final saved = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    final settings = saved['providers']['gateway']['settings'] as Map;
    final currentPath = (settings['apiKey'] as String).replaceFirst('{file:/root/', '').replaceFirst('}', '');
    expect(linux.files[currentPath], 'fixture-new-personal-key');
    expect(linux.files.entries.where((entry) => entry.key.endsWith('.key') && entry.value == 'fixture-legacy-key'), hasLength(1));
    expect(saved['providers']['gateway']['models'], document['providers']['gateway']['models']);
    final names = await ProviderKeyRingStore(prefs).load(
      profileID: 'phone', providerID: 'gateway', currentPath: '/root/$currentPath',
    );
    expect(names.keys.map((key) => key.name), containsAll(['Default', 'Personal']));
    final legacy = names.keys.firstWhere((key) => key.name == 'Default');
    final legacyRow = find.byKey(ValueKey('provider-key-${legacy.id}'));
    await reveal(tester, legacyRow, delta: -240);
    await tester.tap(legacyRow);
    await tester.pumpAndSettle();
    final switched = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    expect(switched['providers']['gateway']['settings']['apiKey'], '{file:${legacy.filePath}}');
    final allPrefs = prefs.getKeys().map((key) => prefs.get(key).toString()).join();
    expect(allPrefs, isNot(contains('fixture-legacy-key')));
    expect(allPrefs, isNot(contains('fixture-new-personal-key')));
  });
}
