import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/background/live_background.dart';
import 'package:opencode_mobile/builtin/builtin_linux.dart';
import 'package:opencode_mobile/builtin/provider_key_ring_store.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';
import 'package:opencode_mobile/domain/custom_provider_record.dart';
import 'package:opencode_mobile/domain/models.dart' show ModelRef;
import 'package:opencode_mobile/domain/server_gateway/value_types_core.dart';
import 'package:opencode_mobile/state/connection.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/screens/custom_provider_screen.dart';
import 'package:opencode_mobile/ui/screens/custom_providers_screen.dart';
import 'package:opencode_mobile/ui/screens/provider_models_screen.dart';
import 'package:opencode_mobile/ui/widgets/pickers.dart';
import 'package:opencode_mobile/ui/widgets/provider_key_switch.dart';

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
  bool failConfigWrite = false;

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
    if (failConfigWrite && relativePath.endsWith('/opencode.json')) {
      throw const BuiltinLinuxException('Fixture config write refused');
    }
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

  void seedKeySwitchCatalog() {
    controller.catalog = const CatalogSnapshot(
      providers: [CatalogProvider(id: 'gateway', name: 'Gateway', enabled: true)],
      agents: [],
      models: [
        CatalogModel(id: 'opaque-model', providerID: 'gateway', name: 'Opaque model',
            enabled: true, status: 'active', contextLimit: 200000, outputLimit: 32000,
            reasoning: true, attachments: false, tools: true,
            variants: [CatalogVariant(id: 'max', options: {'reasoningEffort': 'max'})]),
        CatalogModel(id: 'other-model', providerID: 'gateway', name: 'Other model',
            enabled: true, status: 'active', contextLimit: 200000, outputLimit: 32000,
            reasoning: true, attachments: false, tools: true, variants: []),
      ],
    );
    controller.selectedModel = ModelRef(providerID: 'gateway', modelID: 'opaque-model');
    controller.selectedVariant = 'max';
  }

  Future<void> mountKeyButton(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(
        key: const Key('open-key-switch'),
        onPressed: () => showProviderKeySwitch(context,
            controller: controller, providerID: 'gateway', linux: linux),
        child: const Text('Switch key'),
      ),
    ))));
    await tester.pumpAndSettle();
  }

  Future<void> openKeyButton(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('open-key-switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('provider-key-switch-menu-gateway')), findsOneWidget);
  }

  String activeKeyReference() {
    final doc = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    return doc['providers']['gateway']['settings']['apiKey'] as String;
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

  testWidgets('long press a model to switch among three named keys without changing the model or Max', (tester) async {
    seedKeySwitchCatalog();
    final ring = ProviderKeyRingStore(prefs);
    final saved = await ring.load(profileID: 'phone', providerID: 'gateway',
        currentPath: '/root/.secrets/opencode-plus/gateway/work.key');
    await ring.save(profileID: 'phone', providerID: 'gateway', activeID: 'work', keys: [
      ...saved.keys,
      const ProviderKeyRecord(id: 'spare', name: 'Spare', filePath: '/root/.secrets/opencode-plus/gateway/spare.key'),
    ]);
    linux.files['.secrets/opencode-plus/gateway/spare.key'] = 'fixture-spare-key';
    final before = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ModelCatalogView(controller: controller, linux: linux))));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('model-option-gateway-opaque-model'));
    await tester.ensureVisible(row);
    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-key-switch-gateway-opaque-model')));
    await tester.pumpAndSettle();
    final menu = tester.widget<KitMenuPanel>(find.byType(KitMenuPanel));
    expect(menu.items.map((item) => item.label), ['Work', 'Backup', 'Spare']);
    expect(menu.items.first.checked, isTrue);
    expect(menu.items.first.group, const KitMenuGroup('Gateway · applies to all its models'));
    await tester.tap(find.byKey(const ValueKey('provider-key-choice-gateway-backup')));
    await tester.pumpAndSettle();
    expect(activeKeyReference(), '{file:/root/.secrets/opencode-plus/gateway/backup.key}');
    expect(controller.selectedModel!.wireName, 'gateway/opaque-model');
    expect(controller.selectedVariant, 'max');
    final after = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    expect(after['providers']['gateway']['models'], before['providers']['gateway']['models']);
    final other = find.byKey(const ValueKey('model-option-gateway-other-model'));
    await tester.ensureVisible(other);
    await tester.longPress(other);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-key-switch-gateway-other-model')));
    await tester.pumpAndSettle();
    final reopened = tester.widget<KitMenuPanel>(find.byType(KitMenuPanel));
    expect(reopened.items.singleWhere((item) => item.label == 'Backup').checked, isTrue);
    await tester.tap(find.byKey(const ValueKey('provider-key-choice-gateway-spare')));
    await tester.pumpAndSettle();
    expect(activeKeyReference(), '{file:/root/.secrets/opencode-plus/gateway/spare.key}');
    expect(controller.selectedVariant, 'max');
  });

  testWidgets('key shortcut is also on the provider model list', (tester) async {
    seedKeySwitchCatalog();
    await tester.pumpWidget(MaterialApp(home: ProviderModelsScreen(controller: controller, linux: linux)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const PageStorageKey('provider-section-gateway')));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('provider-model-gateway-opaque-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-key-switch-gateway-opaque-model')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('provider-key-choice-gateway-backup')), findsOneWidget);
    expect(linux.writes, isEmpty, reason: 'opening the key menu never writes');
    await tester.tap(find.byKey(const ValueKey('provider-key-choice-gateway-work')));
    await tester.pumpAndSettle();
    expect(linux.writes, isEmpty, reason: 'selecting the current key is a no-op');
  });

  testWidgets('missing key and failed config write do not change the saved key', (tester) async {
    await mountKeyButton(tester);
    linux.files.remove('.secrets/opencode-plus/gateway/backup.key');
    await openKeyButton(tester);
    await tester.tap(find.byKey(const ValueKey('provider-key-choice-gateway-backup')));
    await tester.pumpAndSettle();
    expect(linux.writes, isEmpty);
    expect(activeKeyReference(), '{file:/root/.secrets/opencode-plus/gateway/work.key}');
    linux.files['.secrets/opencode-plus/gateway/backup.key'] = 'fixture-backup-key';
    linux.failConfigWrite = true;
    await openKeyButton(tester);
    await tester.tap(find.byKey(const ValueKey('provider-key-choice-gateway-backup')));
    await tester.pumpAndSettle();
    expect(activeKeyReference(), '{file:/root/.secrets/opencode-plus/gateway/work.key}');
    linux.failConfigWrite = false;
    await openKeyButton(tester);
    final menu = tester.widget<KitMenuPanel>(find.byType(KitMenuPanel));
    expect(menu.items.singleWhere((item) => item.label == 'Work').checked, isTrue);
    await tester.tap(find.byKey(const ValueKey('provider-key-choice-gateway-work')));
    await tester.pumpAndSettle();
  });

  testWidgets('model shortcut keeps a plaintext legacy key available for switching back', (tester) async {
    final doc = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    doc['providers']['gateway']['settings']['apiKey'] = 'fixture-legacy-key';
    linux.files['.oc-opencode2/config/opencode/opencode.json'] = jsonEncode(doc);
    await mountKeyButton(tester);
    await openKeyButton(tester);
    expect(linux.writes, isEmpty);
    await tester.tap(find.byKey(const ValueKey('provider-key-choice-gateway-backup')));
    await tester.pumpAndSettle();
    expect(activeKeyReference(), '{file:/root/.secrets/opencode-plus/gateway/backup.key}');
    final saved = await ProviderKeyRingStore(prefs).load(profileID: 'phone', providerID: 'gateway',
        currentPath: '/root/.secrets/opencode-plus/gateway/backup.key');
    final legacy = saved.keys.singleWhere((key) => key.name == 'Default');
    expect(linux.files[legacy.filePath.replaceFirst('/root/', '')], 'fixture-legacy-key');
    await openKeyButton(tester);
    await tester.tap(find.byKey(ValueKey('provider-key-choice-gateway-${legacy.id}')));
    await tester.pumpAndSettle();
    expect(activeKeyReference(), '{file:${legacy.filePath}}');
  });

  testWidgets('the key menu refuses to overwrite a choice changed while open', (tester) async {
    await mountKeyButton(tester);
    await openKeyButton(tester);
    final doc = jsonDecode(linux.files['.oc-opencode2/config/opencode/opencode.json']!) as Map;
    doc['providers']['gateway']['settings']['apiKey'] = '{file:/root/some-other.key}';
    linux.files['.oc-opencode2/config/opencode/opencode.json'] = jsonEncode(doc);
    await tester.tap(find.byKey(const ValueKey('provider-key-choice-gateway-backup')));
    await tester.pumpAndSettle();
    expect(linux.writes, isEmpty);
    expect(activeKeyReference(), '{file:/root/some-other.key}');
  });

  testWidgets('the model shortcut does not overwrite key names changed while open', (tester) async {
    await mountKeyButton(tester);
    await openKeyButton(tester);
    final ring = ProviderKeyRingStore(prefs);
    final saved = await ring.load(profileID: 'phone', providerID: 'gateway',
        currentPath: '/root/.secrets/opencode-plus/gateway/work.key');
    await ring.save(profileID: 'phone', providerID: 'gateway', activeID: 'work', keys: [
      for (final key in saved.keys)
        ProviderKeyRecord(id: key.id, name: key.id == 'backup' ? 'Renamed backup' : key.name,
            filePath: key.filePath),
    ]);
    await tester.tap(find.byKey(const ValueKey('provider-key-choice-gateway-backup')));
    await tester.pumpAndSettle();
    expect(linux.writes, isEmpty);
    expect(activeKeyReference(), '{file:/root/.secrets/opencode-plus/gateway/work.key}');
    final latest = await ring.load(profileID: 'phone', providerID: 'gateway',
        currentPath: '/root/.secrets/opencode-plus/gateway/work.key');
    expect(latest.keys.singleWhere((key) => key.id == 'backup').name, 'Renamed backup');
  });
}
