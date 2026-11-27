import 'package:flutter/foundation.dart';

import '../domain/server_gateway.dart';
import '../domain/settings_scope.dart';
import '../domain/subagent_settings.dart';
import 'subagent_settings_store.dart';

class SubagentPoolEdit {
  SubagentPoolEdit._(this.storage, this.generation);
  final SubagentSettingsEdit storage;
  final int generation;
  SubagentModelPool get pool => storage.before.pool;
}

/// UI owner for local drafts. Every catalog result and edit belongs to an exact
/// server/project generation. This controller intentionally has no apply or
/// launch operation until the engine supplies a real enforcement contract.
class SubagentSettingsController extends ChangeNotifier {
  SubagentSettingsController({required this.store, required this.loadCatalog}) {
    store.addListener(_storeChanged);
  }

  final SubagentSettingsStore store;
  final Future<SubagentSettingsCatalog> Function(SubagentSettingsServer server)
  loadCatalog;
  List<SubagentSettingsServer> servers = const [];
  SubagentSettingsServer? server;
  String? projectID;
  SubagentSettingsSnapshot? snapshot;
  SubagentSettingsCatalog? catalog;
  SubagentSettingsFailure? error;
  bool catalogUnavailable = false;
  bool catalogReadFailed = false;
  bool loading = false;
  bool saving = false;
  bool _disposed = false;
  int _generation = 0;

  SettingsTarget? get target => server == null
      ? null
      : projectID == null
      ? SettingsTarget.connection(server!.profileID)
      : SettingsTarget.project(server!.profileID, projectID!);

  /// Called when saved identities or the live transport/location change. It
  /// invalidates old catalogues without silently connecting another server.
  void updateServers(
    List<SubagentSettingsServer> value, {
    String? preferredProfileID,
  }) {
    final previous = server;
    servers = List.unmodifiable(value);
    server =
        servers.where((s) => s.profileID == previous?.profileID).firstOrNull ??
        servers.where((s) => s.profileID == preferredProfileID).firstOrNull ??
        servers.firstOrNull;
    if (previous?.profileID != server?.profileID ||
        previous?.binding != server?.binding) {
      projectID = null;
    }
    invalidateCatalog();
  }

  void invalidateCatalog() {
    _generation++;
    catalog = null;
    loading = false;
    catalogUnavailable = false;
    catalogReadFailed = false;
    _read();
    _notify();
  }

  void selectServer(String profileID) {
    final next = servers.where((s) => s.profileID == profileID).firstOrNull;
    if (next == null || saving) return;
    server = next;
    projectID = null;
    invalidateCatalog();
  }

  void selectProject(String? id) {
    if (saving) return;
    if (id != null && !projects.any((p) => p.id == id)) return;
    projectID = id;
    _generation++;
    loading = false;
    _read();
    _notify();
  }

  List<WorkspaceProject> get projects {
    final selected = server;
    if (selected == null) return const [];
    final live = {
      for (final p in catalog?.projects ?? <WorkspaceProject>[]) p.id: p,
    };
    try {
      for (final id in store.projectIDs(
        selected.profileID,
        binding: selected.binding,
      )) {
        live.putIfAbsent(
          id,
          () => WorkspaceProject(
            id: id,
            name: id,
            directory: '',
            worktrees: const [],
            updatedAt: 0,
          ),
        );
      }
    } on SubagentSettingsException {
      // A local read failure is shown by _read; it never invents a scope.
    }
    return live.values.toList();
  }

  void _read() {
    snapshot = null;
    error = null;
    final destination = target;
    if (destination == null) return;
    try {
      snapshot = store.read(destination, binding: server!.binding);
    } on SubagentSettingsException catch (failure) {
      error = failure.reason;
    } catch (_) {
      error = SubagentSettingsFailure.corrupt;
    }
  }

  void _storeChanged() {
    if (_disposed || saving) return;
    final before = snapshot?.revision;
    _read();
    if (snapshot?.revision != before) {
      // Another page changed the shared document. Show inherited values now,
      // but require an old editor to reopen rather than overwrite that change.
      _generation++;
      loading = false;
    }
    _notify();
  }

  Future<void> refresh() async {
    final selected = server;
    if (_disposed || selected == null || loading || saving) return;
    final generation = ++_generation;
    catalog = null;
    catalogUnavailable = false;
    catalogReadFailed = false;
    loading = true;
    _notify();
    try {
      await store.refresh();
      if (!_current(generation)) return;
      _read();
      final value = await loadCatalog(selected);
      if (!_current(generation)) return;
      catalog = value;
    } catch (failure) {
      if (!_current(generation)) return;
      catalogUnavailable = true;
      catalogReadFailed =
          failure is! SubagentSettingsException ||
          failure.reason != SubagentSettingsFailure.unavailable;
      _read();
    } finally {
      if (_current(generation)) {
        loading = false;
        _notify();
      }
    }
  }

  SubagentPoolEdit beginPoolEdit() {
    final destination = target;
    if (_disposed || destination == null || saving || snapshot == null) {
      throw const SubagentSettingsException(
        SubagentSettingsFailure.unavailable,
      );
    }
    return SubagentPoolEdit._(
      store.beginEdit(destination, binding: server!.binding),
      _generation,
    );
  }

  SubagentPoolEdit? tryBeginPoolEdit() {
    try {
      return beginPoolEdit();
    } on SubagentSettingsException catch (failure) {
      error = failure.reason;
    } catch (_) {
      error = SubagentSettingsFailure.unavailable;
    }
    _notify();
    return null;
  }

  void cancelPoolEdit(SubagentPoolEdit edit) => store.cancelEdit(edit.storage);

  bool isEditCurrent(SubagentPoolEdit edit) =>
      _current(edit.generation) && edit.storage.before.target == target;

  Future<bool> savePool(SubagentPoolEdit edit, SubagentModelPool? pool) async {
    if (!_current(edit.generation) ||
        saving ||
        edit.storage.before.target != target) {
      cancelPoolEdit(edit);
      return false;
    }
    // Keep/remove unavailable saved entries, but only add exact choices from a
    // current server catalogue. A failed refresh never widens a pool.
    final offered =
        catalog?.candidates ?? const <SubagentModelCandidate, String>{};
    if (pool != null &&
        pool.candidates.any(
          (candidate) =>
              !edit.pool.contains(candidate) && !offered.containsKey(candidate),
        )) {
      cancelPoolEdit(edit);
      error = SubagentSettingsFailure.unavailable;
      _notify();
      return false;
    }
    saving = true;
    error = null;
    _notify();
    try {
      final value = await store.save(edit.storage, pool);
      if (!_current(edit.generation)) return false;
      snapshot = value;
      return true;
    } on SubagentSettingsException catch (failure) {
      if (_current(edit.generation)) error = failure.reason;
      return false;
    } catch (_) {
      if (_current(edit.generation)) {
        error = SubagentSettingsFailure.storageFailed;
      }
      return false;
    } finally {
      saving = false;
      _notify();
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    store.removeListener(_storeChanged);
    super.dispose();
  }
}
