import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../builtin/builtin_linux.dart';
import '../../../builtin/snowluma_deployment.dart';
import '../../../builtin/snowluma_release.dart';
import '../../../channels/providers/snowluma_local_probe.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/platform_capabilities.dart';
import '../../app_iconography.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/kit.dart';

/// Guides personal QQ setup. On Android it can also import the official
/// archive the person downloaded themselves and start its launcher.
class SnowLumaSetupScreen extends StatefulWidget {
  const SnowLumaSetupScreen({
    super.key,
    this.localProbe,
    this.linuxStatus,
    this.deployment,
    this.pickArchive = _pickArchive,
  });

  final Future<SnowLumaLocalAvailability> Function()? localProbe;
  final Future<BuiltinLinuxStatus> Function()? linuxStatus;

  /// Omit to use the app-wide controller. A screen never disposes it.
  final SnowLumaDeployment? deployment;
  final Future<SnowLumaArchive?> Function() pickArchive;

  @override
  State<SnowLumaSetupScreen> createState() => _SnowLumaSetupScreenState();
}

Future<SnowLumaArchive?> _pickArchive() async {
  final file = await FilePicker.pickFile();
  if (file == null) return null;
  return SnowLumaArchive(length: file.length, read: file.readAsByteStream);
}

class _SnowLumaSetupScreenState extends State<SnowLumaSetupScreen> {
  SnowLumaLocalAvailability? _local;
  BuiltinLinuxStatus? _ubuntu;
  bool _checking = false;
  bool _verifying = false;
  SnowLumaArchive? _archive;
  SnowLumaArm64Release? _verified;
  bool _archiveMismatch = false;
  bool _readFailed = false;

  SnowLumaDeployment get _deployment =>
      widget.deployment ?? SnowLumaDeployment.shared;

  String _text(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  @override
  void initState() {
    super.initState();
    _deployment.addListener(_changed);
  }

  @override
  void dispose() {
    _deployment.removeListener(_changed);
    // SnowLumaDeployment.shared belongs to the app, not this route.
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _verifyArchive() async {
    if (_verifying) return;
    setState(() => _verifying = true);
    try {
      final archive = await widget.pickArchive();
      if (!mounted || archive == null) return;
      final release = await archive.verify();
      if (!mounted) return;
      _archive = archive;
      _verified = release;
      _archiveMismatch = release == null;
      _readFailed = false;
    } on Object {
      _archive = null;
      _verified = null;
      _archiveMismatch = false;
      _readFailed = true;
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _importAndStart() async {
    final release = _verified;
    final archive = _archive;
    if (release == null || archive == null || _deployment.busy) return;
    final confirmed = await showKitConfirm(
      context,
      title: _text('Start SnowLuma on this phone?', '在这台手机上启动 SnowLuma？'),
      body: _text(
        'The app will copy this verified archive into its own Ubuntu, extract it and run the included launcher. It will not download SnowLuma or sign in to QQ. SnowLuma’s EULA §5.4 requires prior written authorization before a Proprietary Component is deployed through an automated script; confirm your use complies before continuing.',
        'App 会把已校验的发行包复制到内置 Ubuntu、解压并运行包内启动器；不会下载 SnowLuma，也不会登录 QQ。SnowLuma EULA 第 5.4 条要求通过自动化脚本部署专有组件前取得书面授权；请先确认你的使用符合该条款。',
      ),
      confirmLabel: _text('Import and start', '导入并启动'),
    );
    if (!confirmed) return;
    await _deployment.importAndStart(release, archive);
  }

  Future<BuiltinLinuxStatus?> _checkUbuntu() async {
    try {
      return await (widget.linuxStatus ?? BuiltinLinux().status)().timeout(
        const Duration(seconds: 8),
      );
    } on Object {
      return null;
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _local = null;
      _ubuntu = null;
    });
    try {
      final (local, ubuntu) = await (
        (widget.localProbe ?? const SnowLumaLocalProbe().check)(),
        _checkUbuntu(),
      ).wait;
      if (!mounted) return;
      _local = local;
      _ubuntu = ubuntu;
    } on Object {
      // Do not show raw platform or network diagnostics here.
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String _ubuntuStatus() {
    final ubuntu = _ubuntu;
    if (ubuntu == null) {
      return _text('Could not check built-in Ubuntu.', '无法检查内置 Ubuntu。');
    }
    if (!ubuntu.installed || ubuntu.phase != BuiltinLinuxPhase.ready) {
      return _text('Built-in Ubuntu is not ready.', '内置 Ubuntu 尚未就绪。');
    }
    if (!const {'arm64-v8a', 'arm64', 'aarch64'}.contains(ubuntu.abi)) {
      return _text('Built-in Ubuntu is not ARM64.', '内置 Ubuntu 不是 ARM64。');
    }
    return _text('Built-in Ubuntu is ready (ARM64).', '内置 Ubuntu 已就绪（ARM64）。');
  }

  String _stageText(String? stage) => switch (stage) {
    'verify' => _text('Checking the archive again', '再次校验发行包'),
    'install' => _text('Extracting into built-in Ubuntu', '解压到内置 Ubuntu'),
    'start' => _text('Starting SnowLuma', '正在启动 SnowLuma'),
    _ => _text('Working…', '正在处理…'),
  };

  String _failureText(String? failure) => switch (failure) {
    'node_missing' || 'node_incompatible' => _text(
      'The lite archive needs Node.js 24.22.1 or 26.12.1 and later on Ubuntu’s PATH. Use the full ARM64 archive, which includes its runtime, or install a compatible Node.js in Ubuntu.',
      'Lite 发行包需要 Ubuntu 的 PATH 中有 Node.js 24.22.1 或 26.12.1 及更高版本。请改用自带运行环境的完整版 ARM64 发行包，或在 Ubuntu 中安装兼容的 Node.js。',
    ),
    'port_busy' => _text(
      'Port 5099 is already in use, possibly by a SnowLuma you started yourself. Connect to that instance, or stop it and try again.',
      '5099 端口已被占用，可能是你自行启动的 SnowLuma。请直接连接该实例，或停止它后重试。',
    ),
    'integrity' || 'archive_invalid' => _text(
      'The file could not be imported as the selected release. Pick the original tar.gz asset again.',
      '文件无法作为所选发行包导入。请重新选择原始 tar.gz 发行包。',
    ),
    'linux_unavailable' => _text(
      'Built-in Ubuntu is not ready. Finish its setup under This phone → Linux, then try again.',
      '内置 Ubuntu 尚未就绪。请先在「此手机 → Linux」完成安装，再重试。',
    ),
    'unsupported' => _text(
      'Importing on this phone needs Android ARM64 and the built-in Ubuntu.',
      '本机导入需要 Android ARM64 和内置 Ubuntu。',
    ),
    'helper_unavailable' => _text(
      'The extraction helper could not be prepared. Ubuntu may need a network connection to install Python.',
      '无法准备解压组件。Ubuntu 可能需要联网安装 Python。',
    ),
    'start_timeout' || 'start_failed' || 'runtime_exited' => _text(
      'SnowLuma did not become ready. Refresh the status and try starting again; if it keeps failing, run SnowLuma on a separate computer instead.',
      'SnowLuma 未能就绪。请刷新状态后重试；若持续失败，请改在独立电脑上运行 SnowLuma。',
    ),
    'stop_failed' => _text(
      'SnowLuma could not be stopped. Refresh the status and try again.',
      'SnowLuma 未能停止。请刷新状态后重试。',
    ),
    _ => _text(
      'The operation could not finish. Refresh the status or try again.',
      '操作未能完成。请刷新状态或重试。',
    ),
  };

  String _deploymentStatus(SnowLumaDeploymentPhase phase) => switch (phase) {
    SnowLumaDeploymentPhase.checking => _text(
      'Checking built-in Ubuntu…',
      '正在检查内置 Ubuntu…',
    ),
    SnowLumaDeploymentPhase.notInstalled => _text(
      'SnowLuma has not been imported yet.',
      '尚未导入 SnowLuma。',
    ),
    SnowLumaDeploymentPhase.importing => _text(
      'Importing the selected archive…',
      '正在导入所选发行包…',
    ),
    SnowLumaDeploymentPhase.starting => _text(
      'SnowLuma is starting…',
      'SnowLuma 正在启动…',
    ),
    SnowLumaDeploymentPhase.running => _text(
      'SnowLuma is running on port 5099. Signing in to QQ and enabling OneBot still happen in its WebUI; neither is verified here.',
      'SnowLuma 已在 5099 端口运行。QQ 登录和启用 OneBot 仍需在其 WebUI 中完成，这里不代表已完成。',
    ),
    SnowLumaDeploymentPhase.stopped => _text(
      'SnowLuma is stopped. Its data stays in the app’s Ubuntu.',
      'SnowLuma 已停止。数据保留在内置 Ubuntu 中。',
    ),
    SnowLumaDeploymentPhase.failed => _failureText(_deployment.failure),
    SnowLumaDeploymentPhase.unsupported => _text(
      'This device cannot run the app-managed SnowLuma.',
      '此设备无法运行由 App 管理的 SnowLuma。',
    ),
    SnowLumaDeploymentPhase.linuxUnavailable => _failureText(
      'linux_unavailable',
    ),
  };

  void _openConsole() {
    unawaited(
      Navigator.of(context).push<void>(
        KitPageRoute<void>(
          builder: (_) => _SnowLumaConsoleScreen(deployment: _deployment),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final local = _local;
    final verified = _verified;
    final deployment = _deployment;
    final phase = deployment.phase;
    final running = phase == SnowLumaDeploymentPhase.running;
    final installed =
        running ||
        phase == SnowLumaDeploymentPhase.stopped ||
        phase == SnowLumaDeploymentPhase.starting;
    return KitScreen(
      topBar: KitTopBar(title: _text('Set up SnowLuma', '配置 SnowLuma')),
      width: KitScreenWidth.reading,
      loading: deployment.busy,
      loadingLabel: _stageText(deployment.stage),
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text('1. Run SnowLuma and sign in to QQ', '1. 运行 SnowLuma 并登录 QQ'),
            role: KitTextRole.headline,
          ),
          KitText(
            _text(
              'Manually download the release for your host from TomyJan/SnowLuma, not “Source code”. Sign in with desktop QQ and finish setup in SnowLuma’s WebUI (port 5099 by default). No LuckyLillia account is needed.',
              '从 TomyJan/SnowLuma 手动下载适合主机的发行包，不要选「Source code」。登录桌面 QQ，再到 SnowLuma WebUI（默认 5099）完成接入。不需要 LuckyLillia 账号。',
            ),
          ),
          KitButton.fromAction(
            KitAction.copy(
              label: _text('Copy SnowLuma releases link', '复制 SnowLuma 发布页链接'),
              text: () => SnowLumaArm64Release.page,
            ),
            role: KitButtonRole.tertiary,
          ),
          if (platformCapabilities.isAndroid) ...[
            KitText(
              _text(
                'On this phone, pick the downloaded v2.4.2 Linux ARM64 archive (full or lite). The app checks its published SHA-256, then can copy it into built-in Ubuntu, extract it and start its launcher. It never downloads SnowLuma, and lite still needs a compatible Node.js.',
                '在本机上选择下载好的 v2.4.2 Linux ARM64 发行包（完整版或 Lite）。App 会核对发布页的 SHA-256，然后可复制到内置 Ubuntu、解压并启动包内启动器。App 不会下载 SnowLuma；Lite 仍需兼容的 Node.js。',
              ),
              role: KitTextRole.caption,
            ),
            KitButton.secondary(
              key: const ValueKey('snowluma-verify-archive'),
              label: _text(
                'Select and verify ARM64 archive',
                '选择并校验 ARM64 发行包',
              ),
              onPressed: _verifying ? null : () => unawaited(_verifyArchive()),
              working: _verifying,
            ),
            if (!_verifying && verified != null)
              KitNotice(
                tone: AppStatusTone.ok,
                message: _text(
                  '${verified.filename} matches the published SHA-256.',
                  '${verified.filename} 与发布页的 SHA-256 一致。',
                ),
              ),
            if (!_verifying && (_archiveMismatch || _readFailed))
              KitNotice(
                tone: AppStatusTone.failure,
                message: _readFailed
                    ? _text('Could not read the selected file.', '无法读取所选文件。')
                    : _text(
                        'This file does not match a supported v2.4.2 ARM64 release. Select the original tar.gz release asset, not a source archive.',
                        '文件与支持的 v2.4.2 ARM64 发行包不一致。请选择原始 tar.gz 发行包，不要选源码压缩包。',
                      ),
              ),
            if (!_verifying && verified != null) ...[
              KitGroupNote(
                message: _text(
                  'Importing starts a third-party component from the file you chose. It does not accept SnowLuma’s terms for you: the WebUI still asks you to review and accept its EULA and privacy notice.',
                  '导入只会启动你选中的第三方组件，不会代你接受 SnowLuma 条款：WebUI 仍会要求你阅读并接受其 EULA 与隐私说明。',
                ),
              ),
              KitButton.secondary(
                key: const ValueKey('snowluma-import-start'),
                label: _text('Import into Ubuntu and start', '导入到 Ubuntu 并启动'),
                onPressed: deployment.busy
                    ? null
                    : () => unawaited(_importAndStart()),
              ),
            ],
            SizedBox(height: tokens.space2),
            KitGroupNote(message: _deploymentStatus(phase)),
            Wrap(
              spacing: tokens.space2,
              runSpacing: tokens.space2,
              children: [
                if (running) ...[
                  KitButton.secondary(
                    key: const ValueKey('snowluma-open-webui'),
                    label: _text('Open SnowLuma WebUI', '打开 SnowLuma WebUI'),
                    onPressed: _openConsole,
                  ),
                  KitButton.fromAction(
                    KitAction.copy(
                      label: _text('Copy WebUI address', '复制 WebUI 地址'),
                      text: () => deployment.webUiUri.toString(),
                    ),
                    role: KitButtonRole.tertiary,
                  ),
                ],
                if (installed && !running)
                  KitButton.secondary(
                    key: const ValueKey('snowluma-start'),
                    label: _text('Start SnowLuma', '启动 SnowLuma'),
                    onPressed: deployment.busy
                        ? null
                        : () => unawaited(deployment.start()),
                  ),
                if (running || phase == SnowLumaDeploymentPhase.starting)
                  KitButton.secondary(
                    key: const ValueKey('snowluma-stop'),
                    label: _text('Stop SnowLuma', '停止 SnowLuma'),
                    onPressed: deployment.busy
                        ? null
                        : () => unawaited(deployment.stop()),
                  ),
                KitButton.fromAction(
                  KitAction(
                    key: const ValueKey('snowluma-refresh'),
                    label: _text('Refresh status', '刷新状态'),
                    onPressed: deployment.busy
                        ? null
                        : () => unawaited(deployment.refresh()),
                  ),
                  role: KitButtonRole.tertiary,
                ),
              ],
            ),
          ],
          SizedBox(height: tokens.space4),
          KitText(
            _text('2. Configure the OneBot connection', '2. 配置 OneBot 连接'),
            role: KitTextRole.headline,
          ),
          KitText(
            _text(
              'For the QQ account, enable a OneBot 11 WebSocket server with the Universal role, array message format and an Access Token. The default WebSocket port is 3001. For a separate host, prefer wss:// or a trusted private network.',
              '为该 QQ 账号开启 OneBot 11 WebSocket 服务端，选择 Universal（通用）角色和数组消息格式，并设置 Access Token。默认 WebSocket 端口是 3001。连接其他主机时优先用 wss:// 或可信私有网络。',
            ),
          ),
          SizedBox(height: tokens.space4),
          KitText(
            _text('3. Verify the account in this app', '3. 在 App 内验证账号'),
            role: KitTextRole.headline,
          ),
          KitText(
            _text(
              'Go back and enter the OneBot address and token (not your WebUI or QQ password). Test to confirm the QQ account, then review who may send prompts before enabling and saving.',
              '返回后填写 OneBot 地址和 Token（不是 WebUI 或 QQ 密码）。测试确认 QQ 账号，再核对允许发送指令的用户后启用并保存。',
            ),
          ),
          if (platformCapabilities.isAndroid) ...[
            SizedBox(height: tokens.space4),
            KitText(
              _text('Already running on this phone?', '已在本机手动运行？'),
              role: KitTextRole.headline,
            ),
            KitGroupNote(
              message: _text(
                'Android Ubuntu is experimental for SnowLuma. This checks Ubuntu and the default loopback ports only; it does not verify QQ sign-in.',
                'SnowLuma 在安卓 Ubuntu 中的运行仍属实验。这里仅检查 Ubuntu 和默认回环端口，不代表 QQ 登录成功。',
              ),
            ),
            KitButton.secondary(
              key: const ValueKey('snowluma-check-local'),
              label: _text('Check this phone', '检查本机环境'),
              onPressed: _checking ? null : () => unawaited(_check()),
              working: _checking,
            ),
            if (local != null) ...[
              KitText(_ubuntuStatus(), role: KitTextRole.caption),
              KitText(
                local.consoleRecognized
                    ? _text(
                        'SnowLuma WebUI detected on port 5099.',
                        '已在 5099 端口识别到 SnowLuma WebUI。',
                      )
                    : _text(
                        'SnowLuma WebUI not detected on port 5099.',
                        '未在 5099 端口识别到 SnowLuma WebUI。',
                      ),
                role: KitTextRole.caption,
              ),
              KitText(
                local.oneBotPortOpen
                    ? _text(
                        'Port 3001 is reachable. Test OneBot to verify the account.',
                        '3001 端口可达，仍需测试 OneBot 以确认账号。',
                      )
                    : _text(
                        'Port 3001 is not accepting connections.',
                        '3001 端口未接受连接。',
                      ),
                role: KitTextRole.caption,
              ),
              if (local.canSuggestAddress)
                KitButton.secondary(
                  key: const ValueKey('snowluma-use-local-address'),
                  label: _text('Fill in local address', '填入本机地址'),
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(SnowLumaLocalProbe.defaultWebSocketUrl),
                ),
            ],
          ],
          SizedBox(height: tokens.space4),
          KitGroupNote(
            message: _text(
              'SnowLuma is independent of Tencent. Review its license and account risk before running it. OpenCode Plus does not bundle or download SnowLuma.',
              'SnowLuma 不是腾讯官方服务，运行前请查看其许可和账号风险。OpenCode Plus 不捆绑或下载 SnowLuma。',
            ),
          ),
        ],
      ),
    );
  }
}

/// The local WebUI only: the page may not leave 127.0.0.1:5099.
class _SnowLumaConsoleScreen extends StatefulWidget {
  const _SnowLumaConsoleScreen({required this.deployment});

  final SnowLumaDeployment deployment;

  @override
  State<_SnowLumaConsoleScreen> createState() => _SnowLumaConsoleScreenState();
}

class _SnowLumaConsoleScreenState extends State<_SnowLumaConsoleScreen> {
  final _web = KitWebPreviewController();
  bool _blockedLink = false;

  @override
  void dispose() {
    _web.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final supported = KitWebPreview.platformSupported();
    final tokens = KitTokens.of(context);
    return ListenableBuilder(
      listenable: _web,
      builder: (context, _) => KitScreen(
        topBar: KitTopBar(
          title: zh ? '本机 SnowLuma 管理页' : 'Local SnowLuma WebUI',
          actions: [
            if (supported)
              KitAction(
                label: l10n.devPreviewReload,
                icon: AppIconography.retry,
                onPressed: () => unawaited(_web.reload()),
              ),
          ],
        ),
        loading: supported && _web.phase == KitWebPreviewPhase.loading,
        loadingLabel: l10n.devPreviewLoading,
        header: [
          const KitDivider(),
          Padding(
            padding: EdgeInsets.all(tokens.space2),
            child: KitGroupNote(
              message: zh
                  ? '这是本机 SnowLuma，不是 QQ。请自行接受其 EULA、登录桌面 QQ、启用 OneBot，并把 OneBot Token 填回 QQ 表单。'
                  : 'This is the local SnowLuma page, not QQ. Accept its EULA yourself, sign in to desktop QQ, enable OneBot, and copy its token into the QQ form.',
            ),
          ),
          if (_blockedLink)
            Padding(
              padding: EdgeInsets.all(tokens.space2),
              child: KitGroupNote(
                message: zh
                    ? '本机管理页不打开外部链接。'
                    : 'The local console does not open external links.',
              ),
            ),
        ],
        body: KitWebPreview(
          origin: widget.deployment.webUiUri,
          controller: _web,
          strictOrigin: true,
          unsupportedBody: zh
              ? '当前设备无法显示内置的 SnowLuma 管理页。'
              : 'This device cannot display the local SnowLuma page.',
          failureBody: zh
              ? '管理页无法连接，请返回刷新状态，必要时重新启动 SnowLuma。'
              : 'The page is not responding. Go back, refresh the status and start SnowLuma again if needed.',
          onLeave: (_) {
            if (mounted && !_blockedLink) setState(() => _blockedLink = true);
          },
        ),
      ),
    );
  }
}
