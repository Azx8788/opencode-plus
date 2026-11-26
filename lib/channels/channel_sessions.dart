import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The agent conversation a channel conversation is bound to.
///
/// The directory and workspace travel with the session because a session id
/// alone is not enough: OpenCode sessions belong to a project, and answering a
/// QQ message with a session opened in a different folder would send the agent
/// to the wrong tree.
@immutable
class ChannelSessionBinding {
  const ChannelSessionBinding({
    required this.sessionID,
    required this.directory,
    required this.workspace,
    this.boundAt,
  });

  final String sessionID;
  final String directory;
  final String workspace;
  final DateTime? boundAt;

  bool matches({required String directory, required String workspace}) =>
      this.directory == directory && this.workspace == workspace;

  Map<String, Object?> toJson() => {
    'sessionID': sessionID,
    'directory': directory,
    'workspace': workspace,
    if (boundAt != null) 'boundAt': boundAt!.toIso8601String(),
  };

  static ChannelSessionBinding? fromJson(Map<String, Object?> json) {
    final sessionID = json['sessionID']?.toString();
    if (sessionID == null || sessionID.isEmpty) return null;
    return ChannelSessionBinding(
      sessionID: sessionID,
      directory: json['directory']?.toString() ?? '',
      workspace: json['workspace']?.toString() ?? '',
      boundAt: DateTime.tryParse(json['boundAt']?.toString() ?? ''),
    );
  }

  @override
  String toString() =>
      'ChannelSessionBinding($sessionID @ $directory/${workspace.isEmpty ? '-' : workspace})';
}

/// Where a conversation's agent session is remembered.
///
/// [current] is synchronous because the event pump asks "is this session
/// mine?" on every agent event and cannot await there; writes are async and
/// ordered by the caller.
abstract interface class ChannelSessionStore {
  ChannelSessionBinding? get current;

  Future<void> bind(ChannelSessionBinding? binding);

  /// Completes once any persisted binding has been read.
  Future<void> ready();
}

/// A store over a callback pair, used by the Telegram bridge so its existing
/// preferences keys keep working unchanged.
class CallbackChannelSessionStore implements ChannelSessionStore {
  CallbackChannelSessionStore({
    required ChannelSessionBinding? Function() read,
    required Future<void> Function(ChannelSessionBinding? binding) write,
  }) : _read = read,
       _write = write;

  final ChannelSessionBinding? Function() _read;
  final Future<void> Function(ChannelSessionBinding? binding) _write;

  @override
  ChannelSessionBinding? get current => _read();

  @override
  Future<void> bind(ChannelSessionBinding? binding) => _write(binding);

  @override
  Future<void> ready() async {}
}

/// One binding per conversation, persisted with the app's preferences.
class PrefsChannelSessionStore implements ChannelSessionStore {
  PrefsChannelSessionStore({
    required SharedPreferences preferences,
    required String conversationKey,
  }) : _preferences = preferences,
       _storageKey = 'oc.channels.session.$conversationKey';

  final SharedPreferences _preferences;
  final String _storageKey;

  ChannelSessionBinding? _current;
  Future<void>? _loading;

  @override
  ChannelSessionBinding? get current => _current;

  @override
  Future<void> ready() => _loading ??= _load();

  Future<void> _load() async {
    final raw = _preferences.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _current = ChannelSessionBinding.fromJson(
          Map<String, Object?>.from(decoded),
        );
      }
    } on FormatException {
      // An unreadable binding means "start a new conversation", which is
      // recoverable; throwing here would take the channel down.
    }
  }

  @override
  Future<void> bind(ChannelSessionBinding? binding) async {
    _current = binding;
    if (binding == null) {
      await _preferences.remove(_storageKey);
      return;
    }
    await _preferences.setString(_storageKey, jsonEncode(binding.toJson()));
  }
}

/// A store that remembers nothing between runs. Used by tests and by channels
/// whose platform conversation cannot outlive the process.
class EphemeralChannelSessionStore implements ChannelSessionStore {
  ChannelSessionBinding? _current;

  @override
  ChannelSessionBinding? get current => _current;

  @override
  Future<void> bind(ChannelSessionBinding? binding) async => _current = binding;

  @override
  Future<void> ready() async {}
}
