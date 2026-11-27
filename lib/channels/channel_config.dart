import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/kit/kit_redact.dart';
import 'channel_identity.dart';

/// Everything the app stores about the official QQ bot, minus its secret.
@immutable
class OfficialQqConfig {
  const OfficialQqConfig({
    this.appId = '',
    this.enabled = false,
    this.sandbox = false,
    this.intents = defaultIntents,
    this.allowedUsers = const {},
    this.allowedGroups = const {},
    this.allowDirect = true,
    this.allowGroup = true,
    this.requireMentionInGroups = true,
  });

  /// `GROUP_AND_C2C_EVENT` (1 << 25) plus `PUBLIC_GUILD_MESSAGES` (1 << 30).
  /// Anything else needs a permission the bot may not have; subscribing to it
  /// makes the gateway close the connection instead of ignoring it.
  static const defaultIntents = (1 << 25) | (1 << 30);

  final String appId;
  final bool enabled;

  /// Sandbox bots talk to the sandbox API host. Production is the default
  /// because a sandbox bot cannot reach real users.
  final bool sandbox;
  final int intents;

  /// openids of people allowed to drive the agent. Empty: nobody.
  final Set<String> allowedUsers;

  /// group_openids the bot may answer in. Empty: no group.
  final Set<String> allowedGroups;

  final bool allowDirect;
  final bool allowGroup;
  final bool requireMentionInGroups;

  bool get configured => appId.isNotEmpty;

  ChannelPolicy get policy => ChannelPolicy(
    allowedUsers: allowedUsers,
    allowedGroups: allowedGroups,
    allowDirectMessages: allowDirect,
    allowGroupMessages: allowGroup,
    requireMentionInGroups: requireMentionInGroups,
  );

  OfficialQqConfig copyWith({
    String? appId,
    bool? enabled,
    bool? sandbox,
    int? intents,
    Set<String>? allowedUsers,
    Set<String>? allowedGroups,
    bool? allowDirect,
    bool? allowGroup,
    bool? requireMentionInGroups,
  }) => OfficialQqConfig(
    appId: appId ?? this.appId,
    enabled: enabled ?? this.enabled,
    sandbox: sandbox ?? this.sandbox,
    intents: intents ?? this.intents,
    allowedUsers: allowedUsers ?? this.allowedUsers,
    allowedGroups: allowedGroups ?? this.allowedGroups,
    allowDirect: allowDirect ?? this.allowDirect,
    allowGroup: allowGroup ?? this.allowGroup,
    requireMentionInGroups:
        requireMentionInGroups ?? this.requireMentionInGroups,
  );

  Map<String, Object?> toJson() => {
    'appId': appId,
    'enabled': enabled,
    'sandbox': sandbox,
    'intents': intents,
    'allowedUsers': allowedUsers.toList(),
    'allowedGroups': allowedGroups.toList(),
    'allowDirect': allowDirect,
    'allowGroup': allowGroup,
    'requireMentionInGroups': requireMentionInGroups,
  };

  static OfficialQqConfig fromJson(Map<String, Object?> json) =>
      OfficialQqConfig(
        appId: json['appId']?.toString() ?? '',
        enabled: json['enabled'] == true,
        sandbox: json['sandbox'] == true,
        intents: (json['intents'] as num?)?.toInt() ?? defaultIntents,
        allowedUsers: _stringSet(json['allowedUsers']),
        allowedGroups: _stringSet(json['allowedGroups']),
        allowDirect: json['allowDirect'] != false,
        allowGroup: json['allowGroup'] != false,
        requireMentionInGroups: json['requireMentionInGroups'] != false,
      );
}

/// Which protocol implementation the account talks to.
///
/// All three speak OneBot 11 over a WebSocket; the value chooses the defaults
/// and the words on the page, never a different wire format. Adding a fourth
/// implementation that speaks OneBot 11 means adding a value here.
enum OneBotBackend {
  llbot('llbot'),
  napcat('napcat'),
  snowLuma('snowluma');

  const OneBotBackend(this.id);

  /// Stored form. Never the enum name: renaming a value must not lose the
  /// setting.
  final String id;

  static OneBotBackend fromId(String? id) => values.firstWhere(
    (value) => value.id == id,
    orElse: () => OneBotBackend.llbot,
  );
}

/// Which side opens the socket, stored as a string for the same reason.
enum OneBotTransport {
  forward('forward'),
  reverse('reverse');

  const OneBotTransport(this.id);

  final String id;

  static OneBotTransport fromId(String? id) => values.firstWhere(
    (value) => value.id == id,
    orElse: () => OneBotTransport.forward,
  );
}

/// Everything stored about a OneBot 11 account, minus its access token.
@immutable
class OneBot11Config {
  const OneBot11Config({
    this.backend = OneBotBackend.llbot,
    this.transport = OneBotTransport.forward,
    this.webSocketUrl = '',
    this.listenPort = defaultListenPort,
    this.expectedSelfId = '',
    this.enabled = false,
    this.allowedUsers = const {},
    this.allowedGroups = const {},
    this.allowDirect = true,
    this.allowGroup = true,
    this.requireMentionInGroups = true,
  });

  /// The port a reverse connection listens on. 8082 is what NapCat's WebSocket
  /// client ships with, so the default needs only the phone's address.
  static const defaultListenPort = 8082;

  final OneBotBackend backend;
  final OneBotTransport transport;

  /// The forward WebSocket address, for example `ws://192.168.1.10:3001`.
  final String webSocketUrl;

  /// Where a reverse connection listens. Ignored in forward mode.
  final int listenPort;

  /// The QQ number the OneBot implementation reports as `self_id`. Checked
  /// against the first lifecycle event; a mismatch stops the connection
  /// instead of answering as the wrong account.
  final String expectedSelfId;

  final bool enabled;
  final Set<String> allowedUsers;
  final Set<String> allowedGroups;
  final bool allowDirect;
  final bool allowGroup;
  final bool requireMentionInGroups;

  bool get configured => transport == OneBotTransport.forward
      ? webSocketUrl.isNotEmpty
      : listenPort > 0 && listenPort <= 65535;

  /// Plain `ws://` to a non-loopback host sends the access token in clear
  /// text. Allowed (home LANs are common) but always reported in the UI.
  bool get isInsecureTransport {
    final uri = Uri.tryParse(webSocketUrl);
    if (uri == null || uri.scheme != 'ws') return false;
    final host = uri.host.toLowerCase();
    return !(host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host.endsWith('.local'));
  }

  ChannelPolicy get policy => ChannelPolicy(
    allowedUsers: allowedUsers,
    allowedGroups: allowedGroups,
    allowDirectMessages: allowDirect,
    allowGroupMessages: allowGroup,
    requireMentionInGroups: requireMentionInGroups,
  );

  OneBot11Config copyWith({
    OneBotBackend? backend,
    OneBotTransport? transport,
    String? webSocketUrl,
    int? listenPort,
    String? expectedSelfId,
    bool? enabled,
    Set<String>? allowedUsers,
    Set<String>? allowedGroups,
    bool? allowDirect,
    bool? allowGroup,
    bool? requireMentionInGroups,
  }) => OneBot11Config(
    backend: backend ?? this.backend,
    transport: transport ?? this.transport,
    webSocketUrl: webSocketUrl ?? this.webSocketUrl,
    listenPort: listenPort ?? this.listenPort,
    expectedSelfId: expectedSelfId ?? this.expectedSelfId,
    enabled: enabled ?? this.enabled,
    allowedUsers: allowedUsers ?? this.allowedUsers,
    allowedGroups: allowedGroups ?? this.allowedGroups,
    allowDirect: allowDirect ?? this.allowDirect,
    allowGroup: allowGroup ?? this.allowGroup,
    requireMentionInGroups:
        requireMentionInGroups ?? this.requireMentionInGroups,
  );

  Map<String, Object?> toJson() => {
    'backend': backend.id,
    'transport': transport.id,
    'webSocketUrl': webSocketUrl,
    'listenPort': listenPort,
    'expectedSelfId': expectedSelfId,
    'enabled': enabled,
    'allowedUsers': allowedUsers.toList(),
    'allowedGroups': allowedGroups.toList(),
    'allowDirect': allowDirect,
    'allowGroup': allowGroup,
    'requireMentionInGroups': requireMentionInGroups,
  };

  static OneBot11Config fromJson(Map<String, Object?> json) => OneBot11Config(
    backend: OneBotBackend.fromId(json['backend']?.toString()),
    transport: OneBotTransport.fromId(json['transport']?.toString()),
    webSocketUrl: json['webSocketUrl']?.toString() ?? '',
    listenPort: (json['listenPort'] as num?)?.toInt() ?? defaultListenPort,
    expectedSelfId: json['expectedSelfId']?.toString() ?? '',
    enabled: json['enabled'] == true,
    allowedUsers: _stringSet(json['allowedUsers']),
    allowedGroups: _stringSet(json['allowedGroups']),
    allowDirect: json['allowDirect'] != false,
    allowGroup: json['allowGroup'] != false,
    requireMentionInGroups: json['requireMentionInGroups'] != false,
  );
}

Set<String> _stringSet(Object? raw) {
  if (raw is! List) return const {};
  return {
    for (final entry in raw)
      if (entry != null && entry.toString().trim().isNotEmpty)
        entry.toString().trim(),
  };
}

/// Reads and writes channel configuration.
///
/// Secrets live in the platform keystore through the app's existing secure
/// storage; everything else is ordinary preferences. Every write validates
/// first, so a bad AppID cannot reach the network and a half-typed WebSocket
/// URL cannot replace a working one.
class ChannelConfigStore {
  ChannelConfigStore({
    required SharedPreferences preferences,
    required FlutterSecureStorage secureStorage,
  }) : _preferences = preferences,
       _secureStorage = secureStorage;

  static const _qqPrefix = 'oc.channels.qqOfficial.';
  static const _oneBotPrefix = 'oc.channels.onebot11.';
  static const qqSecretKey = '${_qqPrefix}clientSecret';
  static const oneBotTokenKey = '${_oneBotPrefix}accessToken';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;

  // ------------------------------------------------------------ official QQ

  OfficialQqConfig loadOfficialQq() {
    final raw = _preferences.getString('${_qqPrefix}config');
    if (raw == null || raw.isEmpty) return const OfficialQqConfig();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return OfficialQqConfig.fromJson(Map<String, Object?>.from(decoded));
      }
    } on FormatException {
      // Fall through to the empty config: a corrupt record must not stop the
      // settings page from opening so the person can fix it.
    }
    return const OfficialQqConfig();
  }

  Future<String?> readOfficialQqSecret() async {
    final secret = await _secureStorage.read(key: qqSecretKey);
    if (secret != null && secret.isNotEmpty) {
      KitRedact.registerKnownSecret(secret);
    }
    return secret;
  }

  Future<void> saveOfficialQq(
    OfficialQqConfig config, {
    String? clientSecret,
  }) async {
    final appId = config.appId.trim();
    if (config.enabled && !RegExp(r'^[0-9]{5,20}$').hasMatch(appId)) {
      throw const FormatException('AppID 需要是 5 到 20 位数字。');
    }
    final secret = clientSecret?.trim();
    if (secret != null && secret.isNotEmpty) {
      if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(secret)) {
        throw const FormatException('ClientSecret 格式不正确。');
      }
      await _secureStorage.write(key: qqSecretKey, value: secret);
      KitRedact.registerKnownSecret(secret);
    }
    if (config.enabled) {
      final stored = await readOfficialQqSecret();
      if (stored == null || stored.isEmpty) {
        throw const FormatException('启用前需要先填写 ClientSecret。');
      }
    }
    final saved = await _preferences.setString(
      '${_qqPrefix}config',
      jsonEncode(config.copyWith(appId: appId).toJson()),
    );
    if (!saved) {
      throw const FormatException('无法保存 QQ 官方机器人配置。');
    }
  }

  Future<void> clearOfficialQq() async {
    await _preferences.remove('${_qqPrefix}config');
    await _secureStorage.delete(key: qqSecretKey);
  }

  // --------------------------------------------------------------- OneBot 11

  OneBot11Config loadOneBot11() {
    final raw = _preferences.getString('${_oneBotPrefix}config');
    if (raw == null || raw.isEmpty) return const OneBot11Config();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return OneBot11Config.fromJson(Map<String, Object?>.from(decoded));
      }
    } on FormatException {
      // Same reasoning as the official config.
    }
    return const OneBot11Config();
  }

  Future<String?> readOneBot11Token() async {
    final token = await _secureStorage.read(key: oneBotTokenKey);
    if (token != null && token.isNotEmpty) {
      KitRedact.registerKnownSecret(token);
    }
    return token;
  }

  Future<void> saveOneBot11(
    OneBot11Config config, {
    String? accessToken,
  }) async {
    final url = config.webSocketUrl.trim();
    final reverse = config.transport == OneBotTransport.reverse;
    if (!reverse && (config.enabled || url.isNotEmpty)) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'ws' && uri.scheme != 'wss') ||
          uri.host.isEmpty) {
        throw const FormatException(
          'WebSocket 地址需要以 ws:// 或 wss:// 开头，并包含主机和端口。',
        );
      }
    }
    if (reverse && (config.listenPort < 1 || config.listenPort > 65535)) {
      throw const FormatException('监听端口需要在 1 到 65535 之间。');
    }
    final selfId = config.expectedSelfId.trim();
    if (selfId.isNotEmpty && !RegExp(r'^[0-9]{5,12}$').hasMatch(selfId)) {
      throw const FormatException('预期 QQ 账号需要是 5 到 12 位数字。');
    }
    final token = accessToken?.trim();
    if (token != null && token.isNotEmpty) {
      if (token.length < 4 || token.contains(RegExp(r'\s'))) {
        throw const FormatException('Access Token 不能包含空白字符。');
      }
      await _secureStorage.write(key: oneBotTokenKey, value: token);
      KitRedact.registerKnownSecret(token);
    }
    if (config.enabled && !reverse && url.isEmpty) {
      throw const FormatException('启用前需要填写 OneBot 11 的 WebSocket 地址。');
    }
    if (config.enabled && reverse) {
      final stored = await _secureStorage.read(key: oneBotTokenKey);
      if (stored == null || stored.trim().isEmpty) {
        throw const FormatException('反向连接启用前需要设置 Access Token。');
      }
    }
    final saved = await _preferences.setString(
      '${_oneBotPrefix}config',
      jsonEncode(
        config.copyWith(webSocketUrl: url, expectedSelfId: selfId).toJson(),
      ),
    );
    if (!saved) {
      throw const FormatException('无法保存 OneBot 11 配置。');
    }
  }

  Future<void> clearOneBot11() async {
    await _preferences.remove('${_oneBotPrefix}config');
    await _secureStorage.delete(key: oneBotTokenKey);
  }
}
