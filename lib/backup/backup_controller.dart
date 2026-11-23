// Drives one backup from the page: read, stage, ask where, stream. Every step
// is visible because a backup that sits on "working" for a minute is a backup
// people cancel.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../builtin/project_export.dart'
    show
        ProjectExportFailure,
        ProjectExportPlatform,
        ProjectExportResult,
        writeExportPlan;
import 'app_backup.dart';
import 'backup_chat_reader.dart';

enum BackupPhase { idle, collecting, staging, picking, writing, done, failed }

/// One backup's state while the page is open. Nothing here runs in the
/// background: closing the page stops it.
class BackupController extends ChangeNotifier {
  BackupController({
    required this.platform,
    required this.readSettings,
    required this.readSecrets,
    required this.readChats,
    required this.stagingDirectory,
    this.appVersion,
    this.serverLabel,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ProjectExportPlatform platform;
  final Future<Map<String, Object?>> Function() readSettings;
  final Future<Map<String, String>> Function() readSecrets;
  final Future<BackupChatRead> Function(
    BackupOptions options,
    DateTime now,
    BackupChatProgress onProgress,
  )
  readChats;
  final Future<Directory> Function() stagingDirectory;
  final String? appVersion;

  /// Where the conversations came from, for the manifest ("this phone").
  final String? serverLabel;
  final DateTime Function() _now;

  BackupOptions options = const BackupOptions();

  BackupPhase phase = BackupPhase.idle;
  BackupBundle? bundle;
  ProjectExportResult? result;

  /// Conversations read so far, and how many the window selected.
  int chatsDone = 0;
  int chatsTotal = 0;
  int bytesDone = 0;
  int bytesTotal = 0;

  /// Conversations whose messages could not be read.
  int skipped = 0;

  /// Set when the chat half was skipped: no server, or nothing to read.
  String? chatNote;

  bool _disposed = false;
  bool _stopRequested = false;

  bool get busy =>
      phase == BackupPhase.collecting ||
      phase == BackupPhase.staging ||
      phase == BackupPhase.picking ||
      phase == BackupPhase.writing;

  double get progress {
    if (phase == BackupPhase.collecting && chatsTotal > 0) {
      return chatsDone / chatsTotal;
    }
    if (bytesTotal <= 0) return 0;
    return (bytesDone / bytesTotal).clamp(0, 1).toDouble();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void setOptions(BackupOptions next) {
    if (busy) return;
    options = next;
    _changed();
  }

  /// Runs one backup. Returns when it finished, failed, or the person backed
  /// out of the picker.
  Future<void> export() async {
    if (busy) return;
    final at = _now();
    final chosen = options;
    _stopRequested = false;
    result = null;
    bundle = null;
    skipped = 0;
    chatNote = null;
    bytesDone = 0;
    bytesTotal = 0;
    chatsDone = 0;
    chatsTotal = 0;
    phase = BackupPhase.collecting;
    _changed();

    var settings = <String, Object?>{};
    try {
      settings = await readSettings();
    } on Object catch (error) {
      _fail(ProjectExportFailure.source, 'settings: $error');
      return;
    }

    var secrets = <String, String>{};
    if (chosen.includeSecrets) {
      try {
        secrets = await readSecrets();
      } on Object {
        // A locked keystore is not a reason to lose the settings; the archive
        // says how many credentials it holds, so a zero is visible.
        secrets = const {};
      }
    }

    var chats = <BackupChat>[];
    if (chosen.includeChat) {
      try {
        final read = await readChats(chosen, at, (done, total) {
          chatsDone = done;
          chatsTotal = total;
          _changed();
        });
        skipped = read.skipped;
        if (read.unsupported) {
          chatNote = 'unsupported';
        } else if (!read.ok) {
          chatNote = 'unreadable';
        }
        chats = read.chats
            .where((chat) => chatInWindow(chat, chosen.cutoff(at)))
            .toList();
      } on Object {
        chatNote = 'unreadable';
      }
    }
    if (_stopRequested) {
      _finishStopped();
      return;
    }

    phase = BackupPhase.staging;
    _changed();
    final Directory staging;
    try {
      staging = await stagingDirectory();
      await staging.create(recursive: true);
      bundle = await writeBackup(
        staging: staging,
        options: chosen,
        settings: settings,
        secrets: secrets,
        chats: chats,
        now: at,
        appVersion: appVersion,
        server: serverLabel,
      );
      bytesTotal = bundle!.bytes;
    } on Object catch (error) {
      _fail(ProjectExportFailure.source, 'staging: $error');
      return;
    }

    phase = BackupPhase.picking;
    _changed();
    final String? destination;
    try {
      destination = await platform.pickDestination(
        suggestedBackupName(at, chosen),
      );
    } on Object {
      _cleanup(staging);
      _fail(ProjectExportFailure.destination, 'picker');
      return;
    }
    if (destination == null) {
      _cleanup(staging);
      phase = BackupPhase.idle;
      _changed();
      return;
    }

    phase = BackupPhase.writing;
    _changed();
    File? plan;
    try {
      plan = await writeExportPlan(staging, bundle!.entries);
      final outcome = await platform.export(
        destination: destination,
        planPath: plan.path,
        onProgress: (bytes) {
          bytesDone = bytes;
          _changed();
        },
      );
      result = outcome;
      phase = outcome.ok ? BackupPhase.done : BackupPhase.failed;
      if (outcome.ok) bytesDone = outcome.bytes;
    } on Object catch (error) {
      _fail(ProjectExportFailure.failed, 'export: $error');
      return;
    } finally {
      try {
        if (plan != null && plan.existsSync()) plan.deleteSync();
      } on Object {
        // The plan is in the cache; leaving it costs nothing.
      }
      _cleanup(staging);
    }
    _changed();
  }

  Future<void> cancel() async {
    if (!busy) return;
    _stopRequested = true;
    try {
      await platform.cancel();
    } on Object {
      // Nothing to do: the loop checks _stopRequested anyway.
    }
  }

  void _finishStopped() {
    phase = BackupPhase.idle;
    _changed();
  }

  void _fail(ProjectExportFailure failure, String detail) {
    result = ProjectExportResult.failed(failure, detail);
    phase = BackupPhase.failed;
    _changed();
  }

  void _cleanup(Directory staging) {
    try {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    } on Object {
      // The cache is cleared by the system when it needs the room.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRequested = true;
    super.dispose();
  }
}
