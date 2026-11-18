import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/shizuku/shizuku_bridge_js.dart';
import 'package:opencode_mobile/builtin/shizuku/shizuku_plugin_js.dart';
import 'package:opencode_mobile/builtin/shizuku/shizuku_install.dart';

void main() {
  test(
    'Android tools enforce scope, permissions, cancellation and replay',
    () async {
      final directory = await Directory.systemTemp.createTemp('plus-shizuku-');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/package.json')
          .writeAsString('{"type":"module"}');
      await File('${directory.path}/bridge.js').writeAsString(shizukuBridgeJs);
      await File('${directory.path}/index.js').writeAsString(
        shizukuPluginJs.replaceFirst(
          "import { Plugin } from '@opencode/plugin';",
          'const Plugin = { define: value => value };',
        ),
      );
      final result = await Process.run('node', [
        'tool/qa/shizuku_plugin_test.mjs',
        directory.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test('installer preserves unrelated config and refuses unowned plugins', () async {
    final directory = await Directory.systemTemp.createTemp(
      'plus-shizuku-install-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final script = shizukuInstallScript().replaceAll(
      '/root/.oc-opencode2',
      '${directory.path}/runtime',
    );
    final config = File(
      '${directory.path}/runtime/config/opencode/opencode.json',
    );
    await config.parent.create(recursive: true);
    const original =
        '{"plugins":["user-plugin"],"permissions":[{"action":"shell","resource":"*","effect":"deny"}]}';
    await config.writeAsString(original);
    for (var count = 0; count < 2; count++) {
      final result = await Process.run('bash', ['-c', script]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }
    final stored = await config.readAsString();
    expect(stored, contains('user-plugin'));
    expect(stored, contains('"effect": "deny"'));
    expect(RegExp('plugins/mobile-shizuku').allMatches(stored), hasLength(1));
    final marker = File(
      '${config.parent.path}/plugins/mobile-shizuku/opencode-plus-owned',
    );
    await marker.delete();
    final userFile = File('${marker.parent.path}/index.js');
    await userFile.writeAsString('user-owned work');
    final refused = await Process.run('bash', ['-c', script]);
    expect(refused.exitCode, isNot(0));
    expect(await userFile.readAsString(), 'user-owned work');
    expect(await config.readAsString(), stored);
  });
}
