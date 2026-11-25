import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'channel_message.dart';
import 'channel_text.dart';

/// Durable record of which inbound messages have already been handled.
///
/// The only job is to make "the platform redelivered this event" not mean "run
/// the agent twice". The key is scoped by account and conversation, so two
/// bots that both see message id 42 do not shadow each other, and the same
/// person writing the same sentence twice in two groups is two messages.
class ChannelInbox {
  ChannelInbox({required SharedPreferences preferences, this.capacity = 400})
    : _preferences = preferences;

  static const _keyPrefix = 'oc.channels.inbox.';

  final SharedPreferences _preferences;

  /// How many keys are remembered per account. A window, not a history: the
  /// guarantee is "a redelivery inside this many messages", stated in the
  /// reliability notes rather than sold as exactly-once.
  final int capacity;

  final Map<String, _InboxWindow> _windows = {};

  /// Serialises window creation and persistence: two channels admitting at the
  /// same moment used to be able to build two windows for one account and lose
  /// the first one's keys.
  Future<void> _lock = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  String _storageKey(String providerId, String accountId) =>
      '$_keyPrefix$providerId.$accountId';

  /// Returns true when this message is new and should be processed.
  Future<bool> admit(ChannelMessage message) => _locked(() async {
    final window = await _windowFor(message.providerId, message.accountId);
    final key = keyFor(message);
    if (!window.add(key)) return false;
    await _persist(message.providerId, message.accountId, window);
    return true;
  });

  /// Whether [message] was already admitted. Does not record it.
  Future<bool> contains(ChannelMessage message) => _locked(() async {
    final window = await _windowFor(message.providerId, message.accountId);
    return window.contains(keyFor(message));
  });

  /// The dedupe key. Platforms with a stable message id use it directly;
  /// platforms without one fall back to a scoped, time-bucketed fingerprint.
  static String keyFor(ChannelMessage message) {
    final scope = '${message.conversationType.name}:${message.conversationId}';
    if (message.messageId.isNotEmpty) return '$scope#${message.messageId}';
    return '$scope#fp:${messageFingerprint(conversationId: message.conversationId, senderId: message.senderId, text: message.promptText, receivedAt: message.receivedAt)}';
  }

  Future<_InboxWindow> _windowFor(String providerId, String accountId) async {
    final cacheKey = '$providerId.$accountId';
    final cached = _windows[cacheKey];
    if (cached != null) return cached;
    final raw = _preferences.getString(_storageKey(providerId, accountId));
    final window = _InboxWindow(capacity);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is String) window.add(entry);
          }
        }
      } on FormatException {
        // A corrupt window only costs a possible duplicate; rebuilding it is
        // safer than refusing to start.
      }
    }
    _windows[cacheKey] = window;
    return window;
  }

  Future<void> _persist(
    String providerId,
    String accountId,
    _InboxWindow window,
  ) async {
    await _preferences.setString(
      _storageKey(providerId, accountId),
      jsonEncode(window.toList()),
    );
  }

  /// Forgets everything recorded for one account. Called when its
  /// configuration is deleted.
  Future<void> clear(String providerId, String accountId) => _locked(() async {
    _windows.remove('$providerId.$accountId');
    await _preferences.remove(_storageKey(providerId, accountId));
  });
}

class _InboxWindow {
  _InboxWindow(this.capacity);

  final int capacity;
  final List<String> _order = [];
  final Set<String> _keys = {};

  bool contains(String key) => _keys.contains(key);

  /// Returns false when the key was already present.
  bool add(String key) {
    if (!_keys.add(key)) return false;
    _order.add(key);
    while (_order.length > capacity) {
      final evicted = _order.removeAt(0);
      _keys.remove(evicted);
    }
    return true;
  }

  List<String> toList() => List<String>.unmodifiable(_order);
}
