import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/builtin_linux.dart';
import 'package:opencode_mobile/builtin/llbot_deployment.dart';

class _Linux extends BuiltinLinux {
  _Linux(this.rootfs);

  final Directory rootfs;
  final services = <String>{};
  final scripts = <String>[];
  final started = <String>[];
  final installerStarted = Completer<void>();
  String? installJob;
  String? runJob;
  String? installFailure;
  bool autoInstall = true;
  bool autoRun = true;
  bool publishReceipt = true;
  bool linuxInstalled = true;
  String abi = 'arm64-v8a';
  int installerTick = 0;
  int runTick = 0;

  File file(String name) => File('${rootfs.path}${LlbotDeployment.root}/$name');

  Future<void> write(String name, Object value) async {
    final target = file(name);
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(jsonEncode(value));
    await temporary.rename(target.path);
  }

  Future<void> installed() async {
    await write('current.json', {
      'version': LlbotDeployment.version,
      'archive': LlbotDeployment.archiveSha256,
      'patch': LlbotDeployment.runtimePatch,
      'bundle': LlbotDeployment.managedBundleSha256,
      'directory': 'release-${'a' * 32}',
      'tree': 'b' * 64,
    });
    await write('state/connection.json', {'accessToken': 'c' * 64});
    final password = file('state/data/webui_token.txt');
    await password.parent.create(recursive: true);
    await password.writeAsString('${'d' * 64}\n');
  }

  Future<void> finishInstall() async {
    if (publishReceipt) await installed();
    await write('job.json', {
      'job': installJob,
      'phase': installFailure == null ? 'installed' : 'failed',
      'stage': 'configure',
      'failure': installFailure,
    });
  }

  @override
  Future<BuiltinLinuxStatus> status() async {
    if (services.contains(LlbotDeployment.installerServiceName) &&
        autoInstall) {
      final stages = ['download', 'verify', 'install', 'configure'];
      if (installerTick < stages.length) {
        await write('job.json', {
          'job': installJob,
          'phase': 'installing',
          'stage': stages[installerTick++],
        });
      } else {
        await finishInstall();
      }
    }
    if (services.contains(LlbotDeployment.serviceName) &&
        autoRun &&
        ++runTick >= 2) {
      await write('run.json', {'generation': runJob, 'phase': 'running'});
    }
    return BuiltinLinuxStatus(
      installed: linuxInstalled,
      phase: linuxInstalled ? BuiltinLinuxPhase.ready : BuiltinLinuxPhase.idle,
      abi: abi,
      services: services.toList(),
    );
  }

  @override
  Future<BuiltinLinuxRunResult> run(
    String script, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    scripts.add(script);
    final directory = RegExp(r'mkdir -p ([^\n]+)').firstMatch(script)?.group(1);
    if (directory != null) {
      await Directory('${rootfs.path}$directory').create(recursive: true);
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
    started.add(name);
    services.add(name);
    final job = RegExp(r'--job ([a-f0-9]{32})').firstMatch(script)!.group(1)!;
    if (name == LlbotDeployment.installerServiceName) {
      installJob = job;
      installerTick = 0;
      await write('job.json', {
        'job': job,
        'phase': 'installing',
        'stage': 'checking',
      });
      if (!installerStarted.isCompleted) installerStarted.complete();
    } else {
      runJob = job;
      runTick = 0;
      await write('run.json', {'generation': job, 'phase': 'starting'});
    }
  }

  @override
  Future<void> stopService(String name) async => services.remove(name);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory rootfs;
  late _Linux linux;
  late LlbotDeployment deployment;

  setUp(() async {
    rootfs = await Directory.systemTemp.createTemp('llbot-controller-');
    linux = _Linux(rootfs);
    deployment = LlbotDeployment(
      linux: linux,
      rootfs: () async => rootfs,
      supported: true,
      loadAsset: (asset) async => 'fixture for $asset',
      probe: () async => true,
      pollInterval: Duration.zero,
      installPollAttempts: 100,
      startPollAttempts: 5,
    );
  });

  tearDown(() async {
    deployment.dispose();
    await rootfs.delete(recursive: true);
  });

  test(
    'deploy awaits installation and managed readiness, reporting real stages',
    () async {
      final stages = <String>{};
      final phases = <LlbotDeploymentPhase>{};
      deployment.addListener(() {
        if (deployment.stage case final String stage) stages.add(stage);
        phases.add(deployment.phase);
      });
      await deployment.deploy();
      expect(
        stages,
        containsAll([
          'checking',
          'download',
          'verify',
          'install',
          'configure',
          'start',
        ]),
      );
      expect(
        phases,
        containsAll([
          LlbotDeploymentPhase.installing,
          LlbotDeploymentPhase.starting,
        ]),
      );
      expect(deployment.phase, LlbotDeploymentPhase.running);
      expect(deployment.busy, isFalse);
      expect(deployment.failure, isNull);
      expect(linux.services, {LlbotDeployment.serviceName});
      final connection = await deployment.connection();
      expect(connection.webSocketUrl, 'ws://127.0.0.1:3001');
      expect(connection.accountId, isNull);
      expect(connection.accessToken, 'c' * 64);
      expect(connection.webUiPassword, 'd' * 64);
      expect(connection.toString(), isNot(contains(connection.accessToken)));
      expect(linux.scripts.join(), isNot(contains(connection.accessToken)));
      expect(linux.scripts.join(), isNot(contains(connection.webUiPassword)));
      expect(
        await linux.file('NOTICES.txt').readAsString(),
        'fixture for ${LlbotDeployment.noticesAsset}',
      );
      expect(
        await linux.file('COPYING.LLBot').readAsString(),
        'fixture for ${LlbotDeployment.llbotLicenseAsset}',
      );
      expect(
        await linux.file('notices/Node.LICENSE').readAsString(),
        'fixture for ${LlbotDeployment.nodeLicenseAsset}',
      );
    },
  );

  test(
    'accepting a native installer is not deployment success; concurrent calls join',
    () async {
      linux.autoInstall = false;
      var finished = false;
      final work = deployment.deploy()..then((_) => finished = true);
      expect(identical(deployment.deploy(), work), isTrue);
      await linux.installerStarted.future;
      expect(deployment.busy, isTrue);
      expect(finished, isFalse);
      expect(linux.started, [LlbotDeployment.installerServiceName]);
      await linux.finishInstall();
      await work;
      expect(finished, isTrue);
      expect(deployment.phase, LlbotDeploymentPhase.running);
    },
  );

  test(
    'installed job without committed receipt cannot start a runtime',
    () async {
      linux.publishReceipt = false;
      await deployment.deploy();
      expect(deployment.phase, LlbotDeploymentPhase.failed);
      expect(deployment.failure, 'integrity');
      expect(linux.started, [LlbotDeployment.installerServiceName]);
    },
  );

  test(
    'failure is safe and retryable without propagating native output',
    () async {
      linux.installFailure = 'untrusted raw output and fake secret';
      await deployment.deploy();
      expect(deployment.phase, LlbotDeploymentPhase.failed);
      expect(deployment.failure, 'install_failed');
      expect(deployment.busy, isFalse);
      linux.installFailure = null;
      await deployment.deploy();
      expect(deployment.phase, LlbotDeploymentPhase.running);
      expect(deployment.failure, isNull);
    },
  );

  test(
    'repeat deploy is idempotent, stop and start use tracked native ownership',
    () async {
      await deployment.deploy();
      final calls = linux.started.length;
      await deployment.deploy();
      expect(linux.started.length, calls);
      await deployment.stop();
      expect(deployment.phase, LlbotDeploymentPhase.stopped);
      expect(linux.services, isEmpty);
      await deployment.start();
      expect(deployment.phase, LlbotDeploymentPhase.running);
      expect(
        linux.started.where(
          (name) => name == LlbotDeployment.installerServiceName,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'HTTP readiness and stale running record cannot substitute for owned process',
    () async {
      await linux.installed();
      await linux.write('run.json', {
        'generation': 'e' * 32,
        'phase': 'running',
      });
      await deployment.refresh();
      expect(deployment.phase, LlbotDeploymentPhase.stopped);
      expect(linux.started, isEmpty);
    },
  );

  test(
    'a stale run generation is not accepted; timed-out service is stopped',
    () async {
      linux.autoRun = false;
      await deployment.deploy();
      expect(deployment.phase, LlbotDeploymentPhase.failed);
      expect(deployment.failure, 'start_timeout');
      expect(linux.services, isEmpty);
    },
  );

  test('missing Linux and wrong ABI do not launch installer', () async {
    linux.linuxInstalled = false;
    await deployment.deploy();
    expect(deployment.phase, LlbotDeploymentPhase.linuxUnavailable);
    linux.linuxInstalled = true;
    linux.abi = 'x86_64';
    await deployment.deploy();
    expect(deployment.phase, LlbotDeploymentPhase.unsupported);
    expect(linux.started, isEmpty);
  });

  test(
    'missing install is reported and credentials fail with a fixed error',
    () async {
      await deployment.refresh();
      expect(deployment.phase, LlbotDeploymentPhase.notInstalled);
      await expectLater(deployment.connection(), throwsA(isA<StateError>()));
      await deployment.start();
      expect(deployment.phase, LlbotDeploymentPhase.notInstalled);
      expect(linux.started, isEmpty);
    },
  );

  test(
    'disposing an injected controller does not abandon in-flight installation',
    () async {
      linux.autoInstall = false;
      final work = deployment.deploy();
      await linux.installerStarted.future;
      deployment.dispose();
      await linux.finishInstall();
      await work;
      expect(deployment.phase, LlbotDeploymentPhase.running);
      expect(linux.services, {LlbotDeployment.serviceName});
    },
  );

  test(
    'malformed receipts fail start safely and deploy reaches repair',
    () async {
      await linux.installed();
      final good =
          jsonDecode(await linux.file('current.json').readAsString())
              as Map<String, dynamic>;
      final damaged = <String>['{', 'null', '[]', '1', '"text"'];
      for (final key in [
        'directory',
        'tree',
        'version',
        'archive',
        'patch',
        'bundle',
      ]) {
        for (final value in <Object?>[null, 123, [], {}]) {
          damaged.add(jsonEncode({...good, key: value}));
        }
      }
      for (final receipt in [
        ...damaged.map(utf8.encode),
        [0xff],
      ]) {
        await linux.file('current.json').writeAsBytes(receipt);
        await deployment.refresh();
        expect(deployment.phase, LlbotDeploymentPhase.failed);
        expect(deployment.failure, 'integrity');
        final starts = linux.started.length;
        await deployment.start();
        expect(deployment.failure, 'integrity');
        expect(linux.started.length, starts);
        await deployment.deploy();
        expect(deployment.phase, LlbotDeploymentPhase.running);
        expect(deployment.failure, isNull);
        await deployment.stop();
      }
    },
  );

  test(
    'deploy upgrades a tracked older managed runtime before accepting readiness',
    () async {
      await deployment.deploy();
      final receipt =
          jsonDecode(await linux.file('current.json').readAsString())
              as Map<String, dynamic>;
      receipt.remove('patch');
      await linux.write('current.json', receipt);
      await deployment.deploy();
      expect(deployment.phase, LlbotDeploymentPhase.running);
      expect(
        linux.started.where(
          (name) => name == LlbotDeployment.installerServiceName,
        ),
        hasLength(2),
      );
      expect(await deployment.connection(), isA<LlbotLocalConnection>());
    },
  );
}
