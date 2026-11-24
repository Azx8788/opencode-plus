// Wires the backup page to the app: preferences, the keystore, the connected
// server and the same native export channel the project export uses.
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../builtin/project_export.dart' show MethodChannelProjectExport;
import '../state/connection.dart';
import 'backup_chat_reader.dart';
import 'backup_controller.dart';
import 'backup_restore_controller.dart';

/// Builds the page's controller with everything the real app has. Kept apart
/// from the page so a test can build the same controller from fakes.
Future<BackupController> createBackupController(
  ConnectionController connection,
) async {
  String? version;
  try {
    final info = await PackageInfo.fromPlatform();
    version = info.buildNumber.isEmpty
        ? info.version
        : '${info.version}+${info.buildNumber}';
  } on Object {
    // The archive is still useful without a version line.
  }
  return BackupController(
    platform: MethodChannelProjectExport(),
    readSettings: readAppSettings,
    readSecrets: readAppSecrets,
    readChats: (options, now, onProgress) => const BackupChatReader().read(
      connection.api,
      options: options,
      now: now,
      onProgress: onProgress,
    ),
    stagingDirectory: backupStagingDirectory,
    appVersion: version,
    serverLabel: connection.profile?.name,
  );
}

/// Every stored setting, as it is stored. A backup that re-typed values into
/// a schema would break the day a setting changes shape.
Future<Map<String, Object?>> readAppSettings() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)};
}

/// Every credential the app holds: bot token, provider keys, saved server
/// passwords. Written to the archive in plain text, which the page says.
Future<Map<String, String>> readAppSecrets() =>
    const FlutterSecureStorage().readAll();

/// A fresh folder under the cache for one archive's files.
Future<Directory> backupStagingDirectory() async {
  final cache = await getTemporaryDirectory();
  return Directory(
    '${cache.path}/backup-${DateTime.now().microsecondsSinceEpoch}',
  );
}

/// The page's other half: reading an archive back in.
Future<RestoreController> createRestoreController() async => RestoreController(
  platform: MethodChannelProjectExport(),
  stagingDirectory: backupStagingDirectory,
  readSettings: readAppSettings,
  writeSettings: writeAppSettings,
  readSecrets: readAppSecrets,
  writeSecrets: writeAppSecrets,
  restoredChatsDirectory: restoredChatsDirectory,
);

/// Puts settings back as they were stored: the same keys, the same shapes.
/// A key the archive does not hold is left alone, so a setting added after the
/// backup was taken keeps its current value.
Future<void> writeAppSettings(Map<String, Object?> values) async {
  final prefs = await SharedPreferences.getInstance();
  for (final entry in values.entries) {
    final value = entry.value;
    if (value is String) {
      await prefs.setString(entry.key, value);
    } else if (value is bool) {
      await prefs.setBool(entry.key, value);
    } else if (value is int) {
      await prefs.setInt(entry.key, value);
    } else if (value is double) {
      await prefs.setDouble(entry.key, value);
    } else if (value is List) {
      await prefs.setStringList(entry.key, [for (final item in value) '$item']);
    }
  }
}

/// Puts credentials back into Android's keystore.
Future<void> writeAppSecrets(Map<String, String> values) async {
  const storage = FlutterSecureStorage();
  for (final entry in values.entries) {
    await storage.write(key: entry.key, value: entry.value);
  }
}

/// The shelf restored conversations live on: this app's own folder, not
/// OpenCode's, whose schema is not ours to write.
Future<Directory> restoredChatsDirectory() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/restored-chats');
}
