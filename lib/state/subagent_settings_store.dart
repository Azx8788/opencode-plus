import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/settings_scope.dart';
import '../domain/subagent_settings.dart';

/// A profile's non-secret endpoint identity, not its presentation name. Changing
/// an endpoint/account cannot silently reuse a draft for a different server.
String subagentSettingsBinding(Map<String, dynamic> profile) {
  final uri = Uri.tryParse(profile['baseUrl'] as String? ?? '');
  if (profile['backend'] != 'openCode' ||
      profile['flavor'] != 'v2' ||
      profile['requiresOpenCode2Migration'] == true ||
      profile['openCode2HistoryPending'] == true ||
      uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      profile['username'] is! String) {
    throw const SubagentSettingsException(SubagentSettingsFailure.unavailable);
  }
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            uri.scheme,
            uri.host,
            uri.port,
            uri.path.replaceFirst(RegExp(r'/+$'), ''),
            profile['username'],
            profile['backend'],
            profile['flavor'],
          ]),
        ),
      )
      .toString();
}

class SubagentSettingsEdit {
  SubagentSettingsEdit._(this.before, this.binding, this._raw);
  final SubagentSettingsSnapshot before;
  final String binding;
  final String? _raw;
}

/// One serialized writer per preference store. Saves only the draft; it never
/// connects, patches server config, changes models or launches a child.
class SubagentSettingsStore extends ChangeNotifier {
  factory SubagentSettingsStore.shared(SharedPreferences preferences) =>
      _owners[preferences] ??= SubagentSettingsStore._(preferences);

  SubagentSettingsStore._(this.preferences);
  static final _owners = Expando<SubagentSettingsStore>();
  static const maxDocumentBytes = 2 * 1024 * 1024;
  static const maxProjects = 1000;
  static String keyFor(String profileID) => 'oc.subagentSettings.v1.$profileID';

  final SharedPreferences preferences;
  final _writes = <String, Future<void>>{};
  final _closed = <String>{};
  final _unverified = <String>{};
  final _writing = <String>{};
  final _issued = HashSet<SubagentSettingsEdit>.identity();

  /// Close admission before profile deletion discovers its keys. Keep the
  /// fence after deletion so a retained screen cannot resurrect preferences.
  static Future<void> closeProfile(SharedPreferences preferences, String id) {
    final owner = SubagentSettingsStore.shared(preferences);
    owner._closed.add(id);
    owner._issued.removeWhere((edit) => edit.before.target.profileId == id);
    return owner._writes[id] ?? Future<void>.value();
  }

  void _checkTarget(SettingsTarget target, String binding) {
    final id = target.profileId;
    if (id == null ||
        id.isEmpty ||
        _closed.contains(id) ||
        !const [
          SettingOwnerKind.connection,
          SettingOwnerKind.project,
        ].contains(target.kind)) {
      throw const SubagentSettingsException(
        SubagentSettingsFailure.staleTarget,
      );
    }
    if (target.kind == SettingOwnerKind.project) {
      SubagentModelCandidate.validateID(target.projectId ?? '');
    }
    if (_unverified.contains(id)) {
      throw const SubagentSettingsException(
        SubagentSettingsFailure.storageFailed,
      );
    }
    try {
      final raw = preferences.get('oc.profiles');
      final profiles = raw is String ? jsonDecode(raw) : null;
      final matches = profiles is List
          ? profiles.whereType<Map>().where((p) => p['id'] == id).toList()
          : const <Map>[];
      if (matches.length != 1 ||
          subagentSettingsBinding(Map<String, dynamic>.from(matches.single)) !=
              binding) {
        throw const SubagentSettingsException(
          SubagentSettingsFailure.staleTarget,
        );
      }
    } on SubagentSettingsException {
      rethrow;
    } catch (_) {
      throw const SubagentSettingsException(
        SubagentSettingsFailure.staleTarget,
      );
    }
  }

  String? _raw(String profileID) {
    final value = preferences.get(keyFor(profileID));
    if (value != null &&
        (value is! String || utf8.encode(value).length > maxDocumentBytes)) {
      throw const SubagentSettingsException(SubagentSettingsFailure.corrupt);
    }
    return value as String?;
  }

  _Document _readDocument(String? raw, String binding) {
    if (raw == null) return _Document.empty(binding);
    try {
      final doc = _Document.fromJson(jsonDecode(raw));
      if (doc.binding != binding) {
        throw const SubagentSettingsException(
          SubagentSettingsFailure.staleTarget,
        );
      }
      return doc;
    } on SubagentSettingsException {
      rethrow;
    } catch (_) {
      // Never replace unreadable authorization drafts with permissive defaults.
      throw const SubagentSettingsException(SubagentSettingsFailure.corrupt);
    }
  }

  SubagentSettingsSnapshot read(
    SettingsTarget target, {
    required String binding,
  }) {
    _checkTarget(target, binding);
    final raw = _raw(target.profileId!);
    return _readDocument(raw, binding).snapshot(target, stored: raw != null);
  }

  List<String> projectIDs(String profileID, {required String binding}) {
    _checkTarget(SettingsTarget.connection(profileID), binding);
    return List.unmodifiable(
      _readDocument(_raw(profileID), binding).projects.keys,
    );
  }

  Future<void> refresh() async {
    try {
      await Future.wait(_writes.values.toList());
      await preferences.reload();
      _unverified.removeWhere((id) => !_writing.contains(id));
    } catch (_) {
      throw const SubagentSettingsException(
        SubagentSettingsFailure.storageFailed,
      );
    }
  }

  SubagentSettingsEdit beginEdit(
    SettingsTarget target, {
    required String binding,
  }) {
    final snapshot = read(target, binding: binding);
    final edit = SubagentSettingsEdit._(
      snapshot,
      binding,
      _raw(target.profileId!),
    );
    _issued.add(edit);
    return edit;
  }

  void cancelEdit(SubagentSettingsEdit edit) => _issued.remove(edit);

  /// Null removes a project's override; an explicit empty pool remains empty.
  /// Compare the whole document so an inherited edit cannot overwrite a newly
  /// saved server default. A refusal never publishes an optimistic snapshot.
  Future<SubagentSettingsSnapshot> save(
    SubagentSettingsEdit edit,
    SubagentModelPool? pool,
  ) {
    final target = edit.before.target;
    final id = target.profileId!;
    if (!_issued.remove(edit)) {
      return Future.error(
        const SubagentSettingsException(SubagentSettingsFailure.staleTarget),
      );
    }
    if (pool == null && target.kind != SettingOwnerKind.project) {
      return Future.error(
        const SubagentSettingsException(SubagentSettingsFailure.unavailable),
      );
    }
    final result = (_writes[id] ?? Future<void>.value()).then((_) async {
      _checkTarget(target, edit.binding);
      try {
        // Detect edits made by another preferences client since beginEdit,
        // rather than comparing only this object's potentially stale cache.
        await preferences.reload();
      } catch (_) {
        _unverified.add(id);
        throw const SubagentSettingsException(
          SubagentSettingsFailure.storageFailed,
        );
      }
      _checkTarget(target, edit.binding);
      if (_raw(id) != edit._raw) {
        throw const SubagentSettingsException(SubagentSettingsFailure.conflict);
      }
      final before = _readDocument(edit._raw, edit.binding);
      if (before.revision >= 9007199254740990) {
        throw const SubagentSettingsException(
          SubagentSettingsFailure.storageFailed,
        );
      }
      final projects = {...before.projects};
      if (target.kind == SettingOwnerKind.project) {
        if (pool == null) {
          projects.remove(target.projectId!);
        } else {
          projects[target.projectId!] = pool;
        }
      }
      final next = _Document(
        binding: edit.binding,
        revision: before.revision + 1,
        defaults: target.kind == SettingOwnerKind.connection
            ? pool!
            : before.defaults,
        projects: projects,
      );
      final encoded = jsonEncode(next.toJson());
      if (projects.length > maxProjects ||
          utf8.encode(encoded).length > maxDocumentBytes) {
        throw const SubagentSettingsException(
          SubagentSettingsFailure.storageFailed,
        );
      }
      try {
        _writing.add(id);
        _unverified.add(id);
        if (!await preferences.setString(keyFor(id), encoded)) {
          throw const SubagentSettingsException(
            SubagentSettingsFailure.storageFailed,
          );
        }
        // Read platform truth, not SharedPreferences' pre-ack optimistic cache.
        await preferences.reload();
        _unverified.remove(id);
        _checkTarget(target, edit.binding);
        if (_raw(id) != encoded) {
          throw const SubagentSettingsException(
            SubagentSettingsFailure.conflict,
          );
        }
      } catch (error) {
        try {
          await preferences.reload();
          _unverified.remove(id);
        } catch (_) {}
        if (error is SubagentSettingsException) rethrow;
        throw const SubagentSettingsException(
          SubagentSettingsFailure.storageFailed,
        );
      } finally {
        _writing.remove(id);
      }
      notifyListeners();
      return next.snapshot(target, stored: true);
    });
    _writes[id] = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

class _Document {
  _Document({
    required this.binding,
    required this.revision,
    required this.defaults,
    required this.projects,
  });

  factory _Document.empty(String binding) => _Document(
    binding: binding,
    revision: 0,
    defaults: SubagentModelPool(const []),
    projects: const {},
  );

  final String binding;
  final int revision;
  final SubagentModelPool defaults;
  final Map<String, SubagentModelPool> projects;

  factory _Document.fromJson(Object? value) {
    if (value is! Map ||
        value['version'] != 1 ||
        value['binding'] is! String ||
        value['revision'] is! int ||
        value['revision'] < 0 ||
        value['revision'] > 9007199254740990 ||
        value['projects'] is! Map ||
        (value['projects'] as Map).length > SubagentSettingsStore.maxProjects) {
      throw const FormatException('Invalid subagent settings');
    }
    final projects = <String, SubagentModelPool>{};
    for (final entry in (value['projects'] as Map).entries) {
      if (entry.key is! String) {
        throw const FormatException('Invalid project ID');
      }
      SubagentModelCandidate.validateID(entry.key as String);
      projects[entry.key as String] = SubagentModelPool.fromJson(entry.value);
    }
    return _Document(
      binding: value['binding'] as String,
      revision: value['revision'] as int,
      defaults: SubagentModelPool.fromJson(value['defaults']),
      projects: projects,
    );
  }

  SubagentSettingsSnapshot snapshot(
    SettingsTarget target, {
    required bool stored,
  }) {
    final project = target.kind == SettingOwnerKind.project;
    final override = project ? projects[target.projectId] : null;
    return SubagentSettingsSnapshot(
      target: target,
      pool: override ?? defaults,
      inherited: project && override == null,
      stored: stored,
      revision: revision,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'binding': binding,
    'revision': revision,
    'defaults': defaults.toJson(),
    'projects': {
      for (final entry in projects.entries) entry.key: entry.value.toJson(),
    },
  };
}
