import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/long_term_memory.dart';

/// One serialized, encrypted local vault shared by main/side connections.
/// Preferences contain only a presence bit; never memory text or model output.
class LongTermMemoryStore extends ChangeNotifier {
  LongTermMemoryStore({required this.preferences, required this.secure});
  static const presenceKey = 'oc.longTermMemory.present.v1';
  static const storageKey = 'oc.longTermMemory.v1';
  static final _instances = Expando<LongTermMemoryStore>();
  static LongTermMemoryStore shared(
    SharedPreferences prefs,
    FlutterSecureStorage secure,
  ) => _instances[prefs] ??= LongTermMemoryStore(
    preferences: prefs,
    secure: secure,
  );

  final SharedPreferences preferences;
  final FlutterSecureStorage secure;
  MemorySnapshot _snapshot = const MemorySnapshot();
  MemorySnapshot get snapshot => _snapshot;
  bool loaded = false;
  int revision = 0;
  Future<void> _writes = Future.value();
  Future<void>? _loading;

  bool get managed => preferences.getBool(presenceKey) ?? false;

  Future<void> load() {
    if (loaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final raw = await secure.read(key: storageKey);
      // The presence bit is committed before the first secure write. A failed
      // first write may leave the bit alone. Missing managed data is an error,
      // not an empty vault that a later save may silently overwrite.
      if (raw == null && managed) {
        throw const MemoryException(MemoryFailure.storage);
      }
      final next = raw == null
          ? const MemorySnapshot()
          : MemorySnapshot.decode(raw);
      if (raw != null &&
          !managed &&
          !await preferences.setBool(presenceKey, true)) {
        throw const MemoryException(MemoryFailure.storage);
      }
      _snapshot = next;
      loaded = true;
      revision++;
      notifyListeners();
    } on MemoryException {
      rethrow;
    } catch (_) {
      throw const MemoryException(MemoryFailure.storage);
    }
  }

  Future<void> _change(
    MemorySnapshot Function(MemorySnapshot) update, {
    bool reset = false,
    bool Function()? isCurrent,
  }) {
    final operation = _writes.then((_) async {
      if (!reset) await load();
      if (isCurrent != null && !isCurrent()) {
        throw const MemoryException(MemoryFailure.changed);
      }
      final next = update(_snapshot);
      next.validate();
      try {
        // A crash can never leave encrypted text hidden behind an absent bit.
        if (!managed && !await preferences.setBool(presenceKey, true)) {
          throw const MemoryException(MemoryFailure.storage);
        }
        await secure.write(key: storageKey, value: next.encode());
      } on MemoryException {
        rethrow;
      } catch (_) {
        throw const MemoryException(MemoryFailure.storage);
      }
      _snapshot = next;
      loaded = true;
      revision++;
      notifyListeners();
    });
    _writes = operation.then((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> setEnabled(bool enabled) =>
      _change((old) => MemorySnapshot(entries: old.entries, enabled: enabled));

  String _id() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> save({
    required String text,
    MemoryEntry? previous,
    MemoryProject? project,
    bool enabled = true,
    bool extracted = false,
    String? sourceSessionID,
    bool Function()? isCurrent,
  }) => _change((old) {
    if (previous != null && !old.entries.any((e) => identical(e, previous))) {
      throw const MemoryException(MemoryFailure.changed);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = MemoryEntry(
      id: previous?.id ?? _id(),
      text: text.trim(),
      created: previous?.created ?? now,
      updated: max(now, previous?.created ?? now),
      enabled: enabled,
      project: project,
      extracted: previous?.extracted ?? extracted,
      sourceSessionID: previous?.sourceSessionID ?? sourceSessionID,
      sourceCallID: previous?.sourceCallID,
    );
    return MemorySnapshot(
      enabled: old.enabled,
      entries: List.unmodifiable([
        for (final e in old.entries)
          if (e.id != entry.id) e,
        entry,
      ]),
    );
  }, isCurrent: isCurrent);

  Future<void> saveCandidates(
    List<String> texts, {
    MemoryProject? project,
    required String sourceSessionID,
    required String sourceCallID,
    bool Function()? isCurrent,
  }) => _change((old) {
    if (texts.isEmpty ||
        texts.length > 8 ||
        sourceSessionID.isEmpty ||
        sourceCallID.isEmpty) {
      throw const MemoryException(MemoryFailure.invalid);
    }
    if (old.entries.any((e) => e.sourceCallID == sourceCallID)) {
      throw const MemoryException(MemoryFailure.changed);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return MemorySnapshot(
      enabled: old.enabled,
      entries: List.unmodifiable([
        ...old.entries,
        for (final text in texts)
          MemoryEntry(
            id: _id(),
            text: text.trim(),
            created: now,
            updated: now,
            project: project,
            extracted: true,
            sourceSessionID: sourceSessionID,
            sourceCallID: sourceCallID,
          ),
      ]),
    );
  }, isCurrent: isCurrent);

  Future<void> remove(MemoryEntry entry) => _change((old) {
    if (!old.entries.any((e) => identical(e, entry))) {
      throw const MemoryException(MemoryFailure.changed);
    }
    return MemorySnapshot(
      enabled: old.enabled,
      entries: List.unmodifiable(old.entries.where((e) => e.id != entry.id)),
    );
  });

  Future<void> clear() =>
      _change((old) => MemorySnapshot(enabled: old.enabled), reset: true);
}
