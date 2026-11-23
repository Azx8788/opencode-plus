import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/backup/app_backup.dart';
import 'package:opencode_mobile/backup/backup_chat_reader.dart';
import 'package:opencode_mobile/backup/backup_controller.dart';
import 'package:opencode_mobile/builtin/project_export.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/ui/kit/kit.dart';
import 'package:opencode_mobile/ui/screens/settings/backup_screen.dart';

void main() {
  late Directory staging;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('backup-page-');
  });

  tearDown(() async {
    if (staging.existsSync()) await staging.delete(recursive: true);
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

  Future<void> pump(
    WidgetTester tester,
    BackupController backup,
    Locale locale,
  ) async {
    tester.view.physicalSize = const Size(820, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // The page is redrawn by the controller, exactly as BackupScreen
        // wraps it; without the listener nothing after the first frame shows.
        home: ListenableBuilder(
          listenable: backup,
          builder: (context, _) => BackupPage(backup: backup),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the page offers the windows and the contents in English', (
    tester,
  ) async {
    await pump(tester, controller(_FakePlatform()), const Locale('en'));

    expect(find.text('Backup and export'), findsOneWidget);
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
    await pump(tester, controller(_FakePlatform()), const Locale('zh'));

    expect(find.text('备份与导出'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('密钥与登录信息'), findsOneWidget);
    expect(find.text('导出备份'), findsOneWidget);
  });

  testWidgets('exporting reports what was saved', (tester) async {
    final platform = _FakePlatform(destination: 'content://t/backup.zip');
    final backup = controller(platform);
    await pump(tester, backup, const Locale('en'));

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
    await pump(tester, backup, const Locale('en'));

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
}

/// Runs the real file I/O of a backup to completion: the page's export is
/// async past frames, so pumping alone would stop at "staging".
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
