import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/backup/app_backup.dart';
import 'package:opencode_mobile/backup/backup_chat_reader.dart';
import 'package:opencode_mobile/backup/backup_controller.dart';
import 'package:opencode_mobile/builtin/project_export.dart';

void main() {
  group('the window', () {
    final now = DateTime(2026, 11, 23, 12);

    BackupChat chat({int? updated, List<int> messageTimes = const []}) =>
        BackupChat(
          id: 'ses-1',
          title: 'A chat',
          updated: updated,
          messages: [
            for (final time in messageTimes)
              {
                'id': 'msg-$time',
                'time': {'created': time},
              },
          ],
        );

    test('a conversation used inside the window is kept', () {
      final cutoff = const BackupOptions(days: 7).cutoff(now)!;
      expect(
        chatInWindow(
          chat(
            updated: now
                .subtract(const Duration(days: 2))
                .millisecondsSinceEpoch,
          ),
          cutoff,
        ),
        isTrue,
      );
    });

    test('a conversation untouched for longer is dropped', () {
      final cutoff = const BackupOptions(days: 7).cutoff(now)!;
      expect(
        chatInWindow(
          chat(
            updated: now
                .subtract(const Duration(days: 30))
                .millisecondsSinceEpoch,
          ),
          cutoff,
        ),
        isFalse,
      );
    });

    test('a recent message keeps an older conversation', () {
      final cutoff = const BackupOptions(days: 7).cutoff(now)!;
      final old = now.subtract(const Duration(days: 40)).millisecondsSinceEpoch;
      expect(
        chatInWindow(chat(updated: old, messageTimes: [old]), cutoff),
        isFalse,
      );
      expect(
        chatInWindow(
          chat(
            updated: old,
            messageTimes: [
              old,
              now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
            ],
          ),
          cutoff,
        ),
        isTrue,
      );
    });

    test('zero days keeps everything', () {
      final cutoff = const BackupOptions(days: 0).cutoff(now);
      expect(cutoff, isNull);
      expect(chatInWindow(chat(updated: 0), cutoff), isTrue);
    });
  });

  group('text only', () {
    test('keeps the words and drops the machinery', () {
      final raw = <String, dynamic>{
        'id': 'msg-1',
        'type': 'assistant',
        'time': {'created': 1},
        'files': [
          {'name': 'a.png'},
        ],
        'content': [
          {'type': 'text', 'text': 'Reading the file.'},
          {
            'type': 'tool',
            'tool': 'read',
            'state': {'output': 'x' * 1000},
          },
          {'type': 'text', 'text': 'It is a picture.'},
        ],
      };
      final trimmed = textOnlyMessage(raw);
      expect(trimmed['files'], isNull);
      expect(trimmed['id'], 'msg-1');
      expect(trimmed['content'], [
        {'type': 'text', 'text': 'Reading the file.'},
        {'type': 'text', 'text': 'It is a picture.'},
      ]);
      // The input is not mutated: the caller may still write it in full.
      expect((raw['content'] as List), hasLength(3));
    });
  });

  group('names', () {
    test('the archive name carries the day and the window', () {
      expect(
        suggestedBackupName(
          DateTime(2026, 11, 23),
          const BackupOptions(days: 30),
        ),
        'opencode-plus-backup-2026-11-23-30d-private.zip',
      );
      expect(
        suggestedBackupName(
          DateTime(2026, 1, 5),
          const BackupOptions(days: 0, includeSecrets: false),
        ),
        'opencode-plus-backup-2026-01-05-all.zip',
      );
    });

    test('a conversation title becomes a file name', () {
      expect(
        chatFileLabel('Fix: the /login "bug"', 'ses_abc123456789'),
        'Fix-the-login-bug-abc123456789',
      );
      expect(chatFileLabel(null, 'ses_abc123456789'), 'ses_abc123456789');
      expect(chatFileLabel('   ', 'ses_1'), 'ses_1');
      expect(
        chatFileLabel('a' * 80, 'ses_1').length,
        lessThanOrEqualTo(40 + 1 + 5),
      );
    });
  });

  group('writing the archive', () {
    late Directory staging;

    setUp(() async {
      staging = await Directory.systemTemp.createTemp('backup-test-');
    });

    tearDown(() async {
      if (staging.existsSync()) await staging.delete(recursive: true);
    });

    test('settings, credentials and conversations land in place', () async {
      final bundle = await writeBackup(
        staging: staging,
        options: const BackupOptions(days: 30),
        settings: {'oc.theme': 'dark', 'oc.budget': 12},
        secrets: {'oc.telegramBot.token.p1': 'abc'},
        chats: [
          BackupChat(
            id: 'ses_1',
            title: 'Hello',
            updated: DateTime(2026, 11, 20).millisecondsSinceEpoch,
            messages: [
              {
                'id': 'm1',
                'type': 'user',
                'time': {'created': 1},
                'text': 'hi',
              },
            ],
          ),
        ],
        now: DateTime(2026, 11, 23, 12),
        appVersion: '0.3.27+35',
        server: 'This phone',
      );

      expect(bundle.entries.map((e) => e.name), [
        'README.txt',
        'chat/2026-11-20-Hello-ses_1.json',
        'config/secrets.json',
        'config/settings.json',
        'manifest.json',
      ]);
      expect(bundle.sessions, 1);
      expect(bundle.messages, 1);
      expect(bundle.settings, 2);
      expect(bundle.secrets, 1);
      expect(bundle.bytes, greaterThan(0));

      final manifest =
          jsonDecode(File('${staging.path}/manifest.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(manifest['format'], 'opencode-plus-backup');
      expect(manifest['app'], '0.3.27+35');
      expect(manifest['server'], 'This phone');
      expect((manifest['selection'] as Map)['days'], 30);
      expect((manifest['counts'] as Map)['messages'], 1);

      final settings =
          jsonDecode(
                File('${staging.path}/config/settings.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(settings.keys.toList(), ['oc.budget', 'oc.theme']);
      expect(settings['oc.budget'], 12);

      final chat =
          jsonDecode(
                File(
                  '${staging.path}/chat/2026-11-20-Hello-ses_1.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(chat['id'], 'ses_1');
      expect((chat['messages'] as List), hasLength(1));
    });

    test('credentials can be left out, and the archive says so', () async {
      final bundle = await writeBackup(
        staging: staging,
        options: const BackupOptions(days: 7, includeSecrets: false),
        settings: {'oc.theme': 'dark'},
        secrets: {'oc.telegramBot.token.p1': 'abc'},
        chats: const [],
        now: DateTime(2026, 11, 23),
      );
      expect(
        bundle.entries.map((e) => e.name),
        isNot(contains('config/secrets.json')),
      );
      expect(bundle.secrets, 0);
      expect(
        File('${staging.path}/README.txt').readAsStringSync(),
        contains('left out'),
      );
    });

    test('text only reaches the written conversation', () async {
      await writeBackup(
        staging: staging,
        options: const BackupOptions(days: 30, textOnly: true),
        settings: const {},
        secrets: const {},
        chats: [
          BackupChat(
            id: 'ses_2',
            title: 'Tools',
            updated: DateTime(2026, 11, 21).millisecondsSinceEpoch,
            messages: [
              {
                'id': 'm1',
                'type': 'assistant',
                'time': {'created': 1},
                'content': [
                  {'type': 'text', 'text': 'done'},
                  {'type': 'tool', 'tool': 'bash'},
                ],
              },
            ],
          ),
        ],
        now: DateTime(2026, 11, 23),
      );
      final chat =
          jsonDecode(
                File(
                  '${staging.path}/chat/2026-11-21-Tools-ses_2.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final message = (chat['messages'] as List).single as Map<String, dynamic>;
      expect((message['content'] as List), [
        {'type': 'text', 'text': 'done'},
      ]);
    });
  });

  group('the reader', () {
    test('says so when the connection cannot be read', () async {
      final read = await const BackupChatReader().read(
        null,
        options: const BackupOptions(),
        now: DateTime(2026, 11, 23),
      );
      expect(read.unsupported, isTrue);
      expect(read.chats, isEmpty);
    });
  });

  group('one backup', () {
    late Directory staging;

    setUp(() async {
      staging = await Directory.systemTemp.createTemp('backup-flow-');
    });

    tearDown(() async {
      if (staging.existsSync()) await staging.delete(recursive: true);
    });

    BackupController controller(
      _FakePlatform platform, {
      String? destination,
    }) => BackupController(
      platform: platform,
      readSettings: () async => {'oc.theme': 'dark'},
      readSecrets: () async => {'oc.token': 'secret'},
      readChats: (options, now, onProgress) async {
        onProgress(1, 1);
        return const BackupChatRead(
          chats: [BackupChat(id: 'ses_1', title: 'Hi', messages: [])],
        );
      },
      stagingDirectory: () async => staging,
      appVersion: '0.3.27+35',
      now: () => DateTime(2026, 11, 23, 12),
    );

    test(
      'writes the zip, reports what it held, and clears the staging',
      () async {
        final platform = _FakePlatform(
          destination: 'content://target/backup.zip',
        );
        final backup = controller(platform);
        await backup.export();

        expect(backup.phase, BackupPhase.done);
        expect(backup.result?.ok, isTrue);
        expect(backup.result?.files, greaterThan(0));
        expect(platform.exportedPlan, isNotNull);
        expect(platform.exportedPlan, contains('config/settings.json'));
        expect(platform.exportedPlan, contains('config/secrets.json'));
        expect(backup.bundle?.sessions, 1);
        expect(staging.existsSync(), isFalse);
      },
    );

    test('backing out of the picker leaves nothing behind', () async {
      final platform = _FakePlatform(destination: null);
      final backup = controller(platform);
      await backup.export();

      expect(backup.phase, BackupPhase.idle);
      expect(platform.exportCalls, 0);
      expect(staging.existsSync(), isFalse);
    });

    test('a refused destination is reported, not swallowed', () async {
      final platform = _FakePlatform(
        destination: 'content://target/backup.zip',
        failure: ProjectExportFailure.space,
      );
      final backup = controller(platform);
      await backup.export();

      expect(backup.phase, BackupPhase.failed);
      expect(backup.result?.failure, ProjectExportFailure.space);
      expect(staging.existsSync(), isFalse);
    });

    test('the archive name follows the window and the credentials', () async {
      final platform = _FakePlatform(destination: 'content://t/b.zip');
      final backup = controller(platform);
      backup.setOptions(
        const BackupOptions(days: 7, includeSecrets: false, includeChat: false),
      );
      await backup.export();

      expect(platform.suggestedName, 'opencode-plus-backup-2026-11-23-7d.zip');
      expect(platform.exportedPlan, isNot(contains('config/secrets.json')));
    });
  });
}

class _FakePlatform implements ProjectExportPlatform {
  _FakePlatform({this.destination, this.failure});

  final String? destination;
  final ProjectExportFailure? failure;

  String? suggestedName;
  String? exportedPlan;
  int exportCalls = 0;

  @override
  Future<String?> pickDestination(String suggestedName) async {
    this.suggestedName = suggestedName;
    return destination;
  }

  @override
  Future<ProjectExportResult> export({
    required String destination,
    required String planPath,
    required void Function(int bytesDone) onProgress,
  }) async {
    exportCalls++;
    exportedPlan = File(planPath).readAsStringSync();
    var bytes = 0;
    for (final line in exportedPlan!.split('\n')) {
      if (line.trim().isEmpty) continue;
      final source = line.split('\t').last;
      final file = File(source);
      if (file.existsSync()) bytes += file.lengthSync();
    }
    onProgress(bytes);
    if (failure != null) {
      return ProjectExportResult.failed(failure!, 'fake');
    }
    return ProjectExportResult.done(bytes: bytes, files: 4);
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<int> clearCache() async => 0;

  @override
  Future<int> cacheBytes() async => 0;

  @override
  Future<bool> clearAllData() async => false;

  @override
  Future<String?> filesDir() async => null;

  @override
  Future<int> savedServers() async => 0;
}
