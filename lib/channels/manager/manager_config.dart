/// The manager model's own configuration, kept apart from the executor's.
///
/// The executor is whatever the OpenCode server is configured with; the
/// manager is a separate model the person picks here. They are allowed to be
/// the same model, but nothing forces it: a small fast model can run the
/// conversation while a large one writes the code.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class ManagerAgentConfig {
  const ManagerAgentConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.model = '',
    this.maxSteps = 6,
  });

  /// Off by default: with it off, channels behave exactly as before.
  final bool enabled;

  /// `https://host/v1`, or the full `…/chat/completions` URL.
  final String baseUrl;

  final String model;

  /// How many model round trips one request may take before the manager gives
  /// up. A loop that keeps calling tools is a bug, not a conversation.
  final int maxSteps;

  bool get configured => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  bool get ready => enabled && configured;

  ManagerAgentConfig copyWith({
    bool? enabled,
    String? baseUrl,
    String? model,
    int? maxSteps,
  }) => ManagerAgentConfig(
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    maxSteps: maxSteps ?? this.maxSteps,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'baseUrl': baseUrl,
    'model': model,
    'maxSteps': maxSteps,
  };

  static ManagerAgentConfig fromJson(Map<String, Object?> json) =>
      ManagerAgentConfig(
        enabled: json['enabled'] == true,
        baseUrl: json['baseUrl']?.toString() ?? '',
        model: json['model']?.toString() ?? '',
        maxSteps: (json['maxSteps'] as num?)?.toInt() ?? 6,
      );
}

class ManagerConfigStore {
  ManagerConfigStore({
    required SharedPreferences preferences,
    required FlutterSecureStorage secureStorage,
  }) : _preferences = preferences,
       _secureStorage = secureStorage;

  static const _configKey = 'oc.channels.manager.config';
  static const _apiKeyKey = 'oc.channels.manager.apiKey';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;

  ManagerAgentConfig load() {
    final raw = _preferences.getString(_configKey);
    if (raw == null || raw.isEmpty) return const ManagerAgentConfig();
    try {
      final decoded = jsonDecodeMap(raw);
      if (decoded == null) return const ManagerAgentConfig();
      return ManagerAgentConfig.fromJson(decoded);
    } on FormatException {
      return const ManagerAgentConfig();
    }
  }

  Future<void> save(ManagerAgentConfig config) async {
    final url = config.baseUrl.trim();
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host.isEmpty) {
        throw const FormatException('管理模型地址需要以 https:// 或 http:// 开头，并包含主机。');
      }
    }
    if (config.enabled && (url.isEmpty || config.model.trim().isEmpty)) {
      throw const FormatException('启用管理代理前需要填写地址和模型名。');
    }
    if (config.enabled) {
      final key = await _secureStorage.read(key: _apiKeyKey);
      if (key == null || key.trim().isEmpty) {
        throw const FormatException('启用管理代理前需要填写 API Key。');
      }
    }
    await _preferences.setString(_configKey, jsonEncode(config.toJson()));
  }

  Future<String> loadApiKey() async =>
      await _secureStorage.read(key: _apiKeyKey) ?? '';

  Future<void> saveApiKey(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await _secureStorage.delete(key: _apiKeyKey);
      return;
    }
    await _secureStorage.write(key: _apiKeyKey, value: trimmed);
  }

  Future<void> clear() async {
    await _preferences.remove(_configKey);
    await _secureStorage.delete(key: _apiKeyKey);
  }
}

Map<String, Object?>? jsonDecodeMap(String raw) {
  try {
    final value = jsonDecode(raw);
    if (value is Map) return Map<String, Object?>.from(value);
  } on FormatException {
    return null;
  }
  return null;
}
