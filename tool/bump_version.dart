// Moves the one version this app carries, in `pubspec.yaml`.
//
// README's "Versioning" section has always described this command
// (`dart run tool/bump_version.dart`, `--patch`, `--minor`, `--major`), but
// the file itself was never committed with the trimmed tree, so the
// documented workflow failed on its first step and a build made the plain
// `flutter build apk` way kept the previous versionCode. Android compares
// that number first, so the phone treats the new APK as the same build and
// installs nothing.
//
// The build number always moves, including on `--patch`, `--minor` and
// `--major`: a version that calls itself newer while carrying a smaller code
// would never replace the older install.
//
// Only the pubspec's `version:` line is rewritten; its other fields stay
// byte-for-byte. The newest changelog heading moves with it.

import 'dart:io';

const _usage = 'usage: dart run tool/bump_version.dart '
    '[--build|--patch|--minor|--major|--set x.y.z+n] [--dry-run]';

/// Which part of `major.minor.patch` moves. [build] keeps all three and only
/// advances the `+N` build number.
enum VersionBump { build, patch, minor, major }

/// A strict `major.minor.patch+build` version.
class AppVersion {
  const AppVersion(this.major, this.minor, this.patch, this.build);

  final int major;
  final int minor;
  final int patch;
  final int build;

  static final _pattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)\+(\d+)$');

  /// Parses the exact shape this repository uses. Returns null for anything
  /// else (`0.3`, `0.3.14`, `0.3.14+18-dev`): a bump must never guess.
  static AppVersion? tryParse(String text) {
    final match = _pattern.firstMatch(text.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
    );
  }

  /// The next version after this one. The build number moves in every case.
  AppVersion bumped(VersionBump kind) {
    final nextBuild = build + 1;
    switch (kind) {
      case VersionBump.build:
        return AppVersion(major, minor, patch, nextBuild);
      case VersionBump.patch:
        return AppVersion(major, minor, patch + 1, nextBuild);
      case VersionBump.minor:
        return AppVersion(major, minor + 1, 0, nextBuild);
      case VersionBump.major:
        return AppVersion(major + 1, 0, 0, nextBuild);
    }
  }

  @override
  String toString() => '$major.$minor.$patch+$build';
}

/// The `version:` line of a pubspec, replaced with [next] when this returns
/// a different string. A pubspec without exactly one uncommented `version:`
/// line is an error, not a silent no-op.
String bumpPubspecVersion(String pubspec, AppVersion next) {
  final lines = pubspec.split('\n');
  var seen = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.startsWith('version:')) continue;
    seen++;
    lines[i] = 'version: $next';
  }
  if (seen != 1) {
    throw const FormatException(
      'pubspec.yaml must carry exactly one top-level "version:" line',
    );
  }
  return lines.join('\n');
}

void main(List<String> args) {
  var kind = VersionBump.build;
  var dryRun = false;
  AppVersion? explicit;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--build':
        kind = VersionBump.build;
      case '--patch':
        kind = VersionBump.patch;
      case '--minor':
        kind = VersionBump.minor;
      case '--major':
        kind = VersionBump.major;
      case '--dry-run':
        dryRun = true;
      case '--set':
        if (i + 1 >= args.length) {
          stderr.writeln('--set needs x.y.z+n');
          exitCode = 64;
          return;
        }
        explicit = AppVersion.tryParse(args[++i]);
        if (explicit == null) {
          stderr.writeln('--set needs x.y.z+n');
          exitCode = 64;
          return;
        }
      case '--help' || '-h':
        stdout.writeln(_usage);
        return;
      default:
        stderr.writeln('unknown argument: $arg');
        stderr.writeln(_usage);
        exitCode = 64;
        return;
    }
  }

  final file = File('pubspec.yaml');
  if (!file.existsSync()) {
    stderr.writeln('pubspec.yaml not found; run this from the repository root.');
    exitCode = 66;
    return;
  }
  final source = file.readAsStringSync();
  final match = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(source);
  final current = match == null ? null : AppVersion.tryParse(match.group(1)!);
  if (current == null) {
    stderr.writeln(
      'pubspec.yaml needs a "major.minor.patch+build" version line '
      '(for example 0.3.13+18).',
    );
    exitCode = 65;
    return;
  }
  final next = explicit ?? current.bumped(kind);
  if (next.build < current.build) {
    stderr.writeln('refusing to move versionCode backwards: $current -> $next');
    exitCode = 65;
    return;
  }
  final updated = bumpPubspecVersion(source, next);
  if (dryRun) {
    stdout.writeln('$current -> $next (dry run)');
    return;
  }
  file.writeAsStringSync(updated);
  final changelog = File('CHANGELOG.md');
  if (changelog.existsSync()) {
    final text = changelog.readAsStringSync();
    final synced = syncChangelogVersion(text, next);
    if (synced != text) changelog.writeAsStringSync(synced);
  }
  stdout.writeln('$current -> $next');
}

/// Keep the newest entry in step without changing its release notes.
String syncChangelogVersion(String text, AppVersion next) {
  final head = RegExp(
    r'^## \d+\.\d+\.\d+\+\d+ — ',
    multiLine: true,
  ).firstMatch(text);
  if (head == null) return text;
  return text.replaceRange(head.start, head.end, '## $next — ');
}
