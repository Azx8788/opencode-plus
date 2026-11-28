import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../builtin/builtin_linux.dart';
import '../../../channels/providers/snowluma_local_probe.dart';
import '../../../channels/providers/snowluma_release.dart';
import '../../../platform/platform_capabilities.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/kit.dart';

/// Guides personal QQ setup without installing or controlling the protocol host.
class SnowLumaSetupScreen extends StatefulWidget {
  const SnowLumaSetupScreen({
    super.key,
    this.localProbe,
    this.linuxStatus,
    this.pickArchive = _pickArchive,
  });

  final Future<SnowLumaLocalAvailability> Function()? localProbe;
  final Future<BuiltinLinuxStatus> Function()? linuxStatus;
  final Future<SnowLumaArchive?> Function() pickArchive;

  @override
  State<SnowLumaSetupScreen> createState() => _SnowLumaSetupScreenState();
}

typedef SnowLumaArchive = ({
  Future<int> Function() length,
  Stream<List<int>> Function() read,
});

Future<SnowLumaArchive?> _pickArchive() async {
  final file = await FilePicker.pickFile();
  if (file == null) return null;
  return (length: file.length, read: file.readAsByteStream);
}

class _SnowLumaSetupScreenState extends State<SnowLumaSetupScreen> {
  SnowLumaLocalAvailability? _local;
  BuiltinLinuxStatus? _ubuntu;
  bool _checking = false;
  bool _verifying = false;
  SnowLumaArm64Release? _verified;
  bool _archiveMismatch = false;
  bool _readFailed = false;

  String _text(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  Future<void> _verifyArchive() async {
    if (_verifying) return;
    setState(() => _verifying = true);
    try {
      final archive = await widget.pickArchive();
      if (!mounted || archive == null) return;
      final release = await SnowLumaArm64Release.verify(
        length: await archive.length(),
        read: archive.read,
      );
      if (!mounted) return;
      _verified = release;
      _archiveMismatch = release == null;
      _readFailed = false;
    } on Object {
      _verified = null;
      _archiveMismatch = false;
      _readFailed = true;
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final local = _local;
    final verified = _verified;
    return KitScreen(
      topBar: KitTopBar(title: _text('Set up SnowLuma', '配置 SnowLuma')),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text('1. Run SnowLuma and sign in to QQ', '1. 运行 SnowLuma 并登录 QQ'),
            role: KitTextRole.headline,
          ),
          KitText(
            _text(
              'Manually download the release for your host from TomyJan/SnowLuma, not “Source code”. Extract it and run the included launcher yourself. Sign in with desktop QQ and finish setup in SnowLuma’s WebUI (port 5099 by default). No LuckyLillia account is needed.',
              '从 TomyJan/SnowLuma 手动下载适合主机的发行包，不要选「Source code」。请自行解压并运行包内启动器，登录桌面 QQ，再到 SnowLuma WebUI（默认 5099）完成接入。不需要 LuckyLillia 账号。',
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
                'Optional: check the downloaded v2.4.2 Linux ARM64 archive (full or lite) against its published SHA-256. This reads the file locally and does not extract or run it. Lite needs a compatible Node.js runtime.',
                '可选：对下载好的 v2.4.2 Linux ARM64 发行包（完整版或 Lite）做 SHA-256 校验。文件仅在本机读取，不解压、不执行。Lite 需要兼容的 Node.js。',
              ),
              role: KitTextRole.caption,
            ),
            KitButton.secondary(
              key: const ValueKey('snowluma-verify-archive'),
              label: _text(
                'Verify downloaded ARM64 archive',
                '校验已下载的 ARM64 发行包',
              ),
              onPressed: _verifying ? null : () => unawaited(_verifyArchive()),
              working: _verifying,
            ),
            if (!_verifying && verified != null)
              KitNotice(
                tone: AppStatusTone.ok,
                message: _text(
                  '${verified.filename} matches the published SHA-256. The app has not installed it.',
                  '${verified.filename} 与发布页的 SHA-256 一致。App 未进行安装。',
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
                'Android Ubuntu is experimental for SnowLuma. This checks Ubuntu and the default loopback ports only; it does not install SnowLuma or verify QQ sign-in.',
                'SnowLuma 在安卓 Ubuntu 中的运行仍属实验。这里仅检查 Ubuntu 和默认回环端口，不安装 SnowLuma，也不代表 QQ 登录成功。',
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
              'SnowLuma is independent of Tencent. Review its license and account risk before running it. OpenCode Plus does not bundle or install it.',
              'SnowLuma 不是腾讯官方服务，运行前请查看其许可和账号风险。OpenCode Plus 不捆绑或安装它。',
            ),
          ),
        ],
      ),
    );
  }
}
