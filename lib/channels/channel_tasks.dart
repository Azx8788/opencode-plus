/// Durable record of what the agent was asked to do and how it ended.
///
/// The engine used to keep this in memory, per conversation, and lose it on
/// restart: a task that finished while the app was closed left no trace, and
/// "the agent finished" and "the chat got the answer" were the same boolean.
/// They are two different facts here — [ChannelTaskStatus] is what the agent
/// did, [ChannelDeliveryStatus] is what the channel managed to say — and the
/// screen that lists tasks can show either one failing without the other
/// looking fine.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What the agent did with a request.
enum ChannelTaskStatus {
  /// Accepted from the channel, not yet submitted.
  created,

  /// Handed to the agent (`promptAsync` returned).
  submitted,

  /// Waiting behind another task of the same conversation.
  queued,

  /// The session is executing.
  running,

  /// The agent asked for a permission or an answer; only the app can give it.
  waitingPermission,

  /// The agent finished. [ChannelTaskRecord.result] holds what it said.
  completed,

  /// The agent reported an error.
  failed,

  /// `/stop`, or the channel was torn down while it ran.
  cancelled;

  bool get isOpen =>
      this == created ||
      this == submitted ||
      this == queued ||
      this == running ||
      this == waitingPermission;
}

/// What the channel managed to say about it.
enum ChannelDeliveryStatus {
  /// Nothing sent yet.
  pending,

  /// A send is on the wire.
  delivering,

  /// The platform confirmed it.
  delivered,

  /// The platform asked to wait, and a retry is scheduled.
  deferred,

  /// The platform refused it, or every retry failed.
  failed,

  /// The ack was lost. Not retried: a duplicate answer is worse than a
  /// missing one.
  unknown,
}

/// One task: a request, the session it ran in, and what became of it.
class ChannelTaskRecord {
  ChannelTaskRecord({
    required this.id,
    required this.providerId,
    required this.accountId,
    required this.conversationId,
    required this.userId,
    required this.prompt,
    required this.createdAt,
    this.workspaceId = '',
    this.conversationKey,
    this.sessionId,
    this.status = ChannelTaskStatus.created,
    this.delivery = ChannelDeliveryStatus.pending,
    this.result,
    this.error,
    this.startedAt,
    this.completedAt,
    this.deliveryAttempts = 0,
  });

  final String id;
  final String providerId;
  final String accountId;
  final String conversationId;
  final String userId;
  final String workspaceId;
  // Legacy rows lack the chat kind/thread and cannot be exposed to a model.
  final String? conversationKey;
  final String prompt;
  final DateTime createdAt;

  String? sessionId;
  ChannelTaskStatus status;
  ChannelDeliveryStatus delivery;
  String? result;
  String? error;
  DateTime? startedAt;
  DateTime? completedAt;
  int deliveryAttempts;

  /// A task whose answer never reached the chat. This is the case the old
  /// model could not express: the agent succeeded and the person heard
  /// nothing.
  bool get answeredButUndelivered =>
      status == ChannelTaskStatus.completed &&
      result != null &&
      result!.trim().isNotEmpty &&
      delivery != ChannelDeliveryStatus.delivered;

  Map<String, Object?> toJson() => {
    'id': id,
    'providerId': providerId,
    'accountId': accountId,
    'conversationId': conversationId,
    'userId': userId,
    'workspaceId': workspaceId,
    if (conversationKey != null) 'conversationKey': conversationKey,
    'prompt': prompt,
    'createdAt': createdAt.toIso8601String(),
    if (sessionId != null) 'sessionId': sessionId,
    'status': status.name,
    'delivery': delivery.name,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
    if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    'deliveryAttempts': deliveryAttempts,
  };

  static ChannelTaskRecord? fromJson(Map<String, Object?> json) {
    final id = json['id']?.toString();
    final prompt = json['prompt']?.toString();
    if (id == null || id.isEmpty || prompt == null) return null;
    return ChannelTaskRecord(
      id: id,
      providerId: json['providerId']?.toString() ?? '',
      accountId: json['accountId']?.toString() ?? '',
      conversationId: json['conversationId']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      workspaceId: json['workspaceId']?.toString() ?? '',
      conversationKey: json['conversationKey']?.toString(),
      prompt: prompt,
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      sessionId: json['sessionId']?.toString(),
      status: ChannelTaskStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => ChannelTaskStatus.failed,
      ),
      delivery: ChannelDeliveryStatus.values.firstWhere(
        (value) => value.name == json['delivery'],
        orElse: () => ChannelDeliveryStatus.pending,
      ),
      result: json['result']?.toString(),
      error: json['error']?.toString(),
      startedAt: DateTime.tryParse(json['startedAt']?.toString() ?? ''),
      completedAt: DateTime.tryParse(json['completedAt']?.toString() ?? ''),
      deliveryAttempts: (json['deliveryAttempts'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The legal moves of a task.
///
/// One table, checked in one place: the previous design let a `session.idle`
/// callback and a `/stop` command each write whatever they liked, so a
/// cancelled task could still be completed by an event that was already in
/// flight.
class ChannelTaskMachine {
  static const _allowed = <ChannelTaskStatus, Set<ChannelTaskStatus>>{
    ChannelTaskStatus.created: {
      ChannelTaskStatus.submitted,
      // A prompt can be accepted and start running before the record is
      // written; refusing that would leave the task stuck at "created".
      ChannelTaskStatus.running,
      ChannelTaskStatus.waitingPermission,
      ChannelTaskStatus.completed,
      ChannelTaskStatus.cancelled,
      ChannelTaskStatus.failed,
    },
    ChannelTaskStatus.submitted: {
      ChannelTaskStatus.running,
      ChannelTaskStatus.queued,
      ChannelTaskStatus.completed,
      ChannelTaskStatus.failed,
      ChannelTaskStatus.cancelled,
    },
    ChannelTaskStatus.queued: {
      ChannelTaskStatus.submitted,
      ChannelTaskStatus.running,
      ChannelTaskStatus.cancelled,
      ChannelTaskStatus.failed,
    },
    ChannelTaskStatus.running: {
      ChannelTaskStatus.waitingPermission,
      ChannelTaskStatus.running,
      ChannelTaskStatus.completed,
      ChannelTaskStatus.failed,
      ChannelTaskStatus.cancelled,
    },
    ChannelTaskStatus.waitingPermission: {
      ChannelTaskStatus.running,
      ChannelTaskStatus.completed,
      ChannelTaskStatus.failed,
      ChannelTaskStatus.cancelled,
    },
    // Terminal for the agent. Delivery moves separately.
    ChannelTaskStatus.completed: {},
    ChannelTaskStatus.failed: {},
    ChannelTaskStatus.cancelled: {},
  };

  static bool canMove(ChannelTaskStatus from, ChannelTaskStatus to) {
    if (from == to) return true;
    return _allowed[from]?.contains(to) ?? false;
  }

  /// Applies [to] when the table allows it. Returns false when the move was
  /// refused, which is a fact worth recording rather than swallowing.
  static bool move(ChannelTaskRecord record, ChannelTaskStatus to) {
    if (!canMove(record.status, to)) return false;
    record.status = to;
    return true;
  }
}

/// Where the engine records tasks. The default does nothing, so a channel that
/// has no store (and every test) keeps working.
abstract class ChannelTaskLedger {
  const ChannelTaskLedger();

  void record(ChannelTaskRecord record);

  void update(
    String taskId, {
    ChannelTaskStatus? status,
    ChannelDeliveryStatus? delivery,
    String? result,
    String? error,
    String? sessionId,
    int? deliveryAttempts,
    DateTime? at,
  });

  List<ChannelTaskRecord> recent({int limit = 50});

  Future<void> clear(String providerId, String accountId) async {}
}

class NoopTaskLedger extends ChannelTaskLedger {
  const NoopTaskLedger();

  @override
  void record(ChannelTaskRecord record) {}

  @override
  void update(
    String taskId, {
    ChannelTaskStatus? status,
    ChannelDeliveryStatus? delivery,
    String? result,
    String? error,
    String? sessionId,
    int? deliveryAttempts,
    DateTime? at,
  }) {}

  @override
  List<ChannelTaskRecord> recent({int limit = 50}) => const [];
}

/// Tasks kept in the same preferences store as the outbox.
///
/// Bounded on purpose: this is a window onto what happened, not an audit log,
/// and an unbounded list in a preferences string is a file that eventually
/// fails to parse.
class ChannelTaskStore extends ChannelTaskLedger {
  ChannelTaskStore({
    required SharedPreferences preferences,
    this.capacity = 120,
    DateTime Function()? clock,
  }) : _preferences = preferences,
       _clock = clock ?? DateTime.now;

  static const _storageKey = 'oc.channels.tasks';

  final SharedPreferences _preferences;
  final int capacity;
  final DateTime Function() _clock;

  List<ChannelTaskRecord>? _records;
  Future<void> _lock = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  List<ChannelTaskRecord> _load() {
    final cached = _records;
    if (cached != null) return cached;
    final raw = _preferences.getString(_storageKey);
    final loaded = <ChannelTaskRecord>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map) {
              final parsed = ChannelTaskRecord.fromJson(
                Map<String, Object?>.from(entry),
              );
              if (parsed != null) loaded.add(parsed);
            }
          }
        }
      } on FormatException {
        // A corrupt list costs the history, not the channel.
      }
    }
    _records = loaded;
    return loaded;
  }

  Future<void> _save() async {
    final records = _load();
    await _preferences.setString(
      _storageKey,
      jsonEncode([for (final record in records) record.toJson()]),
    );
  }

  @override
  void record(ChannelTaskRecord record) {
    unawaited(
      _locked(() async {
        final records = _load();
        records.removeWhere((existing) => existing.id == record.id);
        records.add(record);
        _trim(records);
        await _save();
      }),
    );
  }

  @override
  void update(
    String taskId, {
    ChannelTaskStatus? status,
    ChannelDeliveryStatus? delivery,
    String? result,
    String? error,
    String? sessionId,
    int? deliveryAttempts,
    DateTime? at,
  }) {
    unawaited(
      _locked(() async {
        final records = _load();
        final index = records.indexWhere((record) => record.id == taskId);
        if (index < 0) return;
        final record = records[index];
        final now = at ?? _clock();
        if (status != null && !ChannelTaskMachine.move(record, status)) return;
        if (status == ChannelTaskStatus.running && record.startedAt == null) {
          record.startedAt = now;
        }
        if (status == ChannelTaskStatus.completed ||
            status == ChannelTaskStatus.failed ||
            status == ChannelTaskStatus.cancelled) {
          record.completedAt = now;
        }
        if (delivery != null) record.delivery = delivery;
        if (result != null) record.result = result;
        if (error != null) record.error = error;
        if (sessionId != null) record.sessionId = sessionId;
        if (deliveryAttempts != null) {
          record.deliveryAttempts = deliveryAttempts;
        }
        await _save();
      }),
    );
  }

  @override
  List<ChannelTaskRecord> recent({int limit = 50}) {
    final records = List<ChannelTaskRecord>.of(_load());
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return records.take(limit).toList();
  }

  /// Everything recorded for one account, newest first.
  List<ChannelTaskRecord> forAccount(String providerId, String accountId) =>
      recent(limit: capacity)
          .where(
            (record) =>
                record.providerId == providerId &&
                record.accountId == accountId,
          )
          .toList();

  @override
  Future<void> clear(String providerId, String accountId) => _locked(() async {
    final records = _load()
      ..removeWhere(
        (record) =>
            record.providerId == providerId && record.accountId == accountId,
      );
    _records = records;
    await _save();
  });

  /// Waits for queued writes. Tests use it; the app does not need to.
  Future<void> settle() => _locked(() async {});

  void _trim(List<ChannelTaskRecord> records) {
    while (records.length > capacity) {
      final finished = records.indexWhere((record) => !record.status.isOpen);
      records.removeAt(finished >= 0 ? finished : 0);
    }
  }
}
