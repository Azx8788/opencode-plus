// A backup a person takes on purpose (backup-export, 2026-11-23): settings,
// credentials and the conversations of the last N days, in one zip, written
// through the same Storage Access Framework path the project export uses.
//
// Why a window instead of everything: a conversation archive grows without
// bound, and a backup people actually take is one small enough to mail to
// themselves once a month. The window is the only thing that makes the size
// predictable before the file is written.
//
// This file is the part that decides what goes in and what the archive looks
// like; it touches no platform API, so the rules are unit-tested without a
// phone. The controller next to it does the reading and the writing.
import 'dart:convert';
import 'dart:io';

import '../builtin/project_export.dart' show ProjectExportEntry;

/// What a backup carries, and how far back.
class BackupOptions {
  const BackupOptions({
    this.days = 30,
    this.includeSecrets = true,
    this.includeChat = true,
    this.textOnly = false,
  });

  /// The windows the page offers, in days; 0 means every conversation.
  static const dayChoices = <int>[7, 30, 90, 0];

  /// How many days of conversation to keep; 0 keeps all of them.
  final int days;

  /// Credentials: bot tokens, provider keys, saved sign-ins. Plain text in
  /// the archive, because the point is to still have them after the phone is
  /// gone — the page and the archive both say so.
  final bool includeSecrets;

  /// Conversations at all.
  final bool includeChat;

  /// Keep only what was said: tool calls, their outputs and attachments are
  /// dropped. Roughly an order of magnitude smaller on agent-heavy sessions.
  final bool textOnly;

  /// The oldest moment inside the window; null when every conversation is in.
  DateTime? cutoff(DateTime now) =>
      days <= 0 ? null : now.subtract(Duration(days: days));

  BackupOptions copyWith({
    int? days,
    bool? includeSecrets,
    bool? includeChat,
    bool? textOnly,
  }) => BackupOptions(
    days: days ?? this.days,
    includeSecrets: includeSecrets ?? this.includeSecrets,
    includeChat: includeChat ?? this.includeChat,
    textOnly: textOnly ?? this.textOnly,
  );

  Map<String, Object?> toJson() => {
    'days': days,
    'secrets': includeSecrets,
    'chat': includeChat,
    'textOnly': textOnly,
  };
}

/// One conversation on its way into the archive. [messages] are the server's
/// own JSON, already trimmed when the person asked for text only.
class BackupChat {
  const BackupChat({
    required this.id,
    required this.messages,
    this.title,
    this.updated,
  });

  final String id;
  final String? title;

  /// Epoch millis of the last activity, when the server reported one.
  final int? updated;
  final List<Map<String, dynamic>> messages;
}

/// What one archive holds, once it is written.
class BackupBundle {
  const BackupBundle({
    required this.entries,
    required this.sessions,
    required this.messages,
    required this.settings,
    required this.secrets,
  });

  final List<ProjectExportEntry> entries;
  final int sessions;
  final int messages;
  final int settings;
  final int secrets;

  int get bytes => entries.fold(0, (sum, entry) => sum + entry.bytes);

  bool get isEmpty => entries.isEmpty;
}

/// Whether a conversation falls inside the window. A session started before
/// the window but used inside it belongs in the archive: its recent messages
/// are the reason the person still cares about it.
bool chatInWindow(BackupChat chat, DateTime? cutoff) {
  if (cutoff == null) return true;
  final moments = [chat.updated];
  for (final message in chat.messages) {
    final time = message['time'];
    if (time is Map) {
      final created = time['created'];
      if (created is num) moments.add(created.toInt());
    }
  }
  var known = false;
  for (final moment in moments) {
    if (moment == null) continue;
    known = true;
    if (!DateTime.fromMillisecondsSinceEpoch(moment).isBefore(cutoff)) {
      return true;
    }
  }
  // Nothing says when it happened: keeping it costs a file, dropping it
  // loses a conversation nobody can get back.
  return !known;
}

/// One message with everything but its words removed: tool calls, their
/// output, file parts and snapshots. Text parts keep their order, so the
/// transcript still reads like the conversation did.
Map<String, dynamic> textOnlyMessage(Map<String, dynamic> raw) {
  final message = Map<String, dynamic>.from(raw);
  message.remove('files');
  message.remove('snapshot');
  message.remove('patch');
  final content = message['content'];
  if (content is List) {
    message['content'] = [
      for (final part in content)
        if (part is Map && part['type'] == 'text') part,
    ];
  }
  return message;
}

/// "opencode-plus-backup-2026-11-23-30d.zip". The window is in the name so
/// two backups of the same day cannot be mistaken for each other, and the
/// file says what it is before it is opened.
String suggestedBackupName(DateTime now, BackupOptions options) {
  String two(int n) => n.toString().padLeft(2, '0');
  final day = '${now.year}-${two(now.month)}-${two(now.day)}';
  final window = options.days <= 0 ? 'all' : '${options.days}d';
  final secrets = options.includeSecrets ? '-private' : '';
  return 'opencode-plus-backup-$day-$window$secrets.zip';
}

/// A file name a person can read, from a conversation title: no separators,
/// no quotes, no run of spaces, and short enough to leave the date and the id
/// visible in a file list.
String chatFileLabel(String? title, String id) {
  final cleaned = (title ?? '')
      .replaceAll(RegExp(r'[/\\:*?"<>|\s]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final short = cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  final suffix = id.length > 12 ? id.substring(id.length - 12) : id;
  // No title: the id alone, in full, is the only thing that names it.
  return short.isEmpty ? id : '$short-$suffix';
}

/// Writes the archive's files under [staging] and returns them as export
/// entries. The caller hands the entries to the native half, which streams
/// them into the zip the person chose.
Future<BackupBundle> writeBackup({
  required Directory staging,
  required BackupOptions options,
  required Map<String, Object?> settings,
  required Map<String, String> secrets,
  required List<BackupChat> chats,
  required DateTime now,
  String? appVersion,
  String? server,
}) async {
  final config = Directory('${staging.path}/config');
  final chatDir = Directory('${staging.path}/chat');
  await config.create(recursive: true);
  await chatDir.create(recursive: true);

  final entries = <ProjectExportEntry>[];

  Future<void> put(String name, File file) async {
    final length = await file.length();
    entries.add(
      ProjectExportEntry(name: name, source: file.path, bytes: length),
    );
  }

  final settingsFile = File('${config.path}/settings.json');
  await settingsFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(_sorted(settings)),
  );
  await put('config/settings.json', settingsFile);

  if (options.includeSecrets) {
    final secretsFile = File('${config.path}/secrets.json');
    await secretsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_sorted(secrets)),
    );
    await put('config/secrets.json', secretsFile);
  }

  var messageCount = 0;
  if (options.includeChat) {
    for (final chat in chats) {
      final messages = [
        for (final message in chat.messages)
          options.textOnly ? textOnlyMessage(message) : message,
      ];
      messageCount += messages.length;
      final stamp = DateTime.fromMillisecondsSinceEpoch(
        chat.updated ?? now.millisecondsSinceEpoch,
      );
      String two(int n) => n.toString().padLeft(2, '0');
      final day = '${stamp.year}-${two(stamp.month)}-${two(stamp.day)}';
      final file = File(
        '${chatDir.path}/$day-${chatFileLabel(chat.title, chat.id)}.json',
      );
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'id': chat.id,
          'title': chat.title,
          'updated': chat.updated,
          'messages': messages,
        }),
      );
      await put('chat/${file.uri.pathSegments.last}', file);
    }
  }

  final manifest = File('${staging.path}/manifest.json');
  await manifest.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'format': 'opencode-plus-backup',
      'formatVersion': 1,
      'createdAt': now.toUtc().toIso8601String(),
      'app': ?appVersion,
      'server': ?server,
      'selection': options.toJson(),
      'counts': {
        'settings': settings.length,
        'secrets': options.includeSecrets ? secrets.length : 0,
        'sessions': options.includeChat ? chats.length : 0,
        'messages': messageCount,
      },
    }),
  );
  await put('manifest.json', manifest);

  final readme = File('${staging.path}/README.txt');
  await readme.writeAsString(
    _readme(
      options: options,
      chats: chats,
      messageCount: messageCount,
      now: now,
    ),
  );
  await put('README.txt', readme);

  entries.sort((a, b) => a.name.compareTo(b.name));
  return BackupBundle(
    entries: entries,
    sessions: options.includeChat ? chats.length : 0,
    messages: messageCount,
    settings: settings.length,
    secrets: options.includeSecrets ? secrets.length : 0,
  );
}

String _readme({
  required BackupOptions options,
  required List<BackupChat> chats,
  required int messageCount,
  required DateTime now,
}) {
  final window = options.days <= 0
      ? 'every conversation'
      : 'conversations with activity in the last ${options.days} days';
  final buffer = StringBuffer()
    ..writeln('OpenCode Plus backup')
    ..writeln('Taken: ${now.toIso8601String()}')
    ..writeln()
    ..writeln('Contents')
    ..writeln(
      '  manifest.json          what this archive holds and how it was made',
    )
    ..writeln('  config/settings.json   the app settings')
    ..writeln(
      options.includeSecrets
          ? '  config/secrets.json    credentials, in plain text'
          : '  (credentials were left out of this archive)',
    )
    ..writeln('  chat/                  $window')
    ..writeln(
      '                         ${chats.length} conversations, $messageCount messages',
    )
    ..writeln();
  if (options.includeSecrets) {
    buffer
      ..writeln(
        'This archive holds credentials in plain text: anyone who opens it',
      )
      ..writeln(
        'can use them. Keep it somewhere you would keep a password, and do',
      )
      ..writeln('not send it through a chat app.');
    buffer.writeln();
  }
  buffer
    ..writeln('Restoring')
    ..writeln(
      '  There is no import in the app yet. Settings and credentials can be',
    )
    ..writeln(
      '  copied back by hand; conversations are kept as a readable record.',
    )
    ..writeln()
    ..writeln('Text only: ${options.textOnly ? 'yes' : 'no'}');
  return buffer.toString();
}

/// Keys in a stable order, so two backups of the same settings differ only
/// where the settings do.
Map<String, Object?> _sorted(Map<String, Object?> values) {
  final keys = values.keys.toList()..sort();
  return {for (final key in keys) key: values[key]};
}
