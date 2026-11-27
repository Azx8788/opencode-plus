import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../../state/connection.dart';
import '../../../telegram/telegram_bot.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/kit.dart';

/// Explicit configuration for the local OpenCode ↔ Telegram bridge.
class TelegramBotScreen extends StatefulWidget {
  const TelegramBotScreen({super.key, required this.controller});

  final ConnectionController controller;

  @override
  State<TelegramBotScreen> createState() => _TelegramBotScreenState();
}

class _TelegramBotScreenState extends State<TelegramBotScreen> {
  late final TextEditingController _token = TextEditingController();
  late final TextEditingController _chatID = TextEditingController();
  late final TextEditingController _username = TextEditingController();
  late final TelegramBotBridge _bridge = widget.controller.telegramBot;
  bool _enabled = false;
  bool _replacingToken = false;
  bool _busy = false;
  bool _identityEdited = false;
  bool _enabledEdited = false;
  bool _manual = false;
  String? _loadedProfile;
  String? _notice;
  String? _error;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String en, String zh) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _bridge.addListener(_changed);
    widget.controller.addListener(_changed);
    unawaited(_bridge.initialize());
    _syncSnapshot();
  }

  void _changed() {
    if (!mounted) return;
    _syncSnapshot();
    setState(() {});
  }

  void _syncSnapshot() {
    final snapshot = _bridge.snapshot;
    if (snapshot.profileID != _loadedProfile) {
      _loadedProfile = snapshot.profileID;
      _identityEdited = false;
      _enabledEdited = false;
      _token.clear();
      _notice = null;
      _error = null;
      _replacingToken = false;
    }
    if (!_enabledEdited) _enabled = snapshot.enabled;
    if (!_identityEdited) {
      final chat = snapshot.awaitingBinding
          ? snapshot.expectedUserID
          : snapshot.chatID;
      final name = snapshot.awaitingUsername ?? '';
      if (_chatID.text != chat) _chatID.text = chat;
      if (_username.text != name) _username.text = name;
    }
  }

  @override
  void dispose() {
    _bridge.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _bridge.cancelPairing();
    _token.dispose();
    _chatID.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    if (_busy || _bridge.isPairing) return;
    setState(() {
      _error = null;
      _notice = null;
    });
    try {
      await _bridge.beginPairing(replacementToken: _token.text);
      if (!mounted) return;
      if (_bridge.pairingSucceeded) {
        _token.clear();
        _replacingToken = false;
        _manual = false;
        _enabledEdited = false;
        _identityEdited = false;
        _syncSnapshot();
        _notice = _text('Telegram is paired and enabled.', 'Telegram 已绑定并启用。');
      } else {
        _error = _bridge.pairingError;
      }
    } on FormatException catch (error) {
      _error = error.message;
    } on Object {
      _error = _text('Could not pair Telegram.', '无法绑定 Telegram。');
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _openTelegram(Uri link) async {
    if (_bridge.pairingLink != link) return;
    try {
      // The bridge generated this fixed t.me URL; no token or user-supplied
      // destination is passed to the launcher.
      if (await launchUrl(link, mode: LaunchMode.externalApplication)) return;
    } on Object {
      // The app or browser may be unavailable.
    }
    if (!mounted) return;
    setState(
      () => _error = _text('Could not open Telegram.', '无法打开 Telegram。'),
    );
  }

  Future<void> _save() async {
    if (_busy) return;
    final owner = _bridge.snapshot.profileID;
    if (owner == null || widget.controller.profile?.id != owner) return;
    final enabled = _enabled;
    final token = _token.text;
    final chat = _chatID.text;
    final username = _username.text;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      var notice = _text('Settings saved.', '设置已保存。');
      if (enabled) {
        notice = await _bridge.testConnection(
          replacementToken: token,
          chatID: chat,
          username: username,
        );
      }
      if (!mounted || widget.controller.profile?.id != owner) return;
      await _bridge.saveConfiguration(
        token: token,
        chatID: chat,
        username: username,
        enabled: enabled,
      );
      if (!mounted || widget.controller.profile?.id != owner) return;
      _token.clear();
      _replacingToken = false;
      _enabledEdited = false;
      _identityEdited = false;
      _syncSnapshot();
      _notice = notice;
    } on FormatException catch (error) {
      _error = error.message;
    } on Object {
      _error = _text('Could not save Telegram settings.', '无法保存 Telegram 设置。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      _notice = await _bridge.testConnection(
        replacementToken: _token.text,
        chatID: _chatID.text,
        username: _username.text,
      );
    } on FormatException catch (error) {
      _error = error.message;
    } on Object {
      _error = _text(
        'Telegram test failed. Check the bot token, user ID, and network.',
        'Telegram 测试失败，请检查 Bot Token、用户 ID 和网络。',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _bridge.clearConfiguration();
      if (!mounted) return;
      _token.clear();
      _chatID.clear();
      _username.clear();
      _enabled = false;
      _replacingToken = false;
      _identityEdited = false;
      _enabledEdited = false;
      _notice = _text(
        'Telegram bot configuration removed.',
        'Telegram 机器人配置已删除。',
      );
    } on Object {
      _error = _text(
        'Could not remove Telegram settings.',
        '无法删除 Telegram 设置。',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _phaseText(TelegramBotPhase phase) => switch (phase) {
    TelegramBotPhase.disabled => _text('Off', '已关闭'),
    TelegramBotPhase.needsSetup => _text(
      'Waiting for local OpenCode',
      '等待本机 OpenCode',
    ),
    TelegramBotPhase.starting => _text(
      'Connecting to Telegram…',
      '正在连接 Telegram…',
    ),
    TelegramBotPhase.polling => _text(
      'Listening for Telegram messages',
      '正在接收 Telegram 消息',
    ),
    TelegramBotPhase.error => _text(
      'Connection problem; retrying',
      '连接异常，正在重试',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final snapshot = _bridge.snapshot;
    final pairing = _bridge.isPairing;
    final link = _bridge.pairingLink;
    final busy = _busy || pairing;
    final localServer = looksLikeInAppServer(widget.controller.profile);
    final tokens = KitTokens.of(context);
    final phaseTone = switch (snapshot.phase) {
      TelegramBotPhase.polling => KitTextTone.success,
      TelegramBotPhase.error => KitTextTone.attention,
      TelegramBotPhase.starting => KitTextTone.accent,
      TelegramBotPhase.disabled ||
      TelegramBotPhase.needsSetup => KitTextTone.secondary,
    };

    return KitScreen(
      topBar: KitTopBar(title: _text('Telegram bot', 'Telegram 机器人')),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text(
              'Relay messages between Telegram and the OpenCode server installed on this phone. Telegram instructions are ordinary agent prompts. Agent replies and brief progress notices are sent back to your private Telegram chat.',
              '在 Telegram 与本机 OpenCode 服务器之间转发消息。Telegram 指令会作为普通 Agent 提示词发送；Agent 回复和简要进度会回传到你的 Telegram 私聊。',
            ),
            role: KitTextRole.body,
          ),
          SizedBox(height: tokens.space3),
          KitText(
            _text(
              'Status: ${_phaseText(snapshot.phase)}',
              '状态：${_phaseText(snapshot.phase)}',
            ),
            role: KitTextRole.secondary,
            tone: phaseTone,
          ),
          if (snapshot.phase == TelegramBotPhase.error &&
              snapshot.lastError != null) ...[
            SizedBox(height: tokens.space2),
            KitText(
              snapshot.lastError!,
              role: KitTextRole.caption,
              tone: KitTextTone.attention,
            ),
          ],
          if (snapshot.awaitingUsername case final name? when snapshot.enabled)
            KitNotice(
              message: _text(
                'Waiting for @$name. Send /start from that account in a private chat with the bot.',
                '正在等待 @$name。请用该账号在机器人私聊中发送 /start。',
              ),
            ),
          if (!localServer) ...[
            SizedBox(height: tokens.space3),
            KitGroupNote(
              message: _text(
                'Select and connect to the OpenCode server hosted by this phone to use the Telegram bridge.',
                '请先选择并连接此手机内置的 OpenCode 服务器。',
              ),
            ),
          ],
          SizedBox(height: tokens.space5),
          KitField.secret(
            key: const ValueKey('telegram-bot-token'),
            label: _text('Bot token', 'Bot Token'),
            controller: _token,
            saved: snapshot.hasToken && !_replacingToken,
            onReplace: () => setState(() => _replacingToken = true),
            enabled: !busy,
            disabledReason: busy ? _text('Setup in progress', '正在配置') : null,
            helper: _text(
              'Create a bot with @BotFather. The token is stored in secure storage and is never shown again.',
              '通过 @BotFather 创建机器人。Token 保存在安全存储中，保存后不会再次显示。',
            ),
          ),
          SizedBox(height: tokens.space3),
          if ((!snapshot.enabled && !(_manual && !snapshot.configured)) ||
              pairing) ...[
            if (link != null) ...[
              KitGroupNote(
                message: _text(
                  'In Telegram, tap Start if prompted, then come back here. This link expires in 3 minutes. Do not share it.',
                  '如 Telegram 显示「开始」，点一下再返回 App。链接 3 分钟内有效，请勿分享。',
                ),
              ),
              KitButton.primary(
                key: const ValueKey('telegram-bot-open-pairing'),
                label: _text('Open Telegram', '打开 Telegram'),
                onPressed: () => _openTelegram(link),
              ),
            ] else if (!snapshot.configured || pairing)
              KitButton.primary(
                key: const ValueKey('telegram-bot-pair'),
                label: _text('Pair automatically', '自动绑定'),
                onPressed: busy || !localServer ? null : _pair,
                working: pairing,
              )
            else
              KitButton.secondary(
                key: const ValueKey('telegram-bot-pair'),
                label: _text('Pair automatically', '自动绑定'),
                onPressed: busy || !localServer ? null : _pair,
              ),
            if (pairing)
              KitButton.secondary(
                label: _text('Cancel pairing', '取消绑定'),
                onPressed: _bridge.isSavingPairing
                    ? null
                    : _bridge.cancelPairing,
              ),
            SizedBox(height: tokens.space2),
          ],
          if (!snapshot.configured && !pairing)
            KitButton.tertiary(
              key: const ValueKey('telegram-bot-manual'),
              label: _manual
                  ? _text('Hide manual setup', '收起手动配置')
                  : _text('Bind by username or numeric ID', '用用户名或数字 ID 绑定'),
              onPressed: _busy
                  ? null
                  : () => setState(() => _manual = !_manual),
            ),
          if (!pairing && (_manual || snapshot.configured)) ...[
            KitField(
              key: const ValueKey('telegram-bot-username'),
              label: _text(
                'Your Telegram username (optional)',
                '你的 Telegram 用户名（可选）',
              ),
              controller: _username,
              enabled: !_busy,
              disabledReason: _busy ? _text('Saving settings', '正在保存设置') : null,
              hint: '@your_username',
              helper: _text(
                'Use your own @username, not the bot’s. A matching private message binds your numeric ID. Changing the username here starts a new binding.',
                '请填写你自己的 @username，而非机器人的。首次匹配的私聊会绑定数字 ID；在这里填写新用户名会重新绑定。',
              ),
              onChanged: (_) => _identityEdited = true,
            ),
            SizedBox(height: tokens.space2),
            KitField(
              key: const ValueKey('telegram-bot-user-id'),
              label: _text('Allowed Telegram user ID', '允许的 Telegram 用户 ID'),
              kind: KitFieldKind.number,
              controller: _chatID,
              enabled: !_busy,
              disabledReason: _busy ? _text('Saving settings', '正在保存设置') : null,
              hint: _text('For example: 123456789', '例如：123456789'),
              helper: _text(
                'With a username, the ID is optional and both must match if entered. Without a username, the ID is required.',
                '使用用户名时，数字 ID 可选；同时填写时必须都匹配。不填用户名时必须填写数字 ID。',
              ),
              onChanged: (_) => _identityEdited = true,
            ),
            SizedBox(height: tokens.space3),
            KitSwitchRow(
              key: const ValueKey('telegram-bot-enabled'),
              title: _text('Enable Telegram relay', '启用 Telegram 双向转发'),
              supporting: _text(
                'Save to start long polling. The token cannot be used by another poller or webhook at the same time. Keep this app process alive for background messages.',
                '保存后开始长轮询；Bot Token 不能同时用于其他轮询程序或 Webhook。后台接收需要保持 App 进程运行。',
              ),
              value: _enabled,
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _enabledEdited = true;
                      _enabled = value;
                    }),
            ),
            if (snapshot.sessionID != null) ...[
              SizedBox(height: tokens.space2),
              KitText(
                _text(
                  'Bound to an OpenCode conversation.',
                  '已绑定到一个 OpenCode 会话。',
                ),
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
              ),
            ],
            SizedBox(height: tokens.space3),
            if (_error != null)
              KitNotice(message: _error!, tone: AppStatusTone.failure),
            if (_notice != null)
              KitNotice(message: _notice!, tone: AppStatusTone.ok),
            KitButton.primary(
              key: const ValueKey('telegram-bot-save'),
              label: _enabled
                  ? _text('Save and enable', '保存并启用')
                  : _text('Save settings', '保存设置'),
              onPressed: _busy ? null : _save,
              working: _busy,
            ),
            SizedBox(height: tokens.space2),
            KitButton.secondary(
              key: const ValueKey('telegram-bot-test'),
              label: _text('Verify bot token', '验证 Bot Token'),
              onPressed: _busy ? null : _test,
              working: _busy,
            ),
            if (snapshot.configured) ...[
              SizedBox(height: tokens.space2),
              KitButton.tertiary(
                key: const ValueKey('telegram-bot-remove'),
                label: _text('Remove bot configuration', '删除机器人配置'),
                destructive: true,
                onPressed: _busy ? null : _clear,
              ),
            ],
          ],
          if (pairing && _error != null)
            KitNotice(message: _error!, tone: AppStatusTone.failure),
          if (!pairing && !_manual && !snapshot.configured && _error != null)
            KitNotice(message: _error!, tone: AppStatusTone.failure),
          SizedBox(height: tokens.space4),
          KitGroupNote(
            message: _text(
              'Telegram receives the agent’s final text and brief tool-progress notices. Existing OpenCode permission rules still apply; this bot does not approve requests. Keep the app available in the background for reliable polling. Do not send secrets you do not want transmitted to Telegram.',
              'Telegram 会收到 Agent 的最终文本和简要工具进度。OpenCode 原有权限规则仍然生效，机器人不会代替你批准请求。请允许 App 在后台运行以保持轮询。不要发送不希望传输到 Telegram 的机密内容。',
            ),
          ),
        ],
      ),
    );
  }
}
