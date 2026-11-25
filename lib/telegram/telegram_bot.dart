import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../channels/channel_agent_port.dart';
import '../channels/channel_engine.dart';
import '../channels/channel_identity.dart';
import '../channels/channel_inbox.dart';
import '../channels/channel_message.dart';
import '../channels/channel_outbox.dart';
import '../channels/channel_provider.dart';
import '../channels/channel_sessions.dart';
import '../channels/channel_text.dart';
import '../channels/providers/telegram_provider.dart';
import '../domain/models.dart';
import '../ui/kit/kit_redact.dart';

enum TelegramBotPhase { disabled, needsSetup, starting, polling, error }

/// The Telegram Bot API origin. Production always talks to
/// `https://api.telegram.org`; the contract test points this at a local fake
/// server so the poll, dispatch and reply paths run for real.
@visibleForTesting
String telegramApiOrigin = 'https://api.telegram.org';

/// Whether [senderID] may talk to the bot in a private chat owned by
/// [allowedUserID]. Kept as a named predicate because it is the one rule the
/// relay must never get wrong.
@visibleForTesting
bool telegramPrivateMessageAllowed({
  required String allowedUserID,
  required Object? chatType,
  required Object? senderID,
  required Object? chatID,
  required bool senderIsBot,
}) =>
    RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(allowedUserID) &&
    chatType == 'private' &&
    !senderIsBot &&
    '$senderID' == allowedUserID &&
    '$chatID' == allowedUserID;

@visibleForTesting
List<String> telegramMessageChunks(String text) =>
    chunkText(text, maxCodeUnits: 3500);

@immutable
class TelegramBotSnapshot {
  const TelegramBotSnapshot({
    required this.profileID,
    required this.chatID,
    required this.sessionID,
    required this.enabled,
    required this.hasToken,
    required this.phase,
    this.lastError,
  });

  final String? profileID;
  final String chatID;
  final String? sessionID;
  final bool enabled;
  final bool hasToken;
  final TelegramBotPhase phase;

  /// The last transport failure in words the person can act on, cleared when
  /// polling recovers. Null while everything works.
  final String? lastError;

  bool get configured => hasToken && chatID.isNotEmpty;
}

/// A Telegram long-poll bridge bound to one saved OpenCode profile.
///
/// Bot credentials stay in Android secure storage. Incoming Telegram text is
/// sent as an ordinary agent prompt; this bridge never approves permissions
/// or executes a shell command itself.
///
/// Since the channel refactor this class is a facade: the transport lives in
/// [TelegramProvider], and everything about prompts, tasks, progress and
/// final answers lives in the shared [ChannelConversationEngine] that QQ uses
/// too. Its public surface is unchanged so the settings page, the connection
/// controller and the regression tests keep working.
class TelegramBotBridge extends ChangeNotifier {
  TelegramBotBridge({
    required SharedPreferences preferences,
    required FlutterSecureStorage secureStorage,
    required Stream<EventEnvelope> events,
    required String? Function() profileID,
    required String? Function() directory,
    required String? Function() workspace,
    required bool Function() supported,
    required void Function(VoidCallback listener) addHostListener,
    required void Function(VoidCallback listener) removeHostListener,
    required Future<String> Function(String text) sendPrompt,
    required Future<void> Function() stopAgent,
    required Future<String?> Function() readLatestReply,
    required String Function() agentStatus,
    required bool Function(String sessionID) isSessionBusy,
  }) : _preferences = preferences,
       _secureStorage = secureStorage,
       _events = events,
       _profileID = profileID,
       _directory = directory,
       _workspace = workspace,
       _supported = supported,
       _addHostListener = addHostListener,
       _removeHostListener = removeHostListener,
       _sendPrompt = sendPrompt,
       _stopAgent = stopAgent,
       _readLatestReply = readLatestReply,
       _agentStatus = agentStatus,
       _isSessionBusy = isSessionBusy {
    _inbox = ChannelInbox(preferences: preferences);
    _outbox = ChannelOutbox(preferences: preferences);
  }

  static const tokenKeyPrefix = 'oc.telegramBot.token.';
  static const enabledKeyPrefix = 'oc.telegramBot.enabled.';
  static const chatIDKeyPrefix = 'oc.telegramBot.chat.';
  static const sessionIDKeyPrefix = 'oc.telegramBot.session.';
  static const directoryKeyPrefix = 'oc.telegramBot.directory.';
  static const workspaceKeyPrefix = 'oc.telegramBot.workspace.';
  static const _offsetPrefix = 'oc.telegramBot.offset.';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;
  final Stream<EventEnvelope> _events;
  final String? Function() _profileID;
  final String? Function() _directory;
  final String? Function() _workspace;
  final bool Function() _supported;
  final void Function(VoidCallback listener) _addHostListener;
  final void Function(VoidCallback listener) _removeHostListener;
  final Future<String> Function(String text) _sendPrompt;
  final Future<void> Function() _stopAgent;
  final Future<String?> Function() _readLatestReply;
  final String Function() _agentStatus;
  final bool Function(String sessionID) _isSessionBusy;

  late final ChannelInbox _inbox;
  late final ChannelOutbox _outbox;

  StreamSubscription<EventEnvelope>? _eventSubscription;
  TelegramProvider? _provider;
  ChannelConversationEngine? _engine;
  ChannelSessionBinding? _binding;

  String? _ownerID;
  String? _token;
  String _chatID = '';
  String? _sessionID;
  String? _sessionDirectory;
  String? _sessionWorkspace;
  bool _enabled = false;
  bool _disposed = false;
  bool? _supportedAtLoad;
  int _loadGeneration = 0;
  Future<void>? _initializing;

  TelegramBotSnapshot get snapshot => TelegramBotSnapshot(
    profileID: _ownerID,
    chatID: _chatID,
    sessionID: _sessionID,
    enabled: _enabled,
    hasToken: _token != null,
    phase: _phase,
    lastError: _provider?.status.lastError,
  );

  /// The engine behind the facade, exposed for diagnostics and tests that need
  /// to see the shared pipeline rather than the transport.
  ChannelConversationEngine? get engine => _engine;

  TelegramBotPhase get _phase {
    if (!_enabled) return TelegramBotPhase.disabled;
    if (!_supported() || _token == null || _chatID.isEmpty) {
      return TelegramBotPhase.needsSetup;
    }
    return switch (_provider?.status.state) {
      null || ProviderState.connecting => TelegramBotPhase.starting,
      ProviderState.online => TelegramBotPhase.polling,
      ProviderState.reconnecting ||
      ProviderState.error => TelegramBotPhase.error,
      ProviderState.needsSetup => TelegramBotPhase.needsSetup,
      ProviderState.disabled ||
      ProviderState.closed => TelegramBotPhase.starting,
    };
  }

  Future<void> initialize() => _initializing ??= _doInitialize();

  Future<void> _doInitialize() async {
    if (_disposed) return;
    _eventSubscription ??= _events.listen(_onEvent);
    _addHostListener(_hostChanged);
    await _loadCurrentProfile();
  }

  void _hostChanged() {
    final next = _profileID();
    if (next == _ownerID && _supported() == _supportedAtLoad) return;
    unawaited(_loadCurrentProfile());
  }

  String _profileKey(String prefix, String profileID) => '$prefix$profileID';

  bool get _canPoll =>
      !_disposed &&
      _enabled &&
      _token != null &&
      _chatID.isNotEmpty &&
      _ownerID != null &&
      _supported();

  Future<void> _teardownChannel() async {
    final engine = _engine;
    final provider = _provider;
    _engine = null;
    _provider = null;
    await engine?.stop();
    await provider?.dispose();
  }

  Future<void> _loadCurrentProfile() async {
    final generation = ++_loadGeneration;
    await _teardownChannel();
    if (generation != _loadGeneration || _disposed) return;
    final owner = _profileID();
    _ownerID = owner;
    _supportedAtLoad = _supported();
    _chatID = '';
    _sessionID = null;
    _sessionDirectory = null;
    _sessionWorkspace = null;
    _binding = null;
    _token = null;
    _enabled = false;
    if (owner != null && owner.isNotEmpty) {
      try {
        _token = await _secureStorage.read(
          key: _profileKey(tokenKeyPrefix, owner),
        );
        if (_token?.isNotEmpty == true) KitRedact.registerKnownSecret(_token!);
        _chatID =
            _preferences.getString(_profileKey(chatIDKeyPrefix, owner)) ?? '';
        _sessionID = _preferences.getString(
          _profileKey(sessionIDKeyPrefix, owner),
        );
        _sessionDirectory = _preferences.getString(
          _profileKey(directoryKeyPrefix, owner),
        );
        _sessionWorkspace = _preferences.getString(
          _profileKey(workspaceKeyPrefix, owner),
        );
        _enabled =
            _preferences.getBool(_profileKey(enabledKeyPrefix, owner)) ?? false;
        if (_sessionID != null && _sessionID!.isNotEmpty) {
          _binding = ChannelSessionBinding(
            sessionID: _sessionID!,
            directory: _sessionDirectory ?? '',
            workspace: _sessionWorkspace ?? '',
          );
        }
        if (generation != _loadGeneration || _disposed) return;
      } catch (_) {
        _notify();
        return;
      }
    }
    _notify();
    if (_canPoll) await _startChannel(generation);
  }

  Future<void> _startChannel(int generation) async {
    final owner = _ownerID;
    final token = _token;
    if (owner == null || token == null) return;
    final provider = TelegramProvider(
      accountId: owner,
      token: token,
      chatId: _chatID,
      apiOrigin: () => telegramApiOrigin,
    )..offset = _preferences.getInt(_profileKey(_offsetPrefix, owner));
    final engine = ChannelConversationEngine(
      provider: provider,
      policy: ChannelPolicy(
        allowedUsers: {_chatID},
        allowDirectMessages: true,
        allowGroupMessages: false,
      ),
      agent: _TelegramAgentPort(this),
      inbox: _inbox,
      outbox: _outbox,
      conversationKeyOf: (_) => _conversationKey(owner),
      primaryConversation: _conversationKey(owner),
      workspaceId: owner,
      directory: () => _directory() ?? '',
      workspace: () => _workspace() ?? '',
      agentReady: () => _supported() && _token != null,
      copy: const ChannelEngineCopy(channelNoun: '机器人'),
      adoptViewedSession: true,
      onChanged: _notify,
    );
    engine.useSessionStores(
      (_) => CallbackChannelSessionStore(
        read: () => _binding,
        write: _writeBinding,
      ),
    );
    _provider = provider;
    _engine = engine;
    await engine.start();
    if (generation != _loadGeneration || _disposed) {
      await _teardownChannel();
      return;
    }
    await provider.connect();
  }

  ConversationKey _conversationKey(String owner) => ConversationKey(
    workspaceId: owner,
    providerId: ChannelProviderIds.telegram,
    accountId: owner,
    conversationType: ChannelConversationKind.direct,
    conversationId: _chatID.isEmpty ? 'pending' : _chatID,
    ownerActorId: _chatID.isEmpty ? 'pending' : _chatID,
  );

  /// Persists a binding with the same keys the relay has always used, so an
  /// existing installation keeps its conversation and the connection
  /// controller's prompt path keeps finding it.
  Future<void> _writeBinding(ChannelSessionBinding? binding) async {
    final owner = _ownerID;
    if (owner == null) return;
    _binding = binding;
    if (binding == null) {
      _sessionID = null;
      _sessionDirectory = null;
      _sessionWorkspace = null;
      await _preferences.remove(_profileKey(sessionIDKeyPrefix, owner));
      await _preferences.remove(_profileKey(directoryKeyPrefix, owner));
      await _preferences.remove(_profileKey(workspaceKeyPrefix, owner));
      return;
    }
    _sessionID = binding.sessionID;
    _sessionDirectory = binding.directory;
    _sessionWorkspace = binding.workspace;
    await _preferences.setString(
      _profileKey(sessionIDKeyPrefix, owner),
      binding.sessionID,
    );
    await _preferences.setString(
      _profileKey(directoryKeyPrefix, owner),
      binding.directory,
    );
    await _preferences.setString(
      _profileKey(workspaceKeyPrefix, owner),
      binding.workspace,
    );
  }

  Future<void> bindSession(String? sessionID) async {
    final engine = _engine;
    if (engine == null) {
      await _writeBinding(
        sessionID == null || sessionID.trim().isEmpty
            ? null
            : ChannelSessionBinding(
                sessionID: sessionID.trim(),
                directory: _directory() ?? '',
                workspace: _workspace() ?? '',
              ),
      );
      _notify();
      return;
    }
    await engine.bindSession(sessionID);
    _notify();
  }

  /// Saves a configuration. A null [token] keeps the existing secret; an
  /// empty string also means "leave the saved token unchanged".
  Future<void> saveConfiguration({
    required String chatID,
    required bool enabled,
    String? token,
  }) async {
    final owner = _profileID();
    if (owner == null || owner.isEmpty) {
      throw const FormatException('Select the phone OpenCode server first.');
    }
    final normalizedChatID = chatID.trim();
    final validChatID = RegExp(
      r'^[1-9][0-9]{0,19}$',
    ).hasMatch(normalizedChatID);
    if (enabled && !validChatID) {
      throw const FormatException('Enter a positive numeric Telegram user ID.');
    }
    final newToken = token?.trim();
    if (newToken != null && newToken.isNotEmpty) {
      if (!RegExp(r'^[0-9]{5,20}:[A-Za-z0-9_-]{20,}$').hasMatch(newToken)) {
        throw const FormatException(
          'The Telegram bot token format is invalid.',
        );
      }
      await _secureStorage.write(
        key: _profileKey(tokenKeyPrefix, owner),
        value: newToken,
      );
      KitRedact.registerKnownSecret(newToken);
      if (newToken != _token) {
        await _preferences.remove(_profileKey(_offsetPrefix, owner));
      }
    }
    final existingToken = newToken?.isNotEmpty == true
        ? newToken
        : await _secureStorage.read(key: _profileKey(tokenKeyPrefix, owner));
    if (enabled && (existingToken == null || existingToken.isEmpty)) {
      throw const FormatException('Add the bot token before enabling the bot.');
    }
    if (validChatID &&
        !await _preferences.setString(
          _profileKey(chatIDKeyPrefix, owner),
          normalizedChatID,
        )) {
      throw const FormatException('Could not save the Telegram chat ID.');
    }
    if (!await _preferences.setBool(
      _profileKey(enabledKeyPrefix, owner),
      enabled,
    )) {
      throw const FormatException('Could not save the Telegram setting.');
    }
    await _loadCurrentProfile();
  }

  Future<void> clearToken() async {
    final owner = _profileID();
    if (owner == null) return;
    await _preferences.setBool(_profileKey(enabledKeyPrefix, owner), false);
    await _secureStorage.delete(key: _profileKey(tokenKeyPrefix, owner));
    await _loadCurrentProfile();
  }

  Future<void> clearConfiguration() async {
    final owner = _profileID();
    if (owner == null) return;
    await _preferences.setBool(_profileKey(enabledKeyPrefix, owner), false);
    await _preferences.remove(_profileKey(chatIDKeyPrefix, owner));
    await _preferences.remove(_profileKey(sessionIDKeyPrefix, owner));
    await _preferences.remove(_profileKey(directoryKeyPrefix, owner));
    await _preferences.remove(_profileKey(workspaceKeyPrefix, owner));
    await _preferences.remove(_profileKey(_offsetPrefix, owner));
    await _secureStorage.delete(key: _profileKey(tokenKeyPrefix, owner));
    await _inbox.clear(ChannelProviderIds.telegram, owner);
    await _outbox.clear(ChannelProviderIds.telegram, owner);
    await _loadCurrentProfile();
  }

  /// Verifies the credential and whether the owner can be written to.
  ///
  /// Returns a notice for the settings page. A missing private chat is not an
  /// error: Telegram forbids a bot from writing first, so the relay can still
  /// be enabled and starts working the moment the owner sends `/start`.
  Future<String> testConnection({
    String? replacementToken,
    String? chatID,
  }) async {
    final owner = _profileID();
    if (owner == null) {
      throw const FormatException('No server profile selected.');
    }
    final token = replacementToken?.trim().isNotEmpty == true
        ? replacementToken!.trim()
        : await _secureStorage.read(key: _profileKey(tokenKeyPrefix, owner));
    final chat = chatID?.trim().isNotEmpty == true
        ? chatID!.trim()
        : _preferences.getString(_profileKey(chatIDKeyPrefix, owner)) ??
              _chatID;
    if (token == null || token.isEmpty || chat.isEmpty) {
      throw const FormatException(
        'Save a bot token and Telegram user ID first.',
      );
    }
    final probe = TelegramProvider(
      accountId: owner,
      token: token,
      chatId: chat,
      apiOrigin: () => telegramApiOrigin,
    );
    try {
      return await probe.probe();
    } finally {
      await probe.dispose();
    }
  }

  void _onEvent(EventEnvelope event) {
    _engine?.handleAgentEvent(event);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _removeHostListener(_hostChanged);
    unawaited(_eventSubscription?.cancel());
    unawaited(_teardownChannel());
    unawaited(_outbox.dispose());
    super.dispose();
  }
}

/// The narrow door from the Telegram channel into the agent.
class _TelegramAgentPort extends ChannelAgentPort {
  _TelegramAgentPort(this._bridge);

  final TelegramBotBridge _bridge;

  @override
  Future<String> sendPrompt(ChannelPromptRequest request) =>
      _bridge._sendPrompt(request.text);

  @override
  Future<void> stopTask(String? sessionID) => _bridge._stopAgent();

  @override
  Future<String?> latestReply(String sessionID) => _bridge._readLatestReply();

  @override
  String statusText() => _bridge._agentStatus();

  @override
  bool isBusy(String sessionID) => _bridge._isSessionBusy(sessionID);
}
