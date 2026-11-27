import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:opencode_mobile/domain/settings_scope.dart';
import 'package:opencode_mobile/domain/subagent_settings.dart';
import 'package:opencode_mobile/state/profiles.dart';
import 'package:opencode_mobile/state/subagent_settings_controller.dart';
import 'package:opencode_mobile/state/subagent_settings_store.dart';

import 'fixtures/subagent_settings_fixture.dart';

Matcher fails(SubagentSettingsFailure reason) => throwsA(
  isA<SubagentSettingsException>().having((e) => e.reason, 'reason', reason),
);

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences(super.data) : super.withData();
  bool refuseWrites = false;
  bool refuseReads = false;
  Completer<void>? writeStarted;
  Completer<void>? writeGate;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writeStarted?.complete();
    await writeGate?.future;
    if (refuseWrites) return false;
    return super.setValue(valueType, key, value);
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    if (refuseReads) throw StateError('Fixture read refused');
    return super.getAllWithParameters(parameters);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late SubagentSettingsStore store;
  late _Preferences platform;
  final server = subagentServer('one');
  final second = subagentServer('two');
  const global = SettingsTarget.connection('one');
  const project = SettingsTarget.project('one', 'project-one');
  final a = subagentCandidate('a');
  final b = subagentCandidate('b', variant: 'high');
  SubagentModelPool pool(List<SubagentModelCandidate> values) =>
      SubagentModelPool(values);
  SubagentSettingsSnapshot read([SettingsTarget target = global]) =>
      store.read(target, binding: server.binding);
  Future<SubagentSettingsSnapshot> save(
    SubagentModelPool? value, [
    SettingsTarget target = global,
  ]) => store.save(store.beginEdit(target, binding: server.binding), value);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    platform = _Preferences({
      'flutter.oc.profiles': jsonEncode([
        subagentProfile('one'),
        subagentProfile('two'),
      ]),
    });
    SharedPreferencesStorePlatform.instance = platform;
    prefs = await SharedPreferences.getInstance();
    store = SubagentSettingsStore.shared(prefs);
  });

  test(
    'candidate identity is exact, supports slash IDs and default is not a wildcard',
    () {
      expect(a, subagentCandidate('a'));
      expect(a, isNot(subagentCandidate('a', variant: 'high')));
      final opaque = subagentCandidate('vendor/model', variant: 'high');
      expect(SubagentModelCandidate.fromJson(opaque.toJson()), opaque);
      expect(
        opaque.key,
        isNot(
          subagentCandidate(
            'model',
            provider: 'gateway/vendor',
            variant: 'high',
          ).key,
        ),
      );
      expect(pool([]).contains(a), isFalse);
      expect(() => pool([a, a]), throwsFormatException);
      expect(
        () => SubagentModelCandidate.fromJson({
          'providerID': 'x',
          'modelID': 'a',
          'variant': null,
        }),
        throwsFormatException,
      );
      expect(() => subagentCandidate('a\n'), throwsFormatException);
    },
  );

  test(
    'catalogue includes old/default/exact variants, but not disabled choices',
    () {
      final catalog = SubagentSettingsCatalog(
        models: [
          subagentCatalogModel('old'),
          subagentCatalogModel('off', enabled: false),
        ],
        projects: [],
      );
      expect(catalog.candidates.keys.toSet(), {
        subagentCandidate('old'),
        subagentCandidate('old', variant: 'high'),
      });
    },
  );

  test('unset drafts are empty and opening them writes nothing', () {
    expect(read().pool.candidates, isEmpty);
    expect(read().stored, isFalse);
    expect(read(project).inherited, isTrue);
    expect(prefs.containsKey(SubagentSettingsStore.keyFor('one')), isFalse);
  });

  test('pool, exact variants and revisions survive platform reload', () async {
    final value = await save(pool([a, b]));
    expect(value.revision, 1);
    await prefs.reload();
    expect(read().pool.candidates, [a, b]);
    final raw = prefs.getString(SubagentSettingsStore.keyFor('one'))!;
    expect(raw, isNot(contains('applied')));
    expect(raw, isNot(contains('password')));
  });

  test(
    'projects dynamically inherit; explicit empty is not inheritance',
    () async {
      await save(pool([a]));
      expect(read(project).pool.candidates, [a]);
      await save(pool([]), project);
      expect(read(project).inherited, isFalse);
      await save(pool([b]));
      expect(read(project).pool.candidates, isEmpty);
      await save(null, project);
      expect(read(project).inherited, isTrue);
      expect(read(project).pool.candidates, [b]);
      await save(pool([a]));
      expect(read(project).pool.candidates, [a]);
      expect(store.projectIDs('one', binding: server.binding), isEmpty);
    },
  );

  test(
    'server and stable project IDs do not mix even with matching names',
    () async {
      await save(pool([a]), project);
      await save(pool([b]), const SettingsTarget.project('one', 'project-two'));
      expect(read(project).pool.candidates, [a]);
      expect(
        read(
          const SettingsTarget.project('one', 'project-two'),
        ).pool.candidates,
        [b],
      );
      expect(
        store
            .read(
              const SettingsTarget.project('two', 'project-one'),
              binding: second.binding,
            )
            .pool
            .candidates,
        isEmpty,
      );
    },
  );

  test(
    'a default change invalidates an already-open inherited editor',
    () async {
      final edit = store.beginEdit(project, binding: server.binding);
      await save(pool([a]));
      await expectLater(
        store.save(edit, pool([b])),
        fails(SubagentSettingsFailure.conflict),
      );
      expect(read(project).inherited, isTrue);
      expect(read(project).pool.candidates, [a]);
    },
  );

  test(
    'concurrent edits serialize and reject stale or replayed tokens',
    () async {
      final first = store.beginEdit(global, binding: server.binding);
      final old = store.beginEdit(global, binding: server.binding);
      final writing = store.save(first, pool([a]));
      final stale = store.save(old, pool([b]));
      final assertion = expectLater(
        stale,
        fails(SubagentSettingsFailure.conflict),
      );
      await writing;
      await assertion;
      await expectLater(
        store.save(first, pool([b])),
        fails(SubagentSettingsFailure.staleTarget),
      );
      expect(read().pool.candidates, [a]);
    },
  );

  test(
    'a platform-side edit is detected even when the local preferences cache is stale',
    () async {
      await save(pool([a]));
      final edit = store.beginEdit(global, binding: server.binding);
      final key = SubagentSettingsStore.keyFor('one');
      final changed = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
      changed['revision'] = 2;
      changed['defaults'] = pool([b]).toJson();
      await platform.setValue('String', 'flutter.$key', jsonEncode(changed));
      await expectLater(
        store.save(edit, pool([])),
        fails(SubagentSettingsFailure.conflict),
      );
      expect(read().pool.candidates, [b]);
    },
  );

  test(
    'revision exhaustion never saves a document that cannot be read again',
    () async {
      await save(pool([a]));
      final key = SubagentSettingsStore.keyFor('one');
      final changed = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
      changed['revision'] = 9007199254740990;
      await prefs.setString(key, jsonEncode(changed));
      await expectLater(
        save(pool([b])),
        fails(SubagentSettingsFailure.storageFailed),
      );
      expect(read().pool.candidates, [a]);
    },
  );

  test('unreadable or newer documents are never overwritten', () async {
    final key = SubagentSettingsStore.keyFor('one');
    for (final value in [
      '{broken',
      '{"version":2}',
      '{"version":1,"defaults":[]}',
    ]) {
      await prefs.setString(key, value);
      expect(() => read(), fails(SubagentSettingsFailure.corrupt));
      expect(prefs.getString(key), value);
    }
    await prefs.setBool(key, true);
    expect(() => read(), fails(SubagentSettingsFailure.corrupt));
  });

  test(
    'endpoint changes cannot repurpose old settings or editor tokens',
    () async {
      await save(pool([a]));
      final edit = store.beginEdit(global, binding: server.binding);
      final changed = subagentProfile(
        'one',
        url: 'https://different.example.test',
      );
      await prefs.setString('oc.profiles', jsonEncode([changed]));
      await expectLater(
        store.save(edit, pool([b])),
        fails(SubagentSettingsFailure.staleTarget),
      );
      final binding = subagentSettingsBinding(changed);
      expect(
        () => store.read(global, binding: binding),
        fails(SubagentSettingsFailure.staleTarget),
      );
    },
  );

  test(
    'refused writes never publish success or an optimistic saved pool',
    () async {
      await save(pool([a]));
      platform.refuseWrites = true;
      await expectLater(
        save(pool([b])),
        fails(SubagentSettingsFailure.storageFailed),
      );
      expect(read().pool.candidates, [a]);
    },
  );

  test(
    'failed reload blocks reads until platform truth is available',
    () async {
      final edit = store.beginEdit(global, binding: server.binding);
      platform.refuseWrites = true;
      platform.refuseReads = true;
      await expectLater(
        store.save(edit, pool([a])),
        fails(SubagentSettingsFailure.storageFailed),
      );
      expect(() => read(), fails(SubagentSettingsFailure.storageFailed));
      platform.refuseReads = false;
      await store.refresh();
      expect(read().pool.candidates, isEmpty);
    },
  );

  test(
    'profile deletion drains in-flight saves and fences retained editors',
    () async {
      final edit = store.beginEdit(global, binding: server.binding);
      platform.writeStarted = Completer<void>();
      platform.writeGate = Completer<void>();
      final writing = store.save(edit, pool([a]));
      final assertion = expectLater(
        writing,
        fails(SubagentSettingsFailure.staleTarget),
      );
      await platform.writeStarted!.future;
      final closing = SubagentSettingsStore.closeProfile(prefs, 'one');
      platform.writeGate!.complete();
      await assertion;
      await closing;
      platform.writeStarted = null;
      platform.writeGate = null;
      final profiles = ProfileStore(prefs: prefs);
      expect(
        profiles.profileScopedPreferenceKeys('one'),
        contains(SubagentSettingsStore.keyFor('one')),
      );
      await prefs.remove(SubagentSettingsStore.keyFor('one'));
      expect(
        () => store.beginEdit(global, binding: server.binding),
        fails(SubagentSettingsFailure.staleTarget),
      );
    },
  );

  test(
    'the real profile preference sweep removes drafts and closes the writer',
    () async {
      await save(pool([a]));
      await prefs.setString(
        SubagentSettingsStore.keyFor('two'),
        'untouched-other-server',
      );
      final profiles = ProfileStore(prefs: prefs);
      expect(await profiles.removeScopedPreferences('one'), isEmpty);
      expect(prefs.containsKey(SubagentSettingsStore.keyFor('one')), isFalse);
      expect(
        prefs.getString(SubagentSettingsStore.keyFor('two')),
        'untouched-other-server',
      );
      expect(
        () => store.beginEdit(global, binding: server.binding),
        fails(SubagentSettingsFailure.staleTarget),
      );
    },
  );

  test(
    'server binding ignores renaming but rejects unsupported or credential-bearing endpoints',
    () {
      expect(
        subagentSettingsBinding({...subagentProfile('one'), 'name': 'Renamed'}),
        server.binding,
      );
      expect(
        subagentSettingsBinding(
          subagentProfile('one', url: 'https://one.example.test/'),
        ),
        server.binding,
      );
      for (final profile in [
        {...subagentProfile('one'), 'backend': 'paseo'},
        {...subagentProfile('one'), 'requiresOpenCode2Migration': true},
        subagentProfile('one', url: 'https://user:secret@one.example.test'),
        subagentProfile('one', url: 'https://one.example.test?token=secret'),
      ]) {
        expect(
          () => subagentSettingsBinding(profile),
          fails(SubagentSettingsFailure.unavailable),
        );
      }
    },
  );

  group('UI controller', () {
    late SubagentSettingsController controller;
    setUp(() {
      controller = SubagentSettingsController(
        store: store,
        loadCatalog: (_) async => subagentCatalog(),
      );
      controller.updateServers([server, second]);
    });
    tearDown(() => controller.dispose());

    test(
      'local save does not change the main model or picker visibility',
      () async {
        await prefs.setString('oc.model.one', 'gateway|main-model');
        await prefs.setString('oc.modelLibrary.one', '{"disabled":[]}');
        await controller.refresh();
        expect(
          await controller.savePool(controller.beginPoolEdit(), pool([b])),
          isTrue,
        );
        expect(prefs.getString('oc.model.one'), 'gateway|main-model');
        expect(prefs.getString('oc.modelLibrary.one'), '{"disabled":[]}');
      },
    );

    test(
      'refresh never automatically adds a new model to the dedicated pool',
      () async {
        await save(pool([a]));
        await controller.refresh();
        expect(
          controller.catalog!.candidates,
          contains(subagentCandidate('b')),
        );
        expect(controller.snapshot!.pool.candidates, [a]);
      },
    );

    test(
      'typed or invented candidates cannot be added through the UI owner',
      () async {
        await controller.refresh();
        expect(
          await controller.savePool(
            controller.beginPoolEdit(),
            pool([subagentCandidate('invented')]),
          ),
          isFalse,
        );
        expect(read().pool.candidates, isEmpty);
      },
    );

    test(
      'offline edits may keep/remove saved choices, not invent new ones',
      () async {
        await save(pool([a, b]));
        controller.invalidateCatalog();
        expect(
          await controller.savePool(controller.beginPoolEdit(), pool([b])),
          isTrue,
        );
        expect(read().pool.candidates, [b]);
      },
    );

    test('switching server invalidates an open editor', () async {
      await controller.refresh();
      final edit = controller.beginPoolEdit();
      controller.selectServer('two');
      expect(controller.isEditCurrent(edit), isFalse);
      expect(await controller.savePool(edit, pool([a])), isFalse);
      expect(read().pool.candidates, isEmpty);
    });

    test('switching project invalidates an open editor', () async {
      await controller.refresh();
      final edit = controller.beginPoolEdit();
      controller.selectProject('project-one');
      expect(await controller.savePool(edit, pool([a])), isFalse);
      expect(read(project).inherited, isTrue);
    });

    test(
      'a server-default save refreshes an open project and invalidates its old editor',
      () async {
        await controller.refresh();
        controller.selectProject('project-one');
        final edit = controller.beginPoolEdit();
        await save(pool([a]));
        expect(controller.snapshot!.inherited, isTrue);
        expect(controller.snapshot!.pool.candidates, [a]);
        expect(controller.isEditCurrent(edit), isFalse);
        expect(await controller.savePool(edit, pool([b])), isFalse);
      },
    );

    test(
      'late catalogue from an old server cannot populate a new one',
      () async {
        final gate = Completer<SubagentSettingsCatalog>();
        final started = Completer<void>();
        final other = SubagentSettingsController(
          store: store,
          loadCatalog: (_) {
            started.complete();
            return gate.future;
          },
        );
        addTearDown(other.dispose);
        other.updateServers([server, second]);
        final pending = other.refresh();
        await started.future;
        other.selectServer('two');
        gate.complete(subagentCatalog());
        await pending;
        expect(other.catalog, isNull);
        expect(other.server!.profileID, 'two');
        expect(other.loading, isFalse);
      },
    );

    test(
      'failed catalogue refresh preserves missing selections and project IDs',
      () async {
        await save(pool([subagentCandidate('retired')]), project);
        final offline = SubagentSettingsController(
          store: store,
          loadCatalog: (_) async => throw StateError('offline'),
        );
        addTearDown(offline.dispose);
        offline.updateServers([server]);
        await offline.refresh();
        expect(offline.catalogUnavailable, isTrue);
        expect(offline.projects.single.id, 'project-one');
        offline.selectProject('project-one');
        expect(offline.snapshot!.pool.candidates, [
          subagentCandidate('retired'),
        ]);
      },
    );
  });
}
