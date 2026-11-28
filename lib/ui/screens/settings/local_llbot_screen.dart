import 'dart:async';

import 'package:flutter/material.dart';

import '../../../builtin/llbot_deployment.dart';
import '../../../l10n/app_localizations.dart';
import '../../app_iconography.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/kit.dart';

/// Manages LLBot in the app's Ubuntu. The shared controller owns the work;
/// leaving this route only detaches its UI, never stops an installation.
class LocalLlbotScreen extends StatefulWidget {
  const LocalLlbotScreen({
    super.key,
    this.deployment,
    this.returnConnection = false,
  });

  final LlbotDeployment? deployment;

  /// Only the QQ form consumes a draft connection. Other entry points manage
  /// the service without returning credentials through an unrelated route.
  final bool returnConnection;

  @override
  State<LocalLlbotScreen> createState() => _LocalLlbotScreenState();
}

enum _LlbotAction { refresh, deploy, start, stop }

class _LocalLlbotScreenState extends State<LocalLlbotScreen> {
  late final LlbotDeployment _deployment =
      widget.deployment ?? LlbotDeployment.shared;
  LlbotLocalConnection? _connection;
  _LlbotAction? _lastAction;
  LlbotDeploymentPhase? _lastPhase;
  bool _pending = false;
  bool _actionFailed = false;
  bool _connectionLoading = false;
  bool _connectionFailed = false;
  bool _showPassword = false;
  int _connectionEpoch = 0;

  bool get _busy => _pending || _deployment.busy;
  bool get _installed =>
      _deployment.phase == LlbotDeploymentPhase.running ||
      _deployment.phase == LlbotDeploymentPhase.stopped;
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String en, String zh) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _deployment.addListener(_changed);
    if (!_deployment.busy) unawaited(_run(_LlbotAction.refresh));
  }

  void _changed() {
    if (!mounted) return;
    if (_deployment.phase == LlbotDeploymentPhase.installing &&
        _lastPhase != LlbotDeploymentPhase.installing) {
      _connectionEpoch++;
      _connection = null;
      _connectionFailed = false;
      _showPassword = false;
    }
    _lastPhase = _deployment.phase;
    setState(() {});
    _readConnectionIfReady();
  }

  void _readConnectionIfReady() {
    if (_installed &&
        _connection == null &&
        !_connectionLoading &&
        !_connectionFailed) {
      unawaited(_readConnection());
    }
  }

  Future<void> _readConnection() async {
    final epoch = _connectionEpoch;
    setState(() {
      _connectionLoading = true;
      _connectionFailed = false;
    });
    try {
      final connection = await _deployment.connection();
      if (mounted && epoch == _connectionEpoch && _installed) {
        KitRedact.registerKnownSecret(connection.webUiPassword);
        KitRedact.registerKnownSecret(connection.accessToken);
        setState(() => _connection = connection);
      }
    } on Object {
      if (mounted && epoch == _connectionEpoch) {
        setState(() => _connectionFailed = true);
      }
    } finally {
      if (mounted) {
        setState(() => _connectionLoading = false);
        if (epoch != _connectionEpoch) _readConnectionIfReady();
      }
    }
  }

  Future<void> _run(_LlbotAction action) async {
    if (_busy) return;
    setState(() {
      _pending = true;
      _actionFailed = false;
      _lastAction = action;
      if (action == _LlbotAction.refresh) {
        _connectionEpoch++;
        _connection = null;
        _connectionFailed = false;
        _showPassword = false;
      }
    });
    try {
      await switch (action) {
        _LlbotAction.refresh => _deployment.refresh(),
        _LlbotAction.deploy => _deployment.deploy(),
        _LlbotAction.start => _deployment.start(),
        _LlbotAction.stop => _deployment.stop(),
      };
    } on Object {
      // Never expose a process error or credentials in an exception message.
      if (mounted) setState(() => _actionFailed = true);
    } finally {
      if (mounted) {
        setState(() => _pending = false);
        _readConnectionIfReady();
      }
    }
  }

  _LlbotAction get _retryAction => switch (_deployment.failure) {
    'start_failed' ||
    'start_timeout' ||
    'runtime_exited' ||
    'listener_refused' ||
    'port_busy' => _LlbotAction.start,
    'stop_failed' => _LlbotAction.stop,
    'status_failed' || 'linux_unavailable' => _LlbotAction.refresh,
    'download_failed' ||
    'download_timeout' ||
    'integrity' ||
    'archive_invalid' ||
    'storage' ||
    'credentials' ||
    'not_installed' ||
    'helper_unavailable' ||
    'install_failed' ||
    'install_interrupted' ||
    'install_timeout' => _LlbotAction.deploy,
    _ => _lastAction ?? _LlbotAction.deploy,
  };

  String get _status => switch (_deployment.phase) {
    LlbotDeploymentPhase.checking => _text(
      'Checking Ubuntu and LLBot…',
      '正在检查 Ubuntu 和 LLBot…',
    ),
    LlbotDeploymentPhase.notInstalled => _text('Not installed', '尚未安装'),
    LlbotDeploymentPhase.installing => _text('Deploying LLBot…', '正在部署 LLBot…'),
    LlbotDeploymentPhase.starting => _text(
      'Starting the local console…',
      '正在启动本机管理页…',
    ),
    LlbotDeploymentPhase.running => _text('Local console ready', '本机管理页已就绪'),
    LlbotDeploymentPhase.stopped => _text('Installed · stopped', '已安装 · 已停止'),
    LlbotDeploymentPhase.failed => _text('Operation failed', '操作失败'),
    LlbotDeploymentPhase.unsupported => _text(
      'Local deployment unavailable on this device',
      '此设备不支持本机部署',
    ),
    LlbotDeploymentPhase.linuxUnavailable => _text(
      'Set up built-in Ubuntu first',
      '请先安装内置 Ubuntu',
    ),
  };

  String? get _stage => switch (_deployment.stage) {
    'checking' => _text('Checking the local environment', '检查本机环境'),
    'download' => _text('Downloading LLBot and its runtime', '下载 LLBot 和运行环境'),
    'verify' => _text('Verifying downloaded files', '校验下载文件'),
    'install' => _text('Installing in built-in Ubuntu', '安装到内置 Ubuntu'),
    'configure' => _text(
      'Preparing local addresses and random credentials',
      '配置本机地址和随机凭据',
    ),
    'start' => _text(
      'Starting LLBot and waiting for the console',
      '启动 LLBot，等待管理页就绪',
    ),
    _ => null,
  };

  String get _failure => switch (_deployment.failure) {
    'download_failed' || 'download_timeout' => _text(
      'Download failed. Check the network, then retry.',
      '下载失败，请检查网络后重试。',
    ),
    'integrity' || 'archive_invalid' => _text(
      'Downloaded files could not be verified. Retry the deployment.',
      '下载文件校验失败，请重试部署。',
    ),
    'storage' || 'install_failed' || 'helper_unavailable' => _text(
      'Installation failed. Check available storage and Ubuntu, then retry.',
      '安装失败，请检查可用空间和 Ubuntu 状态后重试。',
    ),
    'credentials' => _text(
      'Local configuration could not be prepared. Retry the deployment.',
      '无法完成本机配置，请重试部署。',
    ),
    'install_interrupted' || 'install_timeout' => _text(
      'Deployment was interrupted or timed out. Keep the app running and retry.',
      '部署中断或超时，请保持 App 运行后重试。',
    ),
    'port_busy' => _text(
      'A local LLBot port is in use. Stop the conflicting service, then retry.',
      '本机 LLBot 端口已被占用，请停止冲突服务后重试。',
    ),
    'listener_refused' => _text(
      'LLBot could not start its local-only listener. Retry starting.',
      'LLBot 未能建立仅限本机的监听，请重试启动。',
    ),
    'start_failed' || 'start_timeout' || 'runtime_exited' => _text(
      'The local console did not become ready. Refresh status or retry starting.',
      '本机管理页未能就绪，请刷新状态或重试启动。',
    ),
    'stop_failed' => _text(
      'LLBot could not be stopped. Refresh status or retry stopping.',
      'LLBot 未能停止，请刷新状态或重试停止。',
    ),
    _ => _text(
      'The operation could not finish. Refresh status or retry.',
      '操作未能完成，请刷新状态或重试。',
    ),
  };

  void _openConsole(LlbotLocalConnection connection) {
    unawaited(
      Navigator.of(context).push<void>(
        KitPageRoute<void>(
          builder: (_) => _LocalLlbotConsoleScreen(
            deployment: _deployment,
            webUiPassword: connection.webUiPassword,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _deployment.removeListener(_changed);
    // LlbotDeployment.shared belongs to the app, not this route.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final phase = _deployment.phase;
    final failed = _actionFailed || phase == LlbotDeploymentPhase.failed;
    final connection = _connection;
    final running = phase == LlbotDeploymentPhase.running;
    return KitScreen(
      topBar: KitTopBar(
        title: _text('Deploy local LLBot', '本机 LLBot 一键部署'),
        actions: [
          KitAction(
            key: const ValueKey('llbot-refresh'),
            label: _text('Refresh status', '刷新状态'),
            icon: AppIconography.retry,
            onPressed: _busy
                ? null
                : () => unawaited(_run(_LlbotAction.refresh)),
            disabledReason: _busy
                ? _text('Operation in progress', '操作进行中')
                : null,
          ),
        ],
      ),
      width: KitScreenWidth.reading,
      loading: _busy,
      loadingLabel: _stage ?? _status,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text(
              'For existing LLBot users with a valid Auth Token. The upstream site has closed new registrations. If you do not have a token, use the SnowLuma setup guide instead.',
              '仅适用于已有有效 Auth Token 的 LLBot 用户。上游已关闭新用户注册；没有 Token 请改用 SnowLuma 配置指南。',
            ),
          ),
          SizedBox(height: tokens.space2),
          KitText(
            _text(
              'LLBot v8.3.2 · Linux ARM64 · Node included. Download ≈89 MB; installed runtime ≈172 MB.',
              'LLBot v8.3.2 · Linux ARM64 · 自带 Node。下载约 89 MB，安装后运行环境约 172 MB。',
            ),
            role: KitTextRole.caption,
          ),
          SizedBox(height: tokens.space3),
          KitText(
            _status,
            key: const ValueKey('llbot-status'),
            role: KitTextRole.headline,
            tone: failed ? KitTextTone.attention : KitTextTone.primary,
          ),
          if (_busy) ...[
            if (_stage != null) KitText(_stage!, role: KitTextRole.secondary),
            KitGroupNote(
              message: _text(
                'You can leave this page and return to see progress. Deployment continues while the app’s environment is running.',
                '可以离开此页后再回来查看进度；App 环境运行期间，部署会继续。',
              ),
            ),
          ],
          if (failed) ...[
            SizedBox(height: tokens.space2),
            KitNotice(
              key: const ValueKey('llbot-failure'),
              message: _failure,
              tone: AppStatusTone.failure,
            ),
          ],
          SizedBox(height: tokens.space3),
          if (failed)
            KitButton.primary(
              key: const ValueKey('llbot-retry'),
              label: _text('Retry', '重试'),
              onPressed: _busy ? null : () => unawaited(_run(_retryAction)),
            )
          else if (phase == LlbotDeploymentPhase.notInstalled ||
              phase == LlbotDeploymentPhase.installing)
            KitButton.primary(
              key: const ValueKey('llbot-deploy'),
              label: _text('Deploy and start', '一键部署并启动'),
              onPressed: _busy
                  ? null
                  : () => unawaited(_run(_LlbotAction.deploy)),
            )
          else if (phase == LlbotDeploymentPhase.stopped ||
              phase == LlbotDeploymentPhase.starting)
            KitButton.primary(
              key: const ValueKey('llbot-start'),
              label: _text('Start LLBot', '启动 LLBot'),
              onPressed: _busy
                  ? null
                  : () => unawaited(_run(_LlbotAction.start)),
            )
          else if (running)
            KitButton.primary(
              key: const ValueKey('llbot-open-console'),
              label: _text('Open WebUI · QQ sign-in', '打开 WebUI · QQ 登录'),
              onPressed: _busy || connection == null
                  ? null
                  : () => _openConsole(connection),
            ),
          if (phase == LlbotDeploymentPhase.unsupported ||
              phase == LlbotDeploymentPhase.linuxUnavailable)
            KitGroupNote(
              message: phase == LlbotDeploymentPhase.linuxUnavailable
                  ? _text(
                      'Complete built-in Ubuntu setup in Settings, then refresh status here.',
                      '请在设置中完成内置 Ubuntu 安装，再回到此页刷新状态。',
                    )
                  : _text(
                      'You can configure a remote LLBot, NapCat or SnowLuma service on the QQ settings page.',
                      '可以返回 QQ 设置页，配置远程 LLBot、NapCat 或 SnowLuma 服务。',
                    ),
            ),
          if (_installed) ...[
            SizedBox(height: tokens.space3),
            KitGroupNote(
              message: _text(
                'Console readiness does not mean QQ is online. Enter your existing LLBot Auth Token in the WebUI, then scan the QQ QR code. The OneBot listener becomes available after QQ sign-in.',
                '管理页就绪不代表 QQ 在线。在 WebUI 中填写已有的 LLBot Auth Token，再扫描 QQ 二维码。QQ 登录后才会启动 OneBot 监听。',
              ),
            ),
            const KitText.mono(
              'https://auth.luckylillia.com',
              selectable: true,
            ),
            KitButton.fromAction(
              KitAction.copy(
                key: const ValueKey('llbot-copy-auth-site'),
                label: _text('Copy LLBot authorisation URL', '复制 LLBot 授权网址'),
                text: () => 'https://auth.luckylillia.com',
              ),
              role: KitButtonRole.tertiary,
            ),
            KitText(
              _text(
                'The upstream Auth Token, local WebUI password and OneBot access token are three different credentials. This app generates only the two local credentials.',
                '上游 Auth Token、本机 WebUI 密码和 OneBot Access Token 是三种不同凭据；App 只生成后两种本机凭据。',
              ),
              role: KitTextRole.caption,
            ),
            if (_connectionLoading)
              KitText(
                _text('Reading local credentials…', '正在读取本机凭据…'),
                role: KitTextRole.secondary,
              ),
            if (_connectionFailed) ...[
              KitNotice(
                message: _text(
                  'Could not read the local connection credentials.',
                  '无法读取本机连接凭据。',
                ),
                tone: AppStatusTone.failure,
              ),
              KitButton.secondary(
                key: const ValueKey('llbot-retry-connection'),
                label: _text('Retry reading credentials', '重试读取凭据'),
                onPressed: _busy ? null : () => unawaited(_readConnection()),
              ),
            ],
            if (connection != null) ...[
              SizedBox(height: tokens.space3),
              KitText(
                _text('WebUI password', 'WebUI 密码'),
                role: KitTextRole.label,
              ),
              KitText(
                _text(
                  'A strong random password was generated for this installation. Use it only in the local WebUI.',
                  '已为本次安装生成高强度随机密码，仅用于登录本机 WebUI。',
                ),
                role: KitTextRole.caption,
              ),
              SizedBox(height: tokens.space2),
              KitText(
                _showPassword ? connection.webUiPassword : '••••••••••••',
                key: const ValueKey('llbot-webui-password'),
                role: KitTextRole.mono,
              ),
              KitButton.tertiary(
                key: const ValueKey('llbot-reveal-password'),
                label: _showPassword
                    ? _text('Hide password', '隐藏密码')
                    : _text('Show password', '显示密码'),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
              KitButton.fromAction(
                KitAction.copy(
                  key: const ValueKey('llbot-copy-password'),
                  label: _text('Copy WebUI password', '复制 WebUI 密码'),
                  text: () => connection.webUiPassword,
                  redact: false,
                ),
                role: KitButtonRole.secondary,
              ),
              SizedBox(height: tokens.space3),
              KitText(connection.webSocketUrl, role: KitTextRole.mono),
              if (widget.returnConnection) ...[
                KitButton.secondary(
                  key: const ValueKey('llbot-use-connection'),
                  label: _text('Use local connection', '使用本机连接'),
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).pop(connection),
                ),
                KitText(
                  _text(
                    'Returns the address and token to the QQ form. Review the account and allowlists, then test, save and enable when ready.',
                    '将地址和 Token 填入 QQ 表单；请确认账号和允许列表，准备好后再测试、保存并启用。',
                  ),
                  role: KitTextRole.caption,
                ),
              ] else
                KitText(
                  _text(
                    'After QQ sign-in, open Settings → Message channels → QQ personal account to use this local connection.',
                    'QQ 登录后，前往「设置 → 消息渠道 → QQ 普通账号」，使用本机连接。',
                  ),
                  role: KitTextRole.caption,
                ),
            ],
            if (running) ...[
              SizedBox(height: tokens.space3),
              KitButton.secondary(
                key: const ValueKey('llbot-stop'),
                label: _text('Stop LLBot', '停止 LLBot'),
                onPressed: _busy
                    ? null
                    : () => unawaited(_run(_LlbotAction.stop)),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// A console is only opened after the managed service reports readiness.
class _LocalLlbotConsoleScreen extends StatefulWidget {
  const _LocalLlbotConsoleScreen({
    required this.deployment,
    required this.webUiPassword,
  });

  final LlbotDeployment deployment;
  final String webUiPassword;

  @override
  State<_LocalLlbotConsoleScreen> createState() =>
      _LocalLlbotConsoleScreenState();
}

class _LocalLlbotConsoleScreenState extends State<_LocalLlbotConsoleScreen> {
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
          title: zh ? '本机 LLBot 管理页' : 'Local LLBot console',
          actions: [
            if (supported)
              KitAction(
                label: l10n.devPreviewReload,
                icon: AppIconography.retry,
                onPressed: () => unawaited(_web.reload()),
              ),
            KitAction.copy(
              key: const ValueKey('llbot-console-copy-password'),
              label: zh ? '复制 WebUI 密码' : 'Copy WebUI password',
              text: () => widget.webUiPassword,
              redact: false,
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
                  ? '使用本机 WebUI 密码登录，然后填写已有的 LLBot Auth Token，再扫码登录 QQ。管理页就绪不代表 QQ 在线。'
                  : 'Log in with the local WebUI password, enter your existing LLBot Auth Token, then scan the QQ QR code. Console readiness does not mean QQ is online.',
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
          origin: widget.deployment.consoleUri,
          controller: _web,
          strictOrigin: true,
          unsupportedBody: zh
              ? '当前设备无法显示内置的 LLBot 管理页。'
              : 'This device cannot display the built-in LLBot console.',
          failureBody: zh
              ? '管理页无法连接，请返回部署页刷新状态，必要时重新启动 LLBot。'
              : 'The console is not responding. Return to deployment, refresh status and restart LLBot if needed.',
          onLeave: (_) {
            if (mounted && !_blockedLink) setState(() => _blockedLink = true);
          },
        ),
      ),
    );
  }
}
