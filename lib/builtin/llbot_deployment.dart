import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'builtin_linux.dart';

enum LlbotDeploymentPhase {
  checking,
  notInstalled,
  installing,
  starting,
  running,
  stopped,
  failed,
  unsupported,
  linuxUnavailable,
}

/// Ephemeral local handoff. Never include this value in diagnostics or URLs.
class LlbotLocalConnection {
  const LlbotLocalConnection({
    required this.webSocketUrl,
    required this.accessToken,
    required this.webUiPassword,
    this.accountId,
  });

  final String webSocketUrl;
  final String accessToken;
  final String webUiPassword;
  final String? accountId;

  @override
  String toString() => 'LlbotLocalConnection(<redacted>)';
}

/// One-click deployment in the app's Ubuntu, independent of channel activation.
///
/// [shared] owns work across navigation and must not be disposed by a screen.
/// Disposing an injected controller only detaches listeners; it never abandons
/// a tracked native job or stops a person's running service. Concurrent actions
/// join the active operation. `running` means managed process + console ready,
/// never that QQ is logged in or that the OneBot socket is available yet.
class LlbotDeployment extends ChangeNotifier {
  LlbotDeployment({
    BuiltinLinux? linux,
    Future<Directory> Function()? rootfs,
    Future<String> Function(String asset)? loadAsset,
    Future<bool> Function()? probe,
    Future<void> Function(Duration)? delay,
    bool? supported,
    this.pollInterval = const Duration(seconds: 1),
    this.installPollAttempts = 900,
    this.startPollAttempts = 100,
    this.installTimeout = const Duration(minutes: 15),
    this.startTimeout = const Duration(minutes: 2),
  }) : _linux = linux ?? BuiltinLinux(),
       _rootfs = rootfs ?? _defaultRootfs,
       _loadAsset = loadAsset ?? rootBundle.loadString,
       _probe = probe ?? _defaultProbe,
       _delay = delay ?? Future<void>.delayed,
       _supported = supported;

  static final LlbotDeployment _shared = LlbotDeployment().._keepAlive = true;
  static LlbotDeployment get shared => _shared;
  static const root = '/root/.oc-builtin/llbot';
  static const serviceName = 'llbot';
  static const installerServiceName = 'llbot-install';
  static const helperAsset = 'tool/llbot_deploy.py';
  static const guardAsset = 'tool/llbot_deploy_guard.mjs';
  static const noticesAsset = 'tool/llbot_deploy_NOTICES.txt';
  static const llbotLicenseAsset = 'LICENSES/GPL-2.0.txt';
  static const nodeLicenseAsset = 'tool/llbot_deploy_NODE_LICENSE.txt';
  static const version = '8.3.2';
  static const runtimePatch = 'oc-managed-v2';
  static const managedBundleSha256 =
      'a578d1d333795de38d14336a21dd47539d3aeff91e90ba9648fe4941ecfce122';
  static const archiveSha256 =
      'dd7e6bb405ed44a7120e767ac3b3ab169fe343386008c5017729804baa4a4c0f';
  static const _steps = {
    'checking',
    'download',
    'verify',
    'install',
    'configure',
    'start',
  };
  static const _failures = {
    'unsupported',
    'storage',
    'busy',
    'download_failed',
    'download_timeout',
    'integrity',
    'archive_invalid',
    'credentials',
    'not_installed',
    'port_busy',
    'start_failed',
    'start_timeout',
    'listener_refused',
    'runtime_exited',
    'install_failed',
    'install_interrupted',
    'install_timeout',
    'linux_unavailable',
    'helper_unavailable',
    'stop_failed',
    'status_failed',
  };

  final BuiltinLinux _linux;
  final Future<Directory> Function() _rootfs;
  final Future<String> Function(String) _loadAsset;
  final Future<bool> Function() _probe;
  final Future<void> Function(Duration) _delay;
  final bool? _supported;
  final Duration pollInterval;
  final int installPollAttempts;
  final int startPollAttempts;
  final Duration installTimeout;
  final Duration startTimeout;
  Future<void>? _operation;
  Directory? _filesystem;
  bool _disposed = false;
  bool _keepAlive = false;
  LlbotDeploymentPhase _phase = LlbotDeploymentPhase.checking;
  String? _stage;
  String? _failure;

  LlbotDeploymentPhase get phase => _phase;
  bool get busy => _operation != null;
  String? get stage => _stage;
  String? get failure => _failure;
  Uri get consoleUri => Uri.parse('http://127.0.0.1:3080');

  static Future<Directory> _defaultRootfs() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/linux/ubuntu',
  );

  static Future<bool> _defaultProbe() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:3080/'));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      if (response.statusCode != 200 ||
          response.headers.contentType?.mimeType != 'text/html') {
        return false;
      }
      Future<List<int>> body() async {
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk.take(4096 - bytes.length));
          if (bytes.length >= 4096) break;
        }
        return bytes;
      }

      final bytes = await body().timeout(const Duration(seconds: 3));
      return utf8
          .decode(bytes, allowMalformed: true)
          .toLowerCase()
          .contains('<html');
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _set(LlbotDeploymentPhase value, {String? stage, String? failure}) {
    _phase = value;
    _stage = _steps.contains(stage) ? stage : null;
    _failure = failure == null ? null : _safeFailure(failure);
    _changed();
  }

  static String _safeFailure(Object? value) =>
      value is String && _failures.contains(value) ? value : 'install_failed';

  Future<void> _perform(Future<void> Function() action, String failure) {
    final active = _operation;
    if (active != null) return active;
    final completer = Completer<void>();
    _operation = completer.future;
    _failure = null;
    _changed();
    () async {
      try {
        await action();
      } on _DeploymentFailure catch (error) {
        _set(LlbotDeploymentPhase.failed, failure: error.code);
      } on Object {
        _set(LlbotDeploymentPhase.failed, failure: failure);
      } finally {
        _operation = null;
        _stage = null;
        _changed();
        completer.complete();
      }
    }();
    return completer.future;
  }

  Future<BuiltinLinuxStatus> _status() =>
      _linux.status().timeout(const Duration(seconds: 10));

  Future<void> _stop(String name) =>
      _linux.stopService(name).timeout(const Duration(seconds: 20));

  Future<BuiltinLinuxStatus?> _check() async {
    _set(LlbotDeploymentPhase.checking, stage: 'checking');
    if (!(_supported ?? BuiltinLinux.supported)) {
      _set(LlbotDeploymentPhase.unsupported);
      return null;
    }
    final status = await _status();
    if (!status.installed || status.phase != BuiltinLinuxPhase.ready) {
      _set(LlbotDeploymentPhase.linuxUnavailable, failure: 'linux_unavailable');
      return null;
    }
    if (!{'arm64-v8a', 'arm64', 'aarch64'}.contains(status.abi)) {
      _set(LlbotDeploymentPhase.unsupported);
      return null;
    }
    _filesystem = await _rootfs();
    return status;
  }

  File _file(String path) => File('${_filesystem!.path}$root/$path');

  Future<String?> _read(String path) async {
    final file = _file(path);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file || await file.length() > 8192) {
      throw const _DeploymentFailure('storage');
    }
    return file.readAsString();
  }

  Future<Map<String, dynamic>?> _record(String path) async {
    final text = await _read(path);
    if (text == null) return null;
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) {
      throw const _DeploymentFailure('storage');
    }
    return value;
  }

  Future<void> _request(String path, String job) async {
    final destination = _file(path);
    final temporary = File('${destination.path}.${_newId()}');
    try {
      await temporary.writeAsString(jsonEncode({'job': job}), flush: true);
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<String> _requestedJob(String path) async {
    final record = await _record(path);
    final job = record?['job'];
    if (job is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(job)) {
      throw const _DeploymentFailure('status_failed');
    }
    return job;
  }

  Future<bool> _installed() async {
    final Map<String, dynamic>? receipt;
    try {
      receipt = await _record('current.json');
    } on FormatException {
      throw const _DeploymentFailure('integrity');
    } on FileSystemException {
      throw const _DeploymentFailure('integrity');
    } on _DeploymentFailure {
      throw const _DeploymentFailure('integrity');
    }
    if (receipt == null) return false;
    final directory = receipt['directory'];
    final tree = receipt['tree'];
    if (receipt['version'] != version ||
        receipt['archive'] != archiveSha256 ||
        receipt['patch'] != runtimePatch ||
        receipt['bundle'] != managedBundleSha256 ||
        directory is! String ||
        !RegExp(r'^release-[a-f0-9]{32}$').hasMatch(directory) ||
        tree is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(tree)) {
      throw const _DeploymentFailure('integrity');
    }
    return true;
  }

  /// Reconciles native ownership with local completion records and HTTP health.
  Future<void> refresh() => _perform(() async {
    final status = await _check();
    if (status == null) return;
    if (status.serviceRunning(installerServiceName)) {
      await _waitInstall(null);
    }
    if (!await _installed()) {
      _set(LlbotDeploymentPhase.notInstalled);
      return;
    }
    if ((await _status()).serviceRunning(serviceName)) {
      await _waitRunning(null);
    } else {
      final run = await _record('run.json');
      _set(
        run?['phase'] == 'failed'
            ? LlbotDeploymentPhase.failed
            : LlbotDeploymentPhase.stopped,
        failure: run?['phase'] == 'failed'
            ? _safeFailure(run?['failure'])
            : null,
      );
    }
  }, 'status_failed');

  static String _newId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<String> _helpers() async {
    const assets = [
      helperAsset,
      guardAsset,
      noticesAsset,
      llbotLicenseAsset,
      nodeLicenseAsset,
    ];
    const names = [
      'llbot_deploy.py',
      'llbot_deploy_guard.mjs',
      'NOTICES.txt',
      'COPYING.LLBot',
      'notices/Node.LICENSE',
    ];
    final sources = await Future.wait(assets.map(_loadAsset));
    final revision = sha256
        .convert(utf8.encode(sources.join('\x00')))
        .toString();
    final directory = '$root/helpers/$revision';
    // Only fixed paths/digests go over the platform channel. Python creates
    // credentials inside private state; no secret travels in shell argv/logs.
    final prepared = await _linux
        .run(
          'set -eu\numask 077\n'
          'test ! -L $root\n'
          'mkdir -p $directory\nmkdir -p $root/notices\n'
          'chmod 700 $root $root/helpers $directory $root/notices\n',
          timeout: const Duration(seconds: 30),
        )
        .timeout(const Duration(seconds: 45));
    if (!prepared.ok) throw const _DeploymentFailure('helper_unavailable');
    for (var i = 0; i < sources.length; i++) {
      final folder = i < 2 ? directory : root;
      final destination = File('${_filesystem!.path}$folder/${names[i]}');
      await destination.parent.create(recursive: true);
      if (await destination.exists() &&
          await destination.readAsString() == sources[i]) {
        continue;
      }
      final temporary = File('${destination.path}.${_newId()}');
      try {
        await temporary.writeAsString(sources[i], flush: true);
        await temporary.rename(destination.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    return '$directory/llbot_deploy.py';
  }

  String _script(String helper, String action, String job) {
    final script = StringBuffer('set -eu\numask 077\n');
    if (action == 'install') {
      String record(String stage, {String? failure}) => jsonEncode({
        'job': job,
        'phase': failure == null ? 'installing' : 'failed',
        'stage': stage,
        'failure': failure,
      });
      // Minimal Ubuntu need not contain Python/CA certificates. APT verifies
      // the distro's signed packages; its output never enters app diagnostics.
      // Both package steps are finite even when the Dart screen has gone away.
      script.write(
        'llbot_record() { printf "%s\\n" "\$1" > $root/bootstrap-$job.tmp; '
        'mv -f $root/bootstrap-$job.tmp $root/job.json; }\n'
        "llbot_record '${record('checking')}'\n"
        'if ! command -v python3 >/dev/null 2>&1 || '
        '[ ! -s /etc/ssl/certs/ca-certificates.crt ]; then\n'
        "  llbot_record '${record('install')}'\n"
        '  if ! command -v timeout >/dev/null 2>&1 || '
        '! timeout 120s apt-get update -o Acquire::Retries=1 '
        '-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 '
        '>/dev/null 2>&1 || '
        '! DEBIAN_FRONTEND=noninteractive timeout 180s apt-get install -y '
        '--no-install-recommends -o Dpkg::Use-Pty=0 -o Acquire::Retries=1 '
        '-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 '
        'python3 ca-certificates >/dev/null 2>&1; then\n'
        "    llbot_record '${record('install', failure: 'helper_unavailable')}'\n"
        '    exit 1\n'
        '  fi\n'
        'fi\n',
      );
    }
    script.write('exec python3 $helper $action --job $job\n');
    return script.toString();
  }

  /// Completes only after the installer succeeded and the tracked console is ready.
  Future<void> deploy() => _perform(() async {
    final status = await _check();
    if (status == null) return;
    if (status.serviceRunning(serviceName)) {
      var installed = false;
      try {
        installed = await _installed();
      } on _DeploymentFailure catch (error) {
        if (error.code != 'integrity') rethrow;
      }
      if (installed) {
        await _waitRunning(null);
        return;
      }
      // Repair/upgrade only our tracked process. A broken receipt never causes
      // an old unpatched runtime to be accepted as the current managed build.
      await _stop(serviceName);
    }
    final helper = await _helpers();
    if (status.serviceRunning(installerServiceName)) {
      await _waitInstall(null);
    } else {
      final job = _newId();
      await _request('install-request.json', job);
      _set(LlbotDeploymentPhase.installing, stage: 'checking');
      await _linux
          .startService(installerServiceName, _script(helper, 'install', job))
          .timeout(const Duration(seconds: 20));
      await _waitInstall(job);
    }
    await _start(helper);
  }, 'install_failed');

  Future<void> _waitInstall(String? requestedJob) async {
    final job = requestedJob ?? await _requestedJob('install-request.json');
    final elapsed = Stopwatch()..start();
    _set(LlbotDeploymentPhase.installing, stage: 'checking');
    for (
      var attempt = 0;
      attempt < installPollAttempts && elapsed.elapsed < installTimeout;
      attempt++
    ) {
      final record = await _record('job.json');
      final matches =
          record != null &&
          record['job'] == job &&
          RegExp(r'^[a-f0-9]{32}$').hasMatch('${record['job']}');
      if (matches) {
        if (record['phase'] == 'failed') {
          await _stop(installerServiceName);
          throw _DeploymentFailure(_safeFailure(record['failure']));
        }
        if (record['phase'] == 'installed') {
          await _stop(installerServiceName);
          if (!await _installed()) throw const _DeploymentFailure('integrity');
          return;
        }
        _set(
          LlbotDeploymentPhase.installing,
          stage: _steps.contains(record['stage'])
              ? record['stage'] as String
              : 'checking',
        );
      }
      if (!(await _status()).serviceRunning(installerServiceName)) {
        // Read once more after native exit: the final atomic receipt may have
        // appeared between the file read and process-liveness observation.
        final finalRecord = await _record('job.json');
        if (finalRecord?['job'] == job &&
            finalRecord?['phase'] == 'installed' &&
            await _installed()) {
          return;
        }
        if (finalRecord?['job'] == job && finalRecord?['phase'] == 'failed') {
          throw _DeploymentFailure(_safeFailure(finalRecord?['failure']));
        }
        throw const _DeploymentFailure('install_interrupted');
      }
      await _delay(pollInterval);
    }
    await _stop(installerServiceName);
    throw const _DeploymentFailure('install_timeout');
  }

  Future<void> start() => _perform(() async {
    final status = await _check();
    if (status == null) return;
    if (!await _installed()) {
      _set(LlbotDeploymentPhase.notInstalled, failure: 'not_installed');
      return;
    }
    if (status.serviceRunning(serviceName)) {
      await _waitRunning(null);
      return;
    }
    await _start(await _helpers());
  }, 'start_failed');

  Future<void> _start(String helper) async {
    final generation = _newId();
    await _request('run-request.json', generation);
    _set(LlbotDeploymentPhase.starting, stage: 'start');
    await _linux
        .startService(
          serviceName,
          _script(helper, 'run', generation),
          port: 3080,
        )
        .timeout(const Duration(seconds: 20));
    await _waitRunning(generation);
  }

  Future<void> _waitRunning(String? requestedGeneration) async {
    final generation =
        requestedGeneration ?? await _requestedJob('run-request.json');
    _set(LlbotDeploymentPhase.starting, stage: 'start');
    final elapsed = Stopwatch()..start();
    for (
      var attempt = 0;
      attempt < startPollAttempts && elapsed.elapsed < startTimeout;
      attempt++
    ) {
      final status = await _status();
      final record = await _record('run.json');
      final matches =
          record != null &&
          record['generation'] == generation &&
          RegExp(r'^[a-f0-9]{32}$').hasMatch('${record['generation']}');
      if (matches && record['phase'] == 'failed') {
        await _stop(serviceName);
        throw _DeploymentFailure(_safeFailure(record['failure']));
      }
      if (!status.serviceRunning(serviceName)) {
        throw const _DeploymentFailure('runtime_exited');
      }
      if (matches &&
          record['phase'] == 'running' &&
          await _probe().timeout(
            const Duration(seconds: 10),
            onTimeout: () => false,
          ) &&
          (await _status()).serviceRunning(serviceName)) {
        _set(LlbotDeploymentPhase.running);
        return;
      }
      await _delay(pollInterval);
    }
    await _stop(serviceName);
    throw const _DeploymentFailure('start_timeout');
  }

  Future<void> stop() => _perform(() async {
    if (await _check() == null) return;
    await _stop(serviceName);
    if ((await _status()).serviceRunning(serviceName)) {
      throw const _DeploymentFailure('stop_failed');
    }
    _set(
      await _installed()
          ? LlbotDeploymentPhase.stopped
          : LlbotDeploymentPhase.notInstalled,
    );
  }, 'stop_failed');

  /// Reads only generated local connection credentials, never QQ/login state.
  Future<LlbotLocalConnection> connection() async {
    try {
      if (_filesystem == null || !await _installed()) {
        throw const FormatException();
      }
      final record = await _record('state/connection.json');
      final token = record?['accessToken'];
      final password = (await _read('state/data/webui_token.txt'))?.trim();
      if (token is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(token) ||
          password == null ||
          !RegExp(r'^[!-~]{16,128}$').hasMatch(password)) {
        throw const FormatException();
      }
      return LlbotLocalConnection(
        webSocketUrl: 'ws://127.0.0.1:3001',
        accessToken: token,
        webUiPassword: password,
      );
    } on Object {
      throw StateError('llbot_credentials_unavailable');
    }
  }

  @override
  void dispose() {
    if (_keepAlive || _disposed) return;
    _disposed = true;
    super.dispose();
  }
}

class _DeploymentFailure implements Exception {
  const _DeploymentFailure(this.code);
  final String code;
}
