// README "Versioning" promises one command that moves the version, and a CI
// that passes a higher versionCode than the last build. Both were described
// but missing from the tree: `tool/bump_version.dart` did not exist, and
// nothing read `OC_VERSION_CODE`, so two CI runs of the same commit produced
// APKs the phone considered the same version and the second install failed.
// These tests pin the contract so it cannot be dropped again.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/bump_version.dart';

void main() {
  group('AppVersion', () {
    test('parses the shape pubspec uses, and nothing else', () {
      final version = AppVersion.tryParse('0.3.13+18');
      expect(version, isNotNull);
      expect(version.toString(), '0.3.13+18');
      expect(AppVersion.tryParse('0.3.13'), isNull);
      expect(AppVersion.tryParse('0.3.13+18-dev'), isNull);
      expect(AppVersion.tryParse('v0.3.13+18'), isNull);
      expect(AppVersion.tryParse(''), isNull);
    });

    test('a plain bump only moves the build number', () {
      final next = AppVersion.tryParse('0.3.13+18')!.bumped(VersionBump.build);
      expect(next.toString(), '0.3.13+19');
    });

    test('patch, minor and major always move the build number too', () {
      final base = AppVersion.tryParse('0.3.13+18')!;
      expect(base.bumped(VersionBump.patch).toString(), '0.3.14+19');
      expect(base.bumped(VersionBump.minor).toString(), '0.4.0+19');
      expect(base.bumped(VersionBump.major).toString(), '1.0.0+19');
      // Android compares versionCode first: a "newer" version with a smaller
      // code installs nothing, which is the bug this rule prevents.
      for (final kind in VersionBump.values) {
        expect(base.bumped(kind).build, greaterThan(base.build));
      }
    });
  });

  group('pubspec rewrite', () {
    const pubspec = 'name: demo\ndescription: x\nversion: 0.3.13+18\n';

    test('replaces the version line and leaves the rest alone', () {
      final next = AppVersion.tryParse('0.3.13+18')!.bumped(VersionBump.build);
      expect(
        bumpPubspecVersion(pubspec, next),
        'name: demo\ndescription: x\nversion: 0.3.13+19\n',
      );
    });

    test('refuses a pubspec without a version line', () {
      expect(
        () => bumpPubspecVersion(
          'name: demo\n',
          const AppVersion(0, 3, 14, 19),
        ),
        throwsFormatException,
      );
    });

    test('refuses a pubspec with two version lines', () {
      expect(
        () => bumpPubspecVersion(
          'version: 0.1.0+1\nversion: 0.2.0+2\n',
          const AppVersion(0, 3, 14, 19),
        ),
        throwsFormatException,
      );
    });

    test('the repository pubspec actually parses', () {
      final source = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(
        r'^version:\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(source);
      expect(match, isNotNull, reason: 'pubspec.yaml needs version: x.y.z+n');
      expect(AppVersion.tryParse(match!.group(1)!), isNotNull);
    });
  });

  group('the documented release path exists', () {
    test('the bump script and the build script are committed', () {
      expect(File('tool/bump_version.dart').existsSync(), isTrue);
      expect(File('tool/build_apk.sh').existsSync(), isTrue);
      final mode = File('tool/build_apk.sh').statSync().mode;
      expect(
        mode & 0x40 != 0,
        isTrue,
        reason: 'tool/build_apk.sh must be executable (chmod +x)',
      );
    });

    test('Gradle honours the CI version code and the workflow sets it', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('OC_VERSION_CODE'));
      final workflow = File('.github/workflows/build.yml').readAsStringSync();
      expect(
        workflow,
        contains('OC_VERSION_CODE'),
        reason: 'README promises CI raises versionCode every run',
      );
    });
  });
}
