import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  group('Shizuku manifest and build contract', () {
    test('Shizuku provider is registered with app-scoped authority', () {
      final manifest = XmlDocument.parse(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      );
      final provider = manifest
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

    test('SYSTEM_ALERT_WINDOW is declared for the safety overlay', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest, contains('android.permission.SYSTEM_ALERT_WINDOW'));
    });

    // ShizukuService.getApplications() lists an app in the manager's authorized
    // list only when its manifest both requests API_V23 and advertises
    // V3_SUPPORT. An app missing either one cannot be granted there at all, so
    // a request appears to fail and the entry never survives.
    test('the manager can list this app: API_V23 requested and V3_SUPPORT advertised', () {
      final manifest = XmlDocument.parse(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      );
      final requested = manifest
          .findAllElements('uses-permission')
          .map((element) => element.getAttribute('android:name'))
          .toList();
      expect(requested, contains('moe.shizuku.manager.permission.API_V23'));
      final advertised = manifest
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

    test('authorization does not treat Shizuku rationale metadata as a denial', () {
      final controller = File(
        'android/app/src/main/kotlin/com/azx8788/opencode/mini/ShizukuController.kt',
      ).readAsStringSync();
      expect(controller, isNot(contains('shouldShowRequestPermissionRationale')));
      expect(controller, contains('permission.begin(requestCode)'));
      expect(controller, contains('permission.deliver(code'));
    });

    test('permission status reads live server state and validates manager listing requirements', () {
      final controller = File(
        'android/app/src/main/kotlin/com/azx8788/opencode/mini/ShizukuController.kt',
      ).readAsStringSync();
      expect(controller, contains('IShizukuService.Stub.asInterface(binder).checkSelfPermission()'));
      expect(controller, isNot(contains('Shizuku.checkSelfPermission()')));
      expect(controller, contains('private fun serverPermissionGranted(): Boolean?'));
      expect(controller, contains('permissionCheck == null -> "shizuku_permission_unverified"'));
      expect(controller, contains('info.requestedPermissions?.contains(ShizukuProvider.PERMISSION)'));
      expect(controller, contains('moe.shizuku.client.V3_SUPPORT'));
      expect(controller, contains('private fun shizukuProviderValid(context: Context)'));
      expect(controller, contains(r'"${context.packageName}.shizuku"'));
      expect(controller, contains('"shizuku_app_not_listable"'));
    });

    test(
      'Shizuku manager (moe.shizuku.privileged.api) is visible for queries',
      () {
        final manifest = File('android/app/src/main/AndroidManifest.xml')
            .readAsStringSync();
        expect(manifest, contains('moe.shizuku.privileged.api'));
      },
    );

    test('UserService contract reserves official destroy transaction', () {
      final aidl = File(
        'android/app/src/main/aidl/com/azx8788/opencode/mini/IShizukuCommandService.aidl',
      ).readAsStringSync();
      expect(aidl, contains('void destroy() = 16777114;'));
      // AIDL requires ids on every method once one is assigned.
      expect(aidl, contains('= 1;'));
      expect(aidl, contains('= 2;'));
      expect(aidl, contains('= 3;'));
      expect(aidl, contains('execute(String operationId'));
      expect(aidl, contains('boolean cancel(String operationId)'));
      expect(aidl, contains('String expectedInstance, int expectedUid'));
      expect(aidl, contains('String result(String operationId) = 4;'));
    });

    test('Shizuku SDK and UserService keep rules are pinned', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('dev.rikka.shizuku:api:13.1.5'));
      expect(gradle, contains('dev.rikka.shizuku:provider:13.1.5'));
      expect(gradle, contains('shizuku-user-service.pro'));
    });
  });

  group('Shizuku command policy: open but safe', () {
    final policy = File(
      'android/app/src/main/kotlin/com/azx8788/opencode/mini/ShizukuCommandPolicy.kt',
    ).readAsStringSync();
    final controller = File(
      'android/app/src/main/kotlin/com/azx8788/opencode/mini/ShizukuController.kt',
    ).readAsStringSync();

    test('read-only grammar exists and stays narrow', () {
      expect(policy, contains('isSafeReadOnly'));
      // Behavioral cases (including shell composition) run in the native
      // ShizukuCommandPolicyTest. Do not couple this check to regex spelling.
      expect(policy, contains('simpleWords'));
    });

    test(
      'direct execution only covers safe read-only plus advanced YELLOW',
      () {
        expect(controller, contains('DIRECT_READ_ONLY'));
        expect(controller, contains('ADVANCED_MODE'));
        // Advanced mode still confirms RED, with a fixed 3-second wait.
        expect(controller, contains('ShizukuCommandPolicy.admission'));
        // Non-direct commands still resolve to the overlay or a deny path.
        expect(controller, contains('ShizukuSafetyOverlay.confirm'));
      },
    );

    test('overlay is forced and fail-closed on timeout', () {
      final overlay = File(
        'android/app/src/main/kotlin/com/azx8788/opencode/mini/ShizukuSafetyOverlay.kt',
      ).readAsStringSync();
      expect(overlay, contains('TYPE_APPLICATION_OVERLAY'));
      expect(overlay, contains('FLAG_SECURE'));
      expect(overlay, contains('canDrawOverlays'));
      expect(overlay, contains('complete(false)'));
      expect(overlay, contains('timeoutSeconds'));
    });

    test('service reports its own pid instead of using Process.pid', () {
      final service = File(
        'android/app/src/main/kotlin/com/azx8788/opencode/mini/ShizukuCommandService.kt',
      ).readAsStringSync();
      expect(service, contains('OCRPID='));
      expect(_callsUnsupportedPid(service), isFalse);
    });

    test(
      'pid call check ignores explanations but still detects real calls',
      () {
        expect(
          _callsUnsupportedPid(
            '/* Process.pid() is unavailable. */\n'
            '// Do not use process.pid() here.\nval pid = running.pid.get()',
          ),
          isFalse,
        );
        expect(_callsUnsupportedPid('val pid = process.pid()'), isTrue);
        expect(_callsUnsupportedPid('val pid = process . pid ( )'), isTrue);
      },
    );
  });

  group('Android AI bridge execution contract', () {
    test('private bridge uses UID credentials and bounded byte frames, not a LAN listener', () {
      final bridge = File(
        'android/app/src/main/kotlin/com/azx8788/opencode/mini/ShizukuNativeBridge.kt',
      ).readAsStringSync();
      expect(bridge, contains('LocalSocketAddress.Namespace.FILESYSTEM'));
      expect(bridge, contains('client.peerCredentials.uid == Process.myUid()'));
      expect(bridge, contains('ShizukuProtocol.MAX_REQUEST_BYTES'));
      expect(
        RegExp(r'(^|[^A-Za-z])ServerSocket\s*\(').hasMatch(bridge),
        isFalse,
      );
    });
    test('actual binding requires status handshake and has an expiry', () {
      final controller = File(
        'android/app/src/main/kotlin/com/azx8788/opencode/mini/ShizukuController.kt',
      ).readAsStringSync();
      expect(controller, contains('JSONObject(api.status())'));
      expect(controller, contains('binding.expire(epoch)'));
      expect(controller, contains('binding.connected(epoch'));
      expect(controller, contains('journal.dispatch('));
      expect(controller, contains('ShizukuSafetyOverlay.cancel(id)'));
    });
  });
}

bool _callsUnsupportedPid(String source) {
  final code = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/|//[^\r\n]*'), '');
  return RegExp(r'\.\s*pid\s*\(').hasMatch(code);
}
