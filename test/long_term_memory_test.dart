import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opencode_mobile/domain/long_term_memory.dart';
import 'package:opencode_mobile/domain/models.dart';
import 'package:opencode_mobile/state/long_term_memory.dart';

import 'fixtures/memory_secure.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late MemoryTestSecure secure;
  late LongTermMemoryStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    secure = MemoryTestSecure();
    store = LongTermMemoryStore(preferences: prefs, secure: secure);
  });
  tearDown(() => store.dispose());
  Matcher failure(MemoryFailure value) =>
      isA<MemoryException>().having((e) => e.failure, 'failure', value);

  test('manual memory persists only in secure storage, survives reopen and supports edit/delete', () async {
    await store.save(text: '回答请用中文');
    expect(prefs.getKeys(), {LongTermMemoryStore.presenceKey});
    expect(prefs.getBool(LongTermMemoryStore.presenceKey), isTrue);
    final reopened = LongTermMemoryStore(preferences: prefs, secure: secure);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.snapshot.entries.single.text, '回答请用中文');
    await reopened.save(
      text: '先给结论',
      previous: reopened.snapshot.entries.single,
    );
    expect(reopened.snapshot.entries.single.text, '先给结论');
    await reopened.remove(reopened.snapshot.entries.single);
    expect(reopened.snapshot.context(null), isNull);
    expect(secure.values.values.join(), isNot(contains('先给结论')));
  });

  test(
    'global, server, project and disabled scopes are strictly separated',
    () async {
      final a = MemoryProject(
        key: memoryProjectKey('a', 'http://localhost:4097', 'p'),
        label: 'A',
      );
      final b = MemoryProject(
        key: memoryProjectKey('b', 'http://localhost:4097', 'p'),
        label: 'B',
      );
      await store.save(text: 'Global fact');
      await store.save(text: 'Project A', project: a);
      await store.save(text: 'Project B', project: b);
      await store.save(text: 'Disabled fact', enabled: false);
      expect(store.snapshot.context(a.key), contains('Project A'));
      expect(store.snapshot.context(a.key), isNot(contains('Project B')));
      expect(store.snapshot.context(null), contains('Global fact'));
      expect(store.snapshot.context(null), isNot(contains('Disabled fact')));
      await store.setEnabled(false);
      expect(store.snapshot.context(a.key), isNull);
      expect(store.snapshot.entries.length, 4);
    },
  );

  test(
    'all writes serialize; failed writes never change the visible snapshot',
    () async {
      secure.holdWrite = Completer<void>();
      final first = store.save(text: 'One');
      final second = store.save(text: 'Two');
      await Future<void>.delayed(Duration.zero);
      expect(store.snapshot.entries, isEmpty);
      secure.holdWrite!.complete();
      await Future.wait([first, second]);
      expect(store.snapshot.entries.length, 2);
      secure.failWrite = true;
      await expectLater(store.clear(), throwsA(failure(MemoryFailure.storage)));
      expect(store.snapshot.entries.length, 2);
      secure.failWrite = false;
      await store.save(text: 'Three');
      expect(store.snapshot.entries.length, 3);
    },
  );

  test('duplicates, changed editors and full context fail without replacing records', () async {
    await store.save(text: 'Use Chinese');
    final previous = store.snapshot.entries.single;
    await expectLater(
      store.save(text: ' use   chinese '),
      throwsA(failure(MemoryFailure.duplicate)),
    );
    await store.save(text: 'Use English', previous: previous);
    await expectLater(
      store.save(text: 'Stale editor', previous: previous),
      throwsA(failure(MemoryFailure.changed)),
    );
    await expectLater(
      store.save(text: 'a' * 1025),
      throwsA(failure(MemoryFailure.invalid)),
    );
      for (var i = 0; i < 6; i++) {
      await store.save(text: '$i${'x' * 1000}');
    }
    final before = store.snapshot.entries.length;
    await expectLater(
      store.save(text: 'full${'y' * 1000}'),
      throwsA(failure(MemoryFailure.limit)),
    );
    expect(store.snapshot.entries.length, before);
  });

  test(
    'unreadable secure data is not treated as empty; explicit clear recovers',
    () async {
      await prefs.setBool(LongTermMemoryStore.presenceKey, true);
      secure.values[LongTermMemoryStore.storageKey] = '{broken';
      await expectLater(store.load(), throwsA(failure(MemoryFailure.invalid)));
      await expectLater(
        store.save(text: 'Must not overwrite'),
        throwsA(failure(MemoryFailure.invalid)),
      );
      expect(secure.values[LongTermMemoryStore.storageKey], '{broken');
      await store.clear();
      expect(store.loaded, isTrue);
      expect(store.snapshot.entries, isEmpty);
    },
  );

  test(
    'memory tool input is strict and bounded; parsing never writes',
    () async {
      final request = MemoryWriteRequest.fromJson({
        'memories': ['中文回答', '中文回答', '项目用 Flutter'],
        'scope': 'global',
      });
      expect(request.memories.length, 2);
      expect(secure.writes, 0);
      await store.saveCandidates(
        request.memories,
        sourceSessionID: 's1',
        sourceCallID: 'call1',
      );
      expect(
        store.snapshot.entries.every(
          (e) => e.extracted && e.sourceSessionID == 's1',
        ),
        isTrue,
      );
      for (final raw in [
        null,
        'not an object',
        {
          'memories': [3],
          'scope': 'global',
        },
        {
          'memories': [''],
          'scope': 'project',
        },
        {
          'memories': ['a'],
          'scope': 'another-project',
        },
        {
          'memories': ['a'],
          'scope': 'global',
          'extra': true,
        },
        {'memories': [], 'scope': 'global'},
        {
          'memories': ['中' * 342],
          'scope': 'global',
        },
        {'memories': List.filled(9, 'a'), 'scope': 'global'},
      ]) {
        expect(
          () => MemoryWriteRequest.fromJson(raw),
          throwsA(failure(MemoryFailure.invalid)),
        );
      }
    },
  );

  test('only accepted completed memory tool calls offer review, across MCP adapters', () {
    Part part({
      String name = 'oc-ui_memory_write',
      String status = 'completed',
      String output = memoryWriteReceipt,
      bool executed = true,
      bool synthetic = false,
      String type = 'tool',
    }) => Part(
      type: type,
      toolName: name,
      callID: 'call1',
      synthetic: synthetic,
      toolState: ToolState(
        status: status,
        executed: executed,
        output: output,
        input: {
          'memories': ['中文回答'],
          'scope': 'global',
        },
      ),
    );
    for (final name in ['oc-ui_memory_write', 'mcp__oc-ui__memory_write']) {
      expect(MemoryWriteRequest.fromPart(part(name: name))!.memories, ['中文回答']);
    }
    for (final invalid in [
      part(status: 'running'),
      part(status: 'error'),
      part(executed: false),
      part(synthetic: true),
      part(type: 'text'),
      part(name: 'other_memory_write'),
      part(output: 'Invalid memory proposal'),
    ]) {
      expect(MemoryWriteRequest.fromPart(invalid), isNull);
    }
    expect(secure.writes, 0);
  });

  test('confirmed proposals persist a receipt and cannot be saved twice concurrently', () async {
    final outcomes = await Future.wait([
      store
          .saveCandidates(
            ['First'],
            sourceSessionID: 's1',
            sourceCallID: 'call1',
          )
          .then<Object?>((_) => null, onError: (Object error) => error),
      store
          .saveCandidates(
            ['Second'],
            sourceSessionID: 's1',
            sourceCallID: 'call1',
          )
          .then<Object?>((_) => null, onError: (Object error) => error),
    ]);
    expect(outcomes.whereType<MemoryException>().length, 1);
    expect(store.snapshot.entries.single.text, 'First');
    final reopened = LongTermMemoryStore(preferences: prefs, secure: secure);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.snapshot.entries.single.sourceCallID, 'call1');
    await reopened.save(
      text: 'Edited after review',
      previous: reopened.snapshot.entries.single,
    );
    expect(reopened.snapshot.entries.single.sourceCallID, 'call1');
    final key = memoryProposalKey(
      'phone',
      'http://127.0.0.1:4097',
      's1',
      'call1',
    );
    expect(
      key,
      isNot(
        memoryProposalKey('remote', 'http://127.0.0.1:4097', 's1', 'call1'),
      ),
    );
    expect(
      key,
      isNot(memoryProposalKey('phone', 'http://different', 's1', 'call1')),
    );
  });

  test('failed or stale confirmed writes stay atomic and retryable', () async {
    await store.save(text: 'Existing');
    secure.failWrite = true;
    await expectLater(
      store.saveCandidates(['New'], sourceSessionID: 's', sourceCallID: 'c'),
      throwsA(failure(MemoryFailure.storage)),
    );
    expect(store.snapshot.entries.length, 1);
    secure.failWrite = false;
    await expectLater(
      store.saveCandidates(
        ['New'],
        sourceSessionID: 's',
        sourceCallID: 'c',
        isCurrent: () => false,
      ),
      throwsA(failure(MemoryFailure.changed)),
    );
    expect(store.snapshot.entries.length, 1);
    await store.saveCandidates(
      ['New'],
      sourceSessionID: 's',
      sourceCallID: 'c',
    );
    expect(store.snapshot.entries.length, 2);
  });

  test(
    'a managed but missing encrypted vault is not an empty memory library',
    () async {
      await prefs.setBool(LongTermMemoryStore.presenceKey, true);
      await expectLater(store.load(), throwsA(failure(MemoryFailure.storage)));
      await expectLater(
        store.save(text: 'Do not overwrite'),
        throwsA(failure(MemoryFailure.storage)),
      );
      expect(secure.writes, 0);
    },
  );
}
