import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
import '../channels/channel_tasks.dart';
import '../channels/channel_text.dart';
import '../channels/providers/telegram_provider.dart';
import '../domain/models.dart';
import '../ui/kit/kit_redact.dart';

enum TelegramBotPhase { disabled, needsSetup, starting, polling, error }

class _PairingAttempt {
  _PairingAttempt(this.profileID);

  final String profileID;
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  Uri? link;
  Timer? timer;
  bool committing = false;

  void close() {
    timer?.cancel();
    client.close(force: true);
  }
}

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
    required ChannelAgentPort agent,
    ChannelInbox? inbox,
    ChannelOutbox? outbox,
    ChannelTaskLedger ledger = const NoopTaskLedger(),
    Duration replyRecoveryInterval = const Duration(seconds: 10),
    Duration pairingWindow = const Duration(minutes: 3),
  }) : _preferences = preferences,
       _secureStorage = secureStorage,
       _events = events,
       _profileID = profileID,
       _directory = directory,
       _workspace = workspace,
       _supported = supported,
       _addHostListener = addHostListener,
       _removeHostListener = removeHostListener,
       _agent = agent,
       _inbox = inbox ?? ChannelInbox(preferences: preferences),
       _outbox = outbox ?? ChannelOutbox(preferences: preferences),
       _ownsOutbox = outbox == null,
       _ledger = ledger,
       _replyRecoveryInterval = replyRecoveryInterval,
       _pairingWindow = pairingWindow;

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
  final ChannelAgentPort _agent;
  final ChannelInbox _inbox;
  final ChannelOutbox _outbox;
  final bool _ownsOutbox;
  final ChannelTaskLedger _ledger;
  final Duration _replyRecoveryInterval;
  final Duration _pairingWindow;

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
  _PairingAttempt? _pairing;
  String? _pairingError;
  bool _pairingSucceeded = false;

  Uri? get pairingLink => _pairing?.link;
  bool get isPairing => _pairing != null;
  bool get isSavingPairing => _pairing?.committing ?? false;
  String? get pairingError => _pairingError;
  bool get pairingSucceeded => _pairingSucceeded;

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
    if (_pairing != null && _pairing!.profileID != next) cancelPairing();
    if (next == _ownerID) {
      // A transient SSE disconnect is not a change of Telegram identity. Keep
      // the in-flight turns so they can be reconciled once SSE/REST is back.
      if (_engine != null || _supported() == _supportedAtLoad) return;
    }
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
        final token = await _secureStorage.read(
          key: _profileKey(tokenKeyPrefix, owner),
        );
        if (generation != _loadGeneration || _disposed) return;
        _token = token;
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
    final offsetKey = _profileKey(_offsetPrefix, owner);
    final provider = TelegramProvider(
      accountId: owner,
      token: token,
      chatId: _chatID,
      apiOrigin: () => telegramApiOrigin,
      onOffset: (offset) async {
        if (generation != _loadGeneration || _disposed) return;
        if (!await _preferences.setInt(offsetKey, offset)) {
          throw const TelegramFailure('无法保存 Telegram 接收位置。');
        }
      },
    )..offset = _preferences.getInt(offsetKey);
    final engine = ChannelConversationEngine(
      provider: provider,
      policy: ChannelPolicy(
        allowedUsers: {_chatID},
        allowDirectMessages: true,
        allowGroupMessages: false,
      ),
      agent: _agent,
      inbox: _inbox,
      outbox: _outbox,
      conversationKeyOf: (_) => _conversationKey(owner),
      primaryConversation: _conversationKey(owner),
      workspaceId: owner,
      directory: () => _directory() ?? '',
      workspace: () => _workspace() ?? '',
      agentReady: () =>
          _supported() &&
          generation == _loadGeneration &&
          owner == _profileID(),
      copy: const ChannelEngineCopy(
        channelNoun: '机器人',
        finishedEmpty: '任务已结束，但未能读取本轮文字回复。请在 OpenCode Plus 的会话中查看结果。',
      ),
      ledger: _ledger,
      replyRecoveryInterval: _replyRecoveryInterval,
      adoptViewedSession: true,
      onChanged: _notify,
    );
    engine.useSessionStores(
      (_) => CallbackChannelSessionStore(
        read: () => _binding,
        write: (binding) async {
          if (generation != _loadGeneration ||
              owner != _profileID() ||
              _disposed) {
            throw StateError('Telegram profile changed');
          }
          await _writeBinding(binding);
        },
      ),
    );
    _provider = provider;
    _engine = engine;
    await engine.start();
    if (generation != _loadGeneration || _disposed) {
      if (identical(_engine, engine)) {
        _engine = null;
        _provider = null;
      }
      await engine.shutdown();
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
  /// existing installation keeps its conversation across upgrades.
  Future<void> _writeBinding(ChannelSessionBinding? binding) async {
    final owner = _ownerID;
    if (owner == null || owner != _profileID() || _disposed) return;
    if (binding == null) {
      if (!await _preferences.remove(_profileKey(sessionIDKeyPrefix, owner)) ||
          !await _preferences.remove(_profileKey(directoryKeyPrefix, owner)) ||
          !await _preferences.remove(_profileKey(workspaceKeyPrefix, owner))) {
        throw StateError('Could not clear the Telegram session');
      }
    } else if (!await _preferences.setString(
          _profileKey(directoryKeyPrefix, owner),
          binding.directory,
        ) ||
        !await _preferences.setString(
          _profileKey(workspaceKeyPrefix, owner),
          binding.workspace,
        ) ||
        !await _preferences.setString(
          _profileKey(sessionIDKeyPrefix, owner),
          binding.sessionID,
        )) {
      throw StateError('Could not save the Telegram session');
    }
    if (owner != _ownerID || owner != _profileID() || _disposed) return;
    _binding = binding;
    _sessionID = binding?.sessionID;
    _sessionDirectory = binding?.directory;
    _sessionWorkspace = binding?.workspace;
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

  /// Learns the numeric chat ID only from this attempt's one-time /start.
  /// While waiting, no update is sent to OpenCode and no settings are written.
  Future<void> beginPairing({String? replacementToken}) async {
    if (_disposed || isPairing) return;
    final owner = _profileID();
    if (owner == null || owner.isEmpty) {
      throw const FormatException('请先选择本机 OpenCode 服务器。');
    }
    if (_preferences.getBool(_profileKey(enabledKeyPrefix, owner)) == true) {
      throw const FormatException('请先关闭并保存现有 Telegram 转发，再重新绑定。');
    }
    final attempt = _PairingAttempt(owner);
    _pairing = attempt;
    _pairingError = null;
    _pairingSucceeded = false;
    _notify();
    TelegramProvider? provider;
    try {
      await initialize();
      if (!_isCurrentPairing(attempt)) return;
      final replacement = replacementToken?.trim() ?? '';
      final tokenKey = _profileKey(tokenKeyPrefix, owner);
      final previousToken = await _secureStorage.read(key: tokenKey);
      if (!_isCurrentPairing(attempt)) return;
      final token = replacement.isEmpty ? previousToken ?? '' : replacement;
      _validateToken(token);
      KitRedact.registerKnownSecret(token);
      final transport = provider = TelegramProvider(
        accountId: owner,
        token: token,
        chatId: '',
        apiOrigin: () => telegramApiOrigin,
      );
      final username = await transport.pairingUsername(attempt.client);
      if (!_isCurrentPairing(attempt)) return;
      // Six random bytes fit in eight URL-safe characters (48 bits). The
      // credential never appears in the link or in the user's Telegram chat.
      final random = Random.secure();
      final code = base64UrlEncode(
        List.generate(6, (_) => random.nextInt(256)),
      );
      final expiry = DateTime.now().add(_pairingWindow);
      attempt.link = Uri.https('t.me', '/$username', {'start': code});
      attempt.timer = Timer(_pairingWindow, () => _expirePairing(attempt));
      _notify();
      var offset = previousToken == token
          ? _preferences.getInt(_profileKey(_offsetPrefix, owner))
          : null;
      while (_isCurrentPairing(attempt)) {
        final updates = await transport.readUpdates(
          client: attempt.client,
          wait: const Duration(seconds: 10),
          offset: offset,
        );
        if (!_isCurrentPairing(attempt)) return;
        if (!DateTime.now().isBefore(expiry)) {
          _expirePairing(attempt);
          return;
        }
        for (final (id, message) in updates) {
          if (offset != null && id < offset) continue;
          offset = id + 1;
          if (message == null ||
              (message.text.trim() != '/start $code' &&
                  message.text.trim() != '/start@$username $code') ||
              !telegramPrivateMessageAllowed(
                allowedUserID: message.senderId,
                chatType: message.extensions['chat_type'],
                senderID: message.senderId,
                chatID: message.conversationId,
                senderIsBot: message.extensions['sender_is_bot'] != false,
              )) {
            continue;
          }
          attempt
            ..link = null
            ..committing = true;
          attempt.close();
          _notify();
          // Remaining updates in this setup batch predate relay activation.
          await _savePairing(
            attempt,
            token,
            previousToken,
            message.senderId,
            updates.last.$1 + 1,
          );
          if (_isCurrentPairing(attempt)) {
            await _loadCurrentProfile();
            if (_isCurrentPairing(attempt)) _pairingSucceeded = true;
          }
          return;
        }
      }
    } on TelegramFailure catch (error) {
      if (_isCurrentPairing(attempt)) _pairingError = error.message;
    } on FormatException catch (error) {
      if (_isCurrentPairing(attempt)) _pairingError = error.message;
    } on Object {
      if (_isCurrentPairing(attempt)) _pairingError = '无法完成 Telegram 绑定，请重试。';
    } finally {
      attempt.close();
      await provider?.dispose();
      if (identical(_pairing, attempt)) {
        _pairing = null;
        _notify();
      }
    }
  }

  bool _isCurrentPairing(_PairingAttempt attempt) =>
      !_disposed &&
      identical(_pairing, attempt) &&
      _profileID() == attempt.profileID;

  void _expirePairing(_PairingAttempt attempt) {
    if (!_isCurrentPairing(attempt) || attempt.committing) return;
    _pairingError = 'Telegram 配对链接已过期，请重新生成。';
    cancelPairing();
  }

  void cancelPairing() {
    final attempt = _pairing;
    if (attempt == null || attempt.committing) return;
    _pairing = null;
    attempt.close();
    _notify();
  }

  static void _validateToken(String token) {
    if (!RegExp(r'^[0-9]{5,20}:[A-Za-z0-9_-]{20,}$').hasMatch(token)) {
      throw const FormatException('请填写有效的 Telegram Bot Token。');
    }
  }

  Future<void> _savePairing(
    _PairingAttempt attempt,
    String token,
    String? previousToken,
    String chatID,
    int offset,
  ) async {
    final owner = attempt.profileID;
    final chatKey = _profileKey(chatIDKeyPrefix, owner);
    if (token != previousToken || _preferences.getString(chatKey) != chatID) {
      await _clearIdentityState(owner);
    }
    if (!_isCurrentPairing(attempt)) return;
    await _secureStorage.write(
      key: _profileKey(tokenKeyPrefix, owner),
      value: token,
    );
    KitRedact.registerKnownSecret(token);
    if (!_isCurrentPairing(attempt)) return;
    if (!await _preferences.setInt(_profileKey(_offsetPrefix, owner), offset) ||
        !await _preferences.setString(chatKey, chatID)) {
      throw const FormatException('无法保存 Telegram 绑定，转发未启用。');
    }
    if (!_isCurrentPairing(attempt)) return;
    if (!await _preferences.setBool(
      _profileKey(enabledKeyPrefix, owner),
      true,
    )) {
      throw const FormatException('无法启用 Telegram 转发。');
    }
  }

  Future<void> _clearIdentityState(String owner) async {
    for (final prefix in [
      sessionIDKeyPrefix,
      directoryKeyPrefix,
      workspaceKeyPrefix,
      _offsetPrefix,
    ]) {
      if (!await _preferences.remove(_profileKey(prefix, owner))) {
        throw const FormatException('无法移除旧的 Telegram 会话绑定。');
      }
    }
    await _inbox.clear(ChannelProviderIds.telegram, owner);
    await _outbox.clear(ChannelProviderIds.telegram, owner);
    await _ledger.clear(ChannelProviderIds.telegram, owner);
  }

  /// Saves a configuration. A null [token] keeps the existing secret; an
  /// empty string also means "leave the saved token unchanged".
  Future<void> saveConfiguration({
    required String chatID,
    required bool enabled,
    String? token,
  }) async {
    if (isPairing) throw const FormatException('请先完成或取消 Telegram 配对。');
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
      _validateToken(newToken);
    }
    if ((newToken?.isNotEmpty == true && newToken != _token) ||
        (validChatID && normalizedChatID != _chatID)) {
      await _teardownChannel();
      if (!await _preferences.setBool(
        _profileKey(enabledKeyPrefix, owner),
        false,
      )) {
        throw const FormatException(
          'Could not disable the previous Telegram binding.',
        );
      }
      await _clearIdentityState(owner);
    }
    if (newToken != null && newToken.isNotEmpty) {
      await _secureStorage.write(
        key: _profileKey(tokenKeyPrefix, owner),
        value: newToken,
      );
      KitRedact.registerKnownSecret(newToken);
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
    cancelPairing();
    if (isPairing) return;
    final owner = _profileID();
    if (owner == null) return;
    await _teardownChannel();
    await _preferences.setBool(_profileKey(enabledKeyPrefix, owner), false);
    await _secureStorage.delete(key: _profileKey(tokenKeyPrefix, owner));
    await _loadCurrentProfile();
  }

  Future<void> clearConfiguration() async {
    cancelPairing();
    if (isPairing) return;
    final owner = _profileID();
    if (owner == null) return;
    await _teardownChannel();
    await _preferences.setBool(_profileKey(enabledKeyPrefix, owner), false);
    await _preferences.remove(_profileKey(chatIDKeyPrefix, owner));
    await _secureStorage.delete(key: _profileKey(tokenKeyPrefix, owner));
    await _clearIdentityState(owner);
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
    _validateToken(token);
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
    if (_ownerID == _profileID()) _engine?.handleAgentEvent(event);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pairing?.close();
    _pairing = null;
    _removeHostListener(_hostChanged);
    unawaited(_eventSubscription?.cancel());
    unawaited(_teardownChannel());
    if (_ownsOutbox) unawaited(_outbox.dispose());
    super.dispose();
  }
}
