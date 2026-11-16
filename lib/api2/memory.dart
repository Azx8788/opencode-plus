import 'dart:convert';

import '../domain/long_term_memory.dart';
import 'client.dart';
import 'transport.dart';

class Api2Memory {
  const Api2Memory(this.client);
  final Api2Client client;

  Future<void> sync(
    String sessionID,
    Future<MemoryPromptContext?> Function(String) source,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final context = await source(sessionID);
      if (context == null)
        return; // No memory has ever been saved on this phone.
      if (!context.isCurrent()) continue;
      final value = context.value;
      if (value != null &&
          utf8.encode(jsonEncode(value)).length >
              MemorySnapshot.maxContextBytes) {
        throw const MemoryException(MemoryFailure.limit);
      }
      final path =
          '/session/${Uri.encodeComponent(sessionID)}/instructions/entries/${MemoryPromptContext.key}';
      try {
        if (value == null) {
          await client.transport.deleteJson(path);
        } else {
          await client.transport.putJson(path, body: {'value': value});
        }
      } on Api2Error catch (error) {
        if (error.statusCode == 405 ||
            error.statusCode == 501 ||
            (error.statusCode == 404 && error.tag != 'SessionNotFoundError')) {
          throw const MemoryException(MemoryFailure.unsupported);
        }
        rethrow;
      }
      // A deletion or scope switch while HTTP was in flight is synchronized
      // again before the prompt can be sent. Never run with a stale snapshot.
      if (context.isCurrent()) return;
    }
    throw const MemoryException(MemoryFailure.changed);
  }
}
