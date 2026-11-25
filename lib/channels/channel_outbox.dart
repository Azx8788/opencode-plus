import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'channel_message.dart';
import 'channel_provider.dart';

/// The life of one outbound message.
///
/// `delivered` needs a receipt the platform actually confirmed. `accepted`
/// (a 200 from an asynchronous queue) is recorded as [delivered] only when the
/// provider says so; otherwise it stays [sending] until the provider answers.
enum OutboxStatus { planned, sending, delivered, deferred, failed, unknown }

/// One message waiting for, or finished with, the network.
class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.providerId,
    required this.accountId,
    required this.address,
    required this.text,
    required this.purpose,
    required this.status,
    required this.createdAt,
    this.taskId,
    this.attempts = 0,
    this.lastError,
    this.nextAttemptAt,
    this.platformMessageId,
  });

  final String id;
  final String providerId;
  final String accountId;
  final ChannelAddress address;
  final String text;
  final DeliveryPurpose purpose;
  final OutboxStatus status;
  final DateTime createdAt;
  final String? taskId;
  final int attempts;
  final String? lastError;
  final DateTime? nextAttemptAt;
  final String? platformMessageId;

  bool get isTerminal =>
      status == OutboxStatus.delivered ||
      status == OutboxStatus.failed ||
      status == OutboxStatus.unknown;

  OutboxEntry copyWith({
    OutboxStatus? status,
    int? attempts,
    String? lastError,
    DateTime? nextAttemptAt,
    String? platformMessageId,
    bool clearError = false,
  }) => OutboxEntry(
    id: id,
    providerId: providerId,
    accountId: accountId,
    address: address,
    text: text,
    purpose: purpose,
    status: status ?? this.status,
    createdAt: createdAt,
    taskId: taskId,
    attempts: attempts ?? this.attempts,
    lastError: clearError ? null : (lastError ?? this.lastError),
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    platformMessageId: platformMessageId ?? this.platformMessageId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'providerId': providerId,
    'accountId': accountId,
    'conversationId': address.conversationId,
    'conversationType': address.conversationType.name,
    'replyTo': address.replyToMessageId,
    'text': text,
    'purpose': purpose.name,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    if (taskId != null) 'taskId': taskId,
    'attempts': attempts,
    if (lastError != null) 'lastError': lastError,
    if (nextAttemptAt != null)
      'nextAttemptAt': nextAttemptAt!.toIso8601String(),
    if (platformMessageId != null) 'platformMessageId': platformMessageId,
  };

  static OutboxEntry? fromJson(Map<String, Object?> json) {
    final id = json['id']?.toString();
    final conversationId = json['conversationId']?.toString();
    if (id == null || id.isEmpty || conversationId == null) return null;
    final createdAt = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    final nextAttemptAt = DateTime.tryParse(
      json['nextAttemptAt']?.toString() ?? '',
    );
    return OutboxEntry(
      id: id,
      providerId: json['providerId']?.toString() ?? '',
      accountId: json['accountId']?.toString() ?? '',
      address: ChannelAddress(
        providerId: json['providerId']?.toString() ?? '',
        accountId: json['accountId']?.toString() ?? '',
        conversationId: conversationId,
        conversationType: ChannelConversationKind.values.firstWhere(
          (value) => value.name == json['conversationType'],
          orElse: () => ChannelConversationKind.unknown,
        ),
        replyToMessageId: json['replyTo']?.toString(),
      ),
      text: json['text']?.toString() ?? '',
      purpose: DeliveryPurpose.values.firstWhere(
        (value) => value.name == json['purpose'],
        orElse: () => DeliveryPurpose.notice,
      ),
      status: OutboxStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => OutboxStatus.failed,
      ),
      createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      taskId: json['taskId']?.toString(),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastError: json['lastError']?.toString(),
      nextAttemptAt: nextAttemptAt,
      platformMessageId: json['platformMessageId']?.toString(),
    );
  }
}

/// Durable queue of messages that must leave the app through a channel.
///
/// Persistence is a bounded JSON list in the same preferences store the rest
/// of the app uses: an outbox is a few dozen rows, and adding a database for
/// it would be a second source of truth to keep consistent.
///
/// Two rules the queue enforces rather than documents:
/// * a send failure never re-runs the agent — the entry is the unit of retry;
/// * an `unknown` result is never retried, because a duplicate answer in a
///   chat is worse than a missing one.
class ChannelOutbox {
  ChannelOutbox({
    required SharedPreferences preferences,
    this.capacity = 80,
    this.maxAttempts = 3,
    DateTime Function()? clock,
  }) : _preferences = preferences,
       _clock = clock ?? DateTime.now;

  static const _storageKey = 'oc.channels.outbox';

  final SharedPreferences _preferences;

  /// Entries kept on disk. Terminal entries are pruned first when it fills.
  final int capacity;

  /// Attempts before a retryable failure becomes a final one.
  final int maxAttempts;

  final DateTime Function() _clock;

  final _changes = StreamController<OutboxEntry>.broadcast();
  List<OutboxEntry>? _entries;
  int _sequence = 0;

  /// Serialises every read-modify-write. Two channels sending at the same time
  /// used to be able to overwrite each other's row: each read the queue, each
  /// wrote its own copy back, and the second write erased the first entry.
  Future<void> _lock = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Stream<OutboxEntry> get changes => _changes.stream;

  Future<List<OutboxEntry>> _load() async {
    final cached = _entries;
    if (cached != null) return cached;
    final raw = _preferences.getString(_storageKey);
    final loaded = <OutboxEntry>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map) {
              final parsed = OutboxEntry.fromJson(
                Map<String, Object?>.from(entry),
              );
              if (parsed != null) loaded.add(parsed);
            }
          }
        }
      } on FormatException {
        // Losing the queue costs at most a handful of unsent notices; refusing
        // to start would cost every channel.
      }
    }
    _entries = loaded;
    return loaded;
  }

  Future<void> _save(List<OutboxEntry> entries) async {
    _entries = entries;
    await _preferences.setString(
      _storageKey,
      jsonEncode([for (final entry in entries) entry.toJson()]),
    );
  }

  /// Queues a message and returns its entry in `planned`.
  Future<OutboxEntry> enqueue({
    required String providerId,
    required String accountId,
    required ChannelAddress address,
    required String text,
    required DeliveryPurpose purpose,
    String? taskId,
  }) => _locked(() async {
    final entries = List<OutboxEntry>.of(await _load());
    final entry = OutboxEntry(
      id: 'ob-${_clock().microsecondsSinceEpoch}-${_sequence++}',
      providerId: providerId,
      accountId: accountId,
      address: address,
      text: text,
      purpose: purpose,
      status: OutboxStatus.planned,
      createdAt: _clock(),
      taskId: taskId,
    );
    entries.add(entry);
    _trim(entries);
    await _save(entries);
    _emit(entry);
    return entry;
  });

  /// Records the attempt that is about to start. Returns the updated entry,
  /// or null when the entry is gone (a deleted account, a cleared queue).
  Future<OutboxEntry?> markSending(String id) =>
      _update(id, (entry) => entry.copyWith(status: OutboxStatus.sending));

  Future<OutboxEntry?> settle(String id, DeliveryReceipt receipt) =>
      _locked(() async {
        final entries = await _load();
        final index = entries.indexWhere((entry) => entry.id == id);
        if (index < 0) return null;
        final current = entries[index];
        final attempts = current.attempts + 1;
        final OutboxEntry next;
        switch (receipt.status) {
          case DeliveryStatus.delivered:
          case DeliveryStatus.accepted:
            next = current.copyWith(
              status: OutboxStatus.delivered,
              attempts: attempts,
              platformMessageId: receipt.messageId,
              clearError: true,
            );
          case DeliveryStatus.deferred:
            next = current.copyWith(
              status: OutboxStatus.deferred,
              attempts: attempts,
              lastError: receipt.error,
              nextAttemptAt: _clock().add(
                receipt.retryAfter ?? _backoffFor(attempts),
              ),
            );
          case DeliveryStatus.failed:
            final retryable = receipt.retryable && attempts < maxAttempts;
            next = retryable
                ? current.copyWith(
                    status: OutboxStatus.deferred,
                    attempts: attempts,
                    lastError: receipt.error,
                    nextAttemptAt: _clock().add(_backoffFor(attempts)),
                  )
                : current.copyWith(
                    status: OutboxStatus.failed,
                    attempts: attempts,
                    lastError: receipt.error,
                  );
          case DeliveryStatus.unknown:
            next = current.copyWith(
              status: OutboxStatus.unknown,
              attempts: attempts,
              lastError: receipt.error,
            );
        }
        entries[index] = next;
        await _save(entries);
        _emit(next);
        return next;
      });

  /// Entries of one account whose retry time has come.
  Future<List<OutboxEntry>> due(String providerId, String accountId) =>
      _locked(() async {
        final now = _clock();
        final entries = await _load();
        return [
          for (final entry in entries)
            if (entry.providerId == providerId &&
                entry.accountId == accountId &&
                entry.status == OutboxStatus.deferred &&
                (entry.nextAttemptAt == null ||
                    !entry.nextAttemptAt!.isAfter(now)) &&
                entry.attempts < maxAttempts)
              entry,
        ];
      });

  Future<List<OutboxEntry>> pendingFor(
    String providerId,
    String accountId,
  ) async => [
    for (final entry in await _load())
      if (entry.providerId == providerId && entry.accountId == accountId) entry,
  ];

  Future<void> clear(String providerId, String accountId) => _locked(() async {
    final entries = [
      for (final entry in await _load())
        if (entry.providerId != providerId || entry.accountId != accountId)
          entry,
    ];
    await _save(entries);
  });

  Future<void> dispose() => _changes.close();

  Duration _backoffFor(int attempts) =>
      Duration(seconds: (2 * attempts * attempts).clamp(2, 60));

  Future<OutboxEntry?> _update(
    String id,
    OutboxEntry Function(OutboxEntry entry) transform,
  ) => _locked(() async {
    final entries = await _load();
    final index = entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return null;
    final next = transform(entries[index]);
    entries[index] = next;
    await _save(entries);
    _emit(next);
    return next;
  });

  /// Keeps the queue bounded: finished entries go first, then the oldest.
  void _trim(List<OutboxEntry> entries) {
    while (entries.length > capacity) {
      final terminal = entries.indexWhere((entry) => entry.isTerminal);
      entries.removeAt(terminal >= 0 ? terminal : 0);
    }
  }

  void _emit(OutboxEntry entry) {
    if (!_changes.isClosed) _changes.add(entry);
  }
}
