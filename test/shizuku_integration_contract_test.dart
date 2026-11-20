import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// Contract checks that the packaging and the native module keep the shape the
/// Shizuku server and this app agreed on.
///
/// They read the sources instead of duplicating behaviour: the behavioural
/// checks live in the Kotlin unit tests and the widget test.
void main() {
  const module =
      'android/app/src/main/kotlin/com/azx8788/opencode/mini/shizuku';
  String source(String name) => File('$module/$name').readAsStringSync();
  String manifest() =>
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  group('manager discovery', () {
    test('the ShizukuProvider is registered the way the SDK documents', () {
      final provider = XmlDocument.parse(manifest())
          .findAllElements('provider')
          .singleWhere(
            (element) =>
                element.getAttribute('android:name') ==
                'rikka.shizuku.ShizukuProvider',
          );
      expect(
        provider.getAttribute('android:authorities'),
        r'${applicationId}.shizuku',
      );
      expect(provider.getAttribute('android:exported'), 'true');
      expect(provider.getAttribute('android:multiprocess'), 'false');
      expect(
        provider.getAttribute('android:permission'),
        'android.permission.INTERACT_ACROSS_USERS_FULL',
      );
    });

    // ShizukuService.getApplications() lists a package only when it both
    // requests API_V23 and advertises V3_SUPPORT. Missing either one means the
    // app can never appear in the manager's list, so a request looks like it
    // fails and nothing is remembered.
    test('the package meets the two conditions the server filters on', () {
      final document = XmlDocument.parse(manifest());
      final requested = document
          .findAllElements('uses-permission')
          .map((element) => element.getAttribute('android:name'))
          .toList();
      expect(requested, contains('moe.shizuku.manager.permission.API_V23'));

      final advertised = document
          .findAllElements('meta-data')
          .where(
            (element) =>
                element.getAttribute('android:name') ==
                'moe.shizuku.client.V3_SUPPORT',
          )
          .toList();
      expect(advertised, hasLength(1));
      expect(advertised.single.getAttribute('android:value'), 'true');
    });

    test('the provider conditions are checked separately from the list ones', () {
      final probe = source('Probes.kt');
      expect(probe, contains('provider.readPermission'));
      expect(probe, contains('provider.writePermission'));
      // ProviderInfo has no `permission` field; a build that names one does not
      // compile, which is why the previous attempt never reached CI green.
      expect(probe, isNot(contains('provider.permission')));
      expect(
        source('Model.kt'),
        contains('val listed: Boolean get() = permissionDeclared && v3Support'),
      );
    });

    test('the safety overlay permission is declared', () {
      expect(manifest(), contains('android.permission.SYSTEM_ALERT_WINDOW'));
    });
  });

  group('authorization is read from the server, not from a cache', () {
    test('the live transaction is used and the cached SDK call is not', () {
      // Comments may name the API they explain; only code counts.
      final probe = _stripComments(source('Probes.kt'));
      expect(probe, contains('IShizukuService.Stub.asInterface(binder)'));
      expect(probe, contains('service.checkSelfPermission()'));
      expect(probe, isNot(contains('Shizuku.checkSelfPermission')));
      // The rationale field is a server-side "explicitly denied" flag, not
      // "not granted", so it must not decide anything.
      expect(probe, isNot(contains('shouldShowRequestPermissionRationale')));
    });

    test('an answer that could not be read is never "granted"', () {
      final model = source('Model.kt');
      expect(model, contains('UNKNOWN("unknown")'));
      expect(
        model,
        contains(
          'state == AuthorizationState.GRANTED && evidence == AuthorizationEvidence.SERVER',
        ),
      );
      expect(model, contains('val executionAdmitted: Boolean'));
    });

    test('a missing callback is recorded as unconfirmed, not as a denial', () {
      final request = source('Authorization.kt');
      expect(request, contains('RequestPhase.UNCONFIRMED'));
      expect(request, contains('"callback_missing"'));
      expect(request, contains('fun interrupt('));
    });

    test('a revocation replaces a remembered grant', () {
      final request = source('Authorization.kt');
      expect(request, contains('"permission_revoked"'));
      expect(request, contains('fun sync(live: AuthorizationReading)'));
    });
  });

  group('execution admission', () {
    test('every fact has its own reason instead of one boolean', () {
      final model = source('Model.kt');
      for (final reason in [
        'feature_disabled',
        'app_not_listed',
        'provider_misconfigured',
        'shizuku_not_running',
        'shizuku_binder_dead',
        'authorization_pending',
        'authorization_unknown',
        'authorization_denied',
        'identity_unsupported',
        'operation_storage_unavailable',
        'user_service_not_ready',
      ]) {
        expect(model, contains('"$reason"'), reason: reason);
      }
    });

    test('a command is re-checked against the live answer before dispatch', () {
      final runtime = source('Runtime.kt');
      expect(runtime, contains('journal.dispatch('));
      expect(runtime, contains('if (!live.grantsExecution)'));
      expect(runtime, contains('authorization_unconfirmed'));
    });

    test('the UserService is bound through the SDK and handshaken by status', () {
      final runtime = source('Runtime.kt');
      expect(runtime, contains('Shizuku.bindUserService('));
      expect(runtime, contains('JSONObject(api.status())'));
      expect(runtime, contains('session.expire(epoch)'));
      expect(runtime, contains('session.connected(epoch'));
      expect(runtime, contains('handshake.protocol != Protocol.VERSION'));
      expect(runtime, contains('handshake.uid != serverUid'));
    });

    test('the overlay is fail-closed and cancels by operation id', () {
      final overlay = source('Overlay.kt');
      expect(overlay, contains('TYPE_APPLICATION_OVERLAY'));
      expect(overlay, contains('FLAG_SECURE'));
      expect(overlay, contains('canDrawOverlays'));
      expect(overlay, contains('complete(false)'));
      expect(source('Runtime.kt'), contains('SafetyOverlay.cancel(id)'));
    });

    test('the old module is gone instead of running next to the new one', () {
      for (final legacy in [
        'ShizukuController.kt',
        'ShizukuPermissionRequest.kt',
        'ShizukuBindingState.kt',
      ]) {
        expect(
          File(
            'android/app/src/main/kotlin/com/azx8788/opencode/mini/$legacy',
          ).existsSync(),
          isFalse,
          reason: '$legacy must not survive the rewrite',
        );
      }
    });
  });

  group('UserService wire contract', () {
    final aidl = File(
      'android/app/src/main/aidl/com/azx8788/opencode/mini/shizuku/IShizukuCommandService.aidl',
    ).readAsStringSync();

    test('the official destroy transaction id is reserved', () {
      expect(aidl, contains('void destroy() = 16777114;'));
      expect(aidl, contains('String execute(String operationId'));
      expect(aidl, contains('String expectedInstance, int expectedUid'));
      expect(aidl, contains('boolean cancel(String operationId) = 2;'));
      expect(aidl, contains('String status() = 3;'));
      expect(aidl, contains('String result(String operationId) = 4;'));
    });

    test('the service class and its stub survive minification', () {
      final rules = File(
        'android/app/shizuku-user-service.pro',
      ).readAsStringSync();
      expect(
        rules,
        contains('com.azx8788.opencode.mini.shizuku.CommandService'),
      );
      expect(
        rules,
        contains('com.azx8788.opencode.mini.shizuku.IShizukuCommandService'),
      );
      expect(rules, contains('rikka.shizuku.ShizukuProvider'));
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('shizuku-user-service.pro'));
      expect(gradle, contains('dev.rikka.shizuku:api:13.1.5'));
      expect(gradle, contains('dev.rikka.shizuku:provider:13.1.5'));
    });

    test('the service reports its own pid instead of Process.pid', () {
      final service = source('CommandService.kt');
      expect(service, contains('OCRPID='));
      expect(_callsUnsupportedPid(service), isFalse);
      expect(_callsUnsupportedPid('val pid = process.pid()'), isTrue);
      expect(_callsUnsupportedPid('val pid = process . pid ( )'), isTrue);
      expect(
        _callsUnsupportedPid(
          '/* Process.pid() is unavailable. */\n// Do not use process.pid() here.\nval pid = running.pid.get()',
        ),
        isFalse,
      );
    });
  });

  group('AI bridge', () {
    test('the socket is filesystem-scoped and the peer uid is checked', () {
      final bridge = source('NativeBridge.kt');
      expect(bridge, contains('LocalSocketAddress.Namespace.FILESYSTEM'));
      expect(bridge, contains('peerCredentials'));
      expect(bridge, contains('Protocol.MAX_REQUEST_BYTES'));
      expect(
        RegExp(r'(^|[^A-Za-z])ServerSocket\s*\(').hasMatch(bridge),
        isFalse,
      );
    });

    test('a stale broker or service instance cannot submit a command', () {
      final runtime = source('Runtime.kt');
      expect(runtime, contains('bridgeInstance'));
      expect(runtime, contains('instance_changed'));
      expect(runtime, contains('serviceInstance'));
    });
  });
}

String _stripComments(String source) =>
    source.replaceAll(RegExp(r'/\*[\s\S]*?\*/|//[^\r\n]*'), '');

bool _callsUnsupportedPid(String source) {
  final code = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/|//[^\r\n]*'), '');
  return RegExp(r'\.\s*pid\s*\(').hasMatch(code);
}
