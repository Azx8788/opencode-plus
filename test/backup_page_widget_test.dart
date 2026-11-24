import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/backup/app_backup.dart';
import 'package:opencode_mobile/backup/backup_chat_reader.dart';
import 'package:opencode_mobile/backup/backup_controller.dart';
import 'package:opencode_mobile/backup/backup_restore_controller.dart';
import 'package:opencode_mobile/builtin/project_export.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/screens/settings/backup_screen.dart';

void main() {
  late Directory root;
  late Directory staging;
  late Directory shelf;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup-page-');
    staging = Directory('${root.path}/staging');
    shelf = Directory('${root.path}/shelf');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  BackupController controller(_FakePlatform platform) => BackupController(
    platform: platform,
    readSettings: () async => {'oc.theme': 'dark', 'oc.budget': 12},
    readSecrets: () async => {'oc.token': 'secret'},
    readChats: (options, now, onProgress) async {
      onProgress(1, 1);
      return BackupChatRead(
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
      );
    },
    stagingDirectory: () async => staging,
    appVersion: '0.3.27+35',
    now: () => DateTime(2026, 11, 23, 12),
  );

  RestoreController restoreController(_FakeSource source) => RestoreController(
    platform: source,
    stagingDirectory: () async => staging,
    readSettings: () async => {'oc.theme': 'light'},
    writeSettings: (_) async {},
    readSecrets: () async => {'oc.token': 'old'},
    writeSecrets: (_) async {},
    restoredChatsDirectory: () async => shelf,
    now: () => DateTime(2026, 11, 23, 13),
  );

  /// A folder holding a real archive, as the native half would unpack it.
  Future<Directory> archive() async {
    final dir = Directory('${root.path}/unpacked');
    await dir.create(recursive: true);
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
    return dir;
  }

  Future<void> pump(
    WidgetTester tester,
    BackupController backup,
    RestoreController restore,
    Locale locale,
  ) async {
    tester.view.physicalSize = const Size(820, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // The page is redrawn by the controllers, exactly as BackupScreen
        // wraps it; without the listener nothing after the first frame shows.
        home: ListenableBuilder(
          listenable: Listenable.merge([backup, restore]),
          builder: (context, _) => BackupPage(backup: backup, restore: restore),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the page offers the windows and the contents in English', (
    tester,
  ) async {
    await pump(
      tester,
      controller(_FakePlatform()),
      restoreController(_FakeSource()),
      const Locale('en'),
    );

    expect(find.text('Backup and restore'), findsOneWidget);
    for (final label in ['7 days', '30 days', '90 days', 'All']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Conversations'), findsOneWidget);
    expect(find.text('Text only'), findsOneWidget);
    expect(find.text('Credentials'), findsOneWidget);
    // Credentials are on by default, and the page says what that means.
    expect(
      find.text('Anyone who opens the archive can use these credentials.'),
      findsOneWidget,
    );
  });

  testWidgets('the page speaks Chinese when the app does', (tester) async {
    await pump(
      tester,
      controller(_FakePlatform()),
      restoreController(_FakeSource()),
      const Locale('zh'),
    );

    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('密钥与登录信息'), findsOneWidget);
    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('从备份恢复'), findsOneWidget);
    expect(find.text('选择备份文件'), findsOneWidget);
  });

  testWidgets('exporting reports what was saved', (tester) async {
    final platform = _FakePlatform(destination: 'content://t/backup.zip');
    final backup = controller(platform);
    await pump(
      tester,
      backup,
      restoreController(_FakeSource()),
      const Locale('en'),
    );

    await tester.tap(find.byKey(const ValueKey('backup-export')));
    await _settle(tester, backup);

    expect(backup.phase, BackupPhase.done);
    expect(
      find.textContaining('Saved: 1 conversations (1 messages)'),
      findsOneWidget,
    );
    expect(find.text('Export again'), findsOneWidget);
  });

  testWidgets('turning conversations off turns text only off with them', (
    tester,
  ) async {
    final backup = controller(_FakePlatform());
    await pump(
      tester,
      backup,
      restoreController(_FakeSource()),
      const Locale('en'),
    );

    await tester.tap(find.byKey(const ValueKey('backup-chat')));
    await tester.pumpAndSettle();

    expect(backup.options.includeChat, isFalse);
    // The reason replaces the supporting line, and the switch stops working:
    // a row that is off for a reason says why.
    final textOnly = tester.widget<KitSwitchRow>(
      find.byKey(const ValueKey('backup-text-only')),
    );
    expect(textOnly.onChanged, isNull);
    expect(textOnly.disabledReason, 'Conversations are off');
  });

  testWidgets('choosing a backup shows what it holds before anything is used', (
    tester,
  ) async {
    // Real file I/O must run outside the widget test's clock, or its
    // continuation never runs and the test hangs.
    final source = _FakeSource(
      uri: 'content://x/b.zip',
      from: await tester.runAsync(archive),
    );
    final restore = restoreController(source);
    await pump(
      tester,
      controller(_FakePlatform()),
      restore,
      const Locale('en'),
    );

    await tester.tap(find.byKey(const ValueKey('backup-choose-file')));
    await _settleRestore(tester, restore);

    expect(restore.phase, RestorePhase.inspecting);
    expect(find.textContaining('Taken 2026-11-23 12:00'), findsOneWidget);
    expect(find.text('Settings (2)'), findsOneWidget);
    expect(find.text('Credentials (1)'), findsOneWidget);
    expect(find.text('Conversations (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-restore')), findsOneWidget);
  });

  testWidgets('restoring asks first, then says what came back', (tester) async {
    // Real file I/O must run outside the widget test's clock, or its
    // continuation never runs and the test hangs.
    final source = _FakeSource(
      uri: 'content://x/b.zip',
      from: await tester.runAsync(archive),
    );
    final restore = restoreController(source);
    await pump(
      tester,
      controller(_FakePlatform()),
      restore,
      const Locale('en'),
    );

    await tester.tap(find.byKey(const ValueKey('backup-choose-file')));
    await _settleRestore(tester, restore);

    await tester.tap(find.byKey(const ValueKey('backup-restore')));
    await tester.pumpAndSettle();
    expect(find.text('Put this backup back?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('backup-restore-confirm')));
    await _settleRestore(tester, restore);

    expect(restore.phase, RestorePhase.done);
    expect(
      find.textContaining(
        'Restored: 2 settings, 1 credentials, 1 conversations',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Restart the app so the restored settings'),
      findsOneWidget,
    );
    // The shelf is now offered, so the conversations can be read.
    expect(find.byKey(const ValueKey('backup-open-restored')), findsOneWidget);
  });
}

/// Runs the page's export to completion: it is async past frames, so pumping
/// alone would stop at "staging".
Future<void> _settle(WidgetTester tester, BackupController backup) async {
  for (var round = 0; round < 60; round++) {
    if (backup.phase == BackupPhase.done ||
        backup.phase == BackupPhase.failed ||
        backup.phase == BackupPhase.idle) {
      break;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _settleRestore(
  WidgetTester tester,
  RestoreController restore,
) async {
  for (var round = 0; round < 60; round++) {
    if (restore.phase == RestorePhase.inspecting ||
        restore.phase == RestorePhase.done ||
        restore.phase == RestorePhase.failed ||
        restore.phase == RestorePhase.idle) {
      break;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

class _FakePlatform implements ProjectExportPlatform {
  _FakePlatform({this.destination});

  final String? destination;

  @override
  Future<String?> pickDestination(String suggestedName) async => destination;

  @override
  Future<ProjectExportResult> export({
    required String destination,
    required String planPath,
    required void Function(int bytesDone) onProgress,
  }) async {
    final plan = File(planPath).readAsStringSync();
    var bytes = 0;
    for (final line in plan.split('\n')) {
      if (line.trim().isEmpty) continue;
      final file = File(line.split('\t').last);
      if (file.existsSync()) bytes += file.lengthSync();
    }
    onProgress(bytes);
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

/// Stands in for the native half: "unpacks" a prepared folder.
class _FakeSource implements ProjectImportPlatform {
  _FakeSource({this.uri, this.from});

  final String? uri;
  final Directory? from;

  @override
  Future<String?> pickSource() async => uri;

  @override
  Future<ProjectExportResult> extract({
    required String uri,
    required String directory,
    required void Function(int bytesDone) onProgress,
  }) async {
    final source = from;
    if (source == null) {
      return const ProjectExportResult.failed(ProjectExportFailure.source);
    }
    final target = Directory(directory);
    await target.create(recursive: true);
    var bytes = 0;
    for (final entity in source.listSync(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(source.path.length + 1);
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
