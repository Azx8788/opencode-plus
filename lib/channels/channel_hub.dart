import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';
import 'channel_agent_port.dart';
import 'channel_capabilities.dart';
import 'channel_config.dart';
import 'channel_engine.dart';
import 'channel_identity.dart';
import 'channel_inbox.dart';
import 'channel_message.dart';
import 'channel_outbox.dart';
import 'channel_provider.dart';
import 'channel_sessions.dart';
import 'providers/official_qq_provider.dart';
import 'providers/onebot11_provider.dart';

/// What a settings page needs to describe one QQ channel.
@immutable
class ChannelAccountSnapshot {
  const ChannelAccountSnapshot({
    required this.providerId,
    required this.enabled,
    required this.configured,
    required this.state,
    required this.capabilities,
    this.detail,
    this.lastError,
    this.boundSessionID,
    this.queuedCount = 0,
    this.running = false,
  });

  final String providerId;
  final bool enabled;
  final bool configured;
  final ProviderState state;
  final ChannelCapabilities capabilities;
  final String? detail;
  final String? lastError;
  final String? boundSessionID;
  final int queuedCount;
  final bool running;

  bool get online => state == ProviderState.online;

  /// Capabilities this channel cannot do, with the provider's own wording.
  Map<ChannelCapability, CapabilitySpec> get unavailable =>
      capabilities.unavailable;
}

/// Owns the two QQ channels: their configuration, their providers, their
/// engines and their lifecycle.
///
/// The Telegram relay keeps its own bridge because it predates this layer and
/// its settings page, preferences keys and connection-controller hooks are
/// part of the shipped product. It runs on the same engine and the same
/// provider contract, so a fourth channel would not touch the agent core.
class ChannelHub extends ChangeNotifier {
  ChannelHub({
    required SharedPreferences preferences,
    required FlutterSecureStorage secureStorage,
    required ChannelAgentPort agent,
    required Stream<EventEnvelope> events,
    required String? Function() profileID,
    required String? Function() directory,
    required String? Function() workspace,
    required bool Function() supported,
    required void Function(VoidCallback listener) addHostListener,
    required void Function(VoidCallback listener) removeHostListener,
  }) : _preferences = preferences,
       _agent = agent,
       _events = events,
       _profileID = profileID,
       _directory = directory,
       _workspace = workspace,
       _supported = supported,
       _addHostListener = addHostListener,
       _removeHostListener = removeHostListener {
    config = ChannelConfigStore(
      preferences: preferences,
      secureStorage: secureStorage,
    );
    inbox = ChannelInbox(preferences: preferences);
    outbox = ChannelOutbox(preferences: preferences);
  }

  final SharedPreferences _preferences;
  final ChannelAgentPort _agent;
  final Stream<EventEnvelope> _events;
  final String? Function() _profileID;
  final String? Function() _directory;
  final String? Function() _workspace;
  final bool Function() _supported;
  final void Function(VoidCallback listener) _addHostListener;
  final void Function(VoidCallback listener) _removeHostListener;

  late final ChannelConfigStore config;
  late final ChannelInbox inbox;
  late final ChannelOutbox outbox;

  StreamSubscription<EventEnvelope>? _eventSubscription;
  OfficialQqConfig _officialConfig = const OfficialQqConfig();
  OneBot11Config _oneBotConfig = const OneBot11Config();
  OfficialQqProvider? _officialProvider;
  OneBot11Provider? _oneBotProvider;
  ChannelConversationEngine? _officialEngine;
  ChannelConversationEngine? _oneBotEngine;
  String? _ownerProfile;
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initializing;

  OfficialQqConfig get officialConfig => _officialConfig;

  OneBot11Config get oneBotConfig => _oneBotConfig;

  ChannelConversationEngine? get officialEngine => _officialEngine;

  ChannelConversationEngine? get oneBotEngine => _oneBotEngine;

  bool get hasConfiguredAccount =>
      _officialConfig.configured || _oneBotConfig.configured;

  /// The number of QQ channels currently online. Used by the settings hub to
  /// summarise "消息渠道" without opening each page.
  int get onlineCount => [
    _officialProvider,
    _oneBotProvider,
  ].where((provider) => provider?.status.isOnline ?? false).length;

  Future<void> initialize() => _initializing ??= _doInitialize();

  Future<void> _doInitialize() async {
    if (_disposed) return;
    _eventSubscription ??= _events.listen(_onAgentEvent);
    _addHostListener(_hostChanged);
    _officialConfig = config.loadOfficialQq();
    _oneBotConfig = config.loadOneBot11();
    _ownerProfile = _profileID();
    _initialized = true;
    await _applyOfficial();
    await _applyOneBot();
    _notify();
  }

  void _hostChanged() {
    if (_disposed) return;
    final next = _profileID();
    if (next == _ownerProfile) {
      _notify();
      return;
    }
    _ownerProfile = next;
    // Sessions are scoped by workspace, so a profile change is a different
    // set of conversations. Rebuilding is cheaper than re-keying in place.
    unawaited(_reloadAll());
  }

  Future<void> _reloadAll() async {
    _officialConfig = config.loadOfficialQq();
    _oneBotConfig = config.loadOneBot11();
    await _applyOfficial();
    await _applyOneBot();
    _notify();
  }

  void _onAgentEvent(EventEnvelope event) {
    // Each engine filters by its own bound sessions; a failure in one channel's
    // handling must not stop the other from seeing the same event.
    for (final engine in [_officialEngine, _oneBotEngine]) {
      try {
        engine?.handleAgentEvent(event);
      } on Object {
        // An engine is a passive observer here; its exception must not reach
        // the app's event stream.
      }
    }
  }

  ChannelAccountSnapshot snapshotFor(String providerId) {
    switch (providerId) {
      case ChannelProviderIds.officialQq:
        final provider = _officialProvider;
        return ChannelAccountSnapshot(
          providerId: providerId,
          enabled: _officialConfig.enabled,
          configured: _officialConfig.configured,
          state:
              provider?.status.state ??
              _idleState(
                enabled: _officialConfig.enabled,
                configured: _officialConfig.configured,
              ),
          detail: provider?.status.detail,
          lastError: provider?.status.lastError,
          capabilities:
              provider?.capabilities ?? OfficialQqProvider.declaredCapabilities,
          boundSessionID: _officialEngine?.boundSessionID,
          queuedCount: _officialEngine?.queuedCount ?? 0,
          running: _officialEngine?.isRunning ?? false,
        );
      case ChannelProviderIds.oneBot11:
        final provider = _oneBotProvider;
        return ChannelAccountSnapshot(
          providerId: providerId,
          enabled: _oneBotConfig.enabled,
          configured: _oneBotConfig.configured,
          state:
              provider?.status.state ??
              _idleState(
                enabled: _oneBotConfig.enabled,
                configured: _oneBotConfig.configured,
              ),
          detail: provider?.status.detail,
          lastError: provider?.status.lastError,
          capabilities:
              provider?.capabilities ?? OneBot11Provider.declaredCapabilities,
          boundSessionID: _oneBotEngine?.boundSessionID,
          queuedCount: _oneBotEngine?.queuedCount ?? 0,
          running: _oneBotEngine?.isRunning ?? false,
        );
      default:
        throw ArgumentError.value(providerId, 'providerId', 'not a QQ channel');
    }
  }

  ProviderState _idleState({required bool enabled, required bool configured}) {
    if (!enabled) return ProviderState.disabled;
    return configured ? ProviderState.connecting : ProviderState.needsSetup;
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> _applyOfficial() async {
    final engine = _officialEngine;
    final provider = _officialProvider;
    _officialEngine = null;
    _officialProvider = null;
    await engine?.stop();
    await provider?.dispose();
    if (_disposed || !_initialized) return;
    if (!_officialConfig.enabled || !_officialConfig.configured) {
      _notify();
      return;
    }
    final String? secret;
    try {
      secret = await config.readOfficialQqSecret();
    } on Object {
      // Secure storage unavailable: leave the channel in needs-setup instead
      // of taking the settings page down with it.
      _notify();
      return;
    }
    if (secret == null || secret.isEmpty) {
      _notify();
      return;
    }
    final created = OfficialQqProvider(
      accountId: _officialConfig.appId,
      appId: _officialConfig.appId,
      clientSecret: secret,
      sandbox: _officialConfig.sandbox,
      intents: _officialConfig.intents,
    );
    final built = _buildEngine(
      provider: created,
      policy: _officialConfig.policy,
    );
    _officialProvider = created;
    _officialEngine = built;
    await built.start();
    if (_disposed) {
      await built.shutdown();
      return;
    }
    await created.connect();
    _notify();
  }

  Future<void> _applyOneBot() async {
    final engine = _oneBotEngine;
    final provider = _oneBotProvider;
    _oneBotEngine = null;
    _oneBotProvider = null;
    await engine?.stop();
    await provider?.dispose();
    if (_disposed || !_initialized) return;
    if (!_oneBotConfig.enabled || !_oneBotConfig.configured) {
      _notify();
      return;
    }
    String token;
    try {
      token = await config.readOneBot11Token() ?? '';
    } on Object {
      _notify();
      return;
    }
    final created = OneBot11Provider(
      accountId: _oneBotConfig.expectedSelfId.isEmpty
          ? _oneBotConfig.webSocketUrl
          : _oneBotConfig.expectedSelfId,
      webSocketUrl: _oneBotConfig.webSocketUrl,
      accessToken: token,
      expectedSelfId: _oneBotConfig.expectedSelfId,
      transport: _oneBotConfig.transport == OneBotTransport.reverse
          ? OneBot11Transport.reverse
          : OneBot11Transport.forward,
      listenPort: _oneBotConfig.listenPort,
    );
    final built = _buildEngine(provider: created, policy: _oneBotConfig.policy);
    _oneBotProvider = created;
    _oneBotEngine = built;
    await built.start();
    if (_disposed) {
      await built.shutdown();
      return;
    }
    await created.connect();
    _notify();
  }

  ChannelConversationEngine _buildEngine({
    required ChannelProvider provider,
    required ChannelPolicy policy,
  }) {
    final engine = ChannelConversationEngine(
      provider: provider,
      policy: policy,
      agent: _agent,
      inbox: inbox,
      outbox: outbox,
      conversationKeyOf: (message) => _conversationKey(provider, message),
      workspaceId: _profileID() ?? '',
      directory: () => _directory() ?? '',
      workspace: () => _workspace() ?? '',
      agentReady: _supported,
      copy: const ChannelEngineCopy(),
      onChanged: _notify,
    );
    engine.useSessionStores(
      (key) => PrefsChannelSessionStore(
        preferences: _preferences,
        conversationKey: key.value,
      ),
    );
    return engine;
  }

  ConversationKey _conversationKey(
    ChannelProvider provider,
    ChannelMessage message,
  ) => ConversationKey(
    workspaceId: _profileID() ?? '',
    providerId: provider.providerId,
    accountId: provider.accountId,
    conversationType: message.conversationType,
    conversationId: message.conversationId,
    ownerActorId: message.senderId,
    threadId: message.extensions['thread_id']?.toString(),
  );

  // ------------------------------------------------------------ management

  Future<void> saveOfficialQq(
    OfficialQqConfig next, {
    String? clientSecret,
    bool restart = true,
  }) async {
    await config.saveOfficialQq(next, clientSecret: clientSecret);
    _officialConfig = config.loadOfficialQq();
    if (restart) await _applyOfficial();
    _notify();
  }

  Future<void> saveOneBot11(
    OneBot11Config next, {
    String? accessToken,
    bool restart = true,
  }) async {
    await config.saveOneBot11(next, accessToken: accessToken);
    _oneBotConfig = config.loadOneBot11();
    if (restart) await _applyOneBot();
    _notify();
  }

  Future<void> setOfficialEnabled(bool enabled) async {
    await saveOfficialQq(_officialConfig.copyWith(enabled: enabled));
  }

  Future<void> setOneBotEnabled(bool enabled) async {
    await saveOneBot11(_oneBotConfig.copyWith(enabled: enabled));
  }

  Future<void> clearOfficialQq() async {
    final engine = _officialEngine;
    final provider = _officialProvider;
    _officialEngine = null;
    _officialProvider = null;
    await engine?.stop();
    await provider?.dispose();
    await config.clearOfficialQq();
    await inbox.clear(ChannelProviderIds.officialQq, _officialConfig.appId);
    await outbox.clear(ChannelProviderIds.officialQq, _officialConfig.appId);
    _officialConfig = const OfficialQqConfig();
    _notify();
  }

  Future<void> clearOneBot11() async {
    final engine = _oneBotEngine;
    final provider = _oneBotProvider;
    _oneBotEngine = null;
    _oneBotProvider = null;
    await engine?.stop();
    await provider?.dispose();
    await config.clearOneBot11();
    await inbox.clear(
      ChannelProviderIds.oneBot11,
      _oneBotConfig.expectedSelfId,
    );
    await outbox.clear(
      ChannelProviderIds.oneBot11,
      _oneBotConfig.expectedSelfId,
    );
    _oneBotConfig = const OneBot11Config();
    _notify();
  }

  /// Connects with the given credentials, reports what happened and leaves no
  /// socket behind. Never sends a message to a person.
  Future<String> testOfficialQq({
    OfficialQqConfig? candidate,
    String? clientSecret,
  }) async {
    final target = candidate ?? _officialConfig;
    final secret = clientSecret?.trim().isNotEmpty == true
        ? clientSecret!.trim()
        : await config.readOfficialQqSecret();
    if (target.appId.isEmpty) {
      throw const FormatException('请先填写 AppID。');
    }
    if (secret == null || secret.isEmpty) {
      throw const FormatException('请先填写 ClientSecret。');
    }
    final provider = OfficialQqProvider(
      accountId: target.appId,
      appId: target.appId,
      clientSecret: secret,
      sandbox: target.sandbox,
      intents: target.intents,
    );
    try {
      return await provider.probe();
    } on Object catch (error) {
      throw FormatException(_messageOf(error));
    } finally {
      await provider.dispose();
    }
  }

  Future<String> testOneBot11({
    OneBot11Config? candidate,
    String? accessToken,
  }) async {
    final target = candidate ?? _oneBotConfig;
    if (target.transport == OneBotTransport.forward &&
        target.webSocketUrl.isEmpty) {
      throw const FormatException('请先填写 OneBot 11 的 WebSocket 地址。');
    }
    final token = accessToken?.trim().isNotEmpty == true
        ? accessToken!.trim()
        : await config.readOneBot11Token() ?? '';
    final provider = OneBot11Provider(
      accountId: target.expectedSelfId.isEmpty
          ? target.webSocketUrl
          : target.expectedSelfId,
      webSocketUrl: target.webSocketUrl,
      accessToken: token,
      expectedSelfId: target.expectedSelfId,
      transport: target.transport == OneBotTransport.reverse
          ? OneBot11Transport.reverse
          : OneBot11Transport.forward,
      listenPort: target.listenPort,
    );
    try {
      return await provider.probe();
    } on Object catch (error) {
      throw FormatException(_messageOf(error));
    } finally {
      await provider.dispose();
    }
  }

  /// Asks the connected implementation which groups the account is in.
  ///
  /// Throws when nothing is connected: an empty list would look like "no
  /// groups" and send the person hunting for a permission problem.
  Future<List<OneBotGroup>> fetchOneBotGroups() async {
    final provider = _oneBotProvider;
    if (provider == null || !provider.status.isOnline) {
      throw const FormatException('QQ 普通账号尚未连接，无法读取群列表。');
    }
    try {
      return await provider.fetchGroupList();
    } on OneBotFailure catch (error) {
      throw FormatException(error.message);
    }
  }

  static String _messageOf(Object error) {
    final text = error.toString();
    return text.startsWith('FormatException: ')
        ? text.substring('FormatException: '.length)
        : text;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _removeHostListener(_hostChanged);
    unawaited(_eventSubscription?.cancel());
    unawaited(_officialEngine?.stop());
    unawaited(_oneBotEngine?.stop());
    unawaited(_officialProvider?.dispose());
    unawaited(_oneBotProvider?.dispose());
    unawaited(outbox.dispose());
    super.dispose();
  }
}
