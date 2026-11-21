import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';
import '../ui/kit/kit_redact.dart';

enum TelegramBotPhase { disabled, needsSetup, starting, polling, error }

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
List<String> telegramMessageChunks(String text) {
  const maxCodeUnits = 3500;
  final chunks = <String>[];
  final chunk = <int>[];
  var codeUnits = 0;
  for (final rune in text.runes) {
    final width = rune > 0xffff ? 2 : 1;
    if (codeUnits + width > maxCodeUnits && chunk.isNotEmpty) {
      chunks.add(String.fromCharCodes(chunk));
      chunk.clear();
      codeUnits = 0;
    }
    chunk.add(rune);
    codeUnits += width;
  }
  if (chunk.isNotEmpty) chunks.add(String.fromCharCodes(chunk));
  return List.unmodifiable(chunks);
}

@immutable
class TelegramBotSnapshot {
  const TelegramBotSnapshot({
    required this.profileID,
    required this.chatID,
    required this.sessionID,
    required this.enabled,
    required this.hasToken,
    required this.phase,
  });

  final String? profileID;
  final String chatID;
  final String? sessionID;
  final bool enabled;
  final bool hasToken;
  final TelegramBotPhase phase;

  bool get configured => hasToken && chatID.isNotEmpty;
}

/// A Telegram long-poll bridge bound to one saved OpenCode profile.
///
/// Bot credentials stay in Android secure storage. Incoming Telegram text is
/// sent as an ordinary agent prompt; this bridge never approves permissions
/// or executes a shell command itself.
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
       _isSessionBusy = isSessionBusy;

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
  final Future<void> Function(String text) _sendPrompt;
  final Future<void> Function() _stopAgent;
  final Future<String?> Function() _readLatestReply;
  final String Function() _agentStatus;
  final bool Function(String sessionID) _isSessionBusy;

  StreamSubscription<EventEnvelope>? _eventSubscription;
  String? _ownerID;
  String? _token;
  String _chatID = '';
  String? _sessionID;
  String? _sessionDirectory;
  String? _sessionWorkspace;
  bool _enabled = false;
  bool _disposed = false;
  bool _polling = false;
  int _pollGeneration = 0;
  int? _offset;
  bool _sessionRunning = false;
  String? _lastSentAssistantText;
  bool? _supportedAtLoad;
  int _loadGeneration = 0;
  DateTime? _lastProgress;
  HttpClient? _http;
  Future<void>? _initializing;
  int _consecutiveFailures = 0;
  TelegramBotPhase _phase = TelegramBotPhase.needsSetup;

  TelegramBotSnapshot get snapshot => TelegramBotSnapshot(
    profileID: _ownerID,
    chatID: _chatID,
    sessionID: _sessionID,
    enabled: _enabled,
    hasToken: _token != null,
    phase: _phase,
  );

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

  Future<void> _stopPolling() async {
    _polling = false;
    _pollGeneration++;
    _http?.close(force: true);
    _http = null;
  }

  Future<void> _loadCurrentProfile() async {
    final generation = ++_loadGeneration;
    await _stopPolling();
    if (generation != _loadGeneration || _disposed) return;
    final owner = _profileID();
    _ownerID = owner;
    _supportedAtLoad = _supported();
    _lastProgress = null;
    _chatID = '';
    _sessionID = null;
    _sessionDirectory = null;
    _sessionWorkspace = null;
    _sessionRunning = false;
    _lastSentAssistantText = null;
    _token = null;
    _enabled = false;
    _offset = null;
    if (owner != null && owner.isNotEmpty) {
      try {
        _token = await _secureStorage.read(key: _profileKey(tokenKeyPrefix, owner));
        if (_token?.isNotEmpty == true) KitRedact.registerKnownSecret(_token!);
        _chatID = _preferences.getString(_profileKey(chatIDKeyPrefix, owner)) ?? '';
        _sessionID = _preferences.getString(_profileKey(sessionIDKeyPrefix, owner));
        _sessionDirectory = _preferences.getString(
          _profileKey(directoryKeyPrefix, owner),
        );
        _sessionWorkspace = _preferences.getString(
          _profileKey(workspaceKeyPrefix, owner),
        );
        _enabled = _preferences.getBool(_profileKey(enabledKeyPrefix, owner)) ?? false;
        _offset = _preferences.getInt(_profileKey(_offsetPrefix, owner));
        if (generation != _loadGeneration || _disposed) return;
      } catch (_) {
        _phase = TelegramBotPhase.error;
        _notify();
        return;
      }
    }
    _phase = !_enabled
        ? TelegramBotPhase.disabled
        : (!_supported() || _token == null || _chatID.isEmpty)
        ? TelegramBotPhase.needsSetup
        : TelegramBotPhase.starting;
    _notify();
    if (_canPoll) unawaited(_pollLoop(owner!, _token!, _chatID));
  }

  Future<void> bindSession(String? sessionID) async {
    final owner = _profileID();
    if (owner == null) return;
    final normalized = sessionID?.trim();
    final nextSessionID = normalized == null || normalized.isEmpty
        ? null
        : normalized;
    if (nextSessionID != _sessionID) {
      _lastSentAssistantText = null;
      _sessionRunning = false;
    }
    if (normalized == null || normalized.isEmpty) {
      _sessionID = null;
      _sessionDirectory = null;
      _sessionWorkspace = null;
      await _preferences.remove(_profileKey(sessionIDKeyPrefix, owner));
      await _preferences.remove(_profileKey(directoryKeyPrefix, owner));
      await _preferences.remove(_profileKey(workspaceKeyPrefix, owner));
    } else {
      final directory = _directory() ?? '';
      final workspace = _workspace() ?? '';
      _sessionID = normalized;
      _sessionDirectory = directory;
      _sessionWorkspace = workspace;
      await _preferences.setString(_profileKey(sessionIDKeyPrefix, owner), normalized);
      await _preferences.setString(_profileKey(directoryKeyPrefix, owner), directory);
      await _preferences.setString(_profileKey(workspaceKeyPrefix, owner), workspace);
      if (!_sessionRunning && _isSessionBusy(normalized)) {
        _sessionRunning = true;
        _lastSentAssistantText = null;
        unawaited(_sendToAllowed('本地 Agent 已开始处理任务。'));
      }
    }
    _notify();
  }

  bool get _canPoll =>
      !_disposed &&
      _enabled &&
      _token != null &&
      _chatID.isNotEmpty &&
      _ownerID != null &&
      _supported();

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
    final validChatID = RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(normalizedChatID);
    if (enabled && !validChatID) {
      throw const FormatException('Enter a positive numeric Telegram user ID.');
    }
    final newToken = token?.trim();
    if (newToken != null && newToken.isNotEmpty) {
      if (!RegExp(r'^[0-9]{5,20}:[A-Za-z0-9_-]{20,}$').hasMatch(newToken)) {
        throw const FormatException('The Telegram bot token format is invalid.');
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
    if (!await _preferences.setBool(_profileKey(enabledKeyPrefix, owner), enabled)) {
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
    await _loadCurrentProfile();
  }

  Future<void> testConnection({String? replacementToken, String? chatID}) async {
    final owner = _profileID();
    if (owner == null) throw const FormatException('No server profile selected.');
    final token = replacementToken?.trim().isNotEmpty == true
        ? replacementToken!.trim()
        : await _secureStorage.read(key: _profileKey(tokenKeyPrefix, owner));
    final chat = chatID?.trim().isNotEmpty == true
        ? chatID!.trim()
        : _preferences.getString(_profileKey(chatIDKeyPrefix, owner)) ?? _chatID;
    if (token == null || token.isEmpty || chat.isEmpty) {
      throw const FormatException('Save a bot token and Telegram user ID first.');
    }
    final me = await _request(token, 'getMe', const {}, timeout: const Duration(seconds: 12));
    if (me['ok'] != true) throw const FormatException('Telegram could not verify this bot token.');
    // The owner must start the bot first; Telegram does not allow a bot to
    // initiate a private conversation. getMe verifies the credential without
    // sending an unsolicited message.
  }

  Future<void> _pollLoop(String owner, String token, String chatID) async {
    _polling = true;
    final generation = _pollGeneration;
    _phase = TelegramBotPhase.starting;
    _notify();
    while (!_disposed &&
        generation == _pollGeneration &&
        _polling &&
        _ownerID == owner &&
        _token == token &&
        _chatID == chatID &&
        _supported()) {
      final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      _http = http;
      try {
        final query = <String, String>{
          'timeout': '25',
          'allowed_updates': '["message"]',
          if (_offset != null) 'offset': '$_offset',
        };
        final result = await _request(
          token,
          'getUpdates',
          query,
          get: true,
          timeout: const Duration(seconds: 35),
          client: http,
        );
        if (!_polling || generation != _pollGeneration || _ownerID != owner) {
          break;
        }
        if (result['ok'] != true || result['result'] is! List) {
          throw const _TelegramFailure();
        }
        if (_phase != TelegramBotPhase.polling) {
          _phase = TelegramBotPhase.polling;
          _notify();
        }
        _consecutiveFailures = 0;
        for (final raw in result['result'] as List) {
          if (raw is! Map || raw['update_id'] is! int) continue;
          final updateID = raw['update_id'] as int;
          // Advance before dispatch: a process death cannot replay an agent
          // prompt whose delivery to OpenCode may already have succeeded.
          _offset = updateID + 1;
          await _preferences.setInt(_profileKey(_offsetPrefix, owner), _offset!);
          await _handleUpdate(token, chatID, Map<String, dynamic>.from(raw));
        }
      } on Object {
        if (!_polling || generation != _pollGeneration || _disposed) break;
        _consecutiveFailures = (_consecutiveFailures + 1).clamp(1, 5);
        _phase = TelegramBotPhase.error;
        _notify();
        final seconds = 1 << _consecutiveFailures;
        await Future<void>.delayed(
          Duration(seconds: seconds.clamp(5, 60)),
        );
        if (!_polling || generation != _pollGeneration || _disposed) break;
        _phase = TelegramBotPhase.starting;
        _notify();
      } finally {
        if (identical(_http, http)) _http = null;
        http.close(force: true);
      }
    }
    if (generation == _pollGeneration) _polling = false;
    if (generation != _pollGeneration) return;
    if (!_disposed && _enabled) {
      _phase = _supported() ? TelegramBotPhase.starting : TelegramBotPhase.needsSetup;
      _notify();
    }
  }

  Future<Map<String, dynamic>> _request(
    String token,
    String method,
    Map<String, dynamic> values, {
    bool get = false,
    Duration timeout = const Duration(seconds: 15),
    HttpClient? client,
  }) async {
    final http = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));
    final ownsClient = client == null;
    try {
      final uri = Uri.https(
        'api.telegram.org',
        '/bot$token/$method',
        get ? {for (final entry in values.entries) entry.key: '${entry.value}'} : null,
      );
      final request = get
          ? await http.getUrl(uri).timeout(const Duration(seconds: 12))
          : await http.postUrl(uri).timeout(const Duration(seconds: 12));
      request.followRedirects = false;
      if (!get) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(values));
      }
      final httpResponse = await request.close().timeout(timeout);
      final body = await httpResponse.transform(utf8.decoder).join().timeout(timeout);
      if (httpResponse.statusCode != HttpStatus.ok) throw const _TelegramFailure();
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const _TelegramFailure();
      final payload = Map<String, dynamic>.from(decoded);
      if (payload['ok'] != true) throw const _TelegramFailure();
      return payload;
    } on Object {
      throw const _TelegramFailure();
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  Future<void> _handleUpdate(
    String token,
    String allowedID,
    Map<String, dynamic> update,
  ) async {
    final message = update['message'];
    if (message is! Map || message['chat'] is! Map || message['from'] is! Map) return;
    final chat = message['chat'] as Map;
    final from = message['from'] as Map;
    if (!telegramPrivateMessageAllowed(
      allowedUserID: allowedID,
      chatType: chat['type'],
      senderID: from['id'],
      chatID: chat['id'],
      senderIsBot: from['is_bot'] == true,
    )) {
      return;
    }
    final rawText = message['text'];
    if (rawText is! String || rawText.trim().isEmpty) {
      await _sendTelegram(token, allowedID, '目前只支持文字消息。');
      return;
    }
    final text = rawText.trim();
    final command = text.split(RegExp(r'\s+')).first.split('@').first.toLowerCase();
    switch (command) {
      case '/start' || '/help':
        await _sendTelegram(
          token,
          allowedID,
          '已连接到 OpenCode Plus。直接发送文字即可作为 Agent 指令。\n'
          '/status 查看连接状态 · /stop 停止当前任务 · /new 开始新会话。其他文字（含自定义斜杠指令）会发送给 Agent。',
        );
        return;
      case '/status':
        await _sendTelegram(token, allowedID, _agentStatus());
        return;
      case '/stop':
        try {
          await _stopAgent();
          await _sendTelegram(token, allowedID, '已请求停止当前 Agent 任务。');
        } on Object {
          await _sendTelegram(token, allowedID, '无法停止任务；请检查 App 与本机 Agent 连接。');
        }
        return;
      case '/new':
        await bindSession(null);
        _sessionRunning = false;
        _lastSentAssistantText = null;
        await _sendTelegram(token, allowedID, '下条消息将开始一个新的 Agent 会话；已有任务不会被取消。');
        return;
      default:
        try {
          final sessionID = await _sendPrompt(text);
          if (sessionID != _sessionID) await bindSession(sessionID);
          await _sendTelegram(token, allowedID, '已转发给本地 Agent。');
        } on Object {
          await _sendTelegram(
            token,
            allowedID,
            '没有发送成功。请确认 App 已连接到本机 OpenCode、已打开项目，并检查是否有待处理的权限确认。',
          );
        }
        return;
    }
  }

  void _onEvent(EventEnvelope event) {
    final props = event.properties;
    final owner = _ownerID;
    if (owner == null || !_enabled || !_supported()) return;
    if ((event.directory != null &&
            event.directory!.trim() != (_directory() ?? '').trim()) ||
        (event.workspace != null &&
            event.workspace!.trim() != (_workspace() ?? '').trim())) {
      return;
    }
    if (event.type == 'session.viewed') {
      final viewedID = props['sessionID']?.toString();
      if (viewedID != null && viewedID.isNotEmpty) {
        unawaited(_bindViewedSession(viewedID));
      }
      return;
    }
    final sessionID = _sessionID;
    if (_sessionDirectory != (_directory() ?? '') ||
        _sessionWorkspace != (_workspace() ?? '')) {
      return;
    }
    if (sessionID == null || props['sessionID']?.toString() != sessionID) return;
    if (event.type == 'session.status') {
      final status = props['status'];
      final type = status is Map ? status['type']?.toString() : status?.toString();
      if (type == 'busy') {
        if (!_sessionRunning) {
          _sessionRunning = true;
          _lastSentAssistantText = null;
          unawaited(_sendToAllowed('本地 Agent 已开始处理任务。'));
        }
      } else if (type == 'idle') {
        if (_sessionRunning) unawaited(_sendCompletedReply());
      }
    } else if (event.type == 'session.idle') {
      if (_sessionRunning) unawaited(_sendCompletedReply());
    } else if (event.type == 'message.part.updated') {
      final part = props['part'];
      if (part is! Map || part['type'] != 'tool') return;
      final state = part['state'];
      if (state is! Map || state['status'] != 'running') return;
      final now = DateTime.now();
      if (_lastProgress != null && now.difference(_lastProgress!) < const Duration(seconds: 25)) return;
      _lastProgress = now;
      final rawTool = part['tool']?.toString() ?? '';
      final tool = RegExp(r'^[a-zA-Z0-9_-]{1,32}$').hasMatch(rawTool) ? rawTool : '工具';
      unawaited(_sendToAllowed('Agent 进度：正在使用 $tool。'));
    } else if (event.type == 'message.updated') {
      final info = props['info'];
      final time = info is Map ? info['time'] : null;
      if (info is Map &&
          info['role'] == 'assistant' &&
          time is Map &&
          (time['completed'] != null || time['end'] != null) &&
          _sessionRunning) {
        unawaited(_sendAssistantMilestone());
      }
    } else if (event.type == 'session.error') {
      _sessionRunning = false;
      unawaited(_sendToAllowed('本地 Agent 遇到错误，请在 OpenCode Plus 中查看详情。'));
    } else if (event.type == 'permission.asked' ||
        event.type == 'permission.v2.asked' ||
        event.type == 'question.asked' ||
        event.type == 'question.v2.asked') {
      unawaited(
        _sendToAllowed(
          'Agent 正在等待权限或问题确认。请在 OpenCode Plus 应用中查看并处理；Telegram 不会自动批准。',
        ),
      );
    }
  }

  Future<void> _bindViewedSession(String sessionID) async {
    try {
      await bindSession(sessionID);
    } on Object {
      return;
    }
    if (_isSessionBusy(sessionID) && !_sessionRunning) {
      _sessionRunning = true;
      _lastSentAssistantText = null;
      await _sendToAllowed('本地 Agent 已开始处理任务。');
    }
  }

  Future<void> _sendCompletedReply() async {
    if (!_sessionRunning) return;
    final sessionID = _sessionID;
    _sessionRunning = false;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!_canPoll ||
        _sessionRunning ||
        sessionID == null ||
        _sessionID != sessionID ||
        _sessionDirectory != (_directory() ?? '') ||
        _sessionWorkspace != (_workspace() ?? '')) {
      return;
    }
    String? reply;
    try {
      reply = await _readLatestReply();
    } on Object {
      reply = null;
    }
    if (_sessionRunning || _sessionID != sessionID) return;
    if (reply == null || reply.trim().isEmpty) {
      await _sendToAllowed('Agent 已结束，但没有可显示的文字回复。');
      return;
    }
    final text = reply.trim();
    if (text == _lastSentAssistantText) return;
    _lastSentAssistantText = text;
    await _sendToAllowed(text);
  }

  Future<void> _sendAssistantMilestone() async {
    final sessionID = _sessionID;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!_canPoll ||
        !_sessionRunning ||
        sessionID == null ||
        _sessionID != sessionID) {
      return;
    }
    String? reply;
    try {
      reply = await _readLatestReply();
    } on Object {
      return;
    }
    if (!_sessionRunning || _sessionID != sessionID) return;
    final text = reply?.trim() ?? '';
    if (text.isEmpty || text == _lastSentAssistantText) return;
    _lastSentAssistantText = text;
    await _sendToAllowed('Agent 更新：\n$text');
  }

  Future<void> _sendToAllowed(String text) async {
    final token = _token;
    final chatID = _chatID;
    if (token == null || chatID.isEmpty || !_canPoll) return;
    try {
      await _sendTelegram(token, chatID, text);
    } on Object {
      _phase = TelegramBotPhase.error;
      _notify();
    }
  }

  Future<void> _sendTelegram(String token, String chatID, String text) async {
    for (final chunk in telegramMessageChunks(text)) {
      await _request(token, 'sendMessage', {
        'chat_id': chatID,
        'text': chunk,
        'disable_web_page_preview': true,
      });
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _removeHostListener(_hostChanged);
    unawaited(_eventSubscription?.cancel());
    unawaited(_stopPolling());
    super.dispose();
  }
}

class _TelegramFailure implements Exception {
  const _TelegramFailure();
}
