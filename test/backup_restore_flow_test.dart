import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/backup/app_backup.dart';
import 'package:opencode_mobile/backup/app_restore.dart';
import 'package:opencode_mobile/backup/backup_restore_controller.dart';
import 'package:opencode_mobile/builtin/project_export.dart';

void main() {
  late Directory root;
  late Directory staging;
  late Directory shelf;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('restore-flow-');
    staging = Directory('${root.path}/staging');
    shelf = Directory('${root.path}/shelf');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  /// A folder holding a real archive, as the native half would unpack.
  Future<Directory> archive({bool withManifest = true}) async {
    final dir = Directory('${root.path}/unpacked');
    await dir.create(recursive: true);
    if (withManifest) {
      await writeBackup(
        staging: dir,
        options: const BackupOptions(days: 30),
        settings: {'oc.theme': 'dark', 'oc.budget': 12},
        secrets: {'oc.key': 'sk-new'},
        chats: [
          BackupChat(
            id: 'ses_1',
            title: 'Hello',
            updated: DateTime(2026, 11, 20).millisecondsSinceEpoch,
            messages: [
              {
                'id': 'm1',
                'info': {'role': 'user'},
                'parts': [
                  {'type': 'text', 'text': 'hi'},
                ],
              },
            ],
          ),
        ],
        now: DateTime(2026, 11, 23, 12),
        appVersion: '0.3.28+36',
      );
    } else {
      await File('${dir.path}/notes.txt').writeAsString('not a backup');
    }
    return dir;
  }

  RestoreController controller(
    _FakeSource source, {
    Map<String, Object?> settings = const {'oc.theme': 'light', 'oc.keep': 1},
    Map<String, String> secrets = const {'oc.key': 'sk-old'},
    void Function(Map<String, Object?> values)? onSettings,
    void Function(Map<String, String> values)? onSecrets,
  }) => RestoreController(
    platform: source,
    stagingDirectory: () async => staging,
    readSettings: () async => settings,
    writeSettings: (values) async => onSettings?.call(values),
    readSecrets: () async => secrets,
    writeSecrets: (values) async => onSecrets?.call(values),
    restoredChatsDirectory: () async => shelf,
    now: () => DateTime(2026, 11, 23, 13),
  );

  test(
    'a chosen archive is unpacked, read, and shown before it is used',
    () async {
      final source = _FakeSource(
        uri: 'content://x/b.zip',
        from: await archive(),
      );
      final restore = controller(source);

      await restore.choose();

      expect(restore.phase, RestorePhase.inspecting);
      expect(source.extractCalls, 1);
      expect(restore.archive?.chats.single.id, 'ses_1');
      expect(restore.includeSettings, isTrue);
      expect(restore.includeSecrets, isTrue);
      expect(restore.includeChats, isTrue);
      // Nothing is written until the person says so.
      expect(restore.settingsResult, isNull);
      expect(shelf.existsSync(), isFalse);
      expect(staging.existsSync(), isTrue);
      restore.dispose();
      // Closing the page takes the unpacked copy — credentials included — with it.
      expect(staging.existsSync(), isFalse);
    },
  );

  test('backing out of the picker leaves nothing behind', () async {
    final source = _FakeSource(uri: null, from: await archive());
    final restore = controller(source);

    await restore.choose();

    expect(restore.phase, RestorePhase.idle);
    expect(source.extractCalls, 0);
    expect(staging.existsSync(), isFalse);
    restore.dispose();
  });

  test(
    'restoring writes the settings, the credentials and the shelf',
    () async {
      Map<String, Object?>? wroteSettings;
      Map<String, String>? wroteSecrets;
      final source = _FakeSource(
        uri: 'content://x/b.zip',
        from: await archive(),
      );
      final restore = controller(
        source,
        onSettings: (values) => wroteSettings = values,
        onSecrets: (values) => wroteSecrets = values,
      );

      await restore.choose();
      await restore.restore();

      expect(restore.phase, RestorePhase.done);
      // The archive wins where it has a value; `oc.keep` stays as it is because
      // the archive does not mention it.
      expect(wroteSettings, {'oc.theme': 'dark', 'oc.budget': 12});
      expect(restore.settingsResult?.changed, 1);
      expect(restore.settingsResult?.added, 1);
      expect(wroteSecrets, {'oc.key': 'sk-new'});
      expect(restore.secretsResult?.changed, 1);
      expect(restore.chatsRestored, 1);

      expect(restore.restored, hasLength(1));
      expect(restore.restored.single.chats, 1);
      final chats = await readRestoredArchive(restore.restored.single.path);
      expect(messageText(chats.single.messages.single), 'hi');

      // The unpacked copy, which holds the credentials in plain text, is gone.
      expect(staging.existsSync(), isFalse);
      restore.dispose();
    },
  );

  test('only the chosen parts are written', () async {
    Map<String, Object?>? wroteSettings;
    Map<String, String>? wroteSecrets;
    final source = _FakeSource(uri: 'content://x/b.zip', from: await archive());
    final restore = controller(
      source,
      onSettings: (values) => wroteSettings = values,
      onSecrets: (values) => wroteSecrets = values,
    );

    await restore.choose();
    restore.setIncludeSettings(false);
    restore.setIncludeSecrets(false);
    await restore.restore();

    expect(wroteSettings, isNull);
    expect(wroteSecrets, isNull);
    expect(restore.settingsResult, isNull);
    expect(restore.chatsRestored, 1);
    restore.dispose();
  });

  test('a file that is not a backup is refused by name', () async {
    final source = _FakeSource(
      uri: 'content://x/photo.jpg',
      from: await archive(withManifest: false),
    );
    final restore = controller(source);

    await restore.choose();

    expect(restore.phase, RestorePhase.failed);
    expect(restore.readFailure, BackupReadFailure.missing);
    expect(restore.transferFailure, isNull);
    expect(staging.existsSync(), isFalse);
    restore.dispose();
  });

  test('a failed unpack says why, and cleans up', () async {
    final source = _FakeSource(
      uri: 'content://x/b.zip',
      from: await archive(),
      failure: ProjectExportFailure.space,
    );
    final restore = controller(source);

    await restore.choose();

    expect(restore.phase, RestorePhase.failed);
    expect(restore.transferFailure, ProjectExportFailure.space);
    expect(restore.readFailure, isNull);
    expect(staging.existsSync(), isFalse);
    restore.dispose();
  });

  test('forgetting an inspected file puts nothing back', () async {
    final source = _FakeSource(uri: 'content://x/b.zip', from: await archive());
    final restore = controller(source);

    await restore.choose();
    await restore.discard();

    expect(restore.phase, RestorePhase.idle);
    expect(restore.archive, isNull);
    expect(staging.existsSync(), isFalse);
    expect(shelf.existsSync(), isFalse);
    restore.dispose();
  });

  test('the shelf is read before anything is imported', () async {
    final source = _FakeSource(uri: 'content://x/b.zip', from: await archive());
    final restore = controller(source);

    await restore.refreshRestored();
    expect(restore.restored, isEmpty);

    await restore.choose();
    await restore.restore();
    await restore.refreshRestored();
    expect(restore.restored, hasLength(1));
    restore.dispose();
  });
}

/// Stands in for the native half: "unpacks" a prepared folder, or fails.
class _FakeSource implements ProjectImportPlatform {
  _FakeSource({this.uri, required this.from, this.failure});

  final String? uri;
  final Directory from;
  final ProjectExportFailure? failure;

  int extractCalls = 0;

  @override
  Future<String?> pickSource() async => uri;

  @override
  Future<ProjectExportResult> extract({
    required String uri,
    required String directory,
    required void Function(int bytesDone) onProgress,
  }) async {
    extractCalls++;
    if (failure != null) {
      return ProjectExportResult.failed(failure!, 'fake');
    }
    final target = Directory(directory);
    await target.create(recursive: true);
    var bytes = 0;
    for (final entity in from.listSync(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(from.path.length + 1);
      final copy = File('${target.path}/$relative');
      await copy.parent.create(recursive: true);
      await entity.copy(copy.path);
      bytes += await copy.length();
      onProgress(bytes);
    }
    return ProjectExportResult.done(bytes: bytes, files: 3);
  }

  @override
  Future<void> cancel() async {}
}
