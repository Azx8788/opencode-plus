import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/custom_provider.dart';

/// Per-server names and paths for provider API keys.
///
/// This contains no credentials. Secret values live only in owner-readable
/// files inside the in-app server; the server config points at the active one.
class ProviderKeyRingStore {
  ProviderKeyRingStore(this.preferences);

  final SharedPreferences preferences;

  static String _key(String profileID, String providerID) =>
      'oc.providerKeys.v1.$profileID.$providerID';

  Future<({List<ProviderKeyRecord> keys, String? activeID})> load({
    required String profileID,
    required String providerID,
    required String? currentPath,
    String defaultName = 'Default',
  }) async {
    final raw = preferences.getString(_key(profileID, providerID));
    final keys = <ProviderKeyRecord>[];
    if (raw != null) {
      try {
        final value = jsonDecode(raw);
        if (value is Map && value['keys'] is List) {
          for (final item in value['keys'] as List) {
            if (item is! Map) continue;
            final id = item['id'];
            final name = item['name'];
            final path = item['path'];
            if (id is! String ||
                !RegExp(r'^[a-zA-Z0-9_-]{1,48}$').hasMatch(id) ||
                name is! String ||
                name.trim().isEmpty ||
                path is! String ||
                !validProviderKeyPath(path)) {
              continue;
            }
            if (keys.any((key) => key.id == id || key.filePath == path)) {
              continue;
            }
            keys.add(ProviderKeyRecord(id: id, name: name.trim(), filePath: path));
          }
        }
      } on FormatException {
        // Bad app-owned metadata is ignored; the active config path remains
        // authoritative and can still be adopted below.
      }
    }
    if (currentPath != null &&
        validProviderKeyPath(currentPath) &&
        !keys.any((key) => key.filePath == currentPath)) {
      var id = 'legacy';
      var suffix = 2;
      while (keys.any((key) => key.id == id)) {
        id = 'legacy-${suffix++}';
      }
      var name = defaultName;
      var number = 2;
      while (keys.any((key) => key.name.toLowerCase() == name.toLowerCase())) {
        name = '$defaultName ${number++}';
      }
      keys.insert(
        0,
        ProviderKeyRecord(id: id, name: name, filePath: currentPath),
      );
    }
    final active = currentPath == null
        ? null
        : keys.where((key) => key.filePath == currentPath).firstOrNull?.id;
    return (keys: List<ProviderKeyRecord>.unmodifiable(keys), activeID: active);
  }

  Future<void> save({
    required String profileID,
    required String providerID,
    required List<ProviderKeyRecord> keys,
    required String? activeID,
  }) async {
    final normalized = <ProviderKeyRecord>[];
    final ids = <String>{};
    final paths = <String>{};
    final names = <String>{};
    for (final key in keys) {
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,48}$').hasMatch(key.id) ||
          key.name.trim().isEmpty ||
          key.name.trim().length > 80 ||
          !validProviderKeyPath(key.filePath) ||
          !ids.add(key.id) ||
          !paths.add(key.filePath) ||
          !names.add(key.name.trim().toLowerCase())) {
        throw const FormatException('Invalid named provider key');
      }
      normalized.add(
        ProviderKeyRecord(
          id: key.id,
          name: key.name.trim(),
          filePath: key.filePath,
        ),
      );
    }
    if (activeID != null && !ids.contains(activeID)) {
      throw const FormatException('The active provider key is not in the key ring');
    }
    final encoded = jsonEncode({
      'keys': [
        for (final key in normalized)
          {'id': key.id, 'name': key.name, 'path': key.filePath},
      ],
      'active': ?activeID,
    });
    if (!await preferences.setString(_key(profileID, providerID), encoded)) {
      throw const FormatException('Could not save provider key names');
    }
  }

}
