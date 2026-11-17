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
          .singleWhere((element) =>
              element.getAttribute('android:name') ==
              'rikka.shizuku.ShizukuProvider');
      expect(provider.getAttribute('android:authorities'), r'${applicationId}.shizuku');
      expect(provider.getAttribute('android:exported'), 'true');
      expect(provider.getAttribute('android:multiprocess'), 'false');
      expect(provider.getAttribute('android:permission'),
          'android.permission.INTERACT_ACROSS_USERS_FULL');
    });

    test('SYSTEM_ALERT_WINDOW is declared for the safety overlay', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android.permission.SYSTEM_ALERT_WINDOW'));
    });

    test('Shizuku manager (moe.shizuku.privileged.api) is visible for queries', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('moe.shizuku.privileged.api'));
    });

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
      // Pipe/redirect/backtick/dollar markers are rejected from direct reads.
      expect(policy, contains('shellSyntax'));
      expect(policy, contains("Regex(\"[;&|<>`\$(){}\\\\[\\\\]\\\\\\\\\\\\n\\\\r\\\"']\")"));
    });

    test('direct execution only covers safe read-only plus advanced YELLOW', () {
      expect(controller, contains('DIRECT_READ_ONLY'));
      expect(controller, contains('ADVANCED_MODE'));
      // Advanced mode still confirms RED, with a fixed 3-second wait.
      expect(controller, contains('advanced && decision.risk == ShizukuCommandPolicy.Risk.RED'));
      expect(controller, contains('3'));
      // Non-direct commands still resolve to the overlay or a deny path.
      expect(controller, contains('ShizukuSafetyOverlay.confirm'));
    });

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
      expect(service, isNot(contains('.pid()')));
    });
  });
}