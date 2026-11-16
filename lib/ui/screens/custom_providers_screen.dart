import 'dart:async';

import 'package:flutter/material.dart';

import '../../builtin/builtin_linux.dart';
import '../../builtin/builtin_provider_store.dart';
import '../../builtin/builtin_provider_templates.dart';
import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../builtin/provider_key_ring_store.dart';
import '../../builtin/provider_visibility_store.dart';
import '../../domain/custom_provider.dart' show ProviderProtocol;
import '../../domain/custom_provider_record.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_iconography.dart';
import '../app_theme.dart' show AppStatusTone;
import '../kit/kit.dart';
import 'custom_provider_screen.dart';
import 'provider_models_screen.dart';
import 'provider_test_screen.dart';

AppLocalizations _l10nOf(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// The providers written into the server's own config.
///
/// The form could add one but never show it again, so a typo in the base URL
/// or a key that expired could only be fixed by editing the file on the
/// server. This page is the missing half: it lists what the config holds,
/// opens the same form filled in, tests a saved provider with its own key,
/// and removes one with a backup left behind.
class CustomProvidersScreen extends StatefulWidget {
  const CustomProvidersScreen({
    super.key,
    required this.controller,
    this.linux,
    this.embedded = false,
    this.initialProviderID,
  });

  final ConnectionController controller;

  /// The in-app server bridge. Null means "make one" — instances are cheap.
  final BuiltinLinux? linux;

  /// Body only, for a host that already has a top bar of its own.
  final bool embedded;

  /// A provider some other screen asked for ("this model's provider"): its
  /// form opens once, as soon as the list is read. Null opens nothing.
  final String? initialProviderID;

  @override
  State<CustomProvidersScreen> createState() => _CustomProvidersScreenState();
}

class _CustomProvidersScreenState extends State<CustomProvidersScreen> {
  late final BuiltinLinux _linux = widget.linux ?? BuiltinLinux();
  late final BuiltinProviderStore _store = BuiltinProviderStore(linux: _linux);
  late final ProviderVisibilityStore _visibility = ProviderVisibilityStore(
    widget.controller.store.prefs,
  );
  late final ProviderKeyRingStore _keyRingStore = ProviderKeyRingStore(
    widget.controller.store.prefs,
  );

  CustomProviderCatalogue? _catalogue;
  ResolvedProviderConfig? _resolved;
  Object? _error;
  bool _loading = true;
  bool _busy = false;
  bool _initialOpened = false;
  Set<String> _hidden = const {};

  /// True when this profile is the server the app itself runs, whose files
  /// this app may write.
  bool get _writable => looksLikeInAppServer(widget.controller.profile);

  @override
  void initState() {
    super.initState();
    final profileID = widget.controller.profile?.id;
    if (profileID != null) _hidden = _visibility.load(profileID);
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!_writable) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resolved = await _store.resolve();
      final catalogue = await _store.readRecords(resolved: resolved);
      if (!mounted) return;
      setState(() {
        _resolved = resolved;
        _catalogue = catalogue;
        _loading = false;
      });
      _openInitialOnce();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  /// Opens the provider some other screen asked for, once.
  ///
  /// "Configure this model's provider" used to land on the server's own
  /// provider list. That list is hidden now, so the same tap lands here and
  /// opens the entry whose id the caller named.
  void _openInitialOnce() {
    if (_initialOpened || !mounted) return;
    final id = widget.initialProviderID?.trim().toLowerCase();
    if (id == null || id.isEmpty) return;
    final catalogue = _catalogue;
    if (catalogue == null) return;
    ProviderListEntry? entry;
    for (final candidate in providerListEntries(catalogue)) {
      if (candidate.id.toLowerCase() == id) {
        entry = candidate;
        break;
      }
    }
    if (entry == null || entry.blocked) return;
    _initialOpened = true;
    final target = entry;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _openForm(
          target.record,
          template: target.record == null ? target.template : null,
        ),
      );
    });
  }

  Future<void> _openForm(
    CustomProviderRecord? record, {
    BuiltinProviderTemplate? template,
  }) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CustomProviderScreen(
          controller: widget.controller,
          linux: widget.linux,
          editing: record,
          template: template,
        ),
      ),
    );
    if (saved == true && mounted) await _load();
  }

  /// Tests the saved provider with a real turn inside the server.
  ///
  /// The key is not read here any more, and not sent anywhere: the server
  /// opens the session with its own config, which is the only place the key
  /// needs to be.
  Future<void> _test(CustomProviderRecord record) async {
    final l10n = _l10nOf(context);
    if (record.models.isEmpty) {
      _say(l10n.providerManageNoModel);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProviderTestScreen(
          controller: widget.controller,
          providerID: record.id,
          providerName: record.name,
          models: [for (final model in record.models) model.id],
          autoRun: true,
        ),
      ),
    );
  }

  Future<void> _delete(CustomProviderRecord record) async {
    final l10n = _l10nOf(context);
    final agreed = await showKitConfirm(
      context,
      title: l10n.providerManageDeleteTitle(record.name),
      body: l10n.providerManageDeleteBody,
      confirmLabel: l10n.providerManageDelete,
      kind: KitConfirmKind.destructive,
      icon: AppIconography.delete,
      confirmKey: const ValueKey('provider-delete-confirm'),
    );
    if (!agreed || !mounted) return;
    await _removeProvider(record.id, record.name, currentPath: record.secretPath);
  }

  /// Removes an entry the form cannot open. Its shape is unknown, but its id
  /// is enough for a config-level removal, and the backup still protects it.
  Future<void> _deleteUnreadable(String id) async {
    final l10n = _l10nOf(context);
    final agreed = await showKitConfirm(
      context,
      title: l10n.providerManageDeleteTitle(id),
      body: l10n.providerManageDeleteBody,
      confirmLabel: l10n.providerManageDelete,
      kind: KitConfirmKind.destructive,
      icon: AppIconography.delete,
      confirmKey: const ValueKey('provider-unreadable-delete-confirm'),
    );
    if (!agreed || !mounted) return;
    await _removeProvider(id, id);
  }

  Future<void> _removeProvider(
    String id,
    String name, {
    String? currentPath,
  }) async {
    final l10n = _l10nOf(context);
    setState(() => _busy = true);
    try {
      final profileID = widget.controller.profile?.id;
      final keyRing = profileID == null
          ? null
          : await _keyRingStore.load(
              profileID: profileID,
              providerID: id,
              currentPath: currentPath,
            );
      await _store.remove(id, resolved: _resolved);
      await _store.removeProviderKeyFiles(id, [
        for (final key in keyRing?.keys ?? const []) key.filePath,
        if (currentPath case final path?) path,
      ]);
      if (profileID != null) {
        try {
          await _keyRingStore.save(
            profileID: profileID,
            providerID: id,
            keys: const [],
            activeID: null,
          );
        } catch (_) {
          // Stale display names cannot make a removed provider usable again.
        }
      }
      if (!mounted) return;
      setState(() => _busy = false);
      _say(l10n.providerManageDeleted(name));
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  void _say(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _hide(ProviderListEntry entry) async {
    final profileID = widget.controller.profile?.id;
    if (profileID == null) return;
    final l10n = _l10nOf(context);
    try {
      await _visibility.hide(profileID, entry.id);
      if (!mounted) return;
      setState(() => _hidden = _visibility.load(profileID));
      _say(l10n.providerHiddenDone(entry.name));
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _restoreHidden() async {
    final profileID = widget.controller.profile?.id;
    if (profileID == null) return;
    final l10n = _l10nOf(context);
    try {
      await _visibility.restoreAll(profileID);
      if (!mounted) return;
      setState(() => _hidden = _visibility.load(profileID));
      _say(l10n.providerShowHiddenDone);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10nOf(context);
    return KitScreen(
      width: KitScreenWidth.list,
      topBar: widget.embedded
          ? null
          : KitTopBar(
              title: l10n.providerManageTitle,
              subtitle: widget.controller.profile?.name,
              actions: [
                KitAction(
                  key: const ValueKey('providers-add-top'),
                  label: l10n.providerAddTitle,
                  icon: AppIconography.add,
                  onPressed: _loading ? null : () => _openForm(null),
                ),
                KitAction(
                  key: const ValueKey('providers-refresh'),
                  label: l10n.providerManageRefresh,
                  icon: AppIconography.retry,
                  onPressed: _loading ? null : _load,
                ),
              ],
            ),
      status: _busy
          ? KitStatus(
              kind: KitStatusKind.work,
              icon: AppIconography.waiting,
              message: l10n.providerManageWorking,
              tone: AppStatusTone.progress,
            )
          : null,
      body: ListView(
        key: const ValueKey('custom-providers-list'),
        padding: KitScreen.padding(context),
        children: [
          if (!_writable)
            KitNotice(
              key: const ValueKey('providers-copy-only'),
              tone: AppStatusTone.attention,
              icon: AppIconography.warning,
              message: l10n.providerAddCopyOnly,
            )
          else
            KitNotice(
              key: const ValueKey('providers-intro'),
              icon: AppIconography.info,
              message: l10n.providerManageIntro,
            ),
          ..._body(context, l10n),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context, AppLocalizations l10n) {
    final tokens = KitTokens.of(context);
    final gap = SizedBox(height: tokens.space3);
    if (_error != null) {
      return [
        gap,
        KitStateView.error(
          key: const ValueKey('providers-load-failed'),
          size: KitStateSize.inline,
          title: l10n.providerManageLoadFailed,
          body: '$_error',
          error: _error,
          retry: KitAction(label: l10n.commonRetry, onPressed: _load),
        ),
      ];
    }
    final catalogue = _catalogue;
    if (_loading && catalogue == null) {
      return [gap, const KitSkeletonRows(count: 4)];
    }
    if (!_writable) {
      // A remote server's files are out of reach; the form still earns its
      // keep as a snippet generator, so the door is not closed.
      return [
        gap,
        KitStateView(
          key: const ValueKey('providers-copy-only-state'),
          size: KitStateSize.inline,
          icon: AppIconography.model,
          title: l10n.providerManageTitle,
          body: l10n.providerAddCopyOnly,
          primary: KitAction(
            label: l10n.providerAddTitle,
            icon: AppIconography.add,
            onPressed: () => _openForm(null),
          ),
        ),
      ];
    }
    if (catalogue == null) return const [];
    final allEntries = providerListEntries(catalogue);
    // A shipped template that was never saved exists only as a starting
    // point. "Delete" cannot remove what the server never had, so hiding it
    // from this list is the honest act; configured providers are filtered out
    // of hiding entirely and keep their real delete.
    final entries = [
      for (final entry in allEntries)
        if (entry.configured || !_hidden.contains(entry.id)) entry,
    ];
    final hiddenCount = allEntries
        .where(
          (entry) =>
              entry.template != null &&
              !entry.configured &&
              _hidden.contains(entry.id),
        )
        .length;
    // An unreadable entry the shipped list does not already show still has an
    // id, which is all a config-level removal needs.
    final represented = {for (final entry in allEntries) entry.id};
    final unreadableOnly = [
      for (final id in catalogue.unreadableIDs)
        if (!represented.contains(id)) id,
    ]..sort();
    // Two sources, two sections: a shipped template is a provider whose
    // models come from the server's own catalogue, and a custom one is a
    // channel the person declared. They behave differently on save (one is
    // merged onto a catalogue, the other *is* the catalogue), so a single
    // "configured / available" split hid the difference that matters.
    final builtin = [
      for (final entry in entries)
        if (entry.template != null) entry,
    ];
    final custom = [
      for (final entry in entries)
        if (entry.template == null) entry,
    ];
    List<ProviderListEntry> ordered(List<ProviderListEntry> list) => [
      for (final entry in list)
        if (entry.configured) entry,
      for (final entry in list)
        if (!entry.configured) entry,
    ];
    final configuredCount = entries.where((entry) => entry.configured).length;
    return [
      gap,
      if (builtin.isNotEmpty) ...[
        KitRowGroup(
          margin: EdgeInsets.zero,
          label: l10n.providerGroupBuiltin,
          children: [
            for (final entry in ordered(builtin)) _row(context, l10n, entry),
          ],
        ),
        SizedBox(height: tokens.space2),
        KitText(
          l10n.providerGroupBuiltinHint,
          key: const ValueKey('providers-builtin-hint'),
          role: KitTextRole.caption,
          tone: KitTextTone.secondary,
        ),
      ],
      if (custom.isNotEmpty) ...[
        SizedBox(height: tokens.space4),
        KitRowGroup(
          margin: EdgeInsets.zero,
          label: l10n.providerGroupCustom,
          children: [
            for (final entry in ordered(custom)) _row(context, l10n, entry),
          ],
        ),
        SizedBox(height: tokens.space2),
        KitText(
          l10n.providerGroupCustomHint,
          key: const ValueKey('providers-custom-hint'),
          role: KitTextRole.caption,
          tone: KitTextTone.secondary,
        ),
      ],
      if (configuredCount == 0) ...[
        SizedBox(height: tokens.space3),
        KitText(
          l10n.providerGroupAvailable,
          key: const ValueKey('providers-available-hint'),
          role: KitTextRole.caption,
          tone: KitTextTone.secondary,
        ),
      ],
      if (unreadableOnly.isNotEmpty) ...[
        SizedBox(height: tokens.space3),
        KitRowGroup(
          margin: EdgeInsets.zero,
          children: [
            for (final id in unreadableOnly) _unreadableRow(context, l10n, id),
          ],
        ),
      ],
      if (hiddenCount > 0) ...[
        SizedBox(height: tokens.space3),
        KitRowGroup(
          margin: EdgeInsets.zero,
          children: [
            KitRow(
              key: const ValueKey('providers-restore-hidden'),
              title: l10n.providerShowHidden(hiddenCount),
              supporting: TextSpan(text: l10n.providerShowHiddenHint),
              supportingMaxLines: 2,
              titleAccent: true,
              onTap: _restoreHidden,
            ),
          ],
        ),
      ],
      // The catalogue view keeps its door: it is where every model of every
      // provider sits on one page, with a switch and a test each.
      SizedBox(height: tokens.space4),
      KitRowGroup(
        margin: EdgeInsets.zero,
        children: [
          KitRow(
            key: const ValueKey('providers-open-models'),
            title: l10n.providerModelsTitle,
            supporting: TextSpan(text: l10n.providerModelsHint),
            supportingMaxLines: 2,
            trailing: const KitChevron(),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    ProviderModelsScreen(controller: widget.controller),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _unreadableRow(
    BuildContext context,
    AppLocalizations l10n,
    String id,
  ) => KitRow(
    key: ValueKey('provider-unreadable-$id'),
    title: id,
    supporting: TextSpan(text: l10n.providerManageUnreadableBody),
    supportingMaxLines: 3,
    menuLabel: l10n.providerManageMenu(id),
    menu: [
      KitMenuItem(
        key: ValueKey('provider-delete-unreadable-$id'),
        label: l10n.providerManageDelete,
        icon: AppIconography.delete,
        destructive: true,
        onSelected: () => _deleteUnreadable(id),
      ),
    ],
  );

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    ProviderListEntry entry,
  ) {
    final tokens = KitTokens.of(context);
    final record = entry.record;
    final protocol = switch (entry.protocol) {
      ProviderProtocol.chatCompletions => l10n.providerAddProtocolChat,
      ProviderProtocol.responses => l10n.providerAddProtocolResponses,
      ProviderProtocol.anthropic => l10n.providerAddProtocolAnthropic,
      ProviderProtocol.google => 'Google',
    };
    return KitRow(
      key: ValueKey('provider-row-${entry.id}'),
      title: entry.name,
      supporting: TextSpan(
        text: [
          entry.id,
          protocol,
          if (record == null)
            entry.blocked
                ? l10n.providerManageUnreadableBody
                : l10n.providerNotConfigured
          else
            l10n.providerManageModels(record.models.length),
        ].join(' · '),
      ),
      supportingMaxLines: 3,
      trailing: entry.blocked ? null : const KitChevron(),
      onTap: entry.blocked
          ? null
          : () => _openForm(
              record,
              template: record == null ? entry.template : null,
            ),
      menuLabel: l10n.providerManageMenu(entry.name),
      menu: [
        if (entry.blocked)
          KitMenuItem(
            key: ValueKey('provider-delete-${entry.id}'),
            label: l10n.providerManageDelete,
            icon: AppIconography.delete,
            destructive: true,
            onSelected: () => _deleteUnreadable(entry.id),
          )
        else if (record == null) ...[
          KitMenuItem(
            key: ValueKey('provider-setup-${entry.id}'),
            label: l10n.providerManageSetup,
            icon: AppIconography.edit,
            onSelected: () => _openForm(null, template: entry.template),
          ),
          KitMenuItem(
            key: ValueKey('provider-hide-${entry.id}'),
            label: l10n.providerHide,
            icon: AppIconography.archive,
            onSelected: () => _hide(entry),
          ),
        ] else ...[
          KitMenuItem(
            key: ValueKey('provider-edit-${entry.id}'),
            label: l10n.providerManageEdit,
            icon: AppIconography.edit,
            onSelected: () => _openForm(record),
          ),
          KitMenuItem(
            key: ValueKey('provider-test-${entry.id}'),
            label: l10n.providerManageTest,
            icon: AppIconography.play,
            onSelected: () => _test(record),
          ),
          KitMenuItem(
            key: ValueKey('provider-delete-${entry.id}'),
            label: l10n.providerManageDelete,
            icon: AppIconography.delete,
            destructive: true,
            onSelected: () => _delete(record),
          ),
        ],
      ],
      below: Padding(
        padding: EdgeInsetsDirectional.only(top: tokens.space1),
        child: Text(
          entry.baseUrl,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: KitText.styleOf(context, KitTextRole.caption),
        ),
      ),
    );
  }
}
