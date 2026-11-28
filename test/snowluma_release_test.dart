import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/snowluma_release.dart';

void main() {
  test('unknown archive size is rejected without reading the file', () async {
    final verified = await SnowLumaArm64Release.verify(
      length: 1024,
      read: () => throw StateError('unrecognized file must not be read'),
    );
    expect(verified, isNull);
  });

  test('an archive of the right size but wrong contents is rejected', () async {
    final size = SnowLumaArm64Release.lite.size;
    Stream<List<int>> zeros() async* {
      final chunk = Uint8List(64 * 1024);
      for (var left = size; left > 0; left -= chunk.length) {
        yield left >= chunk.length
            ? chunk
            : Uint8List.sublistView(chunk, 0, left);
      }
    }

    final verified = await SnowLumaArm64Release.verify(
      length: size,
      read: zeros,
    );
    expect(verified, isNull);
  });

  test('a stream larger than the claimed archive size is stopped', () async {
    final size = SnowLumaArm64Release.lite.size;
    var readPastLimit = false;
    Stream<List<int>> growing() async* {
      yield Uint8List(size + 1);
      readPastLimit = true;
    }

    final verified = await SnowLumaArm64Release.verify(
      length: size,
      read: growing,
    );
    expect(verified, isNull);
    expect(readPastLimit, isFalse);
  });
}
