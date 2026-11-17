import 'dart:async';

import 'package:flutter/material.dart';

import '../../../api2/gateway.dart';
import '../../../api2/search_settings.dart';
import '../../../builtin/builtin_linux.dart';
import '../../../builtin/insights/insights_install.dart';
import '../../../domain/search_settings.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/connection.dart';
import '../../kit/kit.dart';
import '../../widgets/product_states.dart';
import 'search_provider_detail_screen.dart';

/// Search settings are bound to the exact connected server and location.
/// Catalogue, authorization, selection and live verification are distinct.
class SearchProviderScreen extends StatefulWidget {
  const SearchProviderScreen({super.key, required this.controller});
  final ConnectionController controller;
  @override
  State<SearchProviderScreen> createState() => _SearchProviderScreenState();
}

class _SearchProviderScreenState extends State<SearchProviderScreen> {
  SearchProviderSettings? _settings;
  Object? _error;
  bool _busy = false;
  bool _installed = false;
  bool _tested = false;
  Api2Gateway? _owner;
  int? _location;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  bool _current(Api2Gateway api, int location) =>
      mounted &&
      identical(widget.controller.api, api) &&
      widget.controller.locationRevision == location;

  Future<void> _act(
    Future<void> Function(Api2Gateway api, int location) action,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _tested = false;
    });
    try {
      final api = await widget.controller.prepareActionTransport();
      if (api is! Api2Gateway) {
        throw const FormatException('Search settings need OpenCode V2');
      }
      final location = widget.controller.locationRevision;
      _owner = api;
      _location = location;
      await action(api, location);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _act((api, location) async {
    final settings = await Api2SearchSettings(api.client).load();
    if (_current(api, location)) setState(() => _settings = settings);
  });

  Future<void> _select(String? id) => _act((api, location) async {
    final settings = await Api2SearchSettings(api.client).select(id);
    if (_current(api, location)) setState(() => _settings = settings);
  });

  Future<void> _connect(SearchProviderOption provider) async {
    if (_busy) return;
    final api = _owner;
    final location = _location;
    final repository = widget.controller.repository;
    final settings = _settings;
    if (api == null ||
        location == null ||
        repository == null ||
        settings == null) {
      return;
    }
    void requireCurrent() {
      if (!_current(api, location) ||
          !identical(widget.controller.repository, repository)) {
        throw const FormatException('The connected server changed');
      }
    }

    await pushKitPage<void>(
      context,
      (_) => SearchProviderDetailScreen(
        provider: provider,
        settings: settings,
        saveKey: (key) async {
          requireCurrent();
          final integrations = await repository.listIntegrations();
          requireCurrent();
          final integration = integrations
              .where((item) => item.id == provider.id)
              .firstOrNull;
          if (integration == null ||
              !integration.methods.any((method) => method.type == 'key')) {
            throw const FormatException(
              'This server does not offer API key authentication',
            );
          }
          await repository.connectIntegrationKey(provider.id, key);
          requireCurrent();
          return Api2SearchSettings(api.client).load();
        },
        select: () async {
          requireCurrent();
          return Api2SearchSettings(api.client).select(provider.id);
        },
        test: () async {
          requireCurrent();
          final result = await api.searchWeb(
            'web search documentation',
            providerID: provider.id,
          );
          requireCurrent();
          if (result.results.isEmpty) {
            throw const FormatException('Search returned no sources');
          }
        },
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _test() => _act((api, location) async {
    final id = _settings?.selected;
    if (id == null) {
      throw const FormatException('Select a search provider first');
    }
    final result = await api.searchWeb(
      'web search documentation',
      providerID: id,
    );
    if (result.results.isEmpty) {
      throw const FormatException('Search returned no sources');
    }
    if (_current(api, location)) setState(() => _tested = true);
  });

  Future<void> _install() => _act((api, location) async {
    if (!BuiltinLinux.managesServerUrl(api.transport.serverRoot)) {
      throw const FormatException(
        'Only the managed in-app runtime can be installed here',
      );
    }
    final result = await api.runShellCommand(
      insightsInstallScript(),
      timeout: const Duration(seconds: 30),
    );
    if (result.exitCode != 0) {
      throw const FormatException('Search/insights plugin installation failed');
    }
    if (_current(api, location)) setState(() => _installed = true);
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = KitTokens.of(context);
    final detached = _owner != null && !_current(_owner!, _location!);
    final settings = detached ? null : _settings;
    return KitScreen(
      topBar: KitTopBar(title: l.insightsSearchTitle),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(l.insightsSearchDisclosure, role: KitTextRole.secondary),
          SizedBox(height: t.space3),
          if (_error != null)
            KitNotice.error(
              message: productErrorText(_error!, l10n: l),
              retry: KitAction(
                label: l.commonRetry,
                onPressed: _busy ? null : _load,
              ),
            ),
          if (_installed) KitNotice(message: l.insightsReload),
          if (settings == null &&
              BuiltinLinux.managesServerUrl(
                widget.controller.profile?.baseUrl ?? '',
              ))
            KitButton.secondary(
              label: l.insightsInstall,
              onPressed: _busy ? null : _install,
            ),
          if (settings != null) ...[
            KitRow(
              title: l.insightsSearchOff,
              trailing: settings.enabled ? null : const KitChevron(),
              onTap: _busy ? null : () => _select(null),
            ),
            for (final provider in settings.providers)
              KitRow(
                key: ValueKey('search-provider-${provider.id}'),
                title: provider.name,
                supporting: TextSpan(
                  text: provider.connected
                      ? l.insightsAuthorized
                      : l.insightsNotAuthorized,
                ),
                trailing: settings.selected == provider.id
                    ? KitRowValue(l.insightsSelected)
                    : null,
                onTap: _busy ? null : () => _connect(provider),
              ),
            SizedBox(height: t.space3),
            KitButton.secondary(
              label: l.insightsSearchTest,
              onPressed: _busy || settings.selected == null ? null : _test,
            ),
            if (_tested) KitNotice(message: l.insightsSearchTestOK),
          ],
        ],
      ),
    );
  }
}
