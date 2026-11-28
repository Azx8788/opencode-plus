import 'dart:async';

import 'package:flutter/material.dart';

import '../../../builtin/builtin_linux.dart';
import '../../../builtin/snowluma_release.dart';
import '../../../channels/providers/snowluma_local_probe.dart';
import '../../../platform/platform_capabilities.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';

/// Connection instructions only. Import, startup and credentials live in the
/// separate Local SnowLuma module on the Message channels page.
class SnowLumaSetupScreen extends StatefulWidget {
  const SnowLumaSetupScreen({super.key, this.localProbe, this.linuxStatus});

  final Future<SnowLumaLocalAvailability> Function()? localProbe;
  final Future<BuiltinLinuxStatus> Function()? linuxStatus;

  @override
  State<SnowLumaSetupScreen> createState() => _SnowLumaSetupScreenState();
}

class _SnowLumaSetupScreenState extends State<SnowLumaSetupScreen> {
  SnowLumaLocalAvailability? _local;
  BuiltinLinuxStatus? _ubuntu;
  bool _checking = false;

  String _t(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

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
    setState(() => _checking = true);
    try {
      final (local, ubuntu) = await (
        (widget.localProbe ?? const SnowLumaLocalProbe().check)(),
        _checkUbuntu(),
      ).wait;
      if (!mounted) return;
      _local = local;
      _ubuntu = ubuntu;
    } on Object {
      // Do not display raw network or platform diagnostics.
      _local = null;
      _ubuntu = null;
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String _ubuntuStatus() {
    final ubuntu = _ubuntu;
    if (ubuntu == null) {
      return _t('Could not check built-in Ubuntu.', '无法检查内置 Ubuntu。');
    }
    if (!ubuntu.installed || ubuntu.phase != BuiltinLinuxPhase.ready) {
      return _t('Built-in Ubuntu is not ready.', '内置 Ubuntu 尚未就绪。');
    }
    if (!const {'arm64-v8a', 'arm64', 'aarch64'}.contains(ubuntu.abi)) {
      return _t('Built-in Ubuntu is not ARM64.', '内置 Ubuntu 不是 ARM64。');
    }
    return _t('Built-in Ubuntu is ready (ARM64).', '内置 Ubuntu 已就绪（ARM64）。');
  }

  Widget _step(String title, String description, {Widget? action}) =>
      KitSurface.panel(
        title: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KitText(description, role: KitTextRole.secondary),
            ?action,
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final android = platformCapabilities.isAndroid;
    final local = _local;
    return KitScreen(
      topBar: KitTopBar(title: _t('Set up SnowLuma', 'SnowLuma 配置指南')),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _t('Connect QQ through OneBot 11', '通过 OneBot 11 接入 QQ'),
            role: KitTextRole.headline,
          ),
          SizedBox(height: tokens.space3),
          _step(
            _t('1. Run SnowLuma and sign in to QQ', '1. 运行 SnowLuma 并登录 QQ'),
            android
                ? _t(
                    'On this phone, open Message channels → Local SnowLuma to manage the service and find its WebUI token. On a computer, run the release yourself and use the initial password in its startup output. Review the agreements and sign in to desktop QQ yourself.',
                    '本机部署请到「消息渠道 → 本机 SnowLuma」，管理服务和查看令牌。若在电脑上自行运行，请从启动输出取得管理页初始密码。请自行查看协议并登录桌面 QQ。',
                  )
                : _t(
                    'Run the release for your computer, not the Source code archive. Use the initial password from its startup output to open the WebUI. Review the agreements and sign in to desktop QQ yourself.',
                    '在电脑上运行对应平台的发行版（不是源码压缩包），用启动输出中的初始密码进入管理页，自行查看协议并登录桌面 QQ。',
                  ),
            action: KitButton.fromAction(
              KitAction.copy(
                label: _t('Copy release page link', '复制发行页链接'),
                text: () => SnowLumaArm64Release.page,
              ),
              role: KitButtonRole.tertiary,
            ),
          ),
          SizedBox(height: tokens.space2),
          _step(
            _t('2. Set up the OneBot connection', '2. 配置 OneBot 连接'),
            _t(
              'For the signed-in QQ account, enable a OneBot 11 WebSocket server with the Universal role, array message format and its own Access Token. The default OneBot port is 3001; 5099 is only for the management page.',
              '为该 QQ 账号开启 OneBot 11 WebSocket 服务端，选择 Universal（通用）和数组消息格式，并单独设置 Access Token。OneBot 默认端口是 3001，5099 仅用于管理页。',
            ),
          ),
          SizedBox(height: tokens.space2),
          _step(
            _t('3. Test and enable the channel', '3. 测试并启用渠道'),
            _t(
              'Return to the QQ form and fill in the OneBot address and token, not the WebUI password. Test to confirm the QQ number and review the allowlists before enabling and saving.',
              '返回 QQ 表单填写 OneBot 地址和 Token，不要填管理页密码。测试并核对 QQ 号、检查允许列表后，再启用并保存。',
            ),
          ),
          if (android) ...[
            SizedBox(height: tokens.space3),
            KitSurface.panel(
              title: _t('Use a local address', '使用本机地址'),
              icon: AppIconography.link,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KitText(
                    _t(
                      'This only checks the default ports, not QQ sign-in.',
                      '仅检查默认端口，不验证 QQ 登录。',
                    ),
                    role: KitTextRole.caption,
                  ),
                  if (!_checking && local != null) ...[
                    SizedBox(height: tokens.space2),
                    KitText(_ubuntuStatus(), role: KitTextRole.caption),
                    KitText(
                      local.consoleRecognized
                          ? _t(
                              'SnowLuma WebUI detected on port 5099.',
                              '已在 5099 端口识别到 SnowLuma WebUI。',
                            )
                          : _t(
                              'SnowLuma WebUI not detected on port 5099.',
                              '未在 5099 端口识别到 SnowLuma WebUI。',
                            ),
                      role: KitTextRole.caption,
                    ),
                    KitText(
                      local.oneBotPortOpen
                          ? _t(
                              'Port 3001 is reachable. Test OneBot to verify the account.',
                              '3001 端口可达，仍需测试 OneBot 以确认账号。',
                            )
                          : _t(
                              'Port 3001 is not accepting connections.',
                              '3001 端口未接受连接。',
                            ),
                      role: KitTextRole.caption,
                    ),
                  ],
                  SizedBox(height: tokens.space2),
                  if (!_checking && (local?.canSuggestAddress ?? false))
                    KitButton.primary(
                      key: const ValueKey('snowluma-use-local-address'),
                      label: _t('Fill in local address', '填入本机地址'),
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(SnowLumaLocalProbe.defaultWebSocketUrl),
                    )
                  else
                    KitButton.secondary(
                      key: const ValueKey('snowluma-check-local'),
                      label: _t('Check this phone', '检查本机环境'),
                      onPressed: () => unawaited(_check()),
                      working: _checking,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
