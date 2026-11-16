import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/builtin_linux.dart';
import 'package:opencode_mobile/builtin/builtin_provider_store.dart';
import 'package:opencode_mobile/domain/custom_provider.dart';

/// Answers the read scripts the store can send, and keeps every one of them
/// so their shell can still be checked; file writes arrive through [write],
/// which is the native channel's shape rather than a script.
class _FakeServer {
  _FakeServer({
    this.resolveAnswer =
        'JSON:/root/.oc-opencode2/config/opencode/opencode.json',
  });

  String resolveAnswer;

  /// The base64 body the read script would print, or null for "missing".
  String? fileBody;

  final List<String> scripts = [];

  /// Every file the store wrote, by path inside `/root`.
  final Map<String, String> files = {};

  /// Every file the store deleted, by the same path shape.
  final List<String> deleted = [];

  String? get configFile =>
      files['.oc-opencode2/config/opencode/opencode.json'];

  String? get keyFile => files['.secrets/my-gateway.key'];

  /// The backup the save made, if it made one.
  String? get backupFile {
    for (final entry in files.entries) {
      if (entry.key.contains('.bak.')) return entry.value;
    }
    return null;
  }

  Future<void> write(String relativePath, String content) async {
    files[relativePath] = content;
    if (relativePath == '.oc-opencode2/config/opencode/opencode.json') {
      fileBody = base64Encode(utf8.encode(content));
    }
  }

  Future<void> delete(String relativePath) async {
    deleted.add(relativePath);
    files.remove(relativePath);
    if (relativePath == '.oc-opencode2/config/opencode/opencode.json') {
      fileBody = null;
    }
  }

  Future<BuiltinLinuxRunResult> run(String script, Duration timeout) async {
    scripts.add(script);
    // Order matters: the read script also prints a `JSON:` marker.
    if (script.contains('base64 "\$f"')) {
      if (fileBody == null) {
        return const BuiltinLinuxRunResult(exitCode: 0, output: 'MISSING:');
      }
      return BuiltinLinuxRunResult(exitCode: 0, output: 'JSON:$fileBody');
    }
    return BuiltinLinuxRunResult(exitCode: 0, output: resolveAnswer);
  }
}

CustomProviderDraft _draft({
  ProviderKeyMode keyMode = ProviderKeyMode.secretFile,
  String? apiKey = 'sk-very-secret',
  String id = 'my-gateway',
}) => CustomProviderDraft(
  name: 'My Gateway',
  id: id,
  protocol: ProviderProtocol.chatCompletions,
  baseUrl: 'https://api.example.com/v1',
  apiKey: apiKey,
  keyMode: keyMode,
  models: const [CustomProviderModel(id: 'deepseek-v3.2')],
);

BuiltinProviderStore _store(_FakeServer fake) => BuiltinProviderStore(
  run: fake.run,
  writeFile: fake.write,
  deleteFile: fake.delete,
);

/// `sh -n` on a generated script: a quoting mistake is a syntax error here
/// rather than a save that half-worked on someone's phone.
Future<String?> _syntaxError(String script) async {
  final process = await Process.start('sh', ['-n']);
  process.stdin.write(script);
  await process.stdin.close();
  final stderrText = await process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode;
  return code == 0 ? null : stderrText.trim();
}

void main() {
  group('resolve', () {
    test('reads OpenCode 2 own directory as v2', () async {
      final fake = _FakeServer();
      final resolved = await _store(fake).resolve();
      expect(resolved.format, ProviderConfigFormat.v2);
      expect(
        resolved.relativePath,
        '.oc-opencode2/config/opencode/opencode.json',
      );
      expect(resolved.exists, true);
      expect(resolved.commentFile, false);
    });

    test(
      'always writes the OpenCode 2 path, even with a v1 file left',
      () async {
        // The start script pins XDG_CONFIG_HOME at .oc-opencode2, so a file in
        // the OpenCode 1 directory is invisible to the server. Preferring it
        // used to write every save into a file nothing read.
        final fake = _FakeServer();
        await _store(fake).resolve();
        final script = fake.scripts.last;
        expect(script, contains('.oc-opencode2/config/opencode/opencode.json'));
        expect(script, isNot(contains('/root/.config/opencode')));
      },
    );

    test(
      'a jsonc file is flagged instead of being treated as missing',
      () async {
        final fake = _FakeServer(
          resolveAnswer:
              'JSONC:/root/.oc-opencode2/config/opencode/opencode.jsonc',
        );
        final resolved = await _store(fake).resolve();
        expect(resolved.commentFile, true);
        expect(resolved.exists, true);
      },
    );

    test('a server with no config gets the OpenCode 2 path', () async {
      final fake = _FakeServer(
        resolveAnswer: 'NEW:/root/.oc-opencode2/config/opencode/opencode.json',
      );
      final resolved = await _store(fake).resolve();
      expect(
        resolved.relativePath,
        '.oc-opencode2/config/opencode/opencode.json',
      );
      expect(resolved.exists, false);
    });
  });

  group('scripts', () {
    test('server reload reads the live file rather than a startup snapshot', () async {
      final script = BuiltinLinux.serverScript();
      expect(script, contains('export XDG_CONFIG_HOME=/root/.oc-opencode2/config'));
      expect(script, contains('unset OPENCODE_CONFIG OPENCODE_CONFIG_CONTENT'));
      expect(script, isNot(contains('export OPENCODE_CONFIG_CONTENT')));
      expect(await _syntaxError(script), isNull);
    });

    test('every script the store still sends is a read, not a write', () async {
      final fake = _FakeServer();
      final store = _store(fake);
      await store.resolve();
      await store.save(_draft());
      // Resolve and read are the only guest processes left: the write and the
      // key file are native now, so a save cannot queue behind the installer.
      expect(fake.scripts.length, greaterThanOrEqualTo(2));
      for (final script in fake.scripts) {
        expect(script, isNot(contains('chmod 600')), reason: script);
        expect(script, isNot(contains('.tmp.')), reason: script);
        expect(await _syntaxError(script), isNull, reason: script);
      }
    });
  });

  group('save', () {
    test('Max survives both a config reread and a later provider edit', () async {
      final existing = _draft().toDocument(ProviderConfigFormat.v2);
      final fake = _FakeServer()
        ..fileBody = base64Encode(utf8.encode(jsonEncode(existing)));
      final store = _store(fake);
      final added = await store.setModelReasoningEffort(
        'my-gateway',
        'deepseek-v3.2',
        'max',
      );
      expect(added.backupPath, isNotNull);
      expect(added.keyFileWritten, isFalse);
      expect(fake.keyFile, isNull);
      Map model() =>
          (((jsonDecode(fake.configFile!) as Map)['providers'] as Map)
                      ['my-gateway'] as Map)['models']['deepseek-v3.2'] as Map;
      expect(model()['variants'], [
        {'id': 'max', 'settings': {'reasoningEffort': 'max'}},
      ]);
      await store.save(_draft(apiKey: null), replace: true);
      expect(model()['variants'], [
        {'id': 'max', 'settings': {'reasoningEffort': 'max'}},
      ]);
      final resolved = await store.resolve();
      final snapshot = await store.read(resolved);
      expect(snapshot.document, jsonDecode(fake.configFile!));
    });

    test('writes the provider and never the raw key into the config', () async {
      final fake = _FakeServer();
      final receipt = await _store(fake).save(_draft());
      expect(
        receipt.configPath,
        '/root/.oc-opencode2/config/opencode/opencode.json',
      );
      expect(receipt.keyFileWritten, true);
      final document = jsonDecode(fake.configFile!) as Map;
      final provider = (document['providers'] as Map)['my-gateway'] as Map;
      expect(provider['package'], 'aisdk:@ai-sdk/openai-compatible');
      expect(
        (provider['settings'] as Map)['apiKey'],
        '{file:/root/.secrets/my-gateway.key}',
      );
      expect(fake.configFile!.contains('sk-very-secret'), false);
    });

    test('writes the key into its own file', () async {
      final fake = _FakeServer();
      await _store(fake).save(_draft());
      // The 600 mode is the native writer's job (GuestFileWriterTest); what
      // this checks is that the key lands in its own path, not in the config.
      expect(fake.keyFile, 'sk-very-secret');
    });

    test('keeps what the existing file already had', () async {
      final existing = {
        r'$schema': 'https://opencode.ai/config.json',
        'model': 'anthropic/claude',
        'providers': {
          'other': {'package': 'aisdk:@ai-sdk/openai'},
        },
      };
      final fake = _FakeServer()
        ..fileBody = base64Encode(utf8.encode(jsonEncode(existing)));
      await _store(fake).save(_draft());
      final document = jsonDecode(fake.configFile!) as Map;
      expect(document[r'$schema'], 'https://opencode.ai/config.json');
      expect(document['model'], 'anthropic/claude');
      expect((document['providers'] as Map).keys.toSet(), {
        'other',
        'my-gateway',
      });
    });

    test('backs the previous file up before replacing it', () async {
      final existing = {'providers': <String, Object?>{}};
      final fake = _FakeServer()
        ..fileBody = base64Encode(utf8.encode(jsonEncode(existing)));
      final receipt = await _store(fake).save(_draft());
      expect(receipt.backupPath, isNotNull);
      // The backup is the bytes that were read, not a re-encoding of them.
      expect(fake.backupFile, jsonEncode(existing));
    });

    test('refuses a jsonc config rather than dropping its comments', () async {
      final fake = _FakeServer(
        resolveAnswer:
            'JSONC:/root/.oc-opencode2/config/opencode/opencode.jsonc',
      );
      await expectLater(
        _store(fake).save(_draft()),
        throwsA(
          isA<ProviderWriteRefused>().having(
            (e) => e.reason,
            'reason',
            'jsonc',
          ),
        ),
      );
      expect(fake.files, isEmpty);
    });

    test('refuses to replace a provider with the same id', () async {
      final existing = {
        'providers': {
          'my-gateway': {'package': 'aisdk:@ai-sdk/openai'},
        },
      };
      final fake = _FakeServer()
        ..fileBody = base64Encode(utf8.encode(jsonEncode(existing)));
      await expectLater(
        _store(fake).save(_draft()),
        throwsA(isA<ProviderWriteRefused>()),
      );
      expect(fake.files, isEmpty);
    });

    test('a server with no config starts from this provider alone', () async {
      final fake = _FakeServer();
      await _store(fake).save(_draft());
      final document = jsonDecode(fake.configFile!) as Map;
      expect((document['providers'] as Map).keys, ['my-gateway']);
    });

    test('a named key gets its own owner-only path, never the config body', () async {
      final fake = _FakeServer()
        ..fileBody = base64Encode(
          utf8.encode(jsonEncode(_draft().toDocument(ProviderConfigFormat.v2))),
        );
      final store = _store(fake);
      final resolved = await store.resolve();
      final receipt = await store.saveNamedKey(
        providerID: 'my-gateway',
        keyID: 'work',
        name: 'Work',
        secret: 'sk-work',
        activeKeyID: null,
        keys: const [],
        resolved: resolved,
      );
      expect(receipt.keyFileWritten, true);
      expect(
        fake.files['.secrets/opencode-plus/my-gateway/work.key'],
        'sk-work',
      );
      final document = jsonDecode(fake.configFile!) as Map;
      final settings =
          (((document['providers'] as Map)['my-gateway'] as Map)['settings']
              as Map);
      expect(
        settings['apiKey'],
        '{file:/root/.secrets/opencode-plus/my-gateway/work.key}',
      );
      expect(fake.configFile!.contains('sk-work'), false);
      expect(settings.containsKey('appKeyRing'), false);
    });

    test('two named keys keep separate files and switching changes the reference', () async {
      final fake = _FakeServer()
        ..fileBody = base64Encode(
          utf8.encode(jsonEncode(_draft().toDocument(ProviderConfigFormat.v2))),
        );
      final store = _store(fake);
      final resolved = await store.resolve();
      await store.saveNamedKey(
        providerID: 'my-gateway',
        keyID: 'work',
        name: 'Work',
        secret: 'sk-work',
        activeKeyID: null,
        keys: const [],
        resolved: resolved,
      );
      const work = ProviderKeyRecord(
        id: 'work',
        name: 'Work',
        filePath: '/root/.secrets/opencode-plus/my-gateway/work.key',
      );
      await store.saveNamedKey(
        providerID: 'my-gateway',
        keyID: 'backup',
        name: 'Backup',
        secret: 'sk-backup',
        activeKeyID: null,
        keys: const [work],
        resolved: resolved,
      );
      expect(fake.files['.secrets/opencode-plus/my-gateway/work.key'], 'sk-work');
      expect(fake.files['.secrets/opencode-plus/my-gateway/backup.key'], 'sk-backup');
      await store.updateNamedKeys(
        providerID: 'my-gateway',
        keys: const [
          work,
          ProviderKeyRecord(
            id: 'backup',
            name: 'Backup',
            filePath: '/root/.secrets/opencode-plus/my-gateway/backup.key',
          ),
        ],
        activeKeyID: 'work',
        resolved: resolved,
      );
      final document = jsonDecode(fake.configFile!) as Map;
      final settings =
          (((document['providers'] as Map)['my-gateway'] as Map)['settings']
              as Map);
      expect(
        settings['apiKey'],
        '{file:/root/.secrets/opencode-plus/my-gateway/work.key}',
      );
      expect(fake.files['.secrets/opencode-plus/my-gateway/backup.key'], 'sk-backup');
    });

    test('removing a named key deletes only that managed file', () async {
      final fake = _FakeServer()
        ..fileBody = base64Encode(
          utf8.encode(jsonEncode(_draft().toDocument(ProviderConfigFormat.v2))),
        );
      final store = _store(fake);
      final resolved = await store.resolve();
      await store.saveNamedKey(
        providerID: 'my-gateway',
        keyID: 'work',
        name: 'Work',
        secret: 'sk-work',
        activeKeyID: null,
        keys: const [],
        resolved: resolved,
      );
      const work = ProviderKeyRecord(
        id: 'work',
        name: 'Work',
        filePath: '/root/.secrets/opencode-plus/my-gateway/work.key',
      );
      await store.saveNamedKey(
        providerID: 'my-gateway',
        keyID: 'backup',
        name: 'Backup',
        secret: 'sk-backup',
        activeKeyID: null,
        keys: const [work],
        resolved: resolved,
      );
      await store.removeNamedKey(
        providerID: 'my-gateway',
        keyID: 'backup',
        remaining: const [work],
        activeKeyID: 'work',
        removedPath: '/root/.secrets/opencode-plus/my-gateway/backup.key',
        resolved: resolved,
      );
      expect(
        fake.deleted,
        ['.secrets/opencode-plus/my-gateway/backup.key'],
      );
      expect(fake.files['.secrets/opencode-plus/my-gateway/work.key'], 'sk-work');
    });

    test('provider removal never touches a legacy key path', () async {
      final fake = _FakeServer();
      await _store(fake).removeProviderKeyFiles('my-gateway', [
        '/root/.secrets/my-gateway.key',
        '/root/.secrets/opencode-plus/my-gateway/work.key',
      ]);
      expect(fake.deleted, ['.secrets/opencode-plus/my-gateway/work.key']);
    });
  });
}
