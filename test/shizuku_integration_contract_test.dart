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

    test('SYSTEM_ALERT_WINDOW is declared for the forced safety overlay', () {
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

    test('no command is silently allowed or silently blocked', () {
      // The old fail-closed `allowed` field is gone: every command reaches the
      // overlay. Risk decides colour and delay, not a hard block.
      expect(policy, isNot(contains('allowed: Boolean')));
      expect(policy, contains('allowDelaySeconds'));
    });

    test('risk levels map to colour and delay', () {
      expect(policy, contains('Risk.GREEN'));
      expect(policy, contains('Risk.BLUE'));
      expect(policy, contains('Risk.YELLOW'));
      expect(policy, contains('Risk.RED'));
      // Catastrophic commands get the longest delay, not a silent block.
      expect(policy, contains('catastrophic'));
      expect(policy, contains('10'));
    });

    test('overlay is forced and fail-closed on timeout', () {
      final overlay = File(
        'android/app/src/main/kotlin/com/azx8788/opencode/mini/ShizukuSafetyOverlay.kt',
      ).readAsStringSync();
      expect(overlay, contains('TIMEOUT_MS'));
      expect(overlay, contains('TYPE_APPLICATION_OVERLAY'));
      expect(overlay, contains('FLAG_SECURE'));
      expect(overlay, contains('canDrawOverlays'));
      expect(overlay, contains('complete(false)'));
    });
  });
}
