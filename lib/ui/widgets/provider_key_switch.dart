import 'dart:math';

import 'package:flutter/material.dart';

import '../../api2/server_config_reload.dart';
import '../../builtin/builtin_linux.dart';
import '../../builtin/builtin_provider_store.dart';
import '../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../builtin/provider_key_ring_store.dart';
import '../../domain/custom_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../app_iconography.dart';
import '../kit/kit.dart';

final _keySwitchesInProgress = <String>{};

/// The key chooser shared by the conversation picker and provider model lists.
/// A model is only an entry point: this changes its provider's active key, not
/// the model, reasoning variant or conversation selection.
Future<bool> showProviderKeySwitch(
  BuildContext context, {
  required ConnectionController controller,
  required String providerID,
  BuiltinLinux? linux,
}) async {
  final profile = controller.profile;
  if (profile == null || !looksLikeInAppServer(profile)) return false;
  if (!_keySwitchesInProgress.add(providerID)) return false;
  final origin = profile.baseUrl;
  final location = controller.locationRevision;
  final directory = controller.directory;
  final workspace = controller.workspace;
  bool sameScope() =>
      context.mounted &&
      controller.profile?.id == profile.id &&
      controller.profile?.baseUrl == origin &&
      controller.locationRevision == location;
  void checkScope() {
    if (!sameScope()) {
      throw const ProviderWriteRefused(
        'The selected server or project changed',
      );
    }
  }

  final strings = lookupAppLocalizations(Localizations.localeOf(context));
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String message) {
    if (!sameScope()) return;
    messenger
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  final store = BuiltinProviderStore(linux: linux ?? BuiltinLinux());
  final names = ProviderKeyRingStore(controller.store.prefs);
  var activated = false;
  try {
    messenger?.showSnackBar(
      SnackBar(content: Text(strings.providerKeyLoading)),
    );
    final resolved = await store.resolve();
    final catalog = await store.readRecords(resolved: resolved);
    checkScope();
    final record = catalog.records
        .where((row) => row.id == providerID)
        .firstOrNull;
    if (record == null) {
      say(strings.providerKeyConfigureFirst);
      return false;
    }
    final saved = await names.load(
      profileID: profile.id,
      providerID: providerID,
      currentPath: record.secretPath,
      defaultName: strings.providerKeyDefaultName,
    );
    checkScope();
    final keys = saved.keys.toList();
    var activeID = saved.activeID;
    // Preserve a legacy plaintext key if the person switches away from it.
    // Until they choose a different key this is memory only: opening a menu
    // must never rewrite configuration or credentials.
    String? legacyID;
    final legacySecret = record.apiKey;
    if (legacySecret != null && legacySecret.isNotEmpty) {
      final random = Random.secure();
      legacyID = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      var name = strings.providerKeyDefaultName;
      var suffix = 2;
      while (keys.any((key) => key.name.toLowerCase() == name.toLowerCase())) {
        name = '${strings.providerKeyDefaultName} ${suffix++}';
      }
      keys.add(
        ProviderKeyRecord(
          id: legacyID,
          name: name,
          filePath: '/root/.secrets/opencode-plus/$providerID/$legacyID.key',
        ),
      );
      activeID = legacyID;
    }
    messenger?.clearSnackBars();
    if (keys.isEmpty) {
      say(strings.providerKeyConfigureFirst);
      return false;
    }
    ProviderKeyRecord? chosen;
    if (!context.mounted) return false;
    final group = KitMenuGroup(strings.providerKeyProviderScope(record.name));
    await showKitMenu(
      context,
      menuKey: ValueKey('provider-key-switch-menu-$providerID'),
      semanticsLabel: strings.providerKeySwitch,
      items: [
        for (final key in keys)
          KitMenuItem(
            key: ValueKey('provider-key-choice-$providerID-${key.id}'),
            label: key.name,
            group: group,
            checked: key.id == activeID,
            onSelected: () => chosen = key,
          ),
      ],
    );
    checkScope();
    final key = chosen;
    if (key == null || key.id == activeID) return false;
    messenger?.showSnackBar(
      SnackBar(content: Text(strings.providerKeySwitching)),
    );
    final value = await store.readSecret(key.filePath);
    checkScope();
    if (value == null || value.isEmpty) {
      say(strings.providerKeyMissing);
      return false;
    }
    // Re-read before writing: an editor on another screen may have changed
    // the provider while the menu was open. Never overwrite a newer choice.
    final latest = (await store.readRecords(resolved: resolved)).records
        .where((row) => row.id == providerID)
        .firstOrNull;
    checkScope();
    if (latest == null ||
        latest.secretPath != record.secretPath ||
        latest.apiKey != record.apiKey ||
        latest.keyPlaceholder != record.keyPlaceholder) {
      say(strings.providerKeySelectionChanged);
      return false;
    }
    final latestKeys = await names.load(
      profileID: profile.id,
      providerID: providerID,
      currentPath: latest.secretPath,
    );
    checkScope();
    final sameKeys =
        latestKeys.keys.length == saved.keys.length &&
        latestKeys.keys.indexed.every((entry) {
          final old = saved.keys[entry.$1];
          final current = entry.$2;
          return current.id == old.id &&
              current.name == old.name &&
              current.filePath == old.filePath;
        });
    if (!sameKeys ||
        !latestKeys.keys.any(
          (item) => item.id == key.id && item.filePath == key.filePath,
        )) {
      say(strings.providerKeySelectionChanged);
      return false;
    }
    if (legacyID != null && legacySecret != null) {
      final legacy = keys.firstWhere((item) => item.id == legacyID);
      await store.saveNamedKey(
        providerID: providerID,
        keyID: legacy.id,
        name: legacy.name,
        secret: legacySecret,
        activeKeyID: legacy.id,
        keys: keys.where((item) => item.id != legacyID).toList(),
        resolved: resolved,
        beforeConfigWrite: () async {
          checkScope();
          await names.save(
            profileID: profile.id,
            providerID: providerID,
            keys: keys,
            activeID: legacy.id,
          );
        },
      );
    }
    checkScope();
    await store.updateNamedKeys(
      providerID: providerID,
      keys: keys,
      activeKeyID: key.id,
      resolved: resolved,
      beforeConfigWrite: () async {
        checkScope();
        await names.save(
          profileID: profile.id,
          providerID: providerID,
          keys: keys,
          activeID: key.id,
        );
      },
    );
    activated = true;
    checkScope();
    final reloaded = await reloadServerConfig(
      baseUrl: origin,
      password: profile.password,
      username: profile.username.isEmpty ? 'opencode' : profile.username,
      cleartextConfirmedOrigin: profile.cleartextConfirmedOrigin,
      certificatePinSha256: profile.certificatePinSha256,
      directory: directory,
      workspace: workspace,
    );
    checkScope();
    if (reloaded) await controller.refreshCatalog();
    say(
      reloaded
          ? strings.providerKeySwitched(key.name)
          : strings.providerKeyReloadNeeded,
    );
    return true;
  } catch (_) {
    // Never echo transport or credential errors, which may contain a key.
    say(activated ? strings.providerKeyReloadNeeded : strings.providerKeySwitchFailed);
    return activated;
  } finally {
    messenger?.clearSnackBars();
    _keySwitchesInProgress.remove(providerID);
  }
}

KitMenuItem providerKeySwitchAction({
  required BuildContext context,
  required ConnectionController controller,
  required String providerID,
  required String modelID,
  BuiltinLinux? linux,
  VoidCallback? onSelected,
}) => KitMenuItem(
  key: ValueKey('model-key-switch-$providerID-$modelID'),
  label: lookupAppLocalizations(Localizations.localeOf(context))
      .providerKeySwitch,
  icon: AppIconography.settingsGear,
  onSelected:
      onSelected ??
      () async {
        await showProviderKeySwitch(
          context,
          controller: controller,
          providerID: providerID,
          linux: linux,
        );
      },
);
