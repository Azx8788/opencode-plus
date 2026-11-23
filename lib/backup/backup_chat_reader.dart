// Reads conversations for a backup out of the connected server, through the
// same gateway the chat screen uses, and keeps the server's own JSON: a
// backup that re-serialised the app's models would lose whatever the models
// do not carry (tool metadata, provider quirks, fields added by a newer
// server), and the point of an archive is that it is still right later.
import '../api2/client.dart';
import '../api2/gateway.dart';
import '../api2/models.dart';
import '../domain/server_gateway/interfaces.dart';
import 'app_backup.dart';

/// What one read produced.
class BackupChatRead {
  const BackupChatRead({
    this.chats = const [],
    this.skipped = 0,
    this.unsupported = false,
    this.error,
  });

  final List<BackupChat> chats;

  /// Conversations whose messages could not be read; they are left out
  /// rather than written empty.
  final int skipped;

  /// The connection is not one this can read (nothing is wrong with it).
  final bool unsupported;

  /// The failure that ended the read early, in words for Details.
  final String? error;

  bool get ok => error == null;
}

/// How far the read got, for the page's progress line.
typedef BackupChatProgress = void Function(int done, int total);

class BackupChatReader {
  const BackupChatReader({
    this.sessionPageSize = 100,
    this.messagePageSize = 200,
    this.maxSessions = 500,
  });

  final int sessionPageSize;
  final int messagePageSize;

  /// A ceiling: a backup that walks ten thousand conversations is not a
  /// backup anyone waits for, and the window already bounds the useful set.
  final int maxSessions;

  Future<BackupChatRead> read(
    ServerGateway? api, {
    required BackupOptions options,
    required DateTime now,
    BackupChatProgress? onProgress,
    bool Function()? stopped,
  }) async {
    if (api is! Api2Gateway) {
      return const BackupChatRead(unsupported: true);
    }
    final client = api.client;
    final cutoff = options.cutoff(now);
    final selected = <Api2Session>[];
    String? cursor;
    try {
      while (selected.length < maxSessions) {
        final page = await client.sessions(
          limit: sessionPageSize,
          cursor: cursor,
        );
        for (final session in page.data) {
          final updated = session.time.updated;
          final created = session.time.created;
          final recent =
              cutoff == null ||
              (updated != null &&
                  !DateTime.fromMillisecondsSinceEpoch(
                    updated,
                  ).isBefore(cutoff)) ||
              (created != null &&
                  !DateTime.fromMillisecondsSinceEpoch(
                    created,
                  ).isBefore(cutoff));
          if (recent) selected.add(session);
        }
        if (!page.hasNext) break;
        cursor = page.nextCursor;
        if (cursor == null) break;
        // Newest first on every server seen so far; once a whole page is
        // older than the window there is nothing further back to keep.
        if (cutoff != null && page.data.every((s) => _olderThan(s, cutoff))) {
          break;
        }
      }
    } on Object catch (error) {
      return BackupChatRead(error: '$error', unsupported: false);
    }

    selected.sort(
      (a, b) => (b.time.updated ?? 0).compareTo(a.time.updated ?? 0),
    );
    final chats = <BackupChat>[];
    var skipped = 0;
    onProgress?.call(0, selected.length);
    for (var index = 0; index < selected.length; index++) {
      if (stopped?.call() ?? false) break;
      final session = selected[index];
      try {
        chats.add(
          BackupChat(
            id: session.id,
            title: session.title,
            updated: session.time.updated,
            messages: await _messages(client, session.id),
          ),
        );
      } on Object {
        skipped++;
      }
      onProgress?.call(index + 1, selected.length);
    }
    return BackupChatRead(chats: chats, skipped: skipped);
  }

  static bool _olderThan(Api2Session session, DateTime cutoff) {
    final updated = session.time.updated;
    if (updated == null) return false;
    return DateTime.fromMillisecondsSinceEpoch(updated).isBefore(cutoff);
  }

  Future<List<Map<String, dynamic>>> _messages(
    Api2Client client,
    String sessionID,
  ) async {
    final messages = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final page = await client.messages(
        sessionID,
        limit: messagePageSize,
        cursor: cursor,
      );
      for (final message in page.data) {
        if (message.raw.isNotEmpty) messages.add(message.raw);
      }
      cursor = page.hasNext ? page.nextCursor : null;
    } while (cursor != null);
    messages.sort((a, b) {
      final left = _createdAt(a);
      final right = _createdAt(b);
      return left.compareTo(right);
    });
    return messages;
  }

  static int _createdAt(Map<String, dynamic> message) {
    final time = message['time'];
    if (time is Map) {
      final created = time['created'];
      if (created is num) return created.toInt();
    }
    return 0;
  }
}
