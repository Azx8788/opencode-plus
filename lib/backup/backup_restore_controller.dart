// Drives one restore from the page: choose a file, unpack it, say what is in
// it, put back the parts the person kept, and stop.
//
// The unpacked folder lives in the cache and is deleted as soon as the page is
// done with it (or closes), because it holds credentials in plain text.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../builtin/project_export.dart'
    show ProjectExportFailure, ProjectExportResult, ProjectImportPlatform;
import 'app_restore.dart';

enum RestorePhase { idle, picking, reading, inspecting, applying, done, failed }

/// One restore's state while the page is open. Nothing runs in the
/// background: closing the page stops it.
class RestoreController extends ChangeNotifier {
  RestoreController({
    required this.platform,
    required this.stagingDirectory,
    required this.readSettings,
    required this.writeSettings,
    required this.readSecrets,
    required this.writeSecrets,
    required this.restoredChatsDirectory,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ProjectImportPlatform platform;
  final Future<Map<String, Object?>> Function() readSettings;
  final Future<void> Function(Map<String, Object?> values) writeSettings;
  final Future<Map<String, String>> Function() readSecrets;
  final Future<void> Function(Map<String, String> values) writeSecrets;
  final Future<Directory> Function() restoredChatsDirectory;

  /// A fresh folder in the cache for one unpacked archive.
  final Future<Directory> Function() stagingDirectory;
  final DateTime Function() _now;

  RestorePhase phase = RestorePhase.idle;

  /// What the chosen file holds, once it has been read.
  BackupArchive? archive;

  /// Why the file could not be read, when it could not.
  BackupReadFailure? readFailure;

  /// Why the unpacking failed (a different kind of wrong).
  ProjectExportFailure? transferFailure;

  /// Technical text for Details only.
  String detail = '';

  /// Bytes unpacked so far, for the progress line.
  int bytesDone = 0;

  /// What to put back. All on, for a file that holds each.
  bool includeSettings = true;
  bool includeSecrets = true;
  bool includeChats = true;

  /// What the last restore actually wrote.
  SettingsMerge? settingsResult;
  SecretsMerge? secretsResult;
  int chatsRestored = 0;

  /// Archives already on the shelf, newest first.
  List<RestoredArchive> restored = const [];

  Directory? _staging;
  bool _disposed = false;

  bool get busy =>
      phase == RestorePhase.picking ||
      phase == RestorePhase.reading ||
      phase == RestorePhase.applying;

  bool get inspecting => phase == RestorePhase.inspecting && archive != null;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Reads the shelf so the page can offer it before anything is imported.
  Future<void> refreshRestored() async {
    try {
      final root = await restoredChatsDirectory();
      restored = await listRestoredArchives(root);
    } on Object {
      restored = const [];
    }
    _changed();
  }

  void setIncludeSettings(bool value) {
    if (busy) return;
    includeSettings = value;
    _changed();
  }

  void setIncludeSecrets(bool value) {
    if (busy) return;
    includeSecrets = value;
    _changed();
  }

  void setIncludeChats(bool value) {
    if (busy) return;
    includeChats = value;
    _changed();
  }

  /// Chooses a file, unpacks it and reads what is inside. Ends at
  /// [RestorePhase.inspecting] with the contents, or at [RestorePhase.idle]
  /// when the person backed out of the picker.
  Future<void> choose() async {
    if (busy) return;
    await _discardStaging();
    archive = null;
    readFailure = null;
    transferFailure = null;
    detail = '';
    bytesDone = 0;
    settingsResult = null;
    secretsResult = null;
    chatsRestored = 0;

    phase = RestorePhase.picking;
    _changed();
    final String? uri;
    try {
      uri = await platform.pickSource();
    } on Object catch (error) {
      _failTransfer(ProjectExportFailure.destination, 'picker: $error');
      return;
    }
    if (uri == null) {
      phase = RestorePhase.idle;
      _changed();
      return;
    }

    phase = RestorePhase.reading;
    _changed();
    final Directory staging;
    try {
      staging = await stagingDirectory();
      await staging.create(recursive: true);
    } on Object catch (error) {
      _failTransfer(ProjectExportFailure.source, 'staging: $error');
      return;
    }
    _staging = staging;

    final ProjectExportResult unpacked;
    try {
      unpacked = await platform.extract(
        uri: uri,
        directory: staging.path,
        onProgress: (bytes) {
          bytesDone = bytes;
          _changed();
        },
      );
    } on Object catch (error) {
      await _discardStaging();
      _failTransfer(ProjectExportFailure.source, 'extract: $error');
      return;
    }
    if (!unpacked.ok) {
      await _discardStaging();
      _failTransfer(
        unpacked.failure ?? ProjectExportFailure.failed,
        unpacked.detail,
      );
      return;
    }

    try {
      archive = await readBackupArchive(staging);
    } on BackupFormatException catch (error) {
      await _discardStaging();
      readFailure = error.failure;
      detail = error.detail;
      phase = RestorePhase.failed;
      _changed();
      return;
    } on Object catch (error) {
      await _discardStaging();
      _failTransfer(ProjectExportFailure.source, 'read: $error');
      return;
    }

    // Only offer what the file actually holds.
    final read = archive!;
    includeSettings = read.hasSettings;
    includeSecrets = read.hasSecrets;
    includeChats = read.hasChats;
    phase = RestorePhase.inspecting;
    _changed();
  }

  /// Puts the chosen parts back. Settings and credentials go where they came
  /// from; conversations go onto this app's read-only shelf.
  Future<void> restore() async {
    final read = archive;
    final staging = _staging;
    if (busy || read == null || staging == null) return;
    phase = RestorePhase.applying;
    detail = '';
    _changed();
    try {
      if (includeSettings && read.hasSettings) {
        final current = await readSettings();
        final merge = mergeSettings(current: current, incoming: read.settings);
        settingsResult = merge;
        if (merge.write.isNotEmpty) await writeSettings(merge.write);
        _changed();
      }
      if (includeSecrets && read.hasSecrets) {
        final current = await readSecrets();
        final merge = mergeSecrets(current: current, incoming: read.secrets);
        secretsResult = merge;
        if (merge.write.isNotEmpty) await writeSecrets(merge.write);
        _changed();
      }
      if (includeChats && read.hasChats) {
        final root = await restoredChatsDirectory();
        await root.create(recursive: true);
        chatsRestored = await restoreChats(
          root: root,
          archive: read,
          source: staging,
          now: _now(),
        );
        _changed();
      }
      // The shelf is read again before "done": a page that says it finished
      // while the list is still loading would show the old count.
      await _discardStaging();
      await refreshRestored();
      phase = RestorePhase.done;
    } on Object catch (error) {
      detail = '$error';
      await _discardStaging();
      phase = RestorePhase.failed;
    }
    _changed();
  }

  Future<void> cancel() async {
    if (!busy) return;
    try {
      await platform.cancel();
    } on Object {
      // The worker checks its own flag; nothing else to do.
    }
    await _discardStaging();
    phase = RestorePhase.idle;
    _changed();
  }

  /// Forgets the inspected file without putting anything back.
  Future<void> discard() async {
    if (busy) return;
    await _discardStaging();
    archive = null;
    readFailure = null;
    transferFailure = null;
    detail = '';
    phase = RestorePhase.idle;
    _changed();
  }

  void _failTransfer(ProjectExportFailure failure, String text) {
    transferFailure = failure;
    detail = text;
    phase = RestorePhase.failed;
    _changed();
  }

  Future<void> _discardStaging() async {
    final staging = _staging;
    _staging = null;
    if (staging == null) return;
    try {
      if (staging.existsSync()) await staging.delete(recursive: true);
    } on Object {
      // The cache is the system's to clear; a leftover costs room, not data.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final staging = _staging;
    _staging = null;
    try {
      if (staging != null && staging.existsSync()) {
        staging.deleteSync(recursive: true);
      }
    } on Object {
      // See above.
    }
    super.dispose();
  }
}
