import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/builtin_linux.dart';
import 'package:opencode_mobile/builtin/snowluma_deployment.dart';
import 'package:opencode_mobile/builtin/snowluma_release.dart';

class _Linux extends BuiltinLinux {
  _Linux(this.rootfs);

  final Directory rootfs;
  final services = <String>{};
  final scripts = <String>[];
  String? installJob;
  String? installRelease;
  String? installFailure;
  String? runFailure;
  bool autoInstall = true;
  bool autoRun = true;
  bool linuxInstalled = true;
  String abi = 'arm64-v8a';
  int installTick = 0;
  int runTick = 0;

  File file(String name) =>
      File('${rootfs.path}${SnowLumaDeployment.root}/$name');

  Future<void> write(String name, Object value) async {
    final target = file(name);
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(jsonEncode(value));
    await temporary.rename(target.path);
  }

  Future<void> installed() async {
    await write('current.json', {
      'version': '2.4.2',
      'release': 'lite',
      'sha256': SnowLumaArm64Release.lite.sha256Hex,
      'directory':
          'release-${SnowLumaArm64Release.lite.sha256Hex.substring(0, 16)}',
    });
  }

  @override
  Future<BuiltinLinuxStatus> status() async {
    if (services.contains(SnowLumaDeployment.installerServiceName) &&
        autoInstall) {
      if (installTick == 0) {
        await write('job.json', {
          'job': installJob,
          'phase': 'installing',
          'stage': 'verify',
        });
      } else if (installTick == 1) {
        await write('job.json', {
          'job': installJob,
          'phase': 'installing',
          'stage': 'install',
        });
      } else {
        if (installFailure == null) {
          await installed();
          await write('job.json', {
            'job': installJob,
            'phase': 'installed',
            'stage': 'install',
          });
        } else {
          await write('job.json', {
            'job': installJob,
            'phase': 'failed',
            'stage': 'install',
            'failure': installFailure,
          });
        }
        services.remove(SnowLumaDeployment.installerServiceName);
      }
      installTick++;
    }
    if (services.contains(SnowLumaDeployment.serviceName) && autoRun) {
      runTick++;
      await write('run.json', {
        'generation': _runGeneration,
        'phase': runFailure == null ? 'running' : 'failed',
        'failure': runFailure,
      });
    }
    return BuiltinLinuxStatus(
      installed: linuxInstalled,
      phase: linuxInstalled ? BuiltinLinuxPhase.ready : BuiltinLinuxPhase.idle,
      abi: abi,
      services: services.toList(),
    );
  }

  String? _runGeneration;

  @override
  Future<BuiltinLinuxRunResult> run(
    String script, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    scripts.add(script);
    for (final match in RegExp(r'mkdir -p ([^\n]+)').allMatches(script)) {
      for (final path in match.group(1)!.split(' ')) {
        await Directory('${rootfs.path}$path').create(recursive: true);
      }
    }
    return const BuiltinLinuxRunResult(exitCode: 0, output: '');
  }

  @override
  Future<void> startService(
    String name,
    String script, {
    int? port,
    String? notice,
  }) async {
    scripts.add(script);
    services.add(name);
    final job = RegExp(r'--job ([a-f0-9]{32})').firstMatch(script)!.group(1)!;
    if (name == SnowLumaDeployment.installerServiceName) {
      installJob = job;
      installRelease = RegExp(
        r'--release (full|lite)',
      ).firstMatch(script)?.group(1);
      installTick = 0;
      await write('job.json', {
        'job': job,
        'phase': 'installing',
        'stage': 'verify',
      });
    } else {
      _runGeneration = job;
      runTick = 0;
      await write('run.json', {'generation': job, 'phase': 'starting'});
    }
  }

  @override
  Future<void> stopService(String name) async {
    services.remove(name);
  }
}

SnowLumaArchive _archive(List<int> bytes) => SnowLumaArchive(
  length: () async => bytes.length,
  read: () => Stream<List<int>>.value(bytes),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory rootfs;
  late _Linux linux;

  setUp(() async {
    rootfs = await Directory.systemTemp.createTemp('snowluma-controller-');
    linux = _Linux(rootfs);
  });

  tearDown(() async {
    if (await rootfs.exists()) await rootfs.delete(recursive: true);
  });

  SnowLumaDeployment build({
    bool supported = true,
    Future<bool> Function()? probe,
    int startPollAttempts = 180,
  }) {
    final deployment = SnowLumaDeployment(
      linux: linux,
      rootfs: () async => rootfs,
      supported: supported,
      loadAsset: (asset) async => 'fixture for $asset',
      probe: probe ?? () async => true,
      delay: (_) async {},
      pollInterval: Duration.zero,
      startPollAttempts: startPollAttempts,
      importArchive: (_, _) async {},
    );
    addTearDown(deployment.dispose);
    return deployment;
  }

  test(
    'imports the selected release, extracts and starts on the WebUI port',
    () async {
      final deployment = build();
      await deployment.importAndStart(
        SnowLumaArm64Release.lite,
        _archive([1, 2, 3]),
      );

      expect(deployment.phase, SnowLumaDeploymentPhase.running);
      expect(linux.installRelease, 'lite');
      expect(linux.services, {SnowLumaDeployment.serviceName});
      expect(
        linux.scripts.where((script) => script.contains(' install ')).single,
        contains('--release lite'),
      );
      expect(
        linux.scripts.where((script) => script.contains(' run ')).single,
        contains('run --job'),
      );
      expect(deployment.webUiUri.toString(), 'http://127.0.0.1:5099/');
    },
  );

  test('a start failure keeps its specific reason', () async {
    final deployment = build();
    await linux.installed();
    linux.runFailure = 'node_missing';
    await deployment.start();

    expect(deployment.phase, SnowLumaDeploymentPhase.failed);
    expect(deployment.failure, 'node_missing');
    expect(linux.services, isEmpty);
  });

  test(
    'an extraction failure is reported without starting a runtime',
    () async {
      final deployment = build();
      linux.installFailure = 'archive_invalid';
      await deployment.importAndStart(
        SnowLumaArm64Release.full,
        _archive([1, 2, 3]),
      );

      expect(deployment.phase, SnowLumaDeploymentPhase.failed);
      expect(deployment.failure, 'archive_invalid');
      expect(linux.services, isEmpty);
    },
  );

  test('refuses to import without a ready ARM64 Ubuntu', () async {
    final deployment = build();
    linux.linuxInstalled = false;
    await deployment.importAndStart(
      SnowLumaArm64Release.lite,
      _archive([1, 2, 3]),
    );

    expect(deployment.phase, SnowLumaDeploymentPhase.linuxUnavailable);
    expect(linux.services, isEmpty);
  });

  test('refuses a non-ARM64 Ubuntu even when it is installed', () async {
    final deployment = build();
    linux.abi = 'x86_64';
    await deployment.importAndStart(
      SnowLumaArm64Release.lite,
      _archive([1, 2, 3]),
    );

    expect(deployment.phase, SnowLumaDeploymentPhase.unsupported);
    expect(linux.services, isEmpty);
  });

  test('refresh distinguishes not imported, stopped and running', () async {
    final deployment = build();
    await deployment.refresh();
    expect(deployment.phase, SnowLumaDeploymentPhase.notInstalled);

    await linux.installed();
    await deployment.refresh();
    expect(deployment.phase, SnowLumaDeploymentPhase.stopped);

    linux.services.add(SnowLumaDeployment.serviceName);
    const generation = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await linux.write('run-request.json', {'generation': generation});
    await linux.startService(
      SnowLumaDeployment.serviceName,
      'exec python3 helper run --job $generation',
      port: SnowLumaDeployment.webUiPort,
    );
    await deployment.refresh();
    expect(deployment.phase, SnowLumaDeploymentPhase.running);

    await deployment.stop();
    expect(deployment.phase, SnowLumaDeploymentPhase.stopped);
  });

  test('a WebUI that never answers is a start failure, not running', () async {
    final deployment = build(probe: () async => false, startPollAttempts: 3);
    await linux.installed();
    await deployment.start();

    expect(deployment.phase, SnowLumaDeploymentPhase.failed);
    expect(deployment.failure, 'start_timeout');
    expect(linux.services, isEmpty);
  });

  group('archive copy', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('snowluma-copy-');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('writes only after size and digest match', () async {
      final bytes = utf8.encode('fixture archive');
      final destination = File('${directory.path}/archive.tar.gz');

      await SnowLumaArchiveCopy.write(
        source: _archive(bytes),
        expectedSize: bytes.length,
        expectedSha256: sha256.convert(bytes).toString(),
        destination: destination,
        temporarySuffix: 'tmp',
      );

      expect(await destination.readAsBytes(), bytes);
      expect(directory.listSync().map((entry) => entry.path), [
        destination.path,
      ]);
    });

    test('a wrong digest leaves no file behind', () async {
      final bytes = utf8.encode('fixture archive');
      final destination = File('${directory.path}/archive.tar.gz');

      await expectLater(
        SnowLumaArchiveCopy.write(
          source: _archive(bytes),
          expectedSize: bytes.length,
          expectedSha256: '0' * 64,
          destination: destination,
          temporarySuffix: 'tmp',
        ),
        throwsA(
          isA<SnowLumaArchiveCopyError>().having(
            (error) => error.code,
            'code',
            'integrity',
          ),
        ),
      );
      expect(directory.listSync(), isEmpty);
    });

    test('a stream longer than the published size is rejected', () async {
      final destination = File('${directory.path}/archive.tar.gz');

      await expectLater(
        SnowLumaArchiveCopy.write(
          source: _archive([1, 2, 3, 4]),
          expectedSize: 3,
          expectedSha256: '0' * 64,
          destination: destination,
          temporarySuffix: 'tmp',
        ),
        throwsA(isA<SnowLumaArchiveCopyError>()),
      );
      expect(directory.listSync(), isEmpty);
    });
  });

  test('the helper pins the same releases and is bundled', () async {
    final helper = File('tool/snowluma_launcher.py').readAsStringSync();
    for (final release in SnowLumaArm64Release.values) {
      expect(
        helper,
        contains(
          "('${release.filename}', ${release.size},\n             "
          "'${release.sha256Hex}')",
        ),
        reason: '${release.key} must match the published asset',
      );
      expect(helper, contains("'${release.key}':"));
    }
    expect(helper, contains('WEBUI_PORT = 5099'));
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('- tool/snowluma_launcher.py'),
    );
  });
}
