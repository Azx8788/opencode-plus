import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/long_term_memory.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../../state/long_term_memory.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import '../../widgets/product_states.dart';
import 'memory_editor.dart';

Future<MemoryProject?> readMemoryProject(
  ConnectionController connection,
  String? sessionID,
) async {
  final profile = connection.profile;
  final location = connection.locationRevision;
  final repository = connection.repository;
  if (profile == null || repository == null) return null;
  String? id;
  String? label;
  if (sessionID != null) {
    final session = await repository.getSessionDetails(sessionID);
    id = session.projectID;
    label = session.directory;
  } else {
    final project = await repository.loadCurrentProject();
    id = project?.id;
    label = project?.name.isNotEmpty == true
        ? project!.name
        : project?.directory;
  }
  if (location != connection.locationRevision ||
      repository != connection.repository ||
      profile.id != connection.profile?.id ||
      profile.baseUrl != connection.profile?.baseUrl) {
    throw const MemoryException(MemoryFailure.changed);
  }
  if (id == null || id.isEmpty) return null;
  return MemoryProject(
    key: memoryProjectKey(profile.id, profile.baseUrl, id),
    label: label?.isNotEmpty == true ? label! : id,
  );
}

class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key, required this.controller, this.sessionID});
  final ConnectionController controller;
  final String? sessionID;
  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  late final LongTermMemoryStore _store =
      widget.controller.store.longTermMemory;
  late final int _location = widget.controller.locationRevision;
  late final _identity = (
    widget.controller.profile?.id,
    widget.controller.profile?.baseUrl,
  );
  MemoryProject? _project;
  final _search = TextEditingController();
  Object? _error;
  bool _loading = true, _busy = false;
  String _filter = 'all';
  bool get _current =>
      _location == widget.controller.locationRevision &&
      _identity ==
          (widget.controller.profile?.id, widget.controller.profile?.baseUrl);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _store.load();
      try {
        _project = await readMemoryProject(widget.controller, widget.sessionID);
      } catch (_) {
        _project = null;
      } // Global editing is still available; explained below.
    } catch (error) {
      if (mounted) _error = error;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit([MemoryEntry? entry]) => pushKitPage<void>(
    context,
    (_) => MemoryEditor(
      store: _store,
      entry: entry,
      project: _current ? _project : null,
      isCurrent: () => _current,
    ),
  );

  Future<void> _write(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final l = AppLocalizations.of(context);
    final confirmed = await showKitConfirm(
      context,
      title: l.memoryClear,
      body: l.memoryClearBody,
      confirmLabel: l.memoryClear,
      kind: KitConfirmKind.destructive,
      icon: AppIconography.delete,
    );
    if (confirmed && mounted) await _write(_store.clear);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_store, widget.controller]),
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final t = KitTokens.of(context);
      final snapshot = _store.snapshot;
      final project = _current ? _project : null;
      final query = _search.text.trim().toLowerCase();
      final entries =
          snapshot.entries
              .where(
                (e) =>
                    (_filter == 'all' ||
                        (_filter == 'global'
                            ? e.project == null
                            : e.project?.key == project?.key &&
                                  e.project != null)) &&
                    (query.isEmpty ||
                        e.text.toLowerCase().contains(query) ||
                        e.project?.label.toLowerCase().contains(query) == true),
              )
              .toList()
            ..sort((a, b) => b.updated.compareTo(a.updated));
      return KitScreen(
        topBar: KitTopBar(
          title: l.memoryTitle,
          actions: [
            KitAction(
              key: const ValueKey('memory-add'),
              label: l.memoryAdd,
              icon: AppIconography.add,
              onPressed: _loading || !_store.loaded
                  ? null
                  : () => unawaited(_edit()),
              disabledReason: _loading ? l.usageLoading : l.memoryStorageFailed,
            ),
          ],
          menu: [
            KitMenuItem(
              label: l.memoryClear,
              icon: AppIconography.delete,
              destructive: true,
              onSelected: () => unawaited(_clear()),
            ),
          ],
        ),
        width: KitScreenWidth.reading,
        loading: _loading || _busy,
        loadingLabel: l.usageLoading,
        body: SingleChildScrollView(
          key: const ValueKey('memory-content'),
          padding: KitScreen.padding(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KitSurface.panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KitText(l.memoryIntro, role: KitTextRole.secondary),
                    SizedBox(height: t.space2),
                    KitText(l.memoryToolHint, role: KitTextRole.secondary),
                    SizedBox(height: t.space3),
                    if (_store.loaded)
                      KitText(
                        l.memoryCount(
                          snapshot.entries.length,
                          snapshot.applicable(project?.key).length,
                        ),
                        key: const ValueKey('memory-summary'),
                        role: KitTextRole.headline,
                        tabular: true,
                      ),
                  ],
                ),
              ),
              if (_error != null) ...[
                SizedBox(height: t.space3),
                KitNotice.error(
                  title: l.memoryTitle,
                  message: productErrorText(_error!, l10n: l),
                  retry: KitAction(
                    label: l.commonRetry,
                    onPressed: _loading ? null : _load,
                  ),
                ),
              ],
              if (_store.loaded) ...[
                KitSwitchRow(
                  key: const ValueKey('memory-use'),
                  title: l.memoryUse,
                  value: snapshot.enabled,
                  onChanged: _busy
                      ? null
                      : (on) => unawaited(_write(() => _store.setEnabled(on))),
                  disabledReason: _busy ? l.usageLoading : null,
                ),
                if (project == null)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: t.space2),
                    child: KitText(
                      _current ? l.memoryProjectUnknown : l.memoryChanged,
                      role: KitTextRole.caption,
                      tone: KitTextTone.secondary,
                    ),
                  ),
                SizedBox(height: t.space3),
                KitSegmented<String>(
                  selected: _filter,
                  semanticsLabel: l.memoryScope,
                  onChanged: (value) => setState(() => _filter = value),
                  segments: [
                    KitSegment(value: 'all', label: l.memoryAll),
                    KitSegment(value: 'global', label: l.memoryGlobal),
                    KitSegment(
                      value: 'project',
                      label: l.memoryProject,
                      enabled: project != null,
                      disabledReason: l.memoryProjectUnknown,
                    ),
                  ],
                ),
                SizedBox(height: t.space3),
                KitSearchField(
                  key: const ValueKey('memory-search'),
                  label: l.memorySearch,
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(height: t.space3),
                if (entries.isEmpty)
                  KitSurface.panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        KitText(l.memoryEmpty, role: KitTextRole.headline),
                        SizedBox(height: t.space2),
                        KitText(
                          l.memoryEmptyDetail,
                          role: KitTextRole.secondary,
                          tone: KitTextTone.secondary,
                        ),
                      ],
                    ),
                  ),
                for (final entry in entries) ...[
                  KitSurface.panel(
                    child: KitRow(
                      key: ValueKey('memory-entry-${entry.id}'),
                      title: entry.text,
                      titleMaxLines: 4,
                      supporting: TextSpan(
                        text: [
                          entry.project?.label ?? l.memoryGlobal,
                          entry.extracted ? l.memoryExtracted : l.memoryManual,
                          if (!entry.enabled) l.quotaBudgetOff,
                        ].join(' · '),
                      ),
                      supportingMaxLines: 3,
                      trailing: const KitChevron(),
                      onTap: () => unawaited(_edit(entry)),
                    ),
                  ),
                  SizedBox(height: t.space2),
                ],
              ],
              SizedBox(height: t.space4),
              KitText(
                l.memoryHistoryNotice,
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
              ),
            ],
          ),
        ),
      );
    },
  );
}
