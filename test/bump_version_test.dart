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
  group('version CLI compatibility', () {
    late Directory temporary;
    late File pubspec;
    late File changelog;
    final script = File('tool/bump_version.dart').absolute.path;
    const source = 'name: demo\nversion: 0.3.17+25\npublish_to: none\n';
    const notes = '# Changelog\n\n## 0.3.17+25 — 2026-11-14\nCurrent.\n'
        '\n## 0.3.16+24 — 2026-11-14\nOlder.\n';

    setUp(() {
      temporary = Directory.systemTemp.createTempSync('oc-version-test-');
      pubspec = File('${temporary.path}/pubspec.yaml')..writeAsStringSync(source);
      changelog = File('${temporary.path}/CHANGELOG.md')..writeAsStringSync(notes);
    });
    tearDown(() => temporary.deleteSync(recursive: true));

    Future<ProcessResult> run(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      [script, ...args],
      workingDirectory: temporary.path,
    );

    test('dry-run reports a patch bump without writing either file', () async {
      final result = await run(['--patch', '--dry-run']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('0.3.17+25 -> 0.3.18+26 (dry run)'));
      expect(pubspec.readAsStringSync(), source);
      expect(changelog.readAsStringSync(), notes);
    });

    test('set keeps other fields and older changelog entries', () async {
      final result = await run(['--set', '0.4.0+30']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(pubspec.readAsStringSync(), source.replaceFirst('0.3.17+25', '0.4.0+30'));
      expect(changelog.readAsStringSync(), notes.replaceFirst('0.3.17+25', '0.4.0+30'));
    });

    test('set refuses a lower versionCode without changing files', () async {
      final result = await run(['--set', '0.4.0+24']);
      expect(result.exitCode, isNot(0));
      expect(pubspec.readAsStringSync(), source);
      expect(changelog.readAsStringSync(), notes);
    });

    test('build explicitly moves only the build number', () async {
      final result = await run(['--build']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(pubspec.readAsStringSync(), source.replaceFirst('0.3.17+25', '0.3.17+26'));
      expect(changelog.readAsStringSync(), notes.replaceFirst('0.3.17+25', '0.3.17+26'));
    });
  });

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
    test('the newest changelog heading moves without changing older entries', () {
      const text = '# Changelog\n\n## 0.3.17+25 — 2026-11-14\n'
          'Current notes.\n\n## 0.3.16+24 — 2026-11-14\nOlder notes.\n';
      expect(
        syncChangelogVersion(text, const AppVersion(0, 3, 18, 26)),
        text.replaceFirst('0.3.17+25', '0.3.18+26'),
      );
      expect(
        syncChangelogVersion('# Changelog\n', const AppVersion(0, 3, 18, 26)),
        '# Changelog\n',
      );
    });

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

    test('the build script keeps its own flags away from flutter', () {
      final lines = File(
        'tool/build_apk.sh',
      ).readAsStringSync().split('\n').where((line) =>
          line.trimLeft().startsWith('flutter build apk'));
      expect(lines, hasLength(1));
      expect(
        lines.single,
        isNot(contains(r'"$@"')),
        reason: '--patch and --no-bump are this script\'s flags; '
            'flutter build rejects them after the version already moved',
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
