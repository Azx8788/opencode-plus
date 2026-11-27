import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Text taken back from the server's inbox that has not been re-admitted yet.
///
/// Taking a pending steer back is two steps that cannot be made atomic from
/// the client: the server's `DELETE` cancels the item, and a new prompt then
/// carries the words again. A Stop, a page exit or a crash between the two
/// used to leave the text nowhere — the item was gone from the server and the
/// composer had already been cleared. The escrow is that missing home: it is
/// written *before* the cancel and only released once the replacement prompt
/// is admitted (or the person is given the words back).
///
/// An entry is never auto-sent. It is a place to keep the text, not a second
/// send: the only ways out are a confirmed replacement admission, an explicit
/// resend, or the person discarding it.
class SteerEscrowEntry {
  const SteerEscrowEntry({
    required this.id,
    required this.sessionID,
    required this.text,
    required this.at,
  });

  /// The inbox ID the text was taken back from, so a second pass over the
  /// same item cannot escrow it twice.
  final String id;
  final String sessionID;
  final String text;
  final int at;

  Map<String, Object> toJson() => {
    'id': id,
    'sessionID': sessionID,
    'text': text,
    'at': at,
  };

  static SteerEscrowEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id']?.toString() ?? '';
    final sessionID = value['sessionID']?.toString() ?? '';
    final text = value['text']?.toString() ?? '';
    if (id.isEmpty || sessionID.isEmpty || text.trim().isEmpty) return null;
    return SteerEscrowEntry(
      id: id,
      sessionID: sessionID,
      text: text,
      at: (value['at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Persists escrowed steer text alongside the app's other preferences.
class SteerEscrowStore {
  static const _key = 'oc.steerEscrow';

  /// Bounds the blob: this holds prose a person typed in the last minutes,
  /// not a transcript. Oldest entries go first when the cap is reached, and
  /// the cap is generous enough that a real session never reaches it.
  static const maxEntries = 20;

  final SharedPreferences prefs;
  bool _readFailed = false;

  SteerEscrowStore({required this.prefs});

  List<SteerEscrowEntry> read() {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [for (final value in decoded) ?SteerEscrowEntry.fromJson(value)];
    } catch (_) {
      _readFailed = true;
      return const [];
    }
  }

  /// Whether the last read could not be decoded. A store that cannot read
  /// its own data must not be used to claim text is safely held.
  bool get readable => !_readFailed;

  Future<bool> write(List<SteerEscrowEntry> entries) async {
    final kept = [...entries]..sort((a, b) => a.at.compareTo(b.at));
    if (kept.length > maxEntries) {
      kept.removeRange(0, kept.length - maxEntries);
    }
    try {
      return await prefs.setString(
        _key,
        jsonEncode([for (final entry in kept) entry.toJson()]),
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> add(SteerEscrowEntry entry) async {
    final entries = [...read()];
    final index = entries.indexWhere((existing) => existing.id == entry.id);
    if (index >= 0) {
      entries[index] = entry;
    } else {
      entries.add(entry);
    }
    return write(entries);
  }

  Future<bool> remove(String id) => write([
    for (final entry in read())
      if (entry.id != id) entry,
  ]);

  Future<bool> removeSession(String sessionID) => write([
    for (final entry in read())
      if (entry.sessionID != sessionID) entry,
  ]);
}
