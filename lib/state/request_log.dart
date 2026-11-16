import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/request_log.dart';

/// Bounded local log of prompts this app actually dispatched. Entries are
/// serialized so a burst of sends cannot overwrite one another. A failed
/// write never changes the visible snapshot; a corrupt stored log is never
/// treated as an empty one and must be cleared explicitly.
class RequestLogStore extends ChangeNotifier {
  RequestLogStore(this.preferences);
  static const key = 'oc.requestLog.v1';
  static final _instances = Expando<RequestLogStore>();
  static RequestLogStore shared(SharedPreferences prefs) =>
      _instances[prefs] ??= RequestLogStore(prefs);

  final SharedPreferences preferences;
  RequestLogSnapshot _snapshot = const RequestLogSnapshot(entries: []);
  RequestLogSnapshot get snapshot => _snapshot;
  bool loaded = false;
  Future<void> _writes = Future.value();
  final Random _random = Random.secure();

  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<void> load() async {
    if (loaded) return;
    final raw = preferences.getString(key);
    if (raw != null) _snapshot = RequestLogSnapshot.decode(raw);
    loaded = true;
    notifyListeners();
  }

  Future<void> record({
    required String profileID,
    required String sessionID,
    String? providerID,
    String? modelID,
    String? agent,
    String? variant,
  }) {
    if (profileID.isEmpty || sessionID.isEmpty) return Future.value();
    final operation = _writes.then((_) async {
      final entry = RequestLogEntry(
        id: _id(),
        at: DateTime.now().millisecondsSinceEpoch,
        profileID: profileID,
        sessionID: sessionID,
        providerID: providerID,
        modelID: modelID,
        agent: agent,
        variant: variant,
      );
      final all = <RequestLogEntry>[..._snapshot.entries, entry];
      final overflow = all.length - RequestLogSnapshot.maxEntries;
      final next = RequestLogSnapshot(
        entries: List.unmodifiable(overflow > 0 ? all.skip(overflow) : all),
      );
      if (!await preferences.setString(key, next.encode())) {
        throw StateError('Could not persist request log');
      }
      _snapshot = next;
      loaded = true;
      notifyListeners();
    });
    _writes = operation.then((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> clear() => _writes = _writes.then((_) async {
    if (preferences.containsKey(key) && !await preferences.remove(key)) {
      throw StateError('Could not clear request log');
    }
    _snapshot = const RequestLogSnapshot(entries: []);
    loaded = true;
    notifyListeners();
  });
}
