import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../domain/subagent_settings.dart';
import '../../../state/connection.dart';
import '../../../state/subagent_settings_controller.dart';
import '../../../state/subagent_settings_store.dart';
import '../../kit/kit.dart';
import 'subagent_model_pool_screen.dart';
import 'subagent_settings_copy.dart';

/// The wiring owns no new connection. Viewing a different saved server can
/// read its local draft but cannot rescope the live conversation transport.
class SubagentSettingsScreen extends StatefulWidget {
  const SubagentSettingsScreen({super.key, required this.controller});
  final ConnectionController controller;

  @override
  State<SubagentSettingsScreen> createState() => _SubagentSettingsScreenState();
}

class _SubagentSettingsScreenState extends State<SubagentSettingsScreen> {
  late SubagentSettingsController _settings;
  String? _signature;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _settings = SubagentSettingsController(
      store: SubagentSettingsStore.shared(widget.controller.store.prefs),
      loadCatalog: widget.controller.readSubagentDraftCatalog,
    );
    widget.controller.addListener(_connectionChanged);
    widget.controller.store.changes.addListener(_connectionChanged);
    _sync();
  }

  void _connectionChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync();
      });
    } else {
      _sync();
    }
  }

  void _sync() {
    final host = widget.controller;
    final servers = <SubagentSettingsServer>[];
    for (final profile in host.store.profiles) {
      if (profile.transientTransport) continue;
      try {
        servers.add(
          SubagentSettingsServer(
            profileID: profile.id,
            name: profile.name,
            binding: subagentSettingsBinding(profile.toJson()),
          ),
        );
      } on SubagentSettingsException {
        // Other backends and migration-pending profiles are not OC2 targets.
      }
    }
    final signature = jsonEncode([
      for (final s in servers) [s.profileID, s.binding, s.name],
      host.profile?.id,
      identityHashCode(host.api),
      identityHashCode(host.profile),
      host.locationRevision,
      host.dataRefreshRevision,
      host.isConnected,
    ]);
    if (_signature == signature) return;
    _signature = signature;
    _settings.updateServers(servers, preferredProfileID: host.profile?.id);
    unawaited(_settings.refresh());
  }

  @override
  void didUpdateWidget(covariant SubagentSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_connectionChanged);
    oldWidget.controller.store.changes.removeListener(_connectionChanged);
    _settings.dispose();
    _signature = null;
    _attach();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_connectionChanged);
    widget.controller.store.changes.removeListener(_connectionChanged);
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SubagentSettingsPage(controller: _settings);
}

/// Rendering and local edits are independently testable without an Android
/// host, an engine install or a paid model call.
class SubagentSettingsPage extends StatelessWidget {
  const SubagentSettingsPage({super.key, required this.controller});
  final SubagentSettingsController controller;

  Future<void> _chooseServer(BuildContext context) async {
    final copy = SubagentSettingsCopy(context);
    final selected = await showKitChoiceSheet<String>(
      context,
      title: copy.server,
      selected: controller.server?.profileID,
      choices: [
        for (final s in controller.servers)
          KitChoice(
            value: s.profileID,
            title: s.name,
            supporting: s.profileID,
            key: ValueKey('subagents-server-${s.profileID}'),
          ),
      ],
    );
    if (selected == null || !context.mounted) return;
    controller.selectServer(selected);
    await controller.refresh();
  }

  Future<void> _chooseScope(BuildContext context) async {
    final copy = SubagentSettingsCopy(context);
    final before = controller.server;
    // Project IDs are non-empty, so the blank value is a local picker sentinel.
    final selected = await showKitChoiceSheet<String>(
      context,
      title: copy.scope,
      selected: controller.projectID ?? '',
      choices: [
        KitChoice(
          value: '',
          title: copy.defaults,
          key: const ValueKey('subagents-scope-defaults'),
        ),
        for (final p in controller.projects)
          KitChoice(
            value: p.id,
            title: p.name.isEmpty ? p.id : p.name,
            supporting: p.directory.isEmpty ? p.id : '${p.id}\n${p.directory}',
            key: ValueKey('subagents-scope-${p.id}'),
          ),
      ],
    );
    if (selected == null || !context.mounted) return;
    if (controller.server?.profileID != before?.profileID ||
        controller.server?.binding != before?.binding) {
      return;
    }
    controller.selectProject(selected.isEmpty ? null : selected);
  }

  Future<void> _editPool(BuildContext context) async {
    final edit = controller.tryBeginPoolEdit();
    if (edit == null) return;
    try {
      await pushKitPage<void>(
        context,
        (_) => SubagentModelPoolScreen(controller: controller, edit: edit),
      );
    } finally {
      controller.cancelPoolEdit(edit);
    }
  }

  Future<void> _inherit(BuildContext context) async {
    final copy = SubagentSettingsCopy(context);
    final edit = controller.tryBeginPoolEdit();
    if (edit == null) return;
    try {
      final selected = await showKitChoiceSheet<bool>(
        context,
        title: copy.inherit,
        subtitle: copy.inheritNote,
        choices: [KitChoice(value: true, title: copy.inherit)],
      );
      if (selected == true && context.mounted) {
        await controller.savePool(edit, null);
      }
    } finally {
      controller.cancelPoolEdit(edit);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final copy = SubagentSettingsCopy(context);
      final state = controller.snapshot;
      final selected = controller.server;
      final project = controller.projects
          .where((p) => p.id == controller.projectID)
          .firstOrNull;
      final busy = controller.saving;
      return KitScreen(
        topBar: KitTopBar(title: copy.title),
        width: KitScreenWidth.reading,
        body: ListView(
          key: const ValueKey('subagents-settings-list'),
          padding: KitScreen.padding(context),
          children: [
            KitNotice(
              key: const ValueKey('subagents-draft-status'),
              title: copy.draft,
              message: copy.draftNote,
            ),
            if (selected == null) KitNotice(message: copy.noServers),
            if (selected != null) ...[
              KitSectionLabel.inline(copy.scope),
              KitRowGroup(
                children: [
                  KitRow(
                    key: const ValueKey('subagents-server'),
                    title: copy.server,
                    supporting: TextSpan(text: selected.name),
                    supportingMaxLines: 2,
                    trailing: const KitChevron(),
                    onTap: busy ? null : () => _chooseServer(context),
                  ),
                  KitRow(
                    key: const ValueKey('subagents-scope'),
                    title: copy.scope,
                    supporting: TextSpan(
                      text: controller.projectID == null
                          ? copy.defaults
                          : project?.name ?? controller.projectID,
                    ),
                    supportingMaxLines: 2,
                    trailing: const KitChevron(),
                    onTap: busy ? null : () => _chooseScope(context),
                  ),
                ],
              ),
              if (controller.error case final failure?)
                KitNotice.error(
                  key: const ValueKey('subagents-settings-error'),
                  message: copy.failure(failure),
                ),
              if (controller.catalogUnavailable)
                KitNotice(
                  key: const ValueKey('subagents-catalogue-unavailable'),
                  message: controller.catalogReadFailed
                      ? copy.catalogueReadFailed
                      : copy.unavailable,
                ),
              KitButton.secondary(
                key: const ValueKey('subagents-refresh'),
                label: copy.refresh,
                working: controller.loading,
                onPressed: busy || controller.loading
                    ? null
                    : controller.refresh,
              ),
              if (state != null) ...[
                if (state.stored)
                  KitNotice(
                    key: const ValueKey('subagents-local-receipt'),
                    message: copy.saved,
                  ),
                KitSectionLabel.inline(copy.pool),
                KitRowGroup(
                  children: [
                    KitRow(
                      key: const ValueKey('subagents-pool'),
                      title: copy.editPool,
                      supporting: TextSpan(
                        text: state.pool.candidates.isEmpty
                            ? copy.emptyPool
                            : copy.count(state.pool.candidates.length),
                      ),
                      supportingMaxLines: 2,
                      trailing: const KitChevron(),
                      onTap: busy || controller.loading
                          ? null
                          : () => _editPool(context),
                    ),
                    if (controller.projectID != null)
                      KitRow(
                        key: const ValueKey('subagents-inheritance'),
                        title: state.inherited ? copy.inherit : copy.ownPool,
                        supporting: TextSpan(
                          text: state.inherited
                              ? copy.text(
                                  'Inherited, not copied',
                                  '动态继承，不是复制当时的值',
                                )
                              : copy.text(
                                  'Tap to follow defaults again',
                                  '点击可恢复跟随全局默认',
                                ),
                        ),
                        supportingMaxLines: 2,
                        onTap: state.inherited || busy
                            ? null
                            : () => _inherit(context),
                      ),
                  ],
                ),
                KitText(copy.emptyNote, role: KitTextRole.secondary),
              ],
            ],
            KitSectionLabel.inline(copy.planned),
            KitRowGroup(
              children: [
                for (final (title, value) in [
                  (copy.text('Launch approval', '启动授权'), copy.perTask),
                  (copy.text('Execution mode', '运行方式'), copy.automatic),
                  (copy.text('Concurrency', '并发数量'), copy.concurrency),
                  (copy.text('Model selection', '模型选择'), copy.selection),
                  (copy.text('Error recovery', '错误恢复'), copy.recovery),
                  (copy.text('Result handling', '结果处理'), copy.delivery),
                  (copy.text('Permission ceiling', '权限上限'), copy.permissions),
                  (copy.text('Nested delegation', '嵌套委派'), copy.nesting),
                ])
                  KitRow(
                    title: title,
                    supporting: TextSpan(text: value),
                    supportingMaxLines: 3,
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
