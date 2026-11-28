import 'package:crypto/crypto.dart';

/// Exact ARM64 release assets published by TomyJan. Source tarballs and builds
/// from other forks are not these releases, even if their names match.
enum SnowLumaArm64Release {
  full(
    'SnowLuma-v2.4.2-linux-arm64.tar.gz',
    52545976,
    'c4bcff22828fb465d6fbd8caa375e82432fd3af684b297c43f2c428a2de2200c',
  ),
  lite(
    'SnowLuma-v2.4.2-linux-arm64-lite.tar.gz',
    8064625,
    'f3bc5cdc660fc23701d64e16082aead3159bf24968f7c08cff49933cba7b5753',
  );

  const SnowLumaArm64Release(this.filename, this.size, this.sha256Hex);

  static const page = 'https://github.com/TomyJan/SnowLuma/releases/tag/v2.4.2';

  final String filename;
  final int size;
  final String sha256Hex;

  /// The key tool/snowluma_launcher.py uses for the same published asset.
  String get key => name;

  /// Reads only the selected bytes. The filename is not trusted, and a file
  /// that grows or shrinks after its size check must still fail validation.
  static Future<SnowLumaArm64Release?> verify({
    required int length,
    required Stream<List<int>> Function() read,
  }) async {
    final candidate = values
        .where((release) => length == release.size)
        .firstOrNull;
    if (candidate == null) return null;

    var count = 0;
    Stream<List<int>> bounded() async* {
      await for (final chunk in read()) {
        count += chunk.length;
        if (count > length) throw const _FileGrew();
        yield chunk;
      }
    }

    try {
      final digest = await sha256.bind(bounded()).single;
      return count == length && digest.toString() == candidate.sha256Hex
          ? candidate
          : null;
    } on _FileGrew {
      return null;
    }
  }
}

class _FileGrew implements Exception {
  const _FileGrew();
}

/// A file the person picked. Nothing here is read until [verify] or an import
/// asks for it, and no path is kept.
class SnowLumaArchive {
  const SnowLumaArchive({required this.length, required this.read});

  final Future<int> Function() length;
  final Stream<List<int>> Function() read;

  Future<SnowLumaArm64Release?> verify() async =>
      SnowLumaArm64Release.verify(length: await length(), read: read);
}
