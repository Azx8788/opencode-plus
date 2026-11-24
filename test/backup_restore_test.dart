import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/backup/app_backup.dart';
import 'package:opencode_mobile/backup/app_restore.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('restore-test-');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  Future<Directory> archiveDir({BackupOptions? options}) async {
    final dir = Directory('${root.path}/archive');
    await dir.create(recursive: true);
    await writeBackup(
      staging: dir,
      options: options ?? const BackupOptions(days: 30),
      settings: {
        'oc.theme': 'dark',
        'oc.budget': 12,
        'oc.flow': ['a', 'b'],
      },
      secrets: {'oc.telegramBot.token.p1': 'abc', 'oc.key': 'sk-1'},
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
      server: 'This phone',
    );
    return dir;
  }

  group('reading an archive this app wrote', () {
    test('gives back the settings, the credentials and the chats', () async {
      final archive = await readBackupArchive(await archiveDir());

      expect(archive.formatVersion, 1);
      expect(archive.settings, {
        'oc.theme': 'dark',
        'oc.budget': 12,
        'oc.flow': ['a', 'b'],
      });
      expect(archive.secrets, {
        'oc.telegramBot.token.p1': 'abc',
        'oc.key': 'sk-1',
      });
      expect(archive.chats.single.id, 'ses_1');
      expect(archive.chats.single.title, 'Hello');
      expect(archive.chats.single.messages, hasLength(1));
      expect(archive.messages, 1);
      expect(archive.appVersion, '0.3.28+36');
      expect(archive.server, 'This phone');
      expect(archive.days, 30);
      expect(archive.textOnly, isFalse);
      // The archive stores UTC; reading it gives back the same moment.
      expect(archive.createdAt, DateTime(2026, 11, 23, 12));
      expect(archive.damagedChats, 0);
    });

    test('an archive without credentials says it has none', () async {
      final dir = await archiveDir(
        options: const BackupOptions(days: 7, includeSecrets: false),
      );
      final archive = await readBackupArchive(dir);
      expect(archive.hasSecrets, isFalse);
      expect(archive.hasSettings, isTrue);
      expect(archive.days, 7);
    });
  });

  group('files that are not backups', () {
    Future<BackupReadFailure?> failureOf(
      Future<Directory> Function() build,
    ) async {
      try {
        await readBackupArchive(await build());
      } on BackupFormatException catch (error) {
        return error.failure;
      }
      return null;
    }

    Future<Directory> withManifest(Object manifest) async {
      final dir = Directory('${root.path}/m');
      await dir.create(recursive: true);
      await File(
        '${dir.path}/manifest.json',
      ).writeAsString(manifest is String ? manifest : jsonEncode(manifest));
      return dir;
    }

    test('no manifest at all', () async {
      final dir = Directory('${root.path}/empty');
      await dir.create(recursive: true);
      expect(await failureOf(() async => dir), BackupReadFailure.missing);
    });

    test('a zip from another app', () async {
      expect(
        await failureOf(
          () => withManifest({'format': 'opencode-project-export'}),
        ),
        BackupReadFailure.notABackup,
      );
    });

    test('a format this build cannot read', () async {
      expect(
        await failureOf(
          () =>
              withManifest({'format': backupArchiveFormat, 'formatVersion': 2}),
        ),
        BackupReadFailure.tooNew,
      );
    });

    test('a manifest that is not JSON', () async {
      expect(
        await failureOf(() => withManifest('{oops')),
        BackupReadFailure.damaged,
      );
    });

    test('an archive with nothing in it', () async {
      expect(
        await failureOf(
          () =>
              withManifest({'format': backupArchiveFormat, 'formatVersion': 1}),
        ),
        BackupReadFailure.empty,
      );
    });
  });

  group('putting settings back', () {
    test('only the archive decides a value, and nothing is deleted', () {
      final merge = mergeSettings(
        current: {'oc.theme': 'light', 'oc.budget': 12, 'oc.after': 'kept'},
        incoming: {
          'oc.theme': 'dark',
          'oc.budget': 12,
          'oc.flow': ['a'],
        },
      );
      // `oc.after` is not in the archive, so it is not written (and not
      // removed): a setting added after the backup keeps its value.
      expect(merge.write.keys.toList()..sort(), [
        'oc.budget',
        'oc.flow',
        'oc.theme',
      ]);
      expect(merge.added, 1);
      expect(merge.changed, 1);
      expect(merge.unchanged, 1);
      expect(merge.skipped, 0);
      expect(merge.total, 3);
    });

    test('a value this build cannot store is skipped, not flattened', () {
      final merge = mergeSettings(
        current: const {},
        incoming: {
          'oc.nested': {'a': 1},
          'oc.null': null,
          'oc.list': [1, 2],
          'oc.ok': true,
        },
      );
      expect(merge.write, {'oc.ok': true});
      expect(merge.skipped, 3);
    });

    test('credentials keep the strings and count the rest', () {
      final merge = mergeSecrets(
        current: {'oc.key': 'old'},
        incoming: {'oc.key': 'new', 'oc.token': 'abc', 'oc.bad': 12},
      );
      expect(merge.write, {'oc.key': 'new', 'oc.token': 'abc'});
      expect(merge.changed, 1);
      expect(merge.added, 1);
      expect(merge.skipped, 1);
    });
  });

  group('the restored shelf', () {
    test('a folder is named after the moment the backup was taken', () {
      final archive = BackupArchive(
        formatVersion: 1,
        createdAt: DateTime.utc(2026, 11, 23, 10, 30, 5),
        chats: const [RestoredChat(id: 'ses_1', file: 'a.json')],
      );
      expect(restoredFolderName(archive), '2026-11-23-103005');
    });

    test('an undated archive gets the same name every time', () {
      final archive = BackupArchive(
        formatVersion: 1,
        chats: const [
          RestoredChat(id: 'ses_a', file: 'a.json'),
          RestoredChat(id: 'ses_b', file: 'b.json'),
        ],
      );
      final first = restoredFolderName(archive);
      expect(first, startsWith('undated-'));
      expect(restoredFolderName(archive), first);
    });

    test('importing twice replaces instead of piling up', () async {
      final source = await archiveDir();
      final archive = await readBackupArchive(source);
      final shelf = Directory('${root.path}/shelf');

      expect(
        await restoreChats(root: shelf, archive: archive, source: source),
        1,
      );
      expect(
        await restoreChats(root: shelf, archive: archive, source: source),
        1,
      );

      final folders = shelf.listSync().whereType<Directory>().toList();
      expect(folders, hasLength(1));
      final chats = Directory(
        '${folders.single.path}/chat',
      ).listSync().whereType<File>().toList();
      expect(chats, hasLength(1));

      final archives = await listRestoredArchives(shelf);
      expect(archives, hasLength(1));
      expect(archives.single.chats, 1);
      expect(archives.single.messages, 1);
      expect(archives.single.appVersion, '0.3.28+36');
      expect(archives.single.createdAt, isNotNull);

      final read = await readRestoredArchive(archives.single.path);
      expect(read.single.id, 'ses_1');
      expect(messageText(read.single.messages.single), 'hi');
    });

    test('an empty shelf lists nothing', () async {
      expect(
        await listRestoredArchives(Directory('${root.path}/none')),
        isEmpty,
      );
    });
  });

  group('what a message said', () {
    test('v2: parts, under info', () {
      final raw = <String, dynamic>{
        'info': {'role': 'assistant'},
        'parts': [
          {'type': 'text', 'text': 'Reading it.'},
          {'type': 'tool', 'tool': 'bash'},
          {'type': 'text', 'text': 'Done.'},
        ],
      };
      expect(messageText(raw), 'Reading it.\n\nDone.');
      expect(messageRole(raw), 'assistant');
    });

    test('v1: content, with the role on the message', () {
      final raw = <String, dynamic>{
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'hi'},
        ],
      };
      expect(messageText(raw), 'hi');
      expect(messageRole(raw), 'user');
    });

    test('a plain text message', () {
      expect(messageText({'text': ' hello '}), 'hello');
      expect(messageRole({}), 'message');
    });

    test('a message with only tool calls has no words', () {
      expect(
        messageText({
          'content': [
            {'type': 'tool', 'tool': 'read'},
          ],
        }),
        '',
      );
    });

    test('a timestamp becomes a moment', () {
      final at = DateTime(2026, 11, 20, 9, 30);
      expect(
        messageTime({
          'time': {'created': at.millisecondsSinceEpoch},
        }),
        at,
      );
      expect(messageTime(const {}), isNull);
    });
  });
}
