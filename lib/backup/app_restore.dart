// Reading a backup back in (backup-import, 2026-11-23): the other half of
// app_backup.dart. A backup nobody can restore is a souvenir, and the phone
// it was taken from is exactly the phone that gets wiped.
//
// What can come back, and what honestly cannot:
//
// - Settings and credentials go back where they came from: SharedPreferences
//   and Android's keystore. Same keys, same shapes, no schema to re-invent.
// - Conversations do not. Their store belongs to OpenCode, its schema is not
//   ours to write, and a wrong write there breaks the server instead of the
//   archive. They are restored into this app's own read-only shelf instead
//   ([RestoredChat]s under the app's support folder), which is what the page
//   says and what the viewer reads.
//
// This file touches no platform API: the folder it reads is the one the native
// half unpacked, so every rule below is unit-tested without a phone.
import 'dart:convert';
import 'dart:io';

/// The `format` every backup written by this app carries.
const backupArchiveFormat = 'opencode-plus-backup';

/// The newest archive this build reads. A file from a newer app is refused
/// rather than half-read.
const backupArchiveFormatVersion = 1;

/// Why an archive could not be read, in the words the page needs.
enum BackupReadFailure {
  /// No `manifest.json` at the root: not one of ours at all (a photo, a
  /// project export, some other app's zip).
  missing,

  /// A manifest, but not this app's backup.
  notABackup,

  /// Written by a newer app with a format this build cannot read.
  tooNew,

  /// Ours, but a file inside is broken (truncated download, edited by hand).
  damaged,

  /// Nothing in it to put back.
  empty,
}

class BackupFormatException implements Exception {
  const BackupFormatException(this.failure, [this.detail = '']);

  final BackupReadFailure failure;

  /// Technical text for Details only; never shown as the page's copy.
  final String detail;

  @override
  String toString() =>
      'BackupFormatException(${failure.name}'
      '${detail.isEmpty ? '' : ': $detail'})';
}

/// One conversation as the archive holds it: the server's own message JSON,
/// in order, plus the file it came from.
class RestoredChat {
  const RestoredChat({
    required this.id,
    required this.file,
    this.title,
    this.updated,
    this.messages = const [],
  });

  final String id;

  /// The file name inside `chat/`.
  final String file;
  final String? title;

  /// Epoch millis of the last activity, when the archive recorded one.
  final int? updated;
  final List<Map<String, dynamic>> messages;
}

/// A backup that has been unpacked and understood.
class BackupArchive {
  const BackupArchive({
    required this.formatVersion,
    this.createdAt,
    this.appVersion,
    this.server,
    this.days = 0,
    this.textOnly = false,
    this.settings = const {},
    this.secrets = const {},
    this.chats = const [],
    this.damagedChats = 0,
  });

  final int formatVersion;

  /// When the backup was taken, if the archive says.
  final DateTime? createdAt;
  final String? appVersion;

  /// Which server the conversations came from ("This phone").
  final String? server;

  /// The window the person chose: 0 meant every conversation.
  final int days;
  final bool textOnly;

  final Map<String, Object?> settings;

  /// Credentials, still untyped: [mergeSecrets] keeps the strings and counts
  /// the rest as skipped.
  final Map<String, Object?> secrets;
  final List<RestoredChat> chats;

  /// Conversation files that were unreadable and left out.
  final int damagedChats;

  int get messages => chats.fold(0, (sum, chat) => sum + chat.messages.length);
  bool get hasSettings => settings.isNotEmpty;
  bool get hasSecrets => secrets.isNotEmpty;
  bool get hasChats => chats.isNotEmpty;
}

/// Reads an unpacked archive at [root]. Throws [BackupFormatException] with
/// the reason, so the page can say which kind of wrong file this is.
Future<BackupArchive> readBackupArchive(Directory root) async {
  final manifestFile = File('${root.path}/manifest.json');
  if (!manifestFile.existsSync()) {
    throw const BackupFormatException(BackupReadFailure.missing);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(await manifestFile.readAsString());
  } on Object catch (error) {
    throw BackupFormatException(BackupReadFailure.damaged, 'manifest: $error');
  }
  if (decoded is! Map) {
    throw const BackupFormatException(BackupReadFailure.damaged, 'manifest');
  }
  final manifest = Map<String, Object?>.from(decoded);
  if (manifest['format'] != backupArchiveFormat) {
    throw const BackupFormatException(BackupReadFailure.notABackup);
  }
  final version = manifest['formatVersion'];
  if (version is! num) {
    throw const BackupFormatException(
      BackupReadFailure.damaged,
      'formatVersion',
    );
  }
  if (version.toInt() > backupArchiveFormatVersion) {
    throw BackupFormatException(BackupReadFailure.tooNew, '${version.toInt()}');
  }

  final settings = await _readObject(File('${root.path}/config/settings.json'));
  final secrets = await _readObject(File('${root.path}/config/secrets.json'));
  final chats = await _readChats(Directory('${root.path}/chat'));

  final archive = BackupArchive(
    formatVersion: version.toInt(),
    createdAt: _date(manifest['createdAt']),
    appVersion: manifest['app']?.toString(),
    server: manifest['server']?.toString(),
    days: _selection(manifest['selection'], 'days'),
    textOnly: _selection(manifest['selection'], 'textOnly') == 1,
    settings: settings,
    secrets: secrets,
    chats: chats.chats,
    damagedChats: chats.damaged,
  );
  if (!archive.hasSettings && !archive.hasSecrets && !archive.hasChats) {
    throw const BackupFormatException(BackupReadFailure.empty);
  }
  return archive;
}

/// Whether a value can go back into SharedPreferences: strings, numbers,
/// booleans and lists of strings. Anything else came from a newer app and is
/// left alone instead of being flattened into something read back wrong.
bool _storable(Object? value) =>
    value is String ||
    value is num ||
    value is bool ||
    (value is List && value.every((item) => item is String));

/// What writing one archive's settings would do, and how much of it.
class SettingsMerge {
  const SettingsMerge({
    this.write = const {},
    this.added = 0,
    this.changed = 0,
    this.unchanged = 0,
    this.skipped = 0,
  });

  /// The entries to put into SharedPreferences, and only those: a key the
  /// archive does not hold is never deleted, because the app may have added
  /// settings since the backup was taken.
  final Map<String, Object?> write;
  final int added;
  final int changed;
  final int unchanged;

  /// Values this build cannot store (a newer app's shape).
  final int skipped;

  int get total => added + changed + unchanged;
}

SettingsMerge mergeSettings({
  required Map<String, Object?> current,
  required Map<String, Object?> incoming,
}) {
  final write = <String, Object?>{};
  var added = 0, changed = 0, unchanged = 0, skipped = 0;
  for (final entry in incoming.entries) {
    if (!_storable(entry.value)) {
      skipped++;
      continue;
    }
    write[entry.key] = entry.value;
    if (!current.containsKey(entry.key)) {
      added++;
    } else if (_sameValue(current[entry.key], entry.value)) {
      unchanged++;
    } else {
      changed++;
    }
  }
  return SettingsMerge(
    write: write,
    added: added,
    changed: changed,
    unchanged: unchanged,
    skipped: skipped,
  );
}

/// The same for credentials: keystore values are strings or nothing.
class SecretsMerge {
  const SecretsMerge({
    this.write = const {},
    this.added = 0,
    this.changed = 0,
    this.unchanged = 0,
    this.skipped = 0,
  });

  final Map<String, String> write;
  final int added;
  final int changed;
  final int unchanged;
  final int skipped;

  int get total => added + changed + unchanged;
}

SecretsMerge mergeSecrets({
  required Map<String, String> current,
  required Map<String, Object?> incoming,
}) {
  final write = <String, String>{};
  var added = 0, changed = 0, unchanged = 0, skipped = 0;
  for (final entry in incoming.entries) {
    final value = entry.value;
    if (value is! String) {
      skipped++;
      continue;
    }
    write[entry.key] = value;
    if (!current.containsKey(entry.key)) {
      added++;
    } else if (current[entry.key] == value) {
      unchanged++;
    } else {
      changed++;
    }
  }
  return SecretsMerge(
    write: write,
    added: added,
    changed: changed,
    unchanged: unchanged,
    skipped: skipped,
  );
}

/// Where one archive's conversations live inside the restored shelf. Named
/// after the moment the backup was taken, so importing the same file twice
/// replaces its copy instead of piling up a second one.
String restoredFolderName(BackupArchive archive) {
  final at = archive.createdAt?.toUtc();
  if (at != null) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)}'
        '-${two(at.hour)}${two(at.minute)}${two(at.second)}';
  }
  // No timestamp: the ids it holds still give a stable name, so a second
  // import of the same undated file replaces the first.
  var hash = 0x811c9dc5;
  for (final chat in archive.chats) {
    for (final unit in chat.id.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
  }
  return 'undated-${hash.toRadixString(16).padLeft(8, '0')}';
}

/// Copies an archive's conversations from the unpacked [source] into [root],
/// under one folder per backup. Returns how many files were written; a chat
/// that vanished between reading and copying is counted out rather than
/// written empty.
Future<int> restoreChats({
  required Directory root,
  required BackupArchive archive,
  required Directory source,
  DateTime? now,
}) async {
  final target = Directory('${root.path}/${restoredFolderName(archive)}');
  if (target.existsSync()) await target.delete(recursive: true);
  final chatDir = Directory('${target.path}/chat');
  await chatDir.create(recursive: true);
  var written = 0;
  for (final chat in archive.chats) {
    if (!_plainName(chat.file)) continue;
    final from = File('${source.path}/chat/${chat.file}');
    if (!from.existsSync()) continue;
    await from.copy('${chatDir.path}/${chat.file}');
    written++;
  }
  await File('${target.path}/archive.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'format': backupArchiveFormat,
      'formatVersion': archive.formatVersion,
      'createdAt': ?archive.createdAt?.toUtc().toIso8601String(),
      'app': ?archive.appVersion,
      'server': ?archive.server,
      'days': archive.days,
      'textOnly': archive.textOnly,
      'chats': written,
      'messages': archive.messages,
      'importedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    }),
  );
  return written;
}

/// One archive on the restored shelf.
class RestoredArchive {
  const RestoredArchive({
    required this.folder,
    required this.path,
    required this.chats,
    required this.messages,
    this.createdAt,
    this.appVersion,
    this.server,
    this.importedAt,
  });

  final String folder;
  final String path;
  final int chats;
  final int messages;

  /// When the backup was taken, not when it was imported.
  final DateTime? createdAt;
  final String? appVersion;
  final String? server;
  final DateTime? importedAt;
}

/// Every archive on the shelf, newest first.
Future<List<RestoredArchive>> listRestoredArchives(Directory root) async {
  final archives = <RestoredArchive>[];
  if (!root.existsSync()) return archives;
  final List<FileSystemEntity> children;
  try {
    children = root.listSync(followLinks: false);
  } on FileSystemException {
    return archives;
  }
  for (final child in children) {
    if (child is! Directory) continue;
    final meta = File('${child.path}/archive.json');
    if (!meta.existsSync()) continue;
    final Map<String, Object?> values;
    try {
      final decoded = jsonDecode(await meta.readAsString());
      if (decoded is! Map) continue;
      values = Map<String, Object?>.from(decoded);
    } on Object {
      continue;
    }
    archives.add(
      RestoredArchive(
        folder: child.path.substring(child.path.lastIndexOf('/') + 1),
        path: child.path,
        chats: (values['chats'] as num?)?.toInt() ?? 0,
        messages: (values['messages'] as num?)?.toInt() ?? 0,
        createdAt: _date(values['createdAt']),
        appVersion: values['app']?.toString(),
        server: values['server']?.toString(),
        importedAt: _date(values['importedAt']),
      ),
    );
  }
  archives.sort((a, b) {
    final left = a.createdAt ?? a.importedAt;
    final right = b.createdAt ?? b.importedAt;
    if (left == null || right == null) return a.folder.compareTo(b.folder);
    return right.compareTo(left);
  });
  return archives;
}

/// The conversations of one archive on the shelf, newest first.
Future<List<RestoredChat>> readRestoredArchive(String path) async {
  final chats = await _readChats(Directory('$path/chat'));
  chats.chats.sort((a, b) => (b.updated ?? 0).compareTo(a.updated ?? 0));
  return chats.chats;
}

/// What one message said, in the shapes the servers have used: v2's
/// `{info, parts}`, v1's `{role, content}`, and a plain `text`. Parts that are
/// not words (tool calls, files, steps) contribute nothing here; the viewer
/// shows what was said, not what ran.
String messageText(Map<String, dynamic> raw) {
  final buffer = StringBuffer();
  void collect(Object? parts) {
    if (parts is! List) return;
    for (final part in parts) {
      if (part is! Map) continue;
      final text = part['text'];
      if (text is String && text.trim().isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(text.trim());
      }
    }
  }

  collect(raw['parts']);
  if (buffer.isEmpty) collect(raw['content']);
  if (buffer.isEmpty) {
    final text = raw['text'];
    if (text is String) buffer.write(text.trim());
  }
  return buffer.toString();
}

/// Who said it: "user", "assistant", or whatever the server called it.
String messageRole(Map<String, dynamic> raw) {
  final info = raw['info'];
  final source = info is Map ? info : raw;
  for (final key in ['role', 'type']) {
    final value = source[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return 'message';
}

/// When it was said, if the message says.
DateTime? messageTime(Map<String, dynamic> raw) {
  final time = raw['time'];
  final created = time is Map ? time['created'] : null;
  if (created is! num) return null;
  return DateTime.fromMillisecondsSinceEpoch(created.toInt());
}

Future<Map<String, Object?>> _readObject(File file) async {
  if (!file.existsSync()) return const {};
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const BackupFormatException(
        BackupReadFailure.damaged,
        'config: not an object',
      );
    }
    return Map<String, Object?>.from(decoded);
  } on BackupFormatException {
    rethrow;
  } on Object catch (error) {
    throw BackupFormatException(
      BackupReadFailure.damaged,
      '${file.path}: $error',
    );
  }
}

Future<({List<RestoredChat> chats, int damaged})> _readChats(
  Directory dir,
) async {
  if (!dir.existsSync()) return (chats: const <RestoredChat>[], damaged: 0);
  final List<FileSystemEntity> children;
  try {
    children = dir.listSync(followLinks: false);
  } on FileSystemException {
    return (chats: const <RestoredChat>[], damaged: 0);
  }
  final chats = <RestoredChat>[];
  var damaged = 0;
  for (final child in children) {
    if (child is! File || !child.path.endsWith('.json')) continue;
    final name = child.path.substring(child.path.lastIndexOf('/') + 1);
    try {
      final decoded = jsonDecode(await child.readAsString());
      if (decoded is! Map) throw const FormatException('not an object');
      final values = Map<String, dynamic>.from(decoded);
      final id = values['id'];
      if (id is! String || id.isEmpty) throw const FormatException('no id');
      final messages = <Map<String, dynamic>>[];
      final raw = values['messages'];
      if (raw is List) {
        for (final message in raw) {
          if (message is Map) messages.add(Map<String, dynamic>.from(message));
        }
      }
      chats.add(
        RestoredChat(
          id: id,
          file: name,
          title: values['title']?.toString(),
          updated: (values['updated'] as num?)?.toInt(),
          messages: messages,
        ),
      );
    } on Object {
      damaged++;
    }
  }
  chats.sort((a, b) => (a.updated ?? 0).compareTo(b.updated ?? 0));
  return (chats: chats, damaged: damaged);
}

/// A file name that cannot leave the folder it is joined to.
bool _plainName(String name) =>
    name.isNotEmpty &&
    !name.contains('/') &&
    !name.contains('\\') &&
    name != '.' &&
    name != '..';

bool _sameValue(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
  return a == b;
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

int _selection(Object? selection, String key) {
  if (selection is! Map) return 0;
  final value = selection[key];
  if (value is bool) return value ? 1 : 0;
  return value is num ? value.toInt() : 0;
}
