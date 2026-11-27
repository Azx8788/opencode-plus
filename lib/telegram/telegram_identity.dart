import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

String normalizeTelegramUsername(String value) =>
    value.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();

bool validTelegramUsername(String value) =>
    RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(value);

bool validTelegramUserID(String value) =>
    RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(value);

/// Before binding, both choices must match if an ID was supplied. After
/// binding, pass only the stored ID: a Telegram handle can change ownership.
bool telegramPrivateMessageAllowed({
  String allowedUserID = '',
  String allowedUsername = '',
  required Object? chatType,
  required Object? senderID,
  Object? senderUsername,
  required Object? chatID,
  required bool senderIsBot,
}) {
  final sender = '$senderID';
  if (chatType != 'private' ||
      senderIsBot ||
      !validTelegramUserID(sender) ||
      sender != '$chatID') {
    return false;
  }
  if (allowedUserID.isNotEmpty && allowedUserID != sender) return false;
  if (allowedUsername.isNotEmpty) {
    final name = normalizeTelegramUsername(allowedUsername);
    if (!validTelegramUsername(name) ||
        senderUsername is! String ||
        normalizeTelegramUsername(senderUsername) != name) {
      return false;
    }
  }
  return allowedUserID.isNotEmpty || allowedUsername.isNotEmpty;
}

class TelegramUsernameSetup {
  TelegramUsernameSetup(this.username, this.expectedID, {int? notBefore})
    : notBefore = notBefore ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 {
    if (!validTelegramUsername(username) ||
        (expectedID.isNotEmpty && !validTelegramUserID(expectedID)) ||
        this.notBefore <= 0) {
      throw const FormatException('Invalid Telegram username setup.');
    }
  }

  final String username;
  final String expectedID;
  final int notBefore;

  String encode() => jsonEncode([username, expectedID, notBefore]);

  static TelegramUsernameSetup decode(String raw) {
    final value = jsonDecode(raw);
    if (value is! List ||
        value.length != 3 ||
        value[0] is! String ||
        value[1] is! String ||
        value[2] is! int) {
      throw const FormatException('Invalid Telegram username setup.');
    }
    return TelegramUsernameSetup(value[0], value[1], notBefore: value[2]);
  }
}

typedef TelegramSavedIdentity = ({String chatID, TelegramUsernameSetup? setup});

/// Only [chatKeyPrefix] authorizes an existing private account. The setup
/// record is an invitation to bind and is not an address for outgoing text.
class TelegramIdentityStore {
  TelegramIdentityStore(this.prefs);

  final SharedPreferences prefs;

  static const chatKeyPrefix = 'oc.telegramBot.chat.';
  static const setupKeyPrefix = 'oc.telegramBot.usernameSetup.';
  static const legacyUsernameKeyPrefix = 'oc.telegramBot.username.';
  static const legacyBoundIDKeyPrefix = 'oc.telegramBot.boundUser.';

  Future<TelegramSavedIdentity> load(String owner) async {
    await prefs.reload();
    final chatKey = '$chatKeyPrefix$owner';
    final setupKey = '$setupKeyPrefix$owner';
    final nameKey = '$legacyUsernameKeyPrefix$owner';
    final boundKey = '$legacyBoundIDKeyPrefix$owner';
    final chat = prefs.getString(chatKey) ?? '';
    final rawName = prefs.getString(nameKey) ?? '';
    final name = normalizeTelegramUsername(rawName);
    final bound = prefs.getString(boundKey) ?? '';
    if (chat.isNotEmpty && !validTelegramUserID(chat)) {
      throw const FormatException('Invalid Telegram user ID.');
    }
    if (rawName.isNotEmpty && !validTelegramUsername(name)) {
      throw const FormatException('Invalid Telegram username.');
    }
    if (bound.isNotEmpty) {
      if (!validTelegramUserID(bound) || (chat.isNotEmpty && chat != bound)) {
        throw const FormatException('Conflicting Telegram user IDs.');
      }
      // Keep the old binding authoritative until the same ID is durable.
      await _remove(setupKey);
      await _set(chatKey, bound);
      await _remove(nameKey);
      await _remove(boundKey);
      return (chatID: bound, setup: null);
    }
    if (name.isNotEmpty) {
      // In the username preview `chat` could be only an *expected* ID.
      // Preserve that constraint through interruption, and never poll until
      // it is no longer stored in the authoritative chat slot.
      final raw = prefs.getString(setupKey);
      final setup = raw == null
          ? TelegramUsernameSetup(name, chat)
          : TelegramUsernameSetup.decode(raw);
      if (setup.username != name ||
          (chat.isNotEmpty && setup.expectedID != chat)) {
        throw const FormatException('Conflicting Telegram username settings.');
      }
      await _set(setupKey, setup.encode());
      await _remove(chatKey);
      await _remove(boundKey);
      await _remove(nameKey);
      return (chatID: '', setup: setup);
    }
    final raw = chat.isEmpty ? prefs.getString(setupKey) : null;
    // A successful claim wins even if removing its setup record failed.
    return (
      chatID: chat,
      setup: raw == null ? null : TelegramUsernameSetup.decode(raw),
    );
  }

  /// The caller has stopped the poller and durably disabled the relay.
  Future<void> replace(
    String owner, {
    String chatID = '',
    TelegramUsernameSetup? setup,
  }) async {
    await _remove('$legacyUsernameKeyPrefix$owner');
    await _remove('$legacyBoundIDKeyPrefix$owner');
    await _remove('$setupKeyPrefix$owner');
    if (setup != null) {
      await _remove('$chatKeyPrefix$owner');
      await _set('$setupKeyPrefix$owner', setup.encode());
    } else if (chatID.isNotEmpty) {
      await _set('$chatKeyPrefix$owner', chatID);
    } else {
      await _remove('$chatKeyPrefix$owner');
    }
  }

  /// Acknowledges the ID in platform storage before it can reach the engine.
  Future<void> bind(
    String owner,
    TelegramUsernameSetup setup,
    String userID,
  ) async {
    final current = await load(owner);
    if (current.chatID.isNotEmpty ||
        current.setup?.encode() != setup.encode() ||
        !validTelegramUserID(userID) ||
        (setup.expectedID.isNotEmpty && setup.expectedID != userID)) {
      throw const FormatException('Telegram username setup changed.');
    }
    await _set('$chatKeyPrefix$owner', userID);
    try {
      await _remove('$setupKeyPrefix$owner');
    } on Object {
      // The verified numeric ID supersedes a leftover setup record.
    }
  }

  Future<void> _set(String key, String value) async {
    if (!await prefs.setString(key, value)) {
      await prefs.reload();
      throw const FormatException('Could not save the Telegram identity.');
    }
    await prefs.reload();
    if (prefs.getString(key) != value) {
      throw const FormatException('Could not verify the Telegram identity.');
    }
  }

  Future<void> _remove(String key) async {
    if (!prefs.containsKey(key)) return;
    final removed = await prefs.remove(key);
    await prefs.reload();
    if (!removed || prefs.containsKey(key)) {
      throw const FormatException('Could not clear the Telegram identity.');
    }
  }
}
