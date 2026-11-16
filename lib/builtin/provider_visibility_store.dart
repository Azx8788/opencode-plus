import 'package:shared_preferences/shared_preferences.dart';

/// Built-in provider rows the person hid from the provider list.
///
/// A shipped template that was never configured is not something the app can
/// delete: it is not in the server's configuration. Hiding it locally is the
/// honest equivalent, and restoring is one tap. Configured providers are
/// removed from the configuration by the ordinary delete path.
class ProviderVisibilityStore {
  ProviderVisibilityStore(this.preferences);

  final SharedPreferences preferences;

  static const _prefix = 'oc.hiddenProviderTemplates.v1';

  String _key(String profileID) => '$_prefix.$profileID';

  Set<String> load(String profileID) {
    final raw = preferences.getStringList(_key(profileID)) ?? const [];
    return {
      for (final id in raw)
        if (RegExp(r'^[a-zA-Z0-9._-]{1,48}$').hasMatch(id)) id,
    };
  }

  Future<void> save(String profileID, Set<String> ids) async {
    final sorted = ids.toList()..sort();
    final saved = await preferences.setStringList(_key(profileID), sorted);
    if (!saved) throw StateError('Could not save the hidden provider list');
  }

  Future<void> hide(String profileID, String providerID) async {
    final ids = load(profileID)..add(providerID);
    await save(profileID, ids);
  }

  Future<void> restoreAll(String profileID) => save(profileID, const {});
}