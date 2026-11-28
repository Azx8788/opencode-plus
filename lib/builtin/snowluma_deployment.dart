import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'builtin_linux.dart';
import 'snowluma_release.dart';

enum SnowLumaDeploymentPhase {
  checking,
  notInstalled,
  importing,
  starting,
  running,
  stopped,
  failed,
  unsupported,
  linuxUnavailable,
}

enum SnowLumaWebUiAccess {
  initialToken,
  restartRequired,
  ownPassword,
  unavailable,
}

typedef _WebUiAccess = ({SnowLumaWebUiAccess state, String? token});

/// Imports and starts SnowLuma from an archive the person picked themselves.
///
/// The app never downloads SnowLuma and never signs in to QQ. It copies only
/// the selected file into its own Ubuntu, re-checks the published size and
/// SHA-256, extracts it under `/root/.oc-builtin/snowluma` and runs the
/// included launcher. The helper retains only the current initial WebUI token,
/// separately from status and logs. It is not a OneBot or QQ credential.
///
/// [shared] owns the work across navigation. `running` means the SnowLuma
/// WebUI answered on the loopback; it never means QQ is signed in or that the
/// OneBot connection works.
class SnowLumaDeployment extends ChangeNotifier {
  SnowLumaDeployment({
    BuiltinLinux? linux,
    Future<Directory> Function()? rootfs,
    Future<String> Function(String asset)? loadAsset,
    Future<void> Function(Duration)? delay,
    Future<bool> Function()? probe,
    Future<void> Function(SnowLumaArm64Release, SnowLumaArchive)? importArchive,
    bool? supported,
    this.pollInterval = const Duration(seconds: 1),
    this.installPollAttempts = 600,
    this.startPollAttempts = 180,
    this.installTimeout = const Duration(minutes: 10),
    this.startTimeout = const Duration(minutes: 4),
  }) : _linux = linux ?? BuiltinLinux(),
       _rootfs = rootfs ?? _defaultRootfs,
       _loadAsset = loadAsset ?? rootBundle.loadString,
       _delay = delay ?? Future<void>.delayed,
       _probe = probe ?? _webUiReady,
       _import = importArchive,
       _supported = supported;

  static final SnowLumaDeployment _shared = SnowLumaDeployment()
    .._keepAlive = true;
  static SnowLumaDeployment get shared => _shared;

  static const root = '/root/.oc-builtin/snowluma';
  static const serviceName = 'snowluma';
  static const installerServiceName = 'snowluma-install';
  static const helperAsset = 'tool/snowluma_launcher.py';
  static const webUiPort = 5099;
  static const _bootstrapRecord = 'webui-bootstrap.json';
  static const _steps = {'verify', 'install', 'start'};
  static const _failures = {
    'unsupported',
    'storage',
    'integrity',
    'archive_invalid',
    'not_installed',
    'node_missing',
    'node_incompatible',
    'port_busy',
    'start_failed',
    'start_timeout',
    'runtime_exited',
    'install_failed',
    'install_timeout',
    'stop_failed',
    'linux_unavailable',
    'helper_unavailable',
    'status_failed',
  };

  final BuiltinLinux _linux;
  final Future<Directory> Function() _rootfs;
  final Future<String> Function(String) _loadAsset;
  final Future<void> Function(Duration) _delay;
  final Future<bool> Function() _probe;
  final Future<void> Function(SnowLumaArm64Release, SnowLumaArchive)? _import;
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
  SnowLumaDeploymentPhase _phase = SnowLumaDeploymentPhase.checking;
  String? _stage;
  String? _failure;
  SnowLumaArm64Release? _installedRelease;
  String? _runningGeneration;

  SnowLumaDeploymentPhase get phase => _phase;
  bool get busy => _operation != null;
  String? get stage => _stage;
  String? get failure => _failure;
  SnowLumaArm64Release? get installedRelease => _installedRelease;
  Uri get webUiUri =>
      Uri(scheme: 'http', host: '127.0.0.1', port: webUiPort, path: '/');

  static Future<Directory> _defaultRootfs() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/linux/ubuntu',
  );

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _set(SnowLumaDeploymentPhase value, {String? stage, String? failure}) {
    _phase = value;
    if (value != SnowLumaDeploymentPhase.running) _runningGeneration = null;
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
        _set(SnowLumaDeploymentPhase.failed, failure: error.code);
      } on Object {
        _set(SnowLumaDeploymentPhase.failed, failure: failure);
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
    _installedRelease = null;
    _set(SnowLumaDeploymentPhase.checking, stage: null);
    if (!(_supported ?? BuiltinLinux.supported)) {
      _set(SnowLumaDeploymentPhase.unsupported);
      return null;
    }
    final status = await _status();
    if (!status.installed || status.phase != BuiltinLinuxPhase.ready) {
      _set(
        SnowLumaDeploymentPhase.linuxUnavailable,
        failure: 'linux_unavailable',
      );
      return null;
    }
    if (!const {'arm64-v8a', 'arm64', 'aarch64'}.contains(status.abi)) {
      _set(SnowLumaDeploymentPhase.unsupported);
      return null;
    }
    _filesystem = await _rootfs();
    return status;
  }

  File _file(String path) => File('${_filesystem!.path}$root/$path');

  Future<Map<String, dynamic>?> _record(String path) async {
    final file = _file(path);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file || await file.length() > 65536) {
      throw const _DeploymentFailure('storage');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const _DeploymentFailure('storage');
    }
    return value;
  }

  Future<void> _write(String path, Object value) async {
    final destination = _file(path);
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.${_newId()}');
    try {
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<bool> _installed() async {
    _installedRelease = null;
    final Map<String, dynamic>? record;
    try {
      record = await _record('current.json');
    } on FormatException {
      throw const _DeploymentFailure('not_installed');
    } on FileSystemException {
      throw const _DeploymentFailure('not_installed');
    }
    if (record == null) return false;
    for (final release in SnowLumaArm64Release.values) {
      if (record['version'] == '2.4.2' &&
          record['release'] == release.key &&
          record['sha256'] == release.sha256Hex &&
          record['directory'] == _releaseDirectory(release)) {
        _installedRelease = release;
        return true;
      }
    }
    throw const _DeploymentFailure('not_installed');
  }

  static String _releaseDirectory(SnowLumaArm64Release release) =>
      'release-${release.sha256Hex.substring(0, 16)}';

  /// Reports the credential state without putting the token into UI state.
  Future<SnowLumaWebUiAccess> webUiAccess() async =>
      (await _readWebUiAccess()).state;

  /// Reads the current initial token only on an explicit action. An old run,
  /// a changed password or a service not managed by the app never returns it.
  Future<String?> readInitialWebUiToken() async =>
      (await _readWebUiAccess()).token;

  Future<_WebUiAccess> _readWebUiAccess() async {
    const unavailable = (state: SnowLumaWebUiAccess.unavailable, token: null);
    final release = _installedRelease;
    final generation = _runningGeneration;
    if (_disposed || busy || release == null || generation == null) {
      return unavailable;
    }
    try {
      if (!(await _status()).serviceRunning(serviceName) ||
          busy ||
          generation != _runningGeneration) {
        return unavailable;
      }
      final run = await _record('run.json');
      if (run?['phase'] != 'running' || run?['generation'] != generation) {
        return unavailable;
      }
      final entry = await _record(_bootstrapRecord);
      final directory = 'releases/${_releaseDirectory(release)}';
      for (final path in ['releases', directory, '$directory/config']) {
        if (await FileSystemEntity.type(_file(path).path, followLinks: false) !=
            FileSystemEntityType.directory) {
          return unavailable;
        }
      }
      final file = _file('$directory/config/webui.json');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return unavailable;
      }
      final handle = await file.open();
      final List<int> bytes;
      try {
        bytes = await handle.read(8193);
      } finally {
        await handle.close();
      }
      if (bytes.length > 8192 || busy || generation != _runningGeneration) {
        return unavailable;
      }
      final auth = jsonDecode(utf8.decode(bytes));
      if (auth is! Map || auth['mustChangePassword'] is! bool) {
        return unavailable;
      }
      if (auth['mustChangePassword'] == false) {
        return (state: SnowLumaWebUiAccess.ownPassword, token: null);
      }
      final token = entry?['token'];
      if (entry?['generation'] == generation &&
          entry?['auth_sha256'] == sha256.convert(bytes).toString() &&
          token is String &&
          RegExp(r'^[0-9a-f]{16}$').hasMatch(token)) {
        return (state: SnowLumaWebUiAccess.initialToken, token: token);
      }
      return (state: SnowLumaWebUiAccess.restartRequired, token: null);
    } on Object {
      return unavailable;
    }
  }

  /// Reconciles the tracked service with the records and the loopback WebUI.
  Future<void> refresh() => _perform(() async {
    final status = await _check();
    if (status == null) return;
    if (status.serviceRunning(installerServiceName)) {
      await _waitInstall(null);
    }
    if (!await _installed()) {
      _set(SnowLumaDeploymentPhase.notInstalled);
      return;
    }
    if ((await _status()).serviceRunning(serviceName)) {
      await _waitRunning(null);
    } else {
      final run = await _record('run.json');
      _set(
        run?['phase'] == 'failed'
            ? SnowLumaDeploymentPhase.failed
            : SnowLumaDeploymentPhase.stopped,
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

  Future<String> _helper() async {
    final source = await _loadAsset(helperAsset);
    final revision = sha256.convert(utf8.encode(source)).toString();
    final directory = '$root/helpers/$revision';
    final prepared = await _linux
        .run(
          'set -eu\numask 077\ntest ! -L $root\n'
          'mkdir -p $root\nmkdir -p $root/import $root/releases $root/helpers\n'
          'chmod 700 $root $root/import $root/releases $root/helpers\n',
          timeout: const Duration(seconds: 30),
        )
        .timeout(const Duration(seconds: 45));
    if (!prepared.ok) throw const _DeploymentFailure('helper_unavailable');
    final destination = File(
      '${_filesystem!.path}$directory/snowluma_launcher.py',
    );
    await destination.parent.create(recursive: true);
    if (!await destination.exists() ||
        await destination.readAsString() != source) {
      final temporary = File('${destination.path}.${_newId()}');
      try {
        await temporary.writeAsString(source, flush: true);
        await temporary.rename(destination.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    return '$directory/snowluma_launcher.py';
  }

  /// Copies only the selected archive, checking the published digest again
  /// while it streams. The file name is not trusted.
  Future<void> _copy(
    SnowLumaArm64Release release,
    SnowLumaArchive source,
  ) async {
    _set(SnowLumaDeploymentPhase.importing, stage: 'verify');
    final directory = Directory('${_filesystem!.path}$root/import');
    await directory.create(recursive: true);
    try {
      await SnowLumaArchiveCopy.write(
        source: source,
        expectedSize: release.size,
        expectedSha256: release.sha256Hex,
        destination: File('${directory.path}/${release.filename}'),
        temporarySuffix: _newId(),
      );
    } on SnowLumaArchiveCopyError catch (error) {
      throw _DeploymentFailure(error.code);
    }
  }

  String _installScript(String helper, String job, String release) {
    String record(String phase, {String? stage, String? failure}) => jsonEncode(
      {'job': job, 'phase': phase, 'stage': stage, 'failure': failure},
    );
    final script = StringBuffer('set -eu\numask 077\n');
    script.write(
      'snowluma_record() { printf "%s\\n" "\$1" > $root/bootstrap-$job.tmp; '
      'mv -f $root/bootstrap-$job.tmp $root/job.json; }\n'
      "snowluma_record '${record('installing', stage: 'verify')}'\n"
      'if ! command -v python3 >/dev/null 2>&1 || '
      '[ ! -s /etc/ssl/certs/ca-certificates.crt ]; then\n'
      "  snowluma_record '${record('installing', stage: 'install')}'\n"
      '  if ! command -v timeout >/dev/null 2>&1 || '
      '! timeout 120s apt-get update -o Acquire::Retries=1 '
      '-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 '
      '>/dev/null 2>&1 || '
      '! DEBIAN_FRONTEND=noninteractive timeout 180s apt-get install -y '
      '--no-install-recommends -o Dpkg::Use-Pty=0 -o Acquire::Retries=1 '
      '-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 '
      'python3 ca-certificates >/dev/null 2>&1; then\n'
      "    snowluma_record '${record('failed', failure: 'helper_unavailable')}'\n"
      '    exit 1\n'
      '  fi\n'
      'fi\n'
      'exec python3 $helper install --job $job --release $release\n',
    );
    return script.toString();
  }

  Future<void> importAndStart(
    SnowLumaArm64Release release,
    SnowLumaArchive source,
  ) => _perform(() async {
    final status = await _check();
    if (status == null) return;
    final helper = await _helper();
    await (_import ?? _copy)(release, source);
    if (status.serviceRunning(installerServiceName)) {
      await _waitInstall(null);
    } else {
      final job = _newId();
      await _write('install-request.json', {
        'job': job,
        'release': release.key,
      });
      _set(SnowLumaDeploymentPhase.importing, stage: 'install');
      await _linux
          .startService(
            installerServiceName,
            _installScript(helper, job, release.key),
          )
          .timeout(const Duration(seconds: 20));
      await _waitInstall(job);
    }
    // The extracted tree is self-contained; the uploaded archive is not needed
    // and can be large.
    try {
      await _file('import/${release.filename}').delete();
    } on FileSystemException {
      // Leaving it is harmless; a later import overwrites it.
    }
    await _start(helper);
  }, 'install_failed');

  Future<void> _waitInstall(String? requestedJob) async {
    final job =
        requestedJob ??
        (await _record('install-request.json'))?['job'] as String?;
    if (job == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(job)) {
      throw const _DeploymentFailure('install_failed');
    }
    final elapsed = Stopwatch()..start();
    _set(SnowLumaDeploymentPhase.importing, stage: 'install');
    for (
      var attempt = 0;
      attempt < installPollAttempts && elapsed.elapsed < installTimeout;
      attempt++
    ) {
      final record = await _record('job.json');
      if (record?['job'] == job) {
        if (record?['phase'] == 'failed') {
          await _stop(installerServiceName);
          throw _DeploymentFailure(_safeFailure(record?['failure']));
        }
        if (record?['phase'] == 'installed') {
          await _stop(installerServiceName);
          if (!await _installed()) {
            throw const _DeploymentFailure('install_failed');
          }
          return;
        }
        _set(
          SnowLumaDeploymentPhase.importing,
          stage: record?['stage'] == 'verify' ? 'verify' : 'install',
        );
      }
      if (!(await _status()).serviceRunning(installerServiceName)) {
        final finalRecord = await _record('job.json');
        if (finalRecord?['job'] == job &&
            finalRecord?['phase'] == 'installed' &&
            await _installed()) {
          return;
        }
        if (finalRecord?['job'] == job && finalRecord?['phase'] == 'failed') {
          throw _DeploymentFailure(_safeFailure(finalRecord?['failure']));
        }
        throw const _DeploymentFailure('install_failed');
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
      _set(SnowLumaDeploymentPhase.notInstalled, failure: 'not_installed');
      return;
    }
    if (status.serviceRunning(serviceName)) {
      await _waitRunning(null);
      return;
    }
    await _start(await _helper());
  }, 'start_failed');

  Future<void> _start(String helper) async {
    final generation = _newId();
    await _write('run-request.json', {'generation': generation});
    _set(SnowLumaDeploymentPhase.starting, stage: 'start');
    await _linux
        .startService(
          serviceName,
          'set -eu\numask 077\nexec python3 $helper run --job $generation\n',
          port: webUiPort,
        )
        .timeout(const Duration(seconds: 20));
    await _waitRunning(generation);
  }

  Future<void> _waitRunning(String? requestedGeneration) async {
    final generation =
        requestedGeneration ??
        (await _record('run-request.json'))?['generation'] as String?;
    if (generation == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(generation)) {
      throw const _DeploymentFailure('start_failed');
    }
    _set(SnowLumaDeploymentPhase.starting, stage: 'start');
    final elapsed = Stopwatch()..start();
    for (
      var attempt = 0;
      attempt < startPollAttempts && elapsed.elapsed < startTimeout;
      attempt++
    ) {
      final status = await _status();
      final record = await _record('run.json');
      final matches = record?['generation'] == generation;
      if (matches && record?['phase'] == 'failed') {
        await _stop(serviceName);
        throw _DeploymentFailure(_safeFailure(record?['failure']));
      }
      if (!status.serviceRunning(serviceName)) {
        throw const _DeploymentFailure('runtime_exited');
      }
      if (matches &&
          record?['phase'] == 'running' &&
          await _probe().timeout(
            const Duration(seconds: 10),
            onTimeout: () => false,
          ) &&
          (await _status()).serviceRunning(serviceName)) {
        _runningGeneration = generation;
        _set(SnowLumaDeploymentPhase.running);
        return;
      }
      await _delay(pollInterval);
    }
    await _stop(serviceName);
    throw const _DeploymentFailure('start_timeout');
  }

  Future<void> stop() => _perform(() async {
    if (await _check() == null) return;
    await _stopRuntime();
    _set(
      await _installed()
          ? SnowLumaDeploymentPhase.stopped
          : SnowLumaDeploymentPhase.notInstalled,
    );
  }, 'stop_failed');

  /// Restarts a managed installation without importing or resetting its data.
  Future<void> restart() => _perform(() async {
    final status = await _check();
    if (status == null) return;
    if (!await _installed()) {
      _set(SnowLumaDeploymentPhase.notInstalled);
      return;
    }
    final helper = await _helper();
    if (status.serviceRunning(serviceName)) await _stopRuntime();
    await _start(helper);
  }, 'start_failed');

  Future<void> _stopRuntime() async {
    await _stop(serviceName);
    if ((await _status()).serviceRunning(serviceName)) {
      throw const _DeploymentFailure('stop_failed');
    }
    // Android may have killed the helper before its finalizer ran.
    try {
      await _file(_bootstrapRecord).delete();
    } on FileSystemException {
      // Missing, or inaccessible; an inactive generation cannot expose it.
    }
  }

  /// Same page check as the read-only local probe: no redirects, no bodies
  /// beyond a title, no credentials.
  static Future<bool> _webUiReady() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2)
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client
          .getUrl(
            Uri(scheme: 'http', host: '127.0.0.1', port: webUiPort, path: '/'),
          )
          .timeout(const Duration(seconds: 3));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      if (response.statusCode != 200 ||
          response.headers.contentType?.mimeType != 'text/html') {
        return false;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk.take(8192 - bytes.length));
        if (bytes.length >= 8192) break;
      }
      return RegExp(
        r'<title>\s*SnowLuma(?:\s+(?:控制台|WebUI))?\s*</title>',
        caseSensitive: false,
      ).hasMatch(utf8.decode(bytes, allowMalformed: true));
    } on Object {
      return false;
    } finally {
      client.close(force: true);
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

class SnowLumaArchiveCopyError implements Exception {
  const SnowLumaArchiveCopyError(this.code);

  /// `integrity` or `storage`.
  final String code;
}

/// Streams [source] to [destination] through a temporary file and only renames
/// it after the exact published size and SHA-256 match. A file that grows or
/// shrinks mid-read fails and leaves nothing behind.
class SnowLumaArchiveCopy {
  const SnowLumaArchiveCopy._();

  static Future<void> write({
    required SnowLumaArchive source,
    required int expectedSize,
    required String expectedSha256,
    required File destination,
    required String temporarySuffix,
  }) async {
    final temporary = File('${destination.path}.$temporarySuffix');
    final sink = _DigestSink();
    final hasher = sha256.startChunkedConversion(sink);
    IOSink? writer;
    var count = 0;
    try {
      await destination.parent.create(recursive: true);
      writer = temporary.openWrite();
      await for (final chunk in source.read()) {
        count += chunk.length;
        if (count > expectedSize) {
          throw const SnowLumaArchiveCopyError('integrity');
        }
        hasher.add(chunk);
        writer.add(chunk);
      }
      await writer.flush();
      await writer.close();
      writer = null;
      hasher.close();
      if (count != expectedSize || sink.value.toString() != expectedSha256) {
        throw const SnowLumaArchiveCopyError('integrity');
      }
      await temporary.rename(destination.path);
    } on SnowLumaArchiveCopyError {
      rethrow;
    } on Object {
      throw const SnowLumaArchiveCopyError('storage');
    } finally {
      await writer?.close();
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('digest_missing'));

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
