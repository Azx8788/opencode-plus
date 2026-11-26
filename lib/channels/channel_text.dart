import 'package:flutter/foundation.dart';

/// Splits [text] into pieces no longer than [maxCodeUnits] UTF-16 code units,
/// never splitting a surrogate pair.
///
/// Telegram caps a message at 4096 UTF-16 code units and QQ's official API
/// caps text at a few hundred; the shared renderer needs one splitter whose
/// guarantee is exact, so each provider supplies its own limit.
List<String> chunkText(String text, {int maxCodeUnits = 3500}) {
  if (text.isEmpty) return const [];
  if (maxCodeUnits < 2) {
    throw ArgumentError.value(maxCodeUnits, 'maxCodeUnits', 'must be >= 2');
  }
  final chunks = <String>[];
  final chunk = <int>[];
  var codeUnits = 0;
  for (final rune in text.runes) {
    final width = rune > 0xffff ? 2 : 1;
    if (codeUnits + width > maxCodeUnits && chunk.isNotEmpty) {
      chunks.add(String.fromCharCodes(chunk));
      chunk.clear();
      codeUnits = 0;
    }
    chunk.add(rune);
    codeUnits += width;
  }
  if (chunk.isNotEmpty) chunks.add(String.fromCharCodes(chunk));
  return List.unmodifiable(chunks);
}

/// A slash-style command, parsed the same way on every channel.
@immutable
class ChannelCommand {
  const ChannelCommand({required this.name, required this.argument});

  /// Lower-case command name without its prefix or a `@botname` suffix.
  final String name;

  /// Everything after the command word, trimmed. May be empty.
  final String argument;

  static const status = 'status';
  static const stop = 'stop';
  static const newSession = 'new';
  static const help = 'help';
  static const start = 'start';
  static const queue = 'queue';

  /// Parses [text] when it starts with one of [prefixes].
  ///
  /// Telegram clients send `/status@some_bot` in groups; the suffix is not
  /// part of the command. A full-width slash is accepted because phone
  /// keyboards produce it and a person who typed "／stop" meant stop.
  static ChannelCommand? parse(
    String text, {
    List<String> prefixes = const ['/'],
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final normalised = trimmed.startsWith('／')
        ? '/${trimmed.substring(1)}'
        : trimmed;
    final matched = prefixes.where(
      (prefix) => prefix.isNotEmpty && normalised.startsWith(prefix),
    );
    if (matched.isEmpty) return null;
    final prefix = matched.first;
    final body = normalised.substring(prefix.length);
    if (body.isEmpty) return null;
    final split = body.indexOf(RegExp(r'\s'));
    final head = split < 0 ? body : body.substring(0, split);
    final argument = split < 0 ? '' : body.substring(split).trim();
    final withoutTarget = head.split('@').first;
    if (withoutTarget.isEmpty) return null;
    return ChannelCommand(
      name: withoutTarget.toLowerCase(),
      argument: argument,
    );
  }

  @override
  String toString() => '/$name${argument.isEmpty ? '' : ' $argument'}';
}

/// Removes a leading `@name` mention from group text.
///
/// OneBot delivers the mention as its own segment, but some implementations
/// also leave the plain text behind; QQ's official group event strips it.
/// Doing this here means the agent never receives "@mybot list files".
String stripLeadingMention(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('@')) return text.trim();
  final space = trimmed.indexOf(RegExp(r'\s'));
  if (space < 0) return '';
  return trimmed.substring(space).trim();
}

/// Replaces known secrets in [text] so a log line or an error dialog can be
/// shown and copied without leaking a token.
///
/// Only exact values are replaced: this is not a heuristic scanner, because a
/// heuristic that guesses wrong either misses a token or mangles a message.
String redactSecrets(String text, Iterable<String> secrets) {
  var result = text;
  for (final secret in secrets) {
    if (secret.length < 8) continue;
    result = result.replaceAll(secret, '***');
  }
  return result;
}

/// A short, stable fingerprint for a message that has no platform id.
///
/// The scope is the conversation plus a coarse time bucket, so a redelivered
/// event within [bucket] is recognised as the same message. The guarantee ends
/// at the bucket boundary and at identical text sent twice inside one bucket:
/// documented in the reliability notes rather than presented as exact.
String messageFingerprint({
  required String conversationId,
  required String senderId,
  required String text,
  required DateTime receivedAt,
  Duration bucket = const Duration(seconds: 30),
}) {
  final slot = receivedAt.millisecondsSinceEpoch ~/ bucket.inMilliseconds;
  return '$conversationId|$senderId|$slot|${text.hashCode}';
}
