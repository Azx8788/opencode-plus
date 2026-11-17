/// The selected search service, not a language-model provider. A catalogue
/// entry is support, never proof of a credential or a working search.
class SearchProviderSettings {
  const SearchProviderSettings({
    required this.selected,
    required this.providers,
    required this.enabled,
  });
  final String? selected;
  final List<SearchProviderOption> providers;
  final bool enabled;

  factory SearchProviderSettings.fromJson(Object? value) {
    if (value is! Map ||
        value['providers'] is! List ||
        value['enabled'] is! bool) {
      throw const FormatException('Invalid search settings');
    }
    final selected = value['selected'];
    if (selected != null && selected is! String) {
      throw const FormatException('Invalid selected search provider');
    }
    final seen = <String>{};
    final providers = <SearchProviderOption>[];
    for (final raw in value['providers'] as List) {
      if (raw is! Map ||
          raw['id'] is! String ||
          raw['name'] is! String ||
          raw['connected'] is! bool ||
          !seen.add(raw['id'] as String)) {
        throw const FormatException('Invalid search provider');
      }
      providers.add(
        SearchProviderOption(
          id: raw['id'],
          name: raw['name'],
          connected: raw['connected'],
        ),
      );
    }
    return SearchProviderSettings(
      selected: selected,
      providers: List.unmodifiable(providers),
      enabled: value['enabled'],
    );
  }
}

class SearchProviderOption {
  const SearchProviderOption({
    required this.id,
    required this.name,
    required this.connected,
  });
  final String id, name;
  final bool connected;
}
