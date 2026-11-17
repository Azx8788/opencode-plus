import 'package:flutter/services.dart';

/// Thin bridge to the app-owned Android Shizuku controller.
class ShizukuPlatform {
  static const _methods = MethodChannel('oc/shizuku');
  static const _events = EventChannel('oc/shizuku/events');

  static Stream<Map<String, Object?>> get changes => _events
      .receiveBroadcastStream()
      .where((value) => value is Map)
      .map((value) => Map<String, Object?>.from(value as Map));

  static Future<Map<String, Object?>> status() async => Map<String, Object?>.from(
    await _methods.invokeMapMethod<String, Object?>('status') ?? const {},
  );

  static Future<Map<String, Object?>> settings() async =>
      Map<String, Object?>.from(
        await _methods.invokeMapMethod<String, Object?>('settings') ?? const {},
      );

  static Future<Map<String, Object?>> saveSettings({
    required bool directReadOnly,
    required bool advancedMode,
    required int allowDelaySeconds,
    required int overlayTimeoutSeconds,
    required int commandTimeoutSeconds,
    required int maxOutputKiB,
  }) async =>
      Map<String, Object?>.from(
        await _methods.invokeMapMethod<String, Object?>('saveSettings', {
              'direct_read_only': directReadOnly,
              'advanced_mode': advancedMode,
              'allow_delay_seconds': allowDelaySeconds,
              'overlay_timeout_seconds': overlayTimeoutSeconds,
              'command_timeout_seconds': commandTimeoutSeconds,
              'max_output_kib': maxOutputKiB,
            }) ??
            const {},
      );

  static Future<void> requestPermission() =>
      _methods.invokeMethod<void>('requestPermission');

  static Future<bool> openManager() async =>
      await _methods.invokeMethod<bool>('openManager') ?? false;

  static Future<void> overlaySettings() =>
      _methods.invokeMethod<void>('overlaySettings');

  static Future<Map<String, Object?>> setEnabled(bool enabled) async =>
      Map<String, Object?>.from(
        await _methods.invokeMapMethod<String, Object?>(
              'setEnabled',
              {'enabled': enabled},
            ) ??
            const {},
      );

  static Future<Map<String, Object?>> diagnostic(String operationId) async =>
      Map<String, Object?>.from(
        await _methods.invokeMapMethod<String, Object?>(
              'diagnostic',
              {'operationId': operationId},
            ) ??
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
      await _methods.invokeMethod<bool>('cancel', {'operationId': operationId}) ??
      false;
}
