import 'dart:async';

import 'package:flutter/material.dart';

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
  late final TelegramBotBridge _bridge = widget.controller.telegramBot;
  bool _enabled = false;
  bool _replacingToken = false;
  bool _busy = false;
  bool _chatEdited = false;
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
      _chatEdited = false;
      _enabled = snapshot.enabled;
    }
    if (!_chatEdited && _chatID.text != snapshot.chatID) {
      _chatID.text = snapshot.chatID;
    }
  }

  @override
  void dispose() {
    _bridge.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _token.dispose();
    _chatID.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      if (_enabled) {
        await _bridge.saveConfiguration(
          token: _token.text,
          chatID: _chatID.text,
          enabled: false,
        );
        _enabled = false;
        await _bridge.testConnection(chatID: _chatID.text);
        await _bridge.saveConfiguration(chatID: _chatID.text, enabled: true);
        _enabled = true;
      } else {
        await _bridge.saveConfiguration(
          token: _token.text,
          chatID: _chatID.text,
          enabled: false,
        );
      }
      _token.clear();
      _replacingToken = false;
      _chatEdited = false;
      _notice = _text('Settings saved.', '设置已保存。');
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
      await _bridge.testConnection(
        replacementToken: _token.text,
        chatID: _chatID.text,
      );
      _notice = _text(
        'Bot token verified. Enable the relay, then open the bot chat and send /start.',
        'Bot Token 验证成功。启用转发后，请打开机器人私聊并发送 /start。',
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
      _token.clear();
      _chatID.clear();
      _enabled = false;
      _replacingToken = false;
      _chatEdited = false;
      _notice = _text('Telegram bot configuration removed.', 'Telegram 机器人配置已删除。');
    } on Object {
      _error = _text('Could not remove Telegram settings.', '无法删除 Telegram 设置。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _phaseText(TelegramBotPhase phase) => switch (phase) {
    TelegramBotPhase.disabled => _text('Off', '已关闭'),
    TelegramBotPhase.needsSetup => _text('Waiting for local OpenCode', '等待本机 OpenCode'),
    TelegramBotPhase.starting => _text('Connecting to Telegram…', '正在连接 Telegram…'),
    TelegramBotPhase.polling => _text('Listening for Telegram messages', '正在接收 Telegram 消息'),
    TelegramBotPhase.error => _text('Connection problem; retrying', '连接异常，正在重试'),
  };

  @override
  Widget build(BuildContext context) {
    final snapshot = _bridge.snapshot;
    final localServer = looksLikeInAppServer(widget.controller.profile);
    final tokens = KitTokens.of(context);
    final phaseTone = switch (snapshot.phase) {
      TelegramBotPhase.polling => KitTextTone.success,
      TelegramBotPhase.error => KitTextTone.attention,
      TelegramBotPhase.starting => KitTextTone.accent,
      TelegramBotPhase.disabled || TelegramBotPhase.needsSetup => KitTextTone.secondary,
    };

    return KitScreen(
      topBar: KitTopBar(
        title: _text('Telegram bot', 'Telegram 机器人'),
      ),
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
            _text('Status: ${_phaseText(snapshot.phase)}', '状态：${_phaseText(snapshot.phase)}'),
            role: KitTextRole.secondary,
            tone: phaseTone,
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
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving settings', '正在保存设置') : null,
            helper: _text(
              'Create a bot with @BotFather. The token is stored in secure storage and is never shown again.',
              '通过 @BotFather 创建机器人。Token 保存在安全存储中，保存后不会再次显示。',
            ),
          ),
          SizedBox(height: tokens.space3),
          KitField(
            key: const ValueKey('telegram-bot-user-id'),
            label: _text('Allowed Telegram user ID', '允许的 Telegram 用户 ID'),
            kind: KitFieldKind.number,
            controller: _chatID,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving settings', '正在保存设置') : null,
            hint: _text('For example: 123456789', '例如：123456789'),
            helper: _text(
              'Find your numeric ID with @userinfobot. Only this private chat can send instructions or receive updates.',
              '可通过 @userinfobot 查询数字 ID。只有该账号的私聊可以发送指令或接收进度。',
            ),
            onChanged: (_) => _chatEdited = true,
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
            onChanged: _busy ? null : (value) => setState(() => _enabled = value),
          ),
          if (snapshot.sessionID != null) ...[
            SizedBox(height: tokens.space2),
            KitText(
              _text('Bound to an OpenCode conversation.', '已绑定到一个 OpenCode 会话。'),
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
