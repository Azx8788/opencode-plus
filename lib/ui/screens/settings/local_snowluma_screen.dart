import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../builtin/snowluma_deployment.dart';
import '../../../builtin/snowluma_release.dart';
import '../../../l10n/app_localizations.dart';
import '../../app_iconography.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/kit.dart';

String _text(BuildContext context, String en, String zh) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

/// The local runtime manager. Configuring a QQ channel is a separate task.
class LocalSnowLumaScreen extends StatefulWidget {
  const LocalSnowLumaScreen({
    super.key,
    this.deployment,
    this.pickArchive = _pickArchive,
  });

  final SnowLumaDeployment? deployment;
  final Future<SnowLumaArchive?> Function() pickArchive;

  @override
  State<LocalSnowLumaScreen> createState() => _LocalSnowLumaScreenState();
}

Future<SnowLumaArchive?> _pickArchive() async {
  final file = await FilePicker.pickFile();
  return file == null
      ? null
      : SnowLumaArchive(length: file.length, read: file.readAsByteStream);
}

class _LocalSnowLumaScreenState extends State<LocalSnowLumaScreen> {
  late final _deployment = widget.deployment ?? SnowLumaDeployment.shared;
  SnowLumaArchive? _archive;
  SnowLumaArm64Release? _verified;
  String? _archiveError;
  bool _verifying = false;
  int _accessRevision = 0;

  String _t(String en, String zh) => _text(context, en, zh);
  bool get _busy => _verifying || _deployment.busy;

  @override
  void initState() {
    super.initState();
    unawaited(_deployment.refresh());
  }

  Future<void> _verify() async {
    if (_busy) return;
    setState(() => _verifying = true);
    try {
      final archive = await widget.pickArchive();
      if (!mounted || archive == null) return;
      final verified = await archive.verify();
      if (!mounted) return;
      _archive = verified == null ? null : archive;
      _verified = verified;
      _archiveError = verified == null ? 'mismatch' : null;
    } on Object {
      _archive = null;
      _verified = null;
      _archiveError = 'read';
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _importAndStart() async {
    final archive = _archive;
    final release = _verified;
    if (_busy || archive == null || release == null) return;
    final confirmed = await showKitConfirm(
      context,
      title: _t('Import and start SnowLuma?', '导入并启动 SnowLuma？'),
      body: _t(
        'This copies the verified archive into built-in Ubuntu and runs its launcher. Under SnowLuma’s EULA §5.4, automated deployment of a proprietary component requires prior written authorization. Only proceed if you have the required authorization.',
        '此操作会将已校验的发行包复制到内置 Ubuntu，解压并运行启动器。SnowLuma EULA 第 5.4 条要求通过自动化脚本部署专有组件前取得书面授权；请在取得所需授权后继续。',
      ),
      confirmLabel: _t('Import and start', '导入并启动'),
      confirmKey: const ValueKey('snowluma-confirm-import'),
    );
    if (!confirmed || !mounted || _busy) return;
    await _deployment.importAndStart(release, archive);
    if (mounted && _deployment.installedRelease == release) {
      setState(() {
        _archive = null;
        _verified = null;
      });
    }
  }

  Future<void> _restartForToken() async {
    if (_busy) return;
    final confirmed = await showKitConfirm(
      context,
      title: _t('Restart SnowLuma?', '重启 SnowLuma？'),
      body: _t(
        'SnowLuma will issue a new initial access token if you have not changed its password. It will briefly disconnect, but your files and account settings stay in place.',
        '如果还没改过初始密码，SnowLuma 会生成新的初始令牌。重启会短暂断开连接，文件和账号配置不会被清除。',
      ),
      confirmLabel: _t('Restart', '重启'),
      confirmKey: const ValueKey('snowluma-confirm-restart'),
    );
    if (!confirmed || !mounted || _busy) return;
    await _deployment.restart();
    _updateAccess();
  }

  void _updateAccess() {
    if (mounted) setState(() => _accessRevision++);
  }

  Future<void> _openConsole() async {
    await Navigator.of(context).push<void>(
      KitPageRoute<void>(
        builder: (_) => _SnowLumaConsoleScreen(deployment: _deployment),
      ),
    );
    _updateAccess();
  }

  Future<void> _openIssues() async {
    const url = 'https://github.com/Azx8788/opencode-plus/issues';
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on Object {
      // Some devices cannot open a browser. Offer the same public link.
    }
    if (mounted) await KitCopy.copy(context, url);
  }

  String _status(SnowLumaDeploymentPhase phase) => switch (phase) {
    SnowLumaDeploymentPhase.checking => _t('Checking Ubuntu', '检查 Ubuntu 中'),
    SnowLumaDeploymentPhase.notInstalled => _t('Not imported', '尚未导入'),
    SnowLumaDeploymentPhase.importing =>
      _deployment.stage == 'verify'
          ? _t('Verifying archive', '正在校验发行包')
          : _t('Extracting archive', '正在解压发行包'),
    SnowLumaDeploymentPhase.starting => _t('Starting', '正在启动'),
    SnowLumaDeploymentPhase.running => _t('WebUI ready', '管理页已就绪'),
    SnowLumaDeploymentPhase.stopped => _t('Stopped', '已停止'),
    SnowLumaDeploymentPhase.failed => _t('Operation failed', '操作失败'),
    SnowLumaDeploymentPhase.unsupported => _t('Unsupported device', '设备不支持'),
    SnowLumaDeploymentPhase.linuxUnavailable => _t(
      'Ubuntu not ready',
      'Ubuntu 未就绪',
    ),
  };

  String _failure() => switch (_deployment.failure) {
    'node_missing' || 'node_incompatible' => _t(
      'Lite needs Node.js ^24.22.1 or ≥26.12.1. Import the full archive or install a compatible Node.js in Ubuntu.',
      'Lite 版需要 Node.js ^24.22.1 或 ≥26.12.1。请选择完整版，或在 Ubuntu 中安装兼容的 Node.js。',
    ),
    'port_busy' => _t(
      'Port 5099 is in use. Stop the other service or configure its OneBot connection separately.',
      '5099 端口被占用。请先停止占用端口的服务，或单独配置该实例的 OneBot 连接。',
    ),
    'integrity' || 'archive_invalid' => _t(
      'Could not verify or extract this archive. Pick the original release file again.',
      '无法校验或解压此文件，请重新选择原始发行包。',
    ),
    'helper_unavailable' => _t(
      'Could not prepare the extractor. Ubuntu may need a network connection to install Python.',
      '无法准备解压组件。Ubuntu 可能需要联网安装 Python。',
    ),
    'start_timeout' || 'start_failed' || 'runtime_exited' => _t(
      'The management page did not become ready. Try starting again or run SnowLuma on a separate computer.',
      '管理页未能就绪。请重试启动，或改在独立电脑上运行 SnowLuma。',
    ),
    'stop_failed' => _t(
      'Could not stop SnowLuma. Refresh status and try again.',
      '未能停止 SnowLuma，请刷新状态后重试。',
    ),
    _ => _t('Refresh status and try again.', '请刷新状态后重试。'),
  };

  Widget _runtimeCard(KitTokens tokens, SnowLumaDeploymentPhase phase) {
    final installed = _deployment.installedRelease;
    final running = phase == SnowLumaDeploymentPhase.running;
    final canStart =
        installed != null &&
        (phase == SnowLumaDeploymentPhase.stopped ||
            phase == SnowLumaDeploymentPhase.failed);
    return KitSurface.panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const KitSurface.tile(
                AppIconography.terminal,
                tone: KitTextTone.accent,
              ),
              SizedBox(width: tokens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const KitText('SnowLuma', role: KitTextRole.headline),
                    KitText(
                      installed == null
                          ? _t('Built-in Ubuntu · ARM64', '内置 Ubuntu · ARM64')
                          : 'v2.4.2 · ${installed == SnowLumaArm64Release.full ? _t('Full', '完整版') : 'Lite'}',
                      role: KitTextRole.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.space3),
          Wrap(
            spacing: tokens.space2,
            runSpacing: tokens.space1,
            children: [
              KitStatusTag(
                key: const ValueKey('snowluma-status'),
                label: _status(phase),
                tone: running
                    ? KitStatusTagTone.done
                    : _deployment.busy
                    ? KitStatusTagTone.running
                    : phase == SnowLumaDeploymentPhase.failed
                    ? KitStatusTagTone.needsYou
                    : KitStatusTagTone.failed,
              ),
              KitStatusTag(
                label: _t('Experimental', '实验性'),
                tone: KitStatusTagTone.failed,
              ),
            ],
          ),
          SizedBox(height: tokens.space2),
          KitText(switch (phase) {
            SnowLumaDeploymentPhase.running => _t(
              'The management page runs on this phone. QQ sign-in and OneBot setup are separate.',
              '管理页仅在本机运行，QQ 登录和 OneBot 配置仍需单独完成。',
            ),
            SnowLumaDeploymentPhase.linuxUnavailable => _t(
              'Finish setup under This phone → Linux, then refresh here.',
              '请先在「此手机 → Linux」完成 Ubuntu 安装，再回到这里刷新。',
            ),
            SnowLumaDeploymentPhase.unsupported => _t(
              'Local import requires Android ARM64 with built-in Ubuntu.',
              '本机导入需要 Android ARM64 和内置 Ubuntu。',
            ),
            SnowLumaDeploymentPhase.stopped => _t(
              'Files and account settings are kept.',
              '文件和账号配置已保留。',
            ),
            SnowLumaDeploymentPhase.failed => _failure(),
            _ => _t(
              'Import an existing release to run SnowLuma on this phone.',
              '导入已有发行包，在这台手机上运行 SnowLuma。',
            ),
          }, role: KitTextRole.secondary),
          if (running || canStart) ...[
            SizedBox(height: tokens.space3),
            KitButton.primary(
              key: ValueKey(running ? 'snowluma-open-webui' : 'snowluma-start'),
              label: running
                  ? _t('Open management page', '打开管理页')
                  : _t('Start SnowLuma', '启动 SnowLuma'),
              icon: running ? AppIconography.externalLink : AppIconography.play,
              onPressed: _busy
                  ? null
                  : () => unawaited(
                      running ? _openConsole() : _deployment.start(),
                    ),
            ),
          ],
          if (running)
            KitButton.tertiary(
              key: const ValueKey('snowluma-stop'),
              label: _t('Stop service', '停止服务'),
              icon: AppIconography.stop,
              onPressed: _busy ? null : () => unawaited(_deployment.stop()),
            ),
        ],
      ),
    );
  }

  Widget _archiveCard(KitTokens tokens) {
    final verified = _verified;
    return KitSurface.panel(
      title: _t('Release archive', '发行包'),
      icon: AppIconography.archive,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KitText(
            _t(
              'Choose the v2.4.2 Linux ARM64 .tar.gz you downloaded. The full edition includes Node.js. The app does not download the archive.',
              '选择你已下载的 v2.4.2 Linux ARM64 .tar.gz。推荐自带 Node.js 的完整版，App 不会替你下载。',
            ),
            role: KitTextRole.secondary,
          ),
          SizedBox(height: tokens.space3),
          if (verified == null)
            KitButton.primary(
              key: const ValueKey('snowluma-verify-archive'),
              label: _t('Choose release file', '选择发行包'),
              icon: AppIconography.folderOpen,
              working: _verifying,
              onPressed: _deployment.busy ? null : () => unawaited(_verify()),
            )
          else ...[
            KitNotice(
              tone: AppStatusTone.ok,
              message: _t(
                '${verified.filename} passed SHA-256 verification.',
                '${verified.filename} 已通过 SHA-256 校验。',
              ),
            ),
            SizedBox(height: tokens.space2),
            KitButton.primary(
              key: const ValueKey('snowluma-import-start'),
              label: _t('Import and start', '导入并启动'),
              icon: AppIconography.play,
              onPressed: _busy ? null : () => unawaited(_importAndStart()),
            ),
            KitButton.secondary(
              key: const ValueKey('snowluma-verify-archive'),
              label: _t('Choose a different file', '重新选择文件'),
              working: _verifying,
              expand: false,
              onPressed: _deployment.busy ? null : () => unawaited(_verify()),
            ),
          ],
          if (_archiveError != null && !_verifying) ...[
            SizedBox(height: tokens.space2),
            KitNotice(
              tone: AppStatusTone.failure,
              message: _archiveError == 'read'
                  ? _t('Could not read the selected file.', '无法读取所选文件。')
                  : _t(
                      'This file does not match a supported release. Choose the original ARM64 .tar.gz, not Source code.',
                      '文件与支持的发行包不匹配。请选择原始 ARM64 .tar.gz，不要选源码压缩包。',
                    ),
            ),
          ],
          KitButton.fromAction(
            KitAction.copy(
              label: _t('Copy release page link', '复制发行页链接'),
              text: () => SnowLumaArm64Release.page,
            ),
            role: KitButtonRole.tertiary,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _deployment,
    builder: (context, _) {
      final tokens = KitTokens.of(context);
      final phase = _deployment.phase;
      final canImport =
          !_deployment.busy &&
          (phase == SnowLumaDeploymentPhase.notInstalled ||
              phase == SnowLumaDeploymentPhase.stopped ||
              phase == SnowLumaDeploymentPhase.failed);
      final archive = canImport ? _archiveCard(tokens) : null;
      return KitScreen(
        topBar: KitTopBar(
          title: _t('Local SnowLuma', '本机 SnowLuma'),
          actions: [
            KitAction(
              key: const ValueKey('snowluma-refresh'),
              label: _t('Refresh status', '刷新状态'),
              icon: AppIconography.retry,
              onPressed: _busy ? null : () => unawaited(_deployment.refresh()),
            ),
          ],
        ),
        width: KitScreenWidth.reading,
        loading: _deployment.busy,
        loadingLabel: _status(phase),
        body: ListView(
          padding: KitScreen.padding(context),
          children: [
            _runtimeCard(tokens, phase),
            if (phase == SnowLumaDeploymentPhase.running &&
                !_deployment.busy) ...[
              SizedBox(height: tokens.space3),
              _SnowLumaAccessControls(
                key: ValueKey(_accessRevision),
                deployment: _deployment,
                onRestart: () => unawaited(_restartForToken()),
              ),
            ],
            if (archive != null) ...[
              SizedBox(height: tokens.space3),
              if (phase == SnowLumaDeploymentPhase.stopped)
                KitDetailsFold(
                  label: _t('Replace release archive', '更换发行包'),
                  child: archive,
                )
              else
                archive,
            ],
            SizedBox(height: tokens.space4),
            KitSurface.panel(
              title: _t('Upstream and usage policy', '上游与使用政策'),
              icon: AppIconography.info,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KitText(
                    _t(
                      'The SnowLuma authors have made the official upstream repository private. This module’s developers cannot confirm that this integration complies with the upstream usage policy. If it violates the policy, please open an issue in the OpenCode Plus repository. We’ll address it as soon as possible.',
                      'SnowLuma 作者已将官方上游仓库转为私有。本模块开发者无法确认这种接入方式是否符合上游使用政策。如有违反，请在 OpenCode Plus 仓库提交议题，我们会尽快处理。',
                    ),
                    role: KitTextRole.secondary,
                  ),
                  SizedBox(height: tokens.space2),
                  KitButton.tertiary(
                    key: const ValueKey('snowluma-policy-issues'),
                    label: _t('Open repository issues', '前往仓库议题'),
                    icon: AppIconography.externalLink,
                    onPressed: () => unawaited(_openIssues()),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// No secret goes into a widget or URL. Copy rechecks the current run and
/// password state, even if the button has been visible since before rotation.
class _SnowLumaAccessControls extends StatefulWidget {
  const _SnowLumaAccessControls({
    super.key,
    required this.deployment,
    this.onRestart,
    this.compact = false,
  });

  final SnowLumaDeployment deployment;
  final VoidCallback? onRestart;
  final bool compact;

  @override
  State<_SnowLumaAccessControls> createState() =>
      _SnowLumaAccessControlsState();
}

class _SnowLumaAccessControlsState extends State<_SnowLumaAccessControls> {
  late Future<SnowLumaWebUiAccess> _access = widget.deployment.webUiAccess();
  bool _copying = false;
  bool _copied = false;
  bool _copyFailed = false;

  String _t(String en, String zh) => _text(context, en, zh);

  void _refresh() => setState(() {
    _copied = false;
    _copyFailed = false;
    _access = widget.deployment.webUiAccess();
  });

  Future<void> _copy() async {
    if (_copying) return;
    setState(() {
      _copying = true;
      _copyFailed = false;
    });
    try {
      final token = await widget.deployment.readInitialWebUiToken();
      if (!mounted) return;
      if (token == null) {
        _refresh();
        return;
      }
      await KitCopy.copy(context, token, redact: false);
      if (mounted) setState(() => _copied = true);
    } on Object {
      if (mounted) setState(() => _copyFailed = true);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _access,
    builder: (context, snapshot) {
      final tokens = KitTokens.of(context);
      final state = snapshot.connectionState == ConnectionState.done
          ? snapshot.data ?? SnowLumaWebUiAccess.unavailable
          : null;
      if (widget.compact && state == SnowLumaWebUiAccess.ownPassword) {
        return const SizedBox.shrink();
      }
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state == SnowLumaWebUiAccess.initialToken)
            KitButton.secondary(
              key: const ValueKey('snowluma-copy-webui-token'),
              label: _copied
                  ? _t('Copied · paste into WebUI', '已复制 · 到管理页粘贴')
                  : _t('Copy initial access token', '复制初始访问令牌'),
              icon: _copied ? AppIconography.check : AppIconography.copy,
              working: _copying,
              onPressed: () => unawaited(_copy()),
            ),
          KitText(switch (state) {
            null => _t('Checking access token…', '正在检查访问令牌…'),
            SnowLumaWebUiAccess.initialToken =>
              widget.compact
                  ? _t(
                      'Paste into the login field below and change the password when prompted.',
                      '粘贴到下方登录框，然后按提示修改密码。',
                    )
                  : _t(
                      'Use it to sign into the management page and then change the password. It is not the OneBot token.',
                      '用于首次登录管理页，随后需修改密码。它不是 OneBot Token。',
                    ),
            SnowLumaWebUiAccess.ownPassword => _t(
              'Use the management password you set in SnowLuma.',
              '请使用你在 SnowLuma 中设置的管理密码。',
            ),
            SnowLumaWebUiAccess.restartRequired => _t(
              'The initial token was not captured for this run. Restart from Local SnowLuma to issue a new one.',
              '本次启动未保留初始令牌。回到「本机 SnowLuma」重启即可生成新令牌，无需重新导入。',
            ),
            SnowLumaWebUiAccess.unavailable => _t(
              'Could not read local access status. Refresh it or check that SnowLuma is running.',
              '无法读取访问令牌状态，请刷新或确认 SnowLuma 仍在运行。',
            ),
          }, role: KitTextRole.caption),
          if (_copyFailed)
            KitGroupNote(
              message: _t(
                'Could not copy the token. Try again.',
                '无法复制令牌，请重试。',
              ),
            ),
          if (state == SnowLumaWebUiAccess.restartRequired &&
              widget.onRestart != null) ...[
            SizedBox(height: tokens.space2),
            KitButton.secondary(
              key: const ValueKey('snowluma-restart-token'),
              label: _t('Restart for a new token', '重启获取令牌'),
              icon: AppIconography.retry,
              onPressed: widget.onRestart,
            ),
          ],
          if (state == SnowLumaWebUiAccess.unavailable)
            KitButton.tertiary(
              label: _t('Check again', '重新检查'),
              onPressed: _refresh,
            ),
        ],
      );
      return widget.compact
          ? Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.gutter,
                vertical: tokens.space1,
              ),
              child: content,
            )
          : KitSurface.panel(
              title: _t('Management page access', '管理页访问令牌'),
              icon: AppIconography.locked,
              child: content,
            );
    },
  );
}

/// The third-party WebUI stays on the same loopback origin. OpenCode Plus
/// neither modifies its page nor submits credentials or agreements for you.
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
    final supported = KitWebPreview.platformSupported();
    String t(String en, String zh) => _text(context, en, zh);
    return ListenableBuilder(
      listenable: _web,
      builder: (context, _) => KitScreen(
        topBar: KitTopBar(
          title: t('SnowLuma WebUI', 'SnowLuma 管理页'),
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
          _SnowLumaAccessControls(deployment: widget.deployment, compact: true),
          if (_blockedLink)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: KitTokens.of(context).gutter,
              ),
              child: KitGroupNote(
                message: t(
                  'External links stay closed in this local page.',
                  '本机管理页不打开外部链接。',
                ),
              ),
            ),
          const KitDivider(),
        ],
        body: KitWebPreview(
          origin: widget.deployment.webUiUri,
          controller: _web,
          strictOrigin: true,
          unsupportedBody: t(
            'This device cannot display the local management page.',
            '当前设备无法显示内置管理页。',
          ),
          failureBody: t(
            'The page is not responding. Go back and refresh SnowLuma status.',
            '管理页无法连接，请返回刷新 SnowLuma 状态。',
          ),
          onLeave: (_) {
            if (mounted && !_blockedLink) setState(() => _blockedLink = true);
          },
        ),
      ),
    );
  }
}
