/// Dart side of the Shizuku contract.
///
/// The native side keeps every fact separate (manager, registration, binder,
/// authorization, request, identity, UserService, storage, bridge) and this
/// layer parses them as separate values too. Nothing here derives "authorized"
/// from a local switch, a previous result or a connected UserService.
library;

import 'package:flutter/services.dart';

/// Contract version the native side must report. A mismatch is refused rather
/// than interpreted, so an older APK cannot be shown as a newer state.
const int shizukuContractVersion = 2;

enum ShizukuManager { installed, notInstalled, unknown }

/// The answer to "may this app execute", with the evidence behind it.
enum ShizukuAuthorization { granted, denied, unknown }

enum ShizukuRequestPhase {
  idle,
  pending,
  granted,
  denied,
  unavailable,
  unconfirmed,
  interrupted,
}

enum ShizukuSessionPhase { stopped, binding, handshaking, ready, failed }

enum ShizukuBinder { absent, alive, dead }

class ShizukuRegistration {
  const ShizukuRegistration({
    required this.applicationId,
    required this.listed,
    required this.permissionDeclared,
    required this.v3Support,
    required this.providerConfigured,
    this.providerAuthority,
  });

  final String applicationId;
  final bool listed;
  final bool permissionDeclared;
  final bool v3Support;
  final bool providerConfigured;
  final String? providerAuthority;
}

class ShizukuRequest {
  const ShizukuRequest({
    required this.phase,
    this.reason,
    this.requestCode,
    this.attempts = 0,
    this.startedAt,
  });

  final ShizukuRequestPhase phase;
  final String? reason;
  final int? requestCode;
  final int attempts;
  final int? startedAt;
}

class ShizukuIdentity {
  const ShizukuIdentity({
    this.uid,
    this.backend = 'unknown',
    this.apiVersion,
    this.patchVersion,
    this.selinuxContext,
    this.supported = false,
  });

  final int? uid;
  final String backend;
  final int? apiVersion;
  final int? patchVersion;
  final String? selinuxContext;
  final bool supported;
}

class ShizukuSession {
  const ShizukuSession({
    required this.phase,
    this.reason,
    this.instance,
    this.uid,
    this.serviceVersion,
  });

  final ShizukuSessionPhase phase;
  final String? reason;
  final String? instance;
  final int? uid;
  final int? serviceVersion;
}

/// One immutable reading of the whole integration.
class ShizukuSnapshot {
  const ShizukuSnapshot({
    required this.observedAt,
    required this.featureEnabled,
    required this.manager,
    required this.registration,
    required this.binder,
    required this.binderGeneration,
    required this.provider,
    required this.authorization,
    required this.authorizationEvidence,
    required this.authorizationReason,
    required this.authorizationAgeMs,
    required this.request,
    required this.identity,
    required this.session,
    required this.storageReady,
    required this.storageReason,
    required this.bridgeReady,
    required this.bridgeReason,
    required this.overlayAllowed,
    required this.executionAdmitted,
    required this.blockedBy,
  });

  final int observedAt;
  final bool featureEnabled;
  final ShizukuManager manager;
  final ShizukuRegistration registration;
  final ShizukuBinder binder;
  final int binderGeneration;
  final String provider;
  final ShizukuAuthorization authorization;
  final String authorizationEvidence;
  final String? authorizationReason;
  final int authorizationAgeMs;
  final ShizukuRequest request;
  final ShizukuIdentity identity;
  final ShizukuSession session;
  final bool storageReady;
  final String? storageReason;
  final bool bridgeReady;
  final String? bridgeReason;
  final bool overlayAllowed;
  final bool executionAdmitted;
  final String? blockedBy;

  /// Only a live server answer admits a command. This repeats the native rule
  /// on the Dart side so a malformed snapshot can never look authorized.
  bool get authorizedByServer =>
      authorization == ShizukuAuthorization.granted &&
      authorizationEvidence == 'server';

  factory ShizukuSnapshot.fromMap(Map<Object?, Object?> map) {
    final version = _int(map['contractVersion']);
    if (version != shizukuContractVersion) {
      throw FormatException(
        'Unsupported Shizuku contract: ${version ?? 'missing'}',
      );
    }
    final manager = _map(map['manager']);
    final registration = _map(map['registration']);
    final binder = _map(map['binder']);
    final authorization = _map(map['authorization']);
    final request = _map(map['request']);
    final identity = _map(map['identity']);
    final session = _map(map['session']);
    final storage = _map(map['storage']);
    final bridge = _map(map['bridge']);
    final overlay = _map(map['overlay']);
    final execution = _map(map['execution']);
    return ShizukuSnapshot(
      observedAt: _int(map['observedAt']) ?? 0,
      featureEnabled: _map(map['feature'])['enabled'] == true,
      manager: switch (manager['state']) {
        'installed' => ShizukuManager.installed,
        'not_installed' => ShizukuManager.notInstalled,
        _ => ShizukuManager.unknown,
      },
      registration: ShizukuRegistration(
        applicationId: _string(registration['applicationId']) ?? '',
        listed: registration['listed'] == true,
        permissionDeclared: registration['permissionDeclared'] == true,
        v3Support: registration['v3Support'] == true,
        providerConfigured: registration['providerConfigured'] == true,
        providerAuthority: _string(registration['providerAuthority']),
      ),
      binder: switch (binder['state']) {
        'alive' => ShizukuBinder.alive,
        'dead' => ShizukuBinder.dead,
        _ => ShizukuBinder.absent,
      },
      binderGeneration: _int(binder['generation']) ?? 0,
      provider: _string(binder['provider']) ?? 'unknown',
      authorization: switch (authorization['state']) {
        'granted' => ShizukuAuthorization.granted,
        'denied' => ShizukuAuthorization.denied,
        _ => ShizukuAuthorization.unknown,
      },
      authorizationEvidence: _string(authorization['evidence']) ?? 'none',
      authorizationReason: _string(authorization['reason']),
      authorizationAgeMs: _int(authorization['ageMs']) ?? 0,
      request: ShizukuRequest(
        phase: switch (request['phase']) {
          'pending' => ShizukuRequestPhase.pending,
          'granted' => ShizukuRequestPhase.granted,
          'denied' => ShizukuRequestPhase.denied,
          'unavailable' => ShizukuRequestPhase.unavailable,
          'unconfirmed' => ShizukuRequestPhase.unconfirmed,
          'interrupted' => ShizukuRequestPhase.interrupted,
          _ => ShizukuRequestPhase.idle,
        },
        reason: _string(request['reason']),
        requestCode: _int(request['requestCode']),
        attempts: _int(request['attempts']) ?? 0,
        startedAt: _int(request['startedAt']),
      ),
      identity: ShizukuIdentity(
        uid: _int(identity['uid']),
        backend: _string(identity['backend']) ?? 'unknown',
        apiVersion: _int(identity['apiVersion']),
        patchVersion: _int(identity['patchVersion']),
        selinuxContext: _string(identity['selinuxContext']),
        supported: identity['supported'] == true,
      ),
      session: ShizukuSession(
        phase: switch (session['phase']) {
          'binding' => ShizukuSessionPhase.binding,
          'handshaking' => ShizukuSessionPhase.handshaking,
          'ready' => ShizukuSessionPhase.ready,
          'failed' => ShizukuSessionPhase.failed,
          _ => ShizukuSessionPhase.stopped,
        },
        reason: _string(session['reason']),
        instance: _string(session['instance']),
        uid: _int(session['uid']),
        serviceVersion: _int(session['serviceVersion']),
      ),
      storageReady: storage['ready'] == true,
      storageReason: _string(storage['reason']),
      bridgeReady: bridge['ready'] == true,
      bridgeReason: _string(bridge['reason']),
      overlayAllowed: overlay['allowed'] == true,
      executionAdmitted: execution['admitted'] == true,
      blockedBy: _string(execution['blockedBy']),
    );
  }
}

class ShizukuPolicy {
  const ShizukuPolicy({
    required this.directReadOnly,
    required this.advancedMode,
    required this.allowDelaySeconds,
    required this.overlayTimeoutSeconds,
    required this.commandTimeoutSeconds,
    required this.maxOutputKiB,
  });

  final bool directReadOnly;
  final bool advancedMode;
  final int allowDelaySeconds;
  final int overlayTimeoutSeconds;
  final int commandTimeoutSeconds;
  final int maxOutputKiB;

  factory ShizukuPolicy.fromMap(Map<Object?, Object?> map) => ShizukuPolicy(
    directReadOnly: map['direct_read_only'] != false,
    advancedMode: map['advanced_mode'] == true,
    allowDelaySeconds: _int(map['allow_delay_seconds']) ?? 10,
    overlayTimeoutSeconds: _int(map['overlay_timeout_seconds']) ?? 30,
    commandTimeoutSeconds: _int(map['command_timeout_seconds']) ?? 30,
    maxOutputKiB: _int(map['max_output_kib']) ?? 64,
  );

  ShizukuPolicy copyWith({
    bool? directReadOnly,
    bool? advancedMode,
    int? allowDelaySeconds,
    int? overlayTimeoutSeconds,
    int? commandTimeoutSeconds,
    int? maxOutputKiB,
  }) => ShizukuPolicy(
    directReadOnly: directReadOnly ?? this.directReadOnly,
    advancedMode: advancedMode ?? this.advancedMode,
    allowDelaySeconds: allowDelaySeconds ?? this.allowDelaySeconds,
    overlayTimeoutSeconds: overlayTimeoutSeconds ?? this.overlayTimeoutSeconds,
    commandTimeoutSeconds: commandTimeoutSeconds ?? this.commandTimeoutSeconds,
    maxOutputKiB: maxOutputKiB ?? this.maxOutputKiB,
  );
}

class ShizukuPlatform {
  static const _methods = MethodChannel('oc/shizuku');
  static const _events = EventChannel('oc/shizuku/events');

  static Stream<ShizukuSnapshot> get changes => _events
      .receiveBroadcastStream()
      .where((value) => value is Map)
      .map((value) => ShizukuSnapshot.fromMap(value as Map<Object?, Object?>));

  static Future<ShizukuSnapshot> snapshot() async =>
      ShizukuSnapshot.fromMap(await _map('snapshot'));

  /// A snapshot without starting a bind; used by the diagnostics section.
  static Future<ShizukuSnapshot> diagnostics() async =>
      ShizukuSnapshot.fromMap(await _map('diagnostics'));

  static Future<ShizukuPolicy> readPolicy() async =>
      ShizukuPolicy.fromMap(await _map('policy.read'));

  static Future<ShizukuPolicy> writePolicy(ShizukuPolicy policy) async =>
      ShizukuPolicy.fromMap(
        await _map('policy.write', {
          'direct_read_only': policy.directReadOnly,
          'advanced_mode': policy.advancedMode,
          'allow_delay_seconds': policy.allowDelaySeconds,
          'overlay_timeout_seconds': policy.overlayTimeoutSeconds,
          'command_timeout_seconds': policy.commandTimeoutSeconds,
          'max_output_kib': policy.maxOutputKiB,
        }),
      );

  static Future<void> requestAuthorization() =>
      _methods.invokeMethod<void>('authorization.request');

  static Future<void> cancelAuthorization() =>
      _methods.invokeMethod<void>('authorization.cancel');

  static Future<ShizukuSnapshot> setFeatureEnabled(bool enabled) async =>
      ShizukuSnapshot.fromMap(
        await _map('feature.setEnabled', {'enabled': enabled}),
      );

  static Future<void> connectService() =>
      _methods.invokeMethod<void>('service.connect');

  static Future<void> disconnectService() =>
      _methods.invokeMethod<void>('service.disconnect');

  static Future<bool> openManager() async =>
      await _methods.invokeMethod<bool>('manager.open') ?? false;

  static Future<void> openOverlaySettings() =>
      _methods.invokeMethod<void>('overlay.open');

  static Future<Map<String, Object?>> execute({
    required String operationId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
  }) async => Map<String, Object?>.from(
    await _methods.invokeMapMethod<String, Object?>('command.execute', {
          'operationId': operationId,
          'command': command,
          'timeoutMs': timeout.inMilliseconds,
        }) ??
        const {},
  );

  static Future<Map<String, Object?>> diagnostic(String operationId) async =>
      Map<String, Object?>.from(
        await _methods.invokeMapMethod<String, Object?>('command.diagnostic', {
              'operationId': operationId,
            }) ??
            const {},
      );

  static Future<bool> cancel(String operationId) async =>
      await _methods.invokeMethod<bool>('command.cancel', {
        'operationId': operationId,
      }) ??
      false;

  static Future<Map<Object?, Object?>> _map(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final value = await _methods.invokeMapMethod<Object?, Object?>(
      method,
      arguments,
    );
    if (value == null) throw StateError('Shizuku returned no status');
    return value;
  }
}

int? _int(Object? value) => switch (value) {
  int v => v,
  num v => v.toInt(),
  String v => int.tryParse(v),
  _ => null,
};

String? _string(Object? value) => value is String ? value : null;

Map<Object?, Object?> _map(Object? value) =>
    value is Map ? value : const <Object?, Object?>{};
