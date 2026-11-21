import 'package:flutter/services.dart';

/// Thin bridge to the app-owned Android Shizuku controller.
class ShizukuPlatform {
  static const _methods = MethodChannel('oc/shizuku');
  static const _events = EventChannel('oc/shizuku/events');

  static final Stream<Map<String, Object?>> changes = _events
      .receiveBroadcastStream()
      .map(_readStatus);

  static Map<String, Object?> _readStatus(Object? value) {
    if (value is! Map ||
        value['statusRevision'] is! int ||
        (value['statusRevision'] as int) < 0 ||
        value['enabled'] is! bool ||
        value['binderAlive'] is! bool ||
        value['permission'] is! String ||
        value['binding'] is! String ||
        value['executionReady'] is! bool) {
      throw PlatformException(code: 'invalid_shizuku_status');
    }
    return Map<String, Object?>.from(value);
  }

  static bool _validSettings(Map<String, Object?>? value) =>
      value != null &&
      value['direct_read_only'] is bool &&
      value['advanced_mode'] is bool &&
      value['allow_delay_seconds'] is int &&
      value['overlay_timeout_seconds'] is int &&
      value['command_timeout_seconds'] is int &&
      value['max_output_kib'] is int &&
      (value['allow_delay_seconds'] as int) >= 0 &&
      (value['allow_delay_seconds'] as int) <= 60 &&
      (value['overlay_timeout_seconds'] as int) >= 10 &&
      (value['overlay_timeout_seconds'] as int) <= 120 &&
      (value['overlay_timeout_seconds'] as int) >
          (value['allow_delay_seconds'] as int) &&
      (value['command_timeout_seconds'] as int) >= 1 &&
      (value['command_timeout_seconds'] as int) <= 120 &&
      (value['max_output_kib'] as int) >= 4 &&
      (value['max_output_kib'] as int) <= 256;

  static Future<Map<String, Object?>> status() async =>
      _readStatus(await _methods.invokeMethod<Object?>('status'));

  static Future<Map<String, Object?>> settings() async {
    final value = await _methods.invokeMapMethod<String, Object?>('settings');
    if (!_validSettings(value)) {
      throw PlatformException(code: 'invalid_shizuku_settings');
    }
    return Map<String, Object?>.from(value!);
  }

  static Future<Map<String, Object?>> saveSettings({
    required bool directReadOnly,
    required bool advancedMode,
    required int allowDelaySeconds,
    required int overlayTimeoutSeconds,
    required int commandTimeoutSeconds,
    required int maxOutputKiB,
  }) async {
    final value = await _methods.invokeMapMethod<String, Object?>(
      'saveSettings',
      {
        'direct_read_only': directReadOnly,
        'advanced_mode': advancedMode,
        'allow_delay_seconds': allowDelaySeconds,
        'overlay_timeout_seconds': overlayTimeoutSeconds,
        'command_timeout_seconds': commandTimeoutSeconds,
        'max_output_kib': maxOutputKiB,
      },
    );
    if (!_validSettings(value)) {
      throw PlatformException(code: 'invalid_shizuku_settings');
    }
    return Map<String, Object?>.from(value!);
  }

  static Future<void> requestPermission() =>
      _methods.invokeMethod<void>('requestPermission');

  /// Retry a failed binding and wait for the actual UserService handshake.
  static Future<void> reconnect() =>
      _methods.invokeMethod<void>('startService');

  static Future<bool> openManager() async =>
      await _methods.invokeMethod<bool>('openManager') ?? false;

  static Future<void> overlaySettings() =>
      _methods.invokeMethod<void>('overlaySettings');

  static Future<Map<String, Object?>> setEnabled(bool enabled) async =>
      _readStatus(
        await _methods.invokeMethod<Object?>('setEnabled', {
          'enabled': enabled,
        }),
      );

  static Future<Map<String, Object?>> diagnostic(String operationId) async =>
      Map<String, Object?>.from(
        await _methods.invokeMapMethod<String, Object?>('diagnostic', {
              'operationId': operationId,
            }) ??
            const {},
      );

  static Future<Map<String, Object?>> execute({
    required String operationId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
  }) async => Map<String, Object?>.from(
    await _methods.invokeMapMethod<String, Object?>('execute', {
          'operationId': operationId,
          'command': command,
          'timeoutMs': timeout.inMilliseconds,
        }) ??
        const {},
  );

  static Future<bool> cancel(String operationId) async =>
      await _methods.invokeMethod<bool>('cancel', {
        'operationId': operationId,
      }) ??
      false;
}
