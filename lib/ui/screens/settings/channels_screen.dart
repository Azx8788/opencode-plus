import 'dart:async';

import 'package:flutter/material.dart';

import '../../../builtin/builtin_server.dart' show looksLikeInAppServer;
import '../../../channels/channel_capabilities.dart';
import '../../../channels/channel_config.dart';
import '../../../channels/channel_hub.dart';
import '../../../channels/channel_provider.dart';
import '../../../channels/providers/onebot11_provider.dart' show OneBotGroup;
import '../../../state/connection.dart';
import '../../app_iconography.dart';
import '../../../telegram/telegram_bot.dart';
import '../../app_theme.dart' show AppStatusTone;
import '../../kit/kit.dart';
import 'telegram_bot_screen.dart';

/// 消息渠道: the one door to every messaging channel.
///
/// Each row is a channel, its state in one word, and a page that configures it.
/// Telegram keeps its own page because it has its own product behaviour; the
/// two QQ channels are new and share the channel engine.
class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key, required this.controller});

  final ConnectionController controller;

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  late final TelegramBotBridge _telegram = widget.controller.telegramBot;
  late final ChannelHub _channels = widget.controller.channels;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String en, String zh) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _telegram.addListener(_changed);
    _channels.addListener(_changed);
    widget.controller.addListener(_changed);
    unawaited(_telegram.initialize());
    unawaited(_channels.initialize());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _telegram.removeListener(_changed);
    _channels.removeListener(_changed);
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final localServer = looksLikeInAppServer(widget.controller.profile);
    final telegram = _telegram.snapshot;
    final official = _channels.snapshotFor(ChannelProviderIds.officialQq);
    final oneBot = _channels.snapshotFor(ChannelProviderIds.oneBot11);

    return KitScreen(
      topBar: KitTopBar(title: _text('Message channels', '消息渠道')),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text(
              'Let Telegram and QQ talk to the agent running on this phone. Every channel becomes an ordinary agent prompt; replies come back through the channel the request arrived on.',
              '让 Telegram 和 QQ 与运行在本机的 Agent 对话。所有渠道的指令都会作为普通 Agent 提示词发送，结果通过原渠道返回。',
            ),
            role: KitTextRole.body,
          ),
          if (!localServer) ...[
            SizedBox(height: tokens.space3),
            KitGroupNote(
              message: _text(
                'Select and connect the OpenCode server hosted by this phone before enabling a channel.',
                '请先选择并连接此手机内置的 OpenCode 服务器，再启用消息渠道。',
              ),
            ),
          ],
          SizedBox(height: tokens.space4),
          KitRow(
            key: const ValueKey('channel-row-telegram'),
            title: 'Telegram',
            supporting: TextSpan(
              text: _text('Official Bot API, long polling', '官方 Bot API，长轮询'),
            ),
            leading: KitRow.icon(context, AppIconography.chat),
            trailing: KitStatusTag(
              label: _telegramPhaseLabel(telegram.phase),
              tone: _telegramTone(telegram.phase),
            ),
            onTap: () =>
                _open(TelegramBotScreen(controller: widget.controller)),
          ),
          KitRow(
            key: const ValueKey('channel-row-qq-official'),
            title: _text('QQ official bot', 'QQ 官方机器人'),
            supporting: TextSpan(
              text: _text(
                'Tencent Open Platform, gateway + OpenAPI',
                '腾讯开放平台，Gateway + OpenAPI',
              ),
            ),
            leading: KitRow.icon(context, AppIconography.server),
            trailing: KitStatusTag(
              label: _stateLabel(official.state, official.enabled),
              tone: _stateTone(official.state),
            ),
            onTap: () => _open(OfficialQqScreen(controller: widget.controller)),
          ),
          KitRow(
            key: const ValueKey('channel-row-qq-onebot'),
            title: _text('QQ personal account', 'QQ 普通账号'),
            supporting: TextSpan(
              text: _text(
                'LLBot + OneBot 11, self-hosted',
                'LLBot + OneBot 11，自行部署',
              ),
            ),
            leading: KitRow.icon(context, AppIconography.terminal),
            trailing: KitStatusTag(
              label: _stateLabel(oneBot.state, oneBot.enabled),
              tone: _stateTone(oneBot.state),
            ),
            onTap: () => _open(OneBot11Screen(controller: widget.controller)),
          ),
          SizedBox(height: tokens.space4),
          KitGroupNote(
            message: _text(
              'Telegram and the official QQ bot are platform-authorised. A QQ personal account goes through a third-party implementation you run yourself: OpenCode Plus does not bundle it, and the QQ platform does not authorise it.',
              'Telegram 与 QQ 官方机器人是平台授权渠道。QQ 普通账号依赖你自行部署的第三方实现：OpenCode Plus 不会打包它，腾讯平台也未授权该接入方式。',
            ),
          ),
        ],
      ),
    );
  }

  String _telegramPhaseLabel(TelegramBotPhase phase) => switch (phase) {
    TelegramBotPhase.disabled => _text('Off', '已关闭'),
    TelegramBotPhase.needsSetup => _text('Needs setup', '待配置'),
    TelegramBotPhase.starting => _text('Connecting', '连接中'),
    TelegramBotPhase.polling => _text('Listening', '接收中'),
    TelegramBotPhase.error => _text('Error', '异常'),
  };

  KitStatusTagTone _telegramTone(TelegramBotPhase phase) => switch (phase) {
    TelegramBotPhase.polling => KitStatusTagTone.done,
    TelegramBotPhase.error => KitStatusTagTone.failed,
    TelegramBotPhase.starting => KitStatusTagTone.running,
    TelegramBotPhase.disabled ||
    TelegramBotPhase.needsSetup => KitStatusTagTone.done,
  };

  String _stateLabel(ProviderState state, bool enabled) {
    if (!enabled) return _text('Off', '已关闭');
    return switch (state) {
      ProviderState.disabled => _text('Off', '已关闭'),
      ProviderState.needsSetup => _text('Needs setup', '待配置'),
      ProviderState.connecting => _text('Connecting', '连接中'),
      ProviderState.online => _text('Online', '在线'),
      ProviderState.reconnecting => _text('Reconnecting', '重连中'),
      ProviderState.error => _text('Error', '异常'),
      ProviderState.closed => _text('Closed', '已关闭'),
    };
  }

  KitStatusTagTone _stateTone(ProviderState state) => switch (state) {
    ProviderState.online => KitStatusTagTone.done,
    ProviderState.error ||
    ProviderState.reconnecting => KitStatusTagTone.failed,
    ProviderState.connecting => KitStatusTagTone.running,
    _ => KitStatusTagTone.done,
  };
}

/// The official QQ bot: AppID, secret, scene permissions and the honest list of
/// what the platform will refuse without an approval.
class OfficialQqScreen extends StatefulWidget {
  const OfficialQqScreen({super.key, required this.controller});

  final ConnectionController controller;

  @override
  State<OfficialQqScreen> createState() => _OfficialQqScreenState();
}

class _OfficialQqScreenState extends State<OfficialQqScreen> {
  late final ChannelHub _hub = widget.controller.channels;
  late final TextEditingController _appId = TextEditingController();
  late final TextEditingController _secret = TextEditingController();
  late final TextEditingController _users = TextEditingController();
  late final TextEditingController _groups = TextEditingController();
  bool _enabled = false;
  bool _sandbox = false;
  bool _allowDirect = true;
  bool _allowGroup = true;
  bool _requireMention = true;
  bool _replacingSecret = false;
  bool _hasSecret = false;
  bool _busy = false;
  String? _notice;
  String? _error;
  String? _loadedFor;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String en, String zh) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _hub.addListener(_changed);
    widget.controller.addListener(_changed);
    unawaited(_hub.initialize().then((_) => _load()));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _load() {
    if (!mounted) return;
    final config = _hub.officialConfig;
    if (_loadedFor == config.appId && _appId.text.isNotEmpty) return;
    _loadedFor = config.appId;
    _appId.text = config.appId;
    _users.text = config.allowedUsers.join(', ');
    _groups.text = config.allowedGroups.join(', ');
    _enabled = config.enabled;
    _sandbox = config.sandbox;
    _allowDirect = config.allowDirect;
    _allowGroup = config.allowGroup;
    _requireMention = config.requireMentionInGroups;
    setState(() {});
    unawaited(
      _hub.config.readOfficialQqSecret().then((value) {
        if (!mounted) return;
        setState(() => _hasSecret = value != null && value.isNotEmpty);
      }),
    );
  }

  @override
  void dispose() {
    _hub.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _appId.dispose();
    _secret.dispose();
    _users.dispose();
    _groups.dispose();
    super.dispose();
  }

  OfficialQqConfig _candidate() => OfficialQqConfig(
    appId: _appId.text.trim(),
    enabled: _enabled,
    sandbox: _sandbox,
    allowedUsers: _splitIds(_users.text),
    allowedGroups: _splitIds(_groups.text),
    allowDirect: _allowDirect,
    allowGroup: _allowGroup,
    requireMentionInGroups: _requireMention,
  );

  static Set<String> _splitIds(String raw) => {
    for (final part in raw.split(RegExp(r'[\s,，;；]+')))
      if (part.trim().isNotEmpty) part.trim(),
  };

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _hub.saveOfficialQq(
        _candidate(),
        clientSecret: _replacingSecret ? _secret.text : null,
      );
      _secret.clear();
      _replacingSecret = false;
      if (mounted) {
        setState(() {
          _notice = _text('QQ official bot settings saved.', 'QQ 官方机器人设置已保存。');
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(() {
          _error = _text('Could not save the QQ settings.', '无法保存 QQ 设置。');
        });
      }
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
      final notice = await _hub.testOfficialQq(
        candidate: _candidate(),
        clientSecret: _replacingSecret ? _secret.text : null,
      );
      if (mounted) setState(() => _notice = notice);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(() {
          _error = _text(
            'The connection test failed. Check AppID, ClientSecret and network.',
            '连接测试失败，请检查 AppID、ClientSecret 和网络。',
          );
        });
      }
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
      await _hub.clearOfficialQq();
      _appId.clear();
      _secret.clear();
      _users.clear();
      _groups.clear();
      _enabled = false;
      _hasSecret = false;
      _replacingSecret = false;
      _loadedFor = null;
      if (mounted) {
        setState(() {
          _notice = _text(
            'QQ official bot configuration removed.',
            'QQ 官方机器人配置已删除。',
          );
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _error = _text('Could not remove the configuration.', '无法删除配置。');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final snapshot = _hub.snapshotFor(ChannelProviderIds.officialQq);

    return KitScreen(
      topBar: KitTopBar(title: _text('QQ official bot', 'QQ 官方机器人')),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text(
              'Connect a bot created on the Tencent QQ Open Platform. Messages arrive over the official gateway; replies go through the official OpenAPI. Private chat, group chat and channels are separate permissions granted in the console.',
              '接入在腾讯 QQ 开放平台创建的机器人。消息通过官方网关接收，回复通过官方 OpenAPI 发送。单聊、群聊和频道是在控制台分别授权的独立能力。',
            ),
            role: KitTextRole.body,
          ),
          SizedBox(height: tokens.space3),
          KitText(
            '${_text('Status', '状态')}：${_stateText(snapshot.state, snapshot.enabled)}',
            role: KitTextRole.secondary,
            tone: _stateTextTone(snapshot.state),
          ),
          if (snapshot.detail != null && snapshot.detail!.isNotEmpty) ...[
            SizedBox(height: tokens.space1),
            KitText(snapshot.detail!, role: KitTextRole.caption),
          ],
          if (snapshot.lastError != null) ...[
            SizedBox(height: tokens.space2),
            KitText(
              snapshot.lastError!,
              role: KitTextRole.caption,
              tone: KitTextTone.attention,
            ),
          ],
          SizedBox(height: tokens.space5),
          KitField(
            key: const ValueKey('qq-official-app-id'),
            label: _text('AppID', 'AppID'),
            kind: KitFieldKind.number,
            controller: _appId,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            hint: '1020****',
            helper: _text(
              'The numeric AppID from the QQ Open Platform console.',
              'QQ 开放平台管理端的数字 AppID。',
            ),
          ),
          SizedBox(height: tokens.space3),
          KitField.secret(
            key: const ValueKey('qq-official-secret'),
            label: _text('ClientSecret', 'ClientSecret'),
            controller: _secret,
            saved: _hasSecret && !_replacingSecret,
            onReplace: () => setState(() => _replacingSecret = true),
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            helper: _text(
              'Stored in secure storage and exchanged for an access token. Never written to logs.',
              '保存在安全存储中，用于换取 access token，不会写入日志。',
            ),
          ),
          SizedBox(height: tokens.space3),
          KitField(
            key: const ValueKey('qq-official-users'),
            label: _text('Allowed openids', '允许的 openid'),
            controller: _users,
            maxLines: 3,
            minLines: 1,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            helper: _text(
              'One openid per line or comma. Empty means nobody can drive the agent.',
              '每行一个或用逗号分隔。留空表示任何人都不能驱动 Agent。',
            ),
          ),
          SizedBox(height: tokens.space3),
          KitField(
            key: const ValueKey('qq-official-groups'),
            label: _text('Allowed group openids', '允许的群 openid'),
            controller: _groups,
            maxLines: 3,
            minLines: 1,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            helper: _text(
              'A group must be listed here before the bot answers in it.',
              '只有列在这里的群，机器人才能回复。',
            ),
          ),
          SizedBox(height: tokens.space3),
          KitSwitchRow(
            key: const ValueKey('qq-official-sandbox'),
            title: _text('Sandbox environment', '沙箱环境'),
            supporting: _text(
              'Sandbox bots talk to the sandbox API and cannot reach real users.',
              '沙箱机器人连接沙箱 API，无法触达真实用户。',
            ),
            value: _sandbox,
            onChanged: _busy
                ? null
                : (value) => setState(() => _sandbox = value),
          ),
          KitSwitchRow(
            key: const ValueKey('qq-official-direct'),
            title: _text('Allow private chat', '允许私聊'),
            supporting: _text(
              'Requires the C2C permission on the bot.',
              '需要机器人已获得单聊（C2C）权限。',
            ),
            value: _allowDirect,
            onChanged: _busy
                ? null
                : (value) => setState(() => _allowDirect = value),
          ),
          KitSwitchRow(
            key: const ValueKey('qq-official-group'),
            title: _text('Allow group chat', '允许群聊'),
            supporting: _text(
              'Requires the group permission and the bot being added to the group.',
              '需要群聊权限，且机器人已被加入该群。',
            ),
            value: _allowGroup,
            onChanged: _busy
                ? null
                : (value) => setState(() => _allowGroup = value),
          ),
          KitSwitchRow(
            key: const ValueKey('qq-official-mention'),
            title: _text('Require @ or a command in groups', '群聊需要 @ 或命令'),
            supporting: _text(
              'Without this every group message becomes an agent prompt.',
              '关闭后群内每条消息都会成为 Agent 指令。',
            ),
            value: _requireMention,
            onChanged: _busy
                ? null
                : (value) => setState(() => _requireMention = value),
          ),
          SizedBox(height: tokens.space3),
          KitSwitchRow(
            key: const ValueKey('qq-official-enabled'),
            title: _text('Enable this channel', '启用该渠道'),
            supporting: _text(
              'Connects the gateway while the app is running. Android may stop background work; it is not a permanent server.',
              'App 运行期间保持网关连接。Android 可能暂停后台进程，这不是永久在线服务。',
            ),
            value: _enabled,
            onChanged: _busy
                ? null
                : (value) => setState(() => _enabled = value),
          ),
          if (_error != null)
            KitNotice(message: _error!, tone: AppStatusTone.failure),
          if (_notice != null)
            KitNotice(message: _notice!, tone: AppStatusTone.ok),
          KitButton.primary(
            key: const ValueKey('qq-official-save'),
            label: _enabled
                ? _text('Save and enable', '保存并启用')
                : _text('Save settings', '保存设置'),
            onPressed: _busy ? null : _save,
            working: _busy,
          ),
          SizedBox(height: tokens.space2),
          KitButton.secondary(
            key: const ValueKey('qq-official-test'),
            label: _text('Test credentials', '测试凭据'),
            onPressed: _busy ? null : _test,
            working: _busy,
          ),
          if (snapshot.configured) ...[
            SizedBox(height: tokens.space2),
            KitButton.tertiary(
              key: const ValueKey('qq-official-remove'),
              label: _text('Remove configuration', '删除配置'),
              destructive: true,
              onPressed: _busy ? null : _clear,
            ),
          ],
          SizedBox(height: tokens.space4),
          _CapabilityList(
            title: _text('What this channel can do', '该渠道的能力'),
            capabilities: snapshot.capabilities,
            zh: _zh,
          ),
          SizedBox(height: tokens.space3),
          KitGroupNote(
            message: _text(
              'Platform limits: a passive reply must be sent within 5 minutes of the message and at most 5 times per message; long tasks therefore cannot keep one window open. Active messages and media need approvals this app cannot grant. Permissions without approval show as unavailable rather than silently failing.',
              '平台限制：被动回复必须在收到消息后 5 分钟内发送，且每条消息最多 5 次；长任务无法一直占用同一个回复窗口。主动消息与媒体能力需要本应用无法代为申请的平台审批。未获授权的场景显示为不可用，而不是静默失败。',
            ),
          ),
        ],
      ),
    );
  }

  String _stateText(ProviderState state, bool enabled) {
    if (!enabled) return _text('Off', '已关闭');
    return switch (state) {
      ProviderState.disabled => _text('Off', '已关闭'),
      ProviderState.needsSetup => _text('Needs setup', '待配置'),
      ProviderState.connecting => _text('Connecting…', '正在连接…'),
      ProviderState.online => _text('Connected', '已连接'),
      ProviderState.reconnecting => _text('Reconnecting…', '正在重连…'),
      ProviderState.error => _text('Connection problem', '连接异常'),
      ProviderState.closed => _text('Closed', '已关闭'),
    };
  }

  KitTextTone _stateTextTone(ProviderState state) => switch (state) {
    ProviderState.online => KitTextTone.success,
    ProviderState.error || ProviderState.reconnecting => KitTextTone.attention,
    ProviderState.connecting => KitTextTone.accent,
    _ => KitTextTone.secondary,
  };
}

/// The personal-QQ channel: an LLBot the person runs, spoken to over OneBot 11.
class OneBot11Screen extends StatefulWidget {
  const OneBot11Screen({super.key, required this.controller});

  final ConnectionController controller;

  @override
  State<OneBot11Screen> createState() => _OneBot11ScreenState();
}

class _OneBot11ScreenState extends State<OneBot11Screen> {
  late final ChannelHub _hub = widget.controller.channels;
  late final TextEditingController _url = TextEditingController();
  late final TextEditingController _port = TextEditingController(
    text: '${OneBot11Config.defaultListenPort}',
  );
  OneBotBackend _backend = OneBotBackend.llbot;
  OneBotTransport _transport = OneBotTransport.forward;
  late final TextEditingController _token = TextEditingController();
  late final TextEditingController _selfId = TextEditingController();
  late final TextEditingController _users = TextEditingController();
  late final TextEditingController _groups = TextEditingController();
  bool _enabled = false;
  bool _allowDirect = true;
  bool _allowGroup = true;
  bool _requireMention = true;
  bool _replacingToken = false;
  bool _hasToken = false;
  bool _busy = false;
  String? _notice;
  String? _error;
  String? _loadedFor;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String en, String zh) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _hub.addListener(_changed);
    widget.controller.addListener(_changed);
    unawaited(_hub.initialize().then((_) => _load()));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _load() {
    if (!mounted) return;
    final config = _hub.oneBotConfig;
    if (_loadedFor == config.webSocketUrl && _url.text.isNotEmpty) return;
    _loadedFor = config.webSocketUrl;
    _url.text = config.webSocketUrl;
    _selfId.text = config.expectedSelfId;
    _users.text = config.allowedUsers.join(', ');
    _groups.text = config.allowedGroups.join(', ');
    _enabled = config.enabled;
    _allowDirect = config.allowDirect;
    _allowGroup = config.allowGroup;
    _requireMention = config.requireMentionInGroups;
    setState(() {});
    unawaited(
      _hub.config.readOneBot11Token().then((value) {
        if (!mounted) return;
        setState(() => _hasToken = value != null && value.isNotEmpty);
      }),
    );
  }

  @override
  void dispose() {
    _hub.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _url.dispose();
    _port.dispose();
    _token.dispose();
    _selfId.dispose();
    _users.dispose();
    _groups.dispose();
    super.dispose();
  }

  OneBot11Config _candidate() => OneBot11Config(
    backend: _backend,
    transport: _transport,
    webSocketUrl: _url.text.trim(),
    listenPort: int.tryParse(_port.text.trim()) ?? 0,
    expectedSelfId: _selfId.text.trim(),
    enabled: _enabled,
    allowedUsers: _splitIds(_users.text),
    allowedGroups: _splitIds(_groups.text),
    allowDirect: _allowDirect,
    allowGroup: _allowGroup,
    requireMentionInGroups: _requireMention,
  );

  String _backendHint(OneBotBackend backend) => switch (backend) {
    OneBotBackend.llbot => _text(
      'LLBot on a Linux machine. Its OneBot 11 plugin exposes a forward WebSocket, usually on port 3001.',
      'LLBot 运行在 Linux 机器上，其 OneBot 11 插件提供正向 WebSocket，通常监听 3001 端口。',
    ),
    OneBotBackend.napcat => _text(
      'NapCat logs in the QQ NT client. Its WebUI is on port 6099; add a WebSocket client there that points at this phone.',
      'NapCat 登录 QQ NT 客户端。WebUI 在 6099 端口；在它的网络配置里加一个 WebSocket 客户端，指向这台手机。',
    ),
    OneBotBackend.snowLuma => _text(
      'SnowLuma bridges the desktop QQ client. Its console is on port 5099 and its OneBot gateway on 3000/3001.',
      'SnowLuma 在桌面上桥接 QQ 客户端。控制台在 5099 端口，OneBot 网关在 3000/3001。',
    ),
  };

  /// Reads the real group list from the connected implementation and writes
  /// the chosen groups into the allowlist. Typing nine-digit numbers is how an
  /// allowlist ends up wrong without anyone noticing.
  Future<void> _fetchGroups() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    List<OneBotGroup> groups = const [];
    try {
      groups = await _hub.fetchOneBotGroups();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
      return;
    } on Object {
      if (mounted) {
        setState(() {
          _error = _text(
            'Could not read the group list from the bot.',
            '无法从机器人读取群列表。',
          );
        });
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (groups.isEmpty) {
      setState(() {
        _notice = _text(
          'The bot is not in any group.',
          '机器人目前不在任何群里。',
        );
      });
      return;
    }
    final selected = {..._splitIds(_groups.text)};
    final chosen = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_text('Groups the bot is in', '机器人所在的群')),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final group in groups)
                  CheckboxListTile(
                    key: ValueKey('onebot-group-${group.id}'),
                    value: selected.contains(group.id),
                    title: Text(group.name),
                    subtitle: Text(
                      group.memberCount == null
                          ? group.id
                          : '${group.id} · ${group.memberCount}',
                    ),
                    onChanged: (value) => setDialogState(() {
                      if (value == true) {
                        selected.add(group.id);
                      } else {
                        selected.remove(group.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(_text('Cancel', '取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(selected),
              child: Text(_text('Use these', '使用这些群')),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _groups.text = chosen.join(', ');
      _notice = _text(
        'Allowed groups updated. Save to apply.',
        '允许的群已更新，保存后生效。',
      );
    });
  }

  static Set<String> _splitIds(String raw) => {
    for (final part in raw.split(RegExp(r'[\s,，;；]+')))
      if (part.trim().isNotEmpty) part.trim(),
  };

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _hub.saveOneBot11(
        _candidate(),
        accessToken: _replacingToken ? _token.text : null,
      );
      _token.clear();
      _replacingToken = false;
      if (mounted) {
        setState(() {
          _notice = _text('OneBot 11 settings saved.', 'OneBot 11 设置已保存。');
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(() {
          _error = _text(
            'Could not save the OneBot settings.',
            '无法保存 OneBot 设置。',
          );
        });
      }
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
      final notice = await _hub.testOneBot11(
        candidate: _candidate(),
        accessToken: _replacingToken ? _token.text : null,
      );
      if (mounted) setState(() => _notice = notice);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(() {
          _error = _text(
            'The connection test failed. Check the address, token and that LLBot is running.',
            '连接测试失败，请检查地址、Token，以及 LLBot 是否在运行。',
          );
        });
      }
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
      await _hub.clearOneBot11();
      _url.clear();
      _token.clear();
      _selfId.clear();
      _users.clear();
      _groups.clear();
      _enabled = false;
      _hasToken = false;
      _replacingToken = false;
      _loadedFor = null;
      if (mounted) {
        setState(() {
          _notice = _text(
            'OneBot 11 configuration removed.',
            'OneBot 11 配置已删除。',
          );
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _error = _text('Could not remove the configuration.', '无法删除配置。');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final snapshot = _hub.snapshotFor(ChannelProviderIds.oneBot11);
    final insecure = _candidate().isInsecureTransport;

    return KitScreen(
      topBar: KitTopBar(title: _text('QQ personal account', 'QQ 普通账号')),
      width: KitScreenWidth.reading,
      body: ListView(
        padding: KitScreen.padding(context),
        children: [
          KitText(
            _text(
              'Connect to an LLBot you run yourself over the OneBot 11 forward WebSocket. The bot account, the QQ login and the protocol implementation all live outside this app.',
              '通过 OneBot 11 正向 WebSocket 连接你自行运行的 LLBot。机器人账号、QQ 登录和协议实现都在本应用之外。',
            ),
            role: KitTextRole.body,
          ),
          SizedBox(height: tokens.space3),
          KitText(
            '${_text('Status', '状态')}：${_stateText(snapshot.state, snapshot.enabled)}',
            role: KitTextRole.secondary,
            tone: _stateTextTone(snapshot.state),
          ),
          if (snapshot.detail != null && snapshot.detail!.isNotEmpty) ...[
            SizedBox(height: tokens.space1),
            KitText(snapshot.detail!, role: KitTextRole.caption),
          ],
          if (snapshot.lastError != null) ...[
            SizedBox(height: tokens.space2),
            KitText(
              snapshot.lastError!,
              role: KitTextRole.caption,
              tone: KitTextTone.attention,
            ),
          ],
          SizedBox(height: tokens.space5),
          KitSegmented<OneBotBackend>(
            key: const ValueKey('onebot-backend'),
            segments: const [
              KitSegment(value: OneBotBackend.llbot, label: 'LLBot'),
              KitSegment(value: OneBotBackend.napcat, label: 'NapCat'),
              KitSegment(value: OneBotBackend.snowLuma, label: 'SnowLuma'),
            ],
            selected: _backend,
            onChanged: _busy
                ? null
                : (value) => setState(() => _backend = value),
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            semanticsLabel: _text('Protocol implementation', '协议端'),
          ),
          SizedBox(height: tokens.space2),
          KitText(_backendHint(_backend), role: KitTextRole.caption),
          SizedBox(height: tokens.space4),
          KitSegmented<OneBotTransport>(
            key: const ValueKey('onebot-transport'),
            segments: [
              KitSegment(
                value: OneBotTransport.forward,
                label: _text('App connects out', '应用主动连接'),
              ),
              KitSegment(
                value: OneBotTransport.reverse,
                label: _text('Bot connects in', '协议端连入'),
              ),
            ],
            selected: _transport,
            onChanged: _busy
                ? null
                : (value) => setState(() => _transport = value),
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            semanticsLabel: _text('Connection direction', '连接方向'),
          ),
          SizedBox(height: tokens.space3),
          if (_transport == OneBotTransport.forward) ...[
            KitField(
              key: const ValueKey('onebot-url'),
              label: _text('WebSocket address', 'WebSocket 地址'),
              controller: _url,
              enabled: !_busy,
              disabledReason: _busy ? _text('Saving', '正在保存') : null,
              hint: 'ws://192.168.1.10:3001',
              helper: _text(
                'The forward WebSocket server the implementation exposes.',
                '协议端提供的正向 WebSocket 服务地址。',
              ),
            ),
            if (insecure) ...[
              SizedBox(height: tokens.space2),
              KitNotice(
                message: _text(
                  'This is a plain ws:// address, so the access token travels unencrypted. Use wss:// or a trusted private network.',
                  '当前是明文 ws:// 地址，Access Token 会以明文传输。请使用 wss:// 或可信私有网络。',
                ),
                tone: AppStatusTone.failure,
              ),
            ],
          ] else ...[
            KitField(
              key: const ValueKey('onebot-listen-port'),
              label: _text('Listening port', '监听端口'),
              kind: KitFieldKind.number,
              controller: _port,
              enabled: !_busy,
              disabledReason: _busy ? _text('Saving', '正在保存') : null,
              hint: '8082',
              helper: _text(
                'This phone listens; the bot dials ws://<phone-ip>:port with the token below. 8082 is what NapCat suggests.',
                '由这台手机监听，协议端带着下面的 Token 连接 ws://<手机地址>:端口。NapCat 默认填 8082。',
              ),
            ),
            SizedBox(height: tokens.space2),
            KitNotice(
              message: _text(
                'Anyone who can reach this port with the token can drive the agent. Keep the phone on a trusted network, and the token is required — the listener will not start without one.',
                '能访问该端口并持有 Token 的人即可驱动 Agent。请只在可信网络使用；Token 是必填项，没有 Token 不会开始监听。',
              ),
              tone: AppStatusTone.attention,
            ),
          ],
          SizedBox(height: tokens.space3),
          KitField.secret(
            key: const ValueKey('onebot-token'),
            label: _text('Access token', 'Access Token'),
            controller: _token,
            saved: _hasToken && !_replacingToken,
            onReplace: () => setState(() => _replacingToken = true),
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            helper: _text(
              'Sent as an Authorization: Bearer header, never in the URL.',
              '通过 Authorization: Bearer 请求头发送，不放在 URL 中。',
            ),
          ),
          SizedBox(height: tokens.space3),
          KitField(
            key: const ValueKey('onebot-self-id'),
            label: _text('Expected QQ account', '预期 QQ 账号'),
            kind: KitFieldKind.number,
            controller: _selfId,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            hint: '10001',
            helper: _text(
              'Checked against the self_id LLBot reports; a mismatch disconnects instead of answering as the wrong account.',
              '与 LLBot 上报的 self_id 校验；不一致会断开，避免用错账号回复。',
            ),
          ),
          SizedBox(height: tokens.space3),
          KitField(
            key: const ValueKey('onebot-users'),
            label: _text('Allowed QQ numbers', '允许的 QQ 号'),
            controller: _users,
            maxLines: 3,
            minLines: 1,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            helper: _text(
              'One number per line or comma. Empty means nobody.',
              '每行一个或用逗号分隔。留空表示任何人都不能驱动 Agent。',
            ),
          ),
          SizedBox(height: tokens.space3),
          KitField(
            key: const ValueKey('onebot-groups'),
            label: _text('Allowed group numbers', '允许的群号'),
            controller: _groups,
            maxLines: 3,
            minLines: 1,
            enabled: !_busy,
            disabledReason: _busy ? _text('Saving', '正在保存') : null,
            helper: _text(
              'A group must be listed here before the bot answers in it.',
              '只有列在这里的群，机器人才能回复。',
            ),
          ),
          SizedBox(height: tokens.space2),
          KitButton.secondary(
            key: const ValueKey('onebot-groups-fetch'),
            label: _text(
              'Choose from the bot\'s groups',
              '从机器人拉取群列表',
            ),
            onPressed: _busy ? null : _fetchGroups,
            working: _busy,
          ),
          SizedBox(height: tokens.space3),
          KitSwitchRow(
            key: const ValueKey('onebot-direct'),
            title: _text('Allow private chat', '允许私聊'),
            value: _allowDirect,
            onChanged: _busy
                ? null
                : (value) => setState(() => _allowDirect = value),
          ),
          KitSwitchRow(
            key: const ValueKey('onebot-group'),
            title: _text('Allow group chat', '允许群聊'),
            value: _allowGroup,
            onChanged: _busy
                ? null
                : (value) => setState(() => _allowGroup = value),
          ),
          KitSwitchRow(
            key: const ValueKey('onebot-mention'),
            title: _text('Require @ or a command in groups', '群聊需要 @ 或命令'),
            supporting: _text(
              'Without this every group message becomes an agent prompt.',
              '关闭后群内每条消息都会成为 Agent 指令。',
            ),
            value: _requireMention,
            onChanged: _busy
                ? null
                : (value) => setState(() => _requireMention = value),
          ),
          SizedBox(height: tokens.space3),
          KitSwitchRow(
            key: const ValueKey('onebot-enabled'),
            title: _text('Enable this channel', '启用该渠道'),
            supporting: _text(
              'Connects while the app runs. Android may stop background work; this is not a permanent service.',
              'App 运行期间保持连接。Android 可能暂停后台进程，这不是永久在线服务。',
            ),
            value: _enabled,
            onChanged: _busy
                ? null
                : (value) => setState(() => _enabled = value),
          ),
          if (_error != null)
            KitNotice(message: _error!, tone: AppStatusTone.failure),
          if (_notice != null)
            KitNotice(message: _notice!, tone: AppStatusTone.ok),
          KitButton.primary(
            key: const ValueKey('onebot-save'),
            label: _enabled
                ? _text('Save and enable', '保存并启用')
                : _text('Save settings', '保存设置'),
            onPressed: _busy ? null : _save,
            working: _busy,
          ),
          SizedBox(height: tokens.space2),
          KitButton.secondary(
            key: const ValueKey('onebot-test'),
            label: _text('Test connection', '测试连接'),
            onPressed: _busy ? null : _test,
            working: _busy,
          ),
          if (snapshot.configured) ...[
            SizedBox(height: tokens.space2),
            KitButton.tertiary(
              key: const ValueKey('onebot-remove'),
              label: _text('Remove configuration', '删除配置'),
              destructive: true,
              onPressed: _busy ? null : _clear,
            ),
          ],
          SizedBox(height: tokens.space4),
          _CapabilityList(
            title: _text('What this channel can do', '该渠道的能力'),
            capabilities: snapshot.capabilities,
            zh: _zh,
          ),
          SizedBox(height: tokens.space3),
          KitGroupNote(
            message: _text(
              'Run the protocol implementation on a Linux x64 machine or a PC: LLBot, NapCat or SnowLuma. Turn on its OneBot 11 WebSocket — forward if it can listen, reverse if it should dial this phone — set an access token, then fill in the address or the port and the QQ number it logs in. None of them is bundled with this app — LLBot is GPL-2.0, NapCat and SnowLuma carry their own licences — and hosting any of them under Android/PRoot is not supported.',
              '请在一台 Linux x64 机器或 PC 上运行协议端：LLBot、NapCat 或 SnowLuma。开启它的 OneBot 11 WebSocket——能监听就用正向，需要主动连出就用反向——设置 Access Token，然后填写地址或端口，以及它登录的 QQ 号。三者都不随本应用分发（LLBot 为 GPL-2.0，NapCat 与 SnowLuma 各有自己的许可），也不支持在 Android/PRoot 里托管。',
            ),
          ),
        ],
      ),
    );
  }

  String _stateText(ProviderState state, bool enabled) {
    if (!enabled) return _text('Off', '已关闭');
    return switch (state) {
      ProviderState.disabled => _text('Off', '已关闭'),
      ProviderState.needsSetup => _text('Needs setup', '待配置'),
      ProviderState.connecting => _text('Connecting…', '正在连接…'),
      ProviderState.online => _text('Connected', '已连接'),
      ProviderState.reconnecting => _text('Reconnecting…', '正在重连…'),
      ProviderState.error => _text('Connection problem', '连接异常'),
      ProviderState.closed => _text('Closed', '已关闭'),
    };
  }

  KitTextTone _stateTextTone(ProviderState state) => switch (state) {
    ProviderState.online => KitTextTone.success,
    ProviderState.error || ProviderState.reconnecting => KitTextTone.attention,
    ProviderState.connecting => KitTextTone.accent,
    _ => KitTextTone.secondary,
  };
}

/// The honest capability table: everything the channel cannot do, with the
/// provider's own reason. Shown on every channel page so "why can't it send an
/// image?" is answerable without reading code.
class _CapabilityList extends StatelessWidget {
  const _CapabilityList({
    required this.title,
    required this.capabilities,
    required this.zh,
  });

  final String title;
  final ChannelCapabilities capabilities;
  final bool zh;

  static const _labels = {
    ChannelCapability.directMessage: ('Direct messages', '私聊'),
    ChannelCapability.groupMessage: ('Group messages', '群聊'),
    ChannelCapability.activeMessage: ('Active messages', '主动消息'),
    ChannelCapability.passiveReply: ('Passive replies', '被动回复'),
    ChannelCapability.image: ('Images', '图片'),
    ChannelCapability.file: ('Files', '文件'),
    ChannelCapability.voice: ('Voice', '语音'),
    ChannelCapability.messageReply: ('Message quotes', '消息引用'),
    ChannelCapability.messageEdit: ('Message editing', '消息编辑'),
    ChannelCapability.messageRecall: ('Message recall', '消息撤回'),
    ChannelCapability.messageQuery: ('Message lookup', '消息查询'),
    ChannelCapability.longText: ('Long text', '长文本'),
  };

  static const _statusLabels = {
    CapabilityStatus.native: ('native', '原生'),
    CapabilityStatus.extension: ('extension', '扩展'),
    CapabilityStatus.application: ('application', '应用层实现'),
    CapabilityStatus.unsupported: ('unsupported', '不支持'),
    CapabilityStatus.unverified: ('unverified', '未验证'),
  };

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KitText(title, role: KitTextRole.body, tone: KitTextTone.primary),
        SizedBox(height: tokens.space2),
        for (final entry in capabilities.all.entries)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.space2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 96,
                  child: KitText(
                    zh ? _labels[entry.key]!.$2 : _labels[entry.key]!.$1,
                    role: KitTextRole.caption,
                    tone: entry.value.usable
                        ? KitTextTone.secondary
                        : KitTextTone.attention,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KitText(
                        '${zh ? _statusLabels[entry.value.status]!.$2 : _statusLabels[entry.value.status]!.$1}'
                        '${entry.value.requiresPermission ? (zh ? ' · 需要平台授权' : ' · needs platform permission') : ''}',
                        role: KitTextRole.caption,
                        tone: entry.value.usable
                            ? KitTextTone.secondary
                            : KitTextTone.attention,
                      ),
                      if (entry.value.note != null)
                        KitText(entry.value.note!, role: KitTextRole.caption),
                      if (entry.value.limit != null)
                        KitText(
                          entry.value.limit!,
                          role: KitTextRole.caption,
                          tone: KitTextTone.secondary,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
