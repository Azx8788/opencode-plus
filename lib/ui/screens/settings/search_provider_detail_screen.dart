import 'package:flutter/material.dart';

import '../../../domain/search_settings.dart';
import '../../../l10n/app_localizations.dart';
import '../../kit/kit.dart';

/// Search credentials use the server's integration store, not custom LLM
/// configuration. Only the layout is shared with the provider editor.
class SearchProviderDetailScreen extends StatefulWidget {
  const SearchProviderDetailScreen({
    super.key,
    required this.provider,
    required this.settings,
    required this.saveKey,
    required this.select,
    required this.test,
  });

  final SearchProviderOption provider;
  final SearchProviderSettings settings;
  final Future<SearchProviderSettings> Function(String key) saveKey;
  final Future<SearchProviderSettings> Function() select;
  final Future<void> Function() test;

  @override
  State<SearchProviderDetailScreen> createState() =>
      _SearchProviderDetailScreenState();
}

class _SearchProviderDetailScreenState
    extends State<SearchProviderDetailScreen> {
  final _key = TextEditingController();
  late SearchProviderSettings _settings = widget.settings;
  bool _busy = false;
  bool _tested = false;
  String? _error;

  bool get _connected => _settings.providers.any(
    (provider) => provider.id == widget.provider.id && provider.connected,
  );

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _tested = false;
    });
    try {
      await action();
    } catch (_) {
      // Never echo a server exception: authentication errors can quote secrets.
      if (mounted) {
        _error = AppLocalizations.of(context).e7LibraryTheLastActionFailed;
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_key.text.trim().isEmpty) {
      setState(
        () => _error = AppLocalizations.of(context).integrationsKeyEmpty,
      );
      return;
    }
    await _act(() async {
      final settings = await widget.saveKey(_key.text.trim());
      if (!mounted) return;
      _key.clear();
      _settings = settings;
    });
  }

  @override
  void dispose() {
    _key.clear();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = KitTokens.of(context);
    final selected =
        _settings.enabled && _settings.selected == widget.provider.id;
    return KitScreen(
      topBar: KitTopBar(title: widget.provider.name),
      width: KitScreenWidth.reading,
      body: ListView(
        key: const ValueKey('search-provider-detail'),
        padding: KitScreen.padding(context),
        children: [
          KitSectionLabel(l.providerTabConfig),
          KitRowGroup(
            children: [
              KitRow(
                title: l.insightsSearchTitle,
                trailing: KitRowValue(widget.provider.name),
              ),
              KitRow(
                title: _connected
                    ? l.insightsAuthorized
                    : l.insightsNotAuthorized,
                trailing: selected ? KitRowValue(l.insightsSelected) : null,
              ),
            ],
          ),
          KitSectionLabel(l.providerAddConnection, gapBefore: t.space3),
          KitField.secret(
            controller: _key,
            label: l.providerAddApiKey,
            helper: l.integrationsKeyHelper,
            fieldKey: const ValueKey('search-provider-key'),
            enabled: !_busy,
            disabledReason: _busy ? l.globalSessionsWorking : null,
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: t.space3),
          KitButton.primary(
            key: const ValueKey('search-provider-save'),
            label: l.commonSave,
            onPressed: _busy ? null : _save,
          ),
          if (_error != null) KitNotice.error(message: _error!),
          SizedBox(height: t.space3),
          KitText(l.insightsSearchDisclosure, role: KitTextRole.secondary),
          SizedBox(height: t.space3),
          KitButton.secondary(
            key: const ValueKey('search-provider-select'),
            label: selected ? l.insightsSelected : l.providerEnable,
            onPressed: _busy || !_connected || selected
                ? null
                : () => _act(() async {
                    final settings = await widget.select();
                    if (mounted) _settings = settings;
                  }),
          ),
          SizedBox(height: t.space3),
          KitButton.secondary(
            key: const ValueKey('search-provider-test'),
            label: l.insightsSearchTest,
            onPressed: _busy || !_connected || !selected
                ? null
                : () => _act(() async {
                    await widget.test();
                    if (mounted) _tested = true;
                  }),
          ),
          if (_tested) KitNotice(message: l.insightsSearchTestOK),
        ],
      ),
    );
  }
}
