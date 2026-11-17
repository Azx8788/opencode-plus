import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/task_trace.dart';

/// Durable per-server trace cache. Not a prompt log. It stores only the
/// plugin's restricted projection, and never overwrites unread/corrupt data.
class TaskTraceStore extends ChangeNotifier {
  TaskTraceStore(this.preferences, this.scope);
  static final _instances = Expando<Map<String, TaskTraceStore>>();
  static TaskTraceStore shared(
    SharedPreferences prefs,
    String profileID,
    String origin,
  ) {
    final scope = sha256.convert(utf8.encode('$profileID\n$origin')).toString();
    final stores = _instances[prefs] ??= {};
    return stores[scope] ??= TaskTraceStore(prefs, scope);
  }

  final SharedPreferences preferences;
  final String scope;
  String get key => 'oc.taskTrace.$scope';
  TaskTraceGraph graph = TaskTraceGraph();
  List<Map<String, dynamic>> _events = [];
  bool loaded = false, truncated = false;
  Object? error;
  Future<void> _writes = Future.value();
  int revision = 0;
  int? _serverAnchor;
  final _passage = Stopwatch();
  int? get serverNow => _serverAnchor == null
      ? null
      : _serverAnchor! + _passage.elapsedMilliseconds;
  void anchor(int? at) {
    if (at == null || at <= 0) return;
    _serverAnchor = at;
    _passage
      ..reset()
      ..start();
  }

  void unavailable(Object problem) {
    error = problem;
    notifyListeners();
  }

  Future<void> load() async {
    if (loaded) return;
    final raw = preferences.getString(key);
    if (raw != null) {
      final value = jsonDecode(raw);
      if (value is! Map || value['version'] != 1 || value['events'] is! List)
        throw const FormatException('Unreadable task trace');
      _events = (value['events'] as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      truncated = value['truncated'] == true;
      graph = TaskTraceGraph();
      for (final event in _events) {
        graph.add(event);
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> append(
    Iterable<Map<String, dynamic>> incoming, {
    bool incomplete = false,
  }) {
    final additions = incoming.toList();
    final work = _writes.then((_) async {
      await load();
      final seen = {
        for (final e in _events)
          if (e['id'] is String) e['id'] as String,
      };
      final all = [
        ..._events,
        ...additions.where(
          (e) => e['id'] is! String || seen.add(e['id'] as String),
        ),
      ];
      // Do not prune arbitrary roots out from beneath their children. A full
      // cache is explicitly partial; the authoritative history stays server-side.
      final next = all.take(10000).toList();
      final clipped = truncated || incomplete || all.length > next.length;
      final projection = TaskTraceGraph();
      for (final e in next) {
        projection.add(e);
      }
      if (!await preferences.setString(
        key,
        jsonEncode({'version': 1, 'events': next, 'truncated': clipped}),
      )) {
        throw const FormatException('Task history could not be saved');
      }
      _events = next;
      graph = projection;
      truncated = clipped;
      revision++;
      error = null;
      notifyListeners();
    });
    _writes = work.then(
      (_) {},
      onError: (Object e) {
        error = e;
        notifyListeners();
      },
    );
    return work;
  }
}
