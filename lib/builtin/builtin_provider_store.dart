/// Reads and writes the in-app server's own `opencode.json`.
///
/// The server runs in a rootfs under the app's private storage. Its **reads**
/// still run shell inside that rootfs ([BuiltinLinux.run]) — a script that
/// prints one file is easy to reason about and to test. Its **writes** do not:
/// every save goes through [BuiltinLinux.writeServerFile], one native call
/// that checks each path segment, writes a temp file with the key's own mode
/// and renames it over the target.
///
/// That split is deliberate. A write used to be a shell script too, which
/// meant a save waited for the installer lock and surfaced as an unclassified
/// `builtin_linux` failure whenever the phone was busy. A file write needs no
/// guest process, and a rename either happened or did not.
///
/// Two rules shape the rest:
///
///  * Content crosses the native boundary base64-encoded by the channel, not
///    quoted through `sh -c`: a config carries quotes, newlines and — on
///    Windows-authored machines — full-width punctuation.
///  * A file is replaced by writing a sibling and renaming it, so a failure
///    mid-write leaves the previous config intact.
///
/// A `jsonc` file (a config with comments) is never rewritten: the app cannot
/// preserve comments it cannot parse, and silently dropping a person's
/// comments is worse than asking them to merge by hand.
library;

import 'dart:convert';

import '../diagnostics/app_log.dart';
import '../domain/custom_provider.dart';
import '../domain/custom_provider_record.dart';
import '../domain/model_reasoning.dart';
import '../domain/server_gateway/value_types_catalog.dart'
    show ProductException;
import 'builtin_linux.dart';

/// What the server already has on disk.
class ProviderConfigSnapshot {
  const ProviderConfigSnapshot({
    required this.path,
    required this.exists,
    required this.document,
    required this.hasComments,
    this.raw,
  });

  final String path;
  final bool exists;

  /// Parsed JSON, or null when the file is missing or could not be parsed.
  final Map<String, Object?>? document;

  /// A `.jsonc` file was found where the JSON would be, or the JSON would not
  /// parse. Either way, merging is refused.
  final bool hasComments;

  /// The bytes as they were read. A backup is this text, not a re-encoding of
  /// [document]: re-encoding would drop the person's own ordering and
  /// spacing from the copy that exists to preserve them.
  final String? raw;

  /// True when the file exists but is not a JSON object this app can merge
  /// into — the caller falls back to showing the snippet.
  bool get canMerge => !hasComments && (document != null || !exists);
}

class ProviderWriteReceipt {
  const ProviderWriteReceipt({
    required this.configPath,
    required this.backupPath,
    required this.keyFileWritten,
    required this.providerID,
    required this.format,
    this.keyFileRetained = false,
  });

  /// Absolute path inside the server, for the confirmation line.
  final String configPath;
  final String? backupPath;
  final bool keyFileWritten;
  final String providerID;
  final ProviderConfigFormat format;
  final bool keyFileRetained;
}

/// Which file this server actually reads.
///
/// OpenCode 2 keeps its config under `.oc-opencode2`. Its start script pins
/// `XDG_CONFIG_HOME` there, so that is the only path it reads — a file left
/// in the OpenCode 1 location (`.config/opencode`) is invisible to it.
///
/// This used to prefer whichever file existed, which quietly wrote every
/// save into the v1 location on a server upgraded from OpenCode 1: the file
/// was there, the save said "saved", and the running server never read it.
/// The v1 file is now left untouched and the v2 path is written instead; a
/// person whose old entry lived in v1 sees an empty form once and saves it
/// again into the file that is actually read.
class ResolvedProviderConfig {
  const ResolvedProviderConfig({
    required this.format,
    required this.relativePath,
    required this.exists,
    this.commentFile = false,
  });

  final ProviderConfigFormat format;
  final String relativePath;
  final bool exists;

  /// The file found is a `.jsonc`. Reading it as JSON would report "missing"
  /// (that name is not there) and the write would create a second config
  /// beside it — so this is carried, not re-derived.
  final bool commentFile;
}

/// Thrown when the server's config cannot be written safely.
class ProviderWriteRefused implements Exception {
  const ProviderWriteRefused(this.message, {this.reason});

  final String message;
  final String? reason;

  @override
  String toString() => message;
}

/// Runs a shell script inside the server, as [BuiltinLinux.run] does.
///
/// Injected so the scripts this file generates can be checked for syntax and
/// their effects decoded, without a phone.
typedef BuiltinScriptRunner =
    Future<BuiltinLinuxRunResult> Function(String script, Duration timeout);

/// Writes one file under the server's home, in one native step.
///
/// Injected for the same reason as [BuiltinScriptRunner]: a save is a file
/// write, and a test can hold the bytes without a phone. The real one is
/// [BuiltinLinux.writeServerFile], which checks every path segment and renames
/// a temp file over the target — a shell did none of that, and it had to wait
/// for the installer lock first.
typedef BuiltinFileWriter =
    Future<void> Function(String relativePath, String content);

/// Removes one app-managed provider key file inside the server.
typedef BuiltinFileDeleter = Future<void> Function(String relativePath);

class BuiltinProviderStore {
  BuiltinProviderStore({
    BuiltinLinux? linux,
    String? home,
    BuiltinScriptRunner? run,
    BuiltinFileWriter? writeFile,
    BuiltinFileDeleter? deleteFile,
  }) : assert(
         linux != null || run != null || writeFile != null,
         'BuiltinProviderStore needs a bridge, a runner or a writer',
       ),
       _home = home ?? '/root',
       _run =
           run ?? ((script, timeout) => linux!.run(script, timeout: timeout)),
       _writeFile =
           writeFile ??
           ((path, content) {
             if (linux == null) {
               throw ProviderWriteRefused(
                 'This store cannot write without a native bridge',
                 reason: 'no-writer',
               );
             }
             return linux.writeServerFile(
               relativePath: path,
               content: content,
             );
           }),
       _deleteFile =
           deleteFile ??
           ((path) {
             if (linux == null) {
               throw ProviderWriteRefused(
                 'This store cannot delete without a native bridge',
                 reason: 'no-deleter',
               );
             }
             return linux.deleteServerProviderKey(relativePath: path);
           });

  final String _home;
  final BuiltinScriptRunner _run;
  final BuiltinFileWriter _writeFile;
  final BuiltinFileDeleter _deleteFile;

  /// A path inside the server, as the native writer takes it.
  String _relative(String absolute) {
    final prefix = '$_home/';
    if (!absolute.startsWith(prefix)) {
      throw ProviderWriteRefused('The file is outside the server');
    }
    return absolute.substring(prefix.length);
  }

  /// OpenCode 2's own directory first: it is what this app runs.
  static const _v2Path = '.oc-opencode2/config/opencode/opencode.json';

  /// The OpenCode 1 location, which an upgraded server may still use.
  static const _v1Path = '.config/opencode/opencode.json';

  String _absolute(String relative) => '$_home/$relative';

  /// The absolute path of the file this server reads, for a caller that has
  /// to name it outside this class (the in-server model read does).
  String pathOf(ResolvedProviderConfig resolved) =>
      _absolute(resolved.relativePath);

  /// Finds the file the server would read.
  ///
  /// Only the v2 location: the start script pins `XDG_CONFIG_HOME` at
  /// `.oc-opencode2/config`, and OpenCode 1's directory is not on that path.
  /// A `.jsonc` beside it is refused rather than shadowed.
  Future<ResolvedProviderConfig> resolve() async {
    final script =
        '''
set -u
if [ -f '$_home/$_v2Path' ]; then printf 'JSON:%s' '$_home/$_v2Path'; exit 0; fi
if [ -f '$_home/${_v2Path}c' ]; then printf 'JSONC:%s' '$_home/${_v2Path}c'; exit 0; fi
printf 'NEW:$_home/$_v2Path'
''';
    final result = await _run(script, const Duration(seconds: 30));
    final output = result.output.trim();
    if (result.exitCode != 0) {
      throw ProviderWriteRefused(
        'The server\u2019s configuration could not be found',
        reason: 'exit ${result.exitCode}',
      );
    }
    final marker = output.indexOf(':');
    if (marker < 0) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration could not be found',
      );
    }
    final kind = output.substring(0, marker);
    final path = output.substring(marker + 1).trim();
    final relative = path.startsWith('$_home/')
        ? path.substring(_home.length + 1)
        : path;
    final format = path.endsWith(_v1Path)
        ? ProviderConfigFormat.v1
        : ProviderConfigFormat.v2;
    return ResolvedProviderConfig(
      format: format,
      relativePath: relative,
      exists: kind == 'JSON' || kind == 'JSONC',
      commentFile: kind == 'JSONC',
    );
  }

  /// Reads the current config, without ever logging its contents: on a v1
  /// server it can carry an API key.
  Future<ProviderConfigSnapshot> read(ResolvedProviderConfig resolved) async {
    final path = _absolute(resolved.relativePath);
    if (resolved.commentFile) {
      // Never rewritten: the app cannot re-emit comments it never parsed,
      // and a config that loses the person's comments is worse than one the
      // app declines to touch.
      return ProviderConfigSnapshot(
        path: path,
        exists: true,
        document: null,
        hasComments: true,
      );
    }
    final script =
        '''
set -u
f='$path'
if [ -f "\$f" ]; then
  printf 'JSON:'
  base64 "\$f" | tr -d '\\n'
else
  printf 'MISSING:'
fi
''';
    final result = await _run(script, const Duration(seconds: 30));
    final output = result.output.trim();
    if (result.exitCode != 0) {
      throw ProviderWriteRefused(
        'The server\u2019s configuration could not be read',
        reason: 'exit ${result.exitCode}',
      );
    }
    final marker = output.indexOf(':');
    if (marker < 0) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration could not be read',
      );
    }
    final kind = output.substring(0, marker);
    final payload = output.substring(marker + 1).trim();
    if (kind == 'MISSING') {
      return ProviderConfigSnapshot(
        path: path,
        exists: false,
        document: null,
        hasComments: false,
      );
    }
    if (kind == 'JSONC') {
      return ProviderConfigSnapshot(
        path: path,
        exists: true,
        document: null,
        hasComments: true,
      );
    }
    String text;
    try {
      text = utf8.decode(base64Decode(payload));
    } catch (_) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration could not be decoded',
      );
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const ProviderWriteRefused(
          'The server\u2019s configuration is not a JSON object',
        );
      }
      return ProviderConfigSnapshot(
        path: path,
        exists: true,
        document: {for (final e in decoded.entries) '${e.key}': e.value},
        hasComments: false,
        raw: text,
      );
    } on FormatException {
      // A file that will not parse is treated as a comment-bearing one:
      // whatever makes it unparsable is the person's, and must survive.
      return ProviderConfigSnapshot(
        path: path,
        exists: true,
        document: null,
        hasComments: true,
        raw: text,
      );
    }
  }

  /// Writes the provider, keeping a backup of the previous file.
  ///
  /// [replace] is the edit path: an entry with the same id is overwritten
  /// instead of refused. A draft whose key box was left empty keeps the key
  /// the config already has.
  ///
  /// [requireModels] is false for the write that has to happen before a model
  /// list exists: the server reads the endpoint's own list from the entry, so
  /// the entry goes to disk first and the chosen models are written after.
  Future<ProviderWriteReceipt> save(
    CustomProviderDraft draft, {
    ResolvedProviderConfig? resolved,
    bool replace = false,
    bool requireModels = true,
    Future<void> Function()? beforeConfigWrite,
  }) async {
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    if (snapshot.hasComments) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration has comments, so it cannot be merged '
        'automatically',
        reason: 'jsonc',
      );
    }
    final Map<String, Object?> merged;
    try {
      merged = draft.mergeInto(
        snapshot.document,
        target.format,
        replace: replace,
        requireModels: requireModels,
      );
    } on Exception catch (error) {
      throw ProviderWriteRefused('$error', reason: 'merge');
    }
    var keyWritten = false;
    if (draft.keyMode == ProviderKeyMode.secretFile && draft.hasKey) {
      final secret = draft.secretPath!;
      // A plain write, on the same native path as the config: the key is one
      // small file, and a save that had to start a shell for it queued behind
      // whatever else the phone was doing.
      try {
        await _writeFile(_relative(secret), draft.apiKey!.trim());
        keyWritten = true;
      } on Object {
        throw const ProviderWriteRefused(
          'The key file could not be saved; the configuration was not changed',
          reason: 'key-write',
        );
      }
    }
    // File and metadata failures must leave the active config untouched. New
    // named files have unique IDs, so a failed activation cannot replace a
    // previously active key's bytes.
    await beforeConfigWrite?.call();
    final backup = await _writeDocument(
      merged,
      path: snapshot.path,
      exists: snapshot.exists,
      previous: snapshot.raw,
    );

    AppLog.info('provider', 'custom provider saved', {
      'provider': draft.id,
      'format': target.format.name,
      'models': draft.models.length,
      'keyMode': draft.keyMode.name,
      'backup': backup != null,
      'keyFile': keyWritten,
    });
    return ProviderWriteReceipt(
      configPath: snapshot.path,
      backupPath: backup,
      keyFileWritten: keyWritten,
      providerID: draft.id,
      format: target.format,
    );
  }

  /// Every provider entry the config holds, in the form the editor reads.
  ///
  /// A comment-bearing or unparsable file throws the same refusal a write
  /// would: the list can then say why it is read-only instead of showing
  /// "no providers" for a file that has plenty.
  Future<CustomProviderCatalogue> readRecords({
    ResolvedProviderConfig? resolved,
  }) async {
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    if (snapshot.hasComments) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration has comments, so it cannot be '
        'listed here',
        reason: 'jsonc',
      );
    }
    return readCustomProviders(snapshot.document, target.format);
  }

  /// Removes one provider entry, keeping a backup of the previous file.
  ///
  /// The key file is left alone: another entry may point at it, and deleting
  /// a secret the app did not write is not this method's call.
  Future<ProviderWriteReceipt> remove(
    String providerID, {
    ResolvedProviderConfig? resolved,
  }) async {
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    if (snapshot.hasComments) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration has comments, so it cannot be '
        'changed automatically',
        reason: 'jsonc',
      );
    }
    final document = snapshot.document;
    if (document == null) {
      throw const ProviderWriteRefused(
        'There is no provider configuration to remove from',
        reason: 'missing',
      );
    }
    final root = target.format == ProviderConfigFormat.v1
        ? 'provider'
        : 'providers';
    final current = document[root];
    if (current is! Map || !current.containsKey(providerID)) {
      throw ProviderWriteRefused(
        'No provider named "$providerID" is in the configuration',
        reason: 'missing',
      );
    }
    final providers = <String, Object?>{};
    current.forEach((key, value) => providers['$key'] = value);
    providers.remove(providerID);
    final next = <String, Object?>{...document};
    next[root] = providers;
    final backup = await _writeDocument(
      next,
      path: snapshot.path,
      exists: snapshot.exists,
      previous: snapshot.raw,
    );
    AppLog.info('provider', 'custom provider removed', {
      'provider': providerID,
      'format': target.format.name,
      'backup': backup != null,
    });
    return ProviderWriteReceipt(
      configPath: snapshot.path,
      backupPath: backup,
      keyFileWritten: false,
      providerID: providerID,
      format: target.format,
    );
  }

  /// Writes one named key with an owner-only file, then points the provider
  /// at it and records its display name in app-owned metadata. Existing keys
  /// remain untouched so the person can switch back at any time.
  Future<ProviderWriteReceipt> saveNamedKey({
    required String providerID,
    required String keyID,
    required String name,
    required String secret,
    required String? activeKeyID,
    required List<ProviderKeyRecord> keys,
    ResolvedProviderConfig? resolved,
    Future<void> Function()? beforeConfigWrite,
  }) async {
    if (CustomProviderDraft.normalizeProviderId(providerID) != providerID ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,48}$').hasMatch(keyID) ||
        name.trim().isEmpty ||
        name.trim().length > 80 ||
        keys.any((key) => key.id == keyID) ||
        secret.trim().isEmpty) {
      throw const ProviderWriteRefused('The key details are incomplete');
    }
    final path = '/root/.secrets/opencode-plus/$providerID/$keyID.key';
    final nextKeys = <ProviderKeyRecord>[
      for (final key in keys)
        if (key.id != keyID) key,
      ProviderKeyRecord(id: keyID, name: name.trim(), filePath: path),
    ];
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    final document = snapshot.document;
    if (!snapshot.canMerge || document == null) {
      throw const ProviderWriteRefused('The provider configuration cannot be edited here');
    }
    final root = target.format == ProviderConfigFormat.v1 ? 'provider' : 'providers';
    final providers = document[root];
    if (providers is! Map) {
      throw const ProviderWriteRefused('The provider list is unreadable');
    }
    final provider = providers[providerID];
    final settingsKey = target.format == ProviderConfigFormat.v1 ? 'options' : 'settings';
    final oldSettings = provider is Map ? provider[settingsKey] : null;
    if (provider is! Map || oldSettings is! Map) {
      throw ProviderWriteRefused('No editable provider named "$providerID" exists');
    }
    final chosenID = activeKeyID ?? keyID;
    if (!nextKeys.any((key) => key.id == chosenID)) {
      throw const ProviderWriteRefused('Select a saved key first');
    }
    final active = nextKeys.firstWhere((key) => key.id == chosenID);
    if (!validProviderKeyPath(active.filePath)) {
      throw const ProviderWriteRefused('A saved key entry is invalid');
    }
    final settings = <String, Object?>{
      ...oldSettings.cast<String, Object?>(),
      'apiKey': '{file:${active.filePath}}',
    };
    final entry = <String, Object?>{
      ...provider.cast<String, Object?>(),
      settingsKey: settings,
    };
    final nextProviders = <String, Object?>{
      for (final item in providers.entries) '${item.key}': item.value,
      providerID: entry,
    };
    final next = <String, Object?>{...document, root: nextProviders};
    try {
      await _writeFile(_relative(path), secret.trim());
    } on Object {
      throw const ProviderWriteRefused(
        'The key file could not be saved; the configuration was not changed',
        reason: 'key-write',
      );
    }
    await beforeConfigWrite?.call();
    final backup = await _writeDocument(
      next,
      path: snapshot.path,
      exists: snapshot.exists,
      previous: snapshot.raw,
    );
    return ProviderWriteReceipt(
      configPath: snapshot.path,
      backupPath: backup,
      keyFileWritten: true,
      providerID: providerID,
      format: target.format,
    );
  }

  /// Renames a key or changes the active key. It writes only the config; key
  /// bytes never leave their existing private file.
  Future<ProviderWriteReceipt> updateNamedKeys({
    required String providerID,
    required List<ProviderKeyRecord> keys,
    required String? activeKeyID,
    ResolvedProviderConfig? resolved,
    Future<void> Function()? beforeConfigWrite,
  }) => _writeKeyRingConfig(
    providerID: providerID,
    activeKeyID: activeKeyID,
    keys: keys,
    resolved: resolved,
    beforeConfigWrite: beforeConfigWrite,
  );

  Future<ProviderWriteReceipt> _writeKeyRingConfig({
    required String providerID,
    required List<ProviderKeyRecord> keys,
    required String? activeKeyID,
    ResolvedProviderConfig? resolved,
    Future<void> Function()? beforeConfigWrite,
  }) async {
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    final document = snapshot.document;
    if (!snapshot.canMerge || document == null) {
      throw const ProviderWriteRefused(
        'The provider configuration cannot be edited here',
        reason: 'unwritable',
      );
    }
    final root = target.format == ProviderConfigFormat.v1
        ? 'provider'
        : 'providers';
    final providers = document[root];
    if (providers is! Map) {
      throw const ProviderWriteRefused(
        'The provider list is unreadable',
        reason: 'missing',
      );
    }
    if (providers[providerID] is! Map) {
      throw ProviderWriteRefused(
        'No provider named "$providerID" is in the configuration',
        reason: 'missing',
      );
    }
    final existingProvider = providers[providerID] as Map;
    final settingsKey = target.format == ProviderConfigFormat.v1
        ? 'options'
        : 'settings';
    final oldSettings = existingProvider[settingsKey];
    if (oldSettings is! Map) {
      throw const ProviderWriteRefused('The provider settings are unreadable');
    }
    if (activeKeyID != null && !keys.any((key) => key.id == activeKeyID)) {
      throw const ProviderWriteRefused('Select a saved key first');
    }
    for (final key in keys) {
      if (!validProviderKeyPath(key.filePath) || key.name.trim().isEmpty) {
        throw const ProviderWriteRefused('A saved key entry is invalid');
      }
    }
    final settings = <String, Object?>{
      ...oldSettings.cast<String, Object?>(),
    };
    if (activeKeyID != null) {
      settings['apiKey'] =
          '{file:${keys.firstWhere((key) => key.id == activeKeyID).filePath}}';
    } else {
      settings.remove('apiKey');
    }
    final entry = <String, Object?>{
      ...existingProvider.cast<String, Object?>(),
      settingsKey: settings,
    };
    final nextProviders = <String, Object?>{
      for (final item in providers.entries) '${item.key}': item.value,
      providerID: entry,
    };
    final next = <String, Object?>{...document, root: nextProviders};
    await beforeConfigWrite?.call();
    final backup = await _writeDocument(
      next,
      path: snapshot.path,
      exists: snapshot.exists,
      previous: snapshot.raw,
    );
    return ProviderWriteReceipt(
      configPath: snapshot.path,
      backupPath: backup,
      keyFileWritten: false,
      providerID: providerID,
      format: target.format,
    );
  }

  /// Remove a named key only when it is not selected and the config explicitly
  /// owns the managed key ring. Legacy/external files are never deleted.
  Future<ProviderWriteReceipt> removeNamedKey({
    required String providerID,
    required String keyID,
    required List<ProviderKeyRecord> remaining,
    required String activeKeyID,
    String? removedPath,
    ResolvedProviderConfig? resolved,
    Future<void> Function()? beforeDelete,
  }) async {
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    if (!snapshot.canMerge || snapshot.document == null ||
        removedPath == null ||
        remaining.any((key) => key.id == keyID || key.filePath == removedPath) ||
        !remaining.any((key) => key.id == activeKeyID)) {
      throw const ProviderWriteRefused('That saved key cannot be removed');
    }
    final root = target.format == ProviderConfigFormat.v1 ? 'provider' : 'providers';
    final providers = snapshot.document![root];
    final provider = providers is Map ? providers[providerID] : null;
    final settings = provider is Map
        ? provider[target.format == ProviderConfigFormat.v1 ? 'options' : 'settings']
        : null;
    if (settings is! Map || settings['apiKey'] == '{file:$removedPath}') {
      throw const ProviderWriteRefused('Choose another key before removing the active key');
    }
    // This is removal from the named-key list, not a change to the active
    // provider. Commit metadata first, and never re-select a stale active ID.
    await beforeDelete?.call();
    var retained = true;
    if (managedProviderKeyPath(removedPath, providerID) &&
        !_referencesKey(snapshot.document, removedPath)) {
      try {
        await _deleteFile(_relative(removedPath));
        retained = false;
      } catch (_) {
        // Tell the caller that the private file was retained rather than
        // claiming that the credential was erased.
      }
    }
    return ProviderWriteReceipt(
      configPath: snapshot.path,
      backupPath: null,
      keyFileWritten: false,
      providerID: providerID,
      format: target.format,
      keyFileRetained: retained,
    );
  }

  /// Deletes the key files this app created for a provider that is being
  /// removed. Only the managed folder is touched; a legacy or external key is
  /// left where its owner put it.
  Future<void> removeProviderKeyFiles(
    String providerID,
    Iterable<String> paths,
  ) async {
    final target = await resolve();
    final snapshot = await read(target);
    if (!snapshot.canMerge) return;
    for (final path in paths) {
      if (!managedProviderKeyPath(path, providerID) ||
          _referencesKey(snapshot.document, path)) continue;
      try {
        await _deleteFile(_relative(path));
      } catch (_) {
        // Best effort: the provider entry is gone either way.
      }
    }
  }

  static bool _referencesKey(Object? value, String path) => switch (value) {
    String text => text.contains(path),
    Map map => map.values.any((item) => _referencesKey(item, path)),
    List list => list.any((item) => _referencesKey(item, path)),
    _ => false,
  };

  /// Writes one model's context window into an entry that is already on disk.
  ///
  /// Nothing else in the file changes: the key, the headers, the package name
  /// and the other models are carried through as they were read, so a window
  /// can be corrected from a conversation without rebuilding the entry. A
  /// window of zero removes the `limit` record, which is how "let the server
  /// decide" is written.
  Future<ProviderWriteReceipt> setModelContext(
    String providerID,
    String modelID, {
    required int context,
    int output = 0,
    ResolvedProviderConfig? resolved,
  }) async {
    final target = resolved ?? await resolve();
    final snapshot = await read(target);
    if (snapshot.hasComments) {
      throw const ProviderWriteRefused(
        'The server\u2019s configuration has comments, so it cannot be '
        'changed automatically',
        reason: 'jsonc',
      );
    }
    final document = snapshot.document;
    if (document == null) {
      throw const ProviderWriteRefused(
        'There is no provider configuration to change',
        reason: 'missing',
      );
    }
    final Map<String, Object?> next;
    try {
      next = withModelContext(
        document,
        target.format,
        providerID: providerID,
        modelID: modelID,
        context: context,
        output: output,
      );
    } on ProductException catch (error) {
      throw ProviderWriteRefused(error.message, reason: 'missing');
    }
    final backup = await _writeDocument(
      next,
      path: snapshot.path,
      exists: snapshot.exists,
      previous: snapshot.raw,
    );
    AppLog.info('provider', 'model context window changed', {
      'provider': providerID,
      'model': modelID,
      'context': context,
      'backup': backup != null,
    });
    return ProviderWriteReceipt(
      configPath: snapshot.path,
      backupPath: backup,
      keyFileWritten: false,
      providerID: providerID,
      format: target.format,
    );
  }

  /// Adds one requested reasoning level to the persistent server config.
  /// The same path is used for every provider advertising reasoningEffort.
  Future<ProviderWriteReceipt> setModelReasoningEffort(
    String providerID,
    String modelID,
    String effort,
  ) async {
    final target = await resolve();
    final snapshot = await read(target);
    if (!snapshot.canMerge || snapshot.document == null) {
      throw const ProviderWriteRefused(
        'The server configuration cannot be edited here',
        reason: 'unwritable',
      );
    }
    final next = withModelReasoningEffort(
      snapshot.document!,
      target.format,
      providerID: providerID,
      modelID: modelID,
      effort: effort,
    );
    final backup = identical(next, snapshot.document)
        ? null
        : await _writeDocument(
            next,
            path: snapshot.path,
            exists: snapshot.exists,
            previous: snapshot.raw,
          );
    return ProviderWriteReceipt(
      configPath: snapshot.path,
      backupPath: backup,
      keyFileWritten: false,
      providerID: providerID,
      format: target.format,
    );
  }

  /// Reads the key file an entry points at, or null when it is not there.
  ///
  /// Only the list's explicit "test" action asks for this: a key that cannot
  /// be read means the test cannot run, not that the provider is broken.
  Future<String?> readSecret(String path) async {
    if (!validProviderKeyPath(path)) {
      throw const ProviderWriteRefused('The key file path is invalid');
    }
    final quotedPath = "'${path.replaceAll("'", "'\"'\"'")}'";
    final script =
        '''
set -u
f=$quotedPath
if [ -f "\$f" ]; then
  printf 'KEY:'
  base64 "\$f" | tr -d '\\n'
else
  printf 'MISSING:'
fi
''';
    final result = await _run(script, const Duration(seconds: 20));
    if (result.exitCode != 0) return null;
    final output = result.output.trim();
    if (!output.startsWith('KEY:')) return null;
    try {
      return utf8.decode(base64Decode(output.substring(4))).trim();
    } catch (_) {
      return null;
    }
  }

  /// Replaces the file with [document], writing a sibling first. Returns the
  /// backup path when there was a previous file.
  Future<String?> _writeDocument(
    Map<String, Object?> document, {
    required String path,
    required bool exists,
    String? previous,
  }) async {
    if (!await _underLimit(document)) {
      throw const ProviderWriteRefused(
        'The configuration would grow beyond the size this app writes',
        reason: 'too-large',
      );
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final relative = _relative(path);
    final backup = exists ? '$path.bak.$stamp' : null;
    try {
      // The backup first: if the new file cannot be written, the copy that
      // exists to survive exactly that is already on disk.
      if (backup != null && previous != null) {
        await _writeFile(_relative(backup), previous);
      }
      await _writeFile(relative, '${jsonEncode(document)}\n');
    } on Object catch (error) {
      throw ProviderWriteRefused(
        'The configuration could not be written',
        reason: '$error',
      );
    }
    return backup;
  }

  /// The config is one JSON file the server reads on every start; a document
  /// this app would not want to hand back is a bug, not a preference.
  Future<bool> _underLimit(Map<String, Object?> document) async =>
      jsonEncode(document).length <= 4 * 1024 * 1024;

  /// Whether this provider id is already in the config.
  Future<bool> contains(
    String providerID,
    ResolvedProviderConfig resolved,
  ) async {
    final snapshot = await read(resolved);
    final document = snapshot.document;
    if (document == null) return false;
    final root = resolved.format == ProviderConfigFormat.v1
        ? 'provider'
        : 'providers';
    final providers = document[root];
    return providers is Map && providers.containsKey(providerID);
  }
}
