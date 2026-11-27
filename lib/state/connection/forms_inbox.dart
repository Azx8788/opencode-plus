part of '../connection.dart';

// Forms and the session inbox (OpenCode 2).

/// What [ConnectionController.cancelInboxItem] achieved, with the text the
/// item carried so the caller can return it to the person.
class InboxCancelResult {
  const InboxCancelResult({required this.outcome, this.text});
  final Api2InboxCancel outcome;
  final String? text;
}

/// [ConnectionController]'s forms and session inbox.
mixin _ConnectionControllerFormsInbox on ChangeNotifier {
  ConnectionController get _self;

  /// Outstanding OpenCode 2 form requests keyed by form ID. Includes global
  /// (MCP elicitation) forms whose `sessionID` is the `"global"` sentinel.
  /// Always empty on v1 (capability `forms` is false).
  Map<String, Api2FormInfo> forms = {};
  bool formsLoading = false;
  String? formsError;

  /// Pending OpenCode 2 inbox items (admitted, not-yet-delivered sends) per
  /// session, keyed by inbox ID. Feeds the pending-sends strip; empty on v1.
  final Map<String, Map<String, Api2InboxItem>> _inboxBySession = {};

  /// Bumps whenever the inbox slice of any session changes.
  int inboxRevision = 0;

  /// Per-session event counters. A REST reconcile compares the counter it
  /// started at with the current one instead of relying on a single global
  /// revision: an event for another conversation used to invalidate this
  /// session's reconcile, and an event for *this* one could be overtaken by a
  /// read that started before it.
  final Map<String, int> _inboxEpochs = {};

  /// Items this client knows are no longer pending (cancelled or delivered).
  /// A reconcile that started before the event must not put them back: the
  /// strip would show a send that cannot happen and hide the real message.
  final Map<String, Set<String>> _inboxTombstones = {};

  /// Bounded: only the most recent removals need to survive one in-flight
  /// read.
  static const _maxInboxTombstones = 64;

  void _noteInboxTombstone(String sessionID, String inboxID) {
    final set = _inboxTombstones[sessionID] ??= <String>{};
    set.add(inboxID);
    if (set.length > _maxInboxTombstones) {
      set.remove(set.first);
    }
  }

  final Set<String> _resolvedFormIDs = {};
  int _formRevision = 0;
  int _formRefreshGeneration = 0;

  CapturedFormRequest? formRequestForFeedItem(ChatFeedItem item) =>
      _self._formRequestForFeedItem(item);

  CapturedFormRequest? formRequestForForm(Api2FormInfo form) =>
      _self._formRequestForForm(form);

  final _feedDirectoryForms = <String, Map<String, _DirectoryForm>>{};
  final _formAttempts = <String>{};
  final _formSettled = <String>{};
  final _formReplies = <String, Future<void>>{};

  bool get supportsForms => _self.api?.capabilities.forms ?? false;

  /// True when the connected server exposes the v2 session inbox.
  bool get supportsInbox => _self.api?.capabilities.inbox ?? false;

  List<Api2FormInfo> formsForSession(String sessionID) => forms.values
      .where((form) => form.sessionID == sessionID)
      .toList(growable: false);

  Api2FormInfo? formForSession(String sessionID) {
    for (final form in forms.values) {
      if (form.sessionID == sessionID) return form;
    }
    return null;
  }

  /// Re-polls the pending form lists. Form events are ephemeral, so this
  /// runs after every SSE (re)connect; it is a no-op on v1 servers.
  Future<void> refreshPendingForms() => _self._refreshPendingForms();

  /// Sends the assembled answer of a pending form. Rethrows transport
  /// failures for the presenter (400 invalid-answer keeps the form open with
  /// a banner); a 409 already-settled also resolves the form locally so the
  /// presenter can toast-and-close.
  Future<void> replyForm(String formID, Map<String, dynamic> answer) =>
      _self._replyForm(formID, answer);

  /// Cancels (dismisses) a pending form; the agent continues unanswered.
  Future<void> cancelForm(String formID) => _self._cancelForm(formID);

  // ---------------- Inbox (OpenCode 2) ----------------

  /// Pending (admitted, undelivered) sends of one session, oldest first.
  List<Api2InboxItem> inboxItemsFor(String sessionID) {
    final items = _inboxBySession[sessionID];
    if (items == null || items.isEmpty) return const [];
    final sorted = items.values.toList()
      ..sort((a, b) => (a.timeCreated ?? 0).compareTo(b.timeCreated ?? 0));
    return sorted;
  }

  /// Reconciles one session's pending sends from REST (events are volatile).
  /// No-op on servers without an inbox.
  Future<void> refreshInbox(String sessionID) => _self._refreshInbox(sessionID);

  /// Cancels a pending send and reports what that actually achieved.
  ///
  /// A `204` is not proof: the server answers it for an item it could not
  /// cancel. Only a follow-up look separates "will not be delivered" from
  /// "was delivered already", and the caller needs that to decide whether
  /// the text may be merged into a new prompt.
  Future<InboxCancelResult> cancelInboxItem(String sessionID, String inboxID) =>
      _self._cancelInboxItem(sessionID, inboxID);

  /// Flips a pending send between steer and queue delivery. A 409
  /// already-delivered drops the local item and rethrows for the toast.
  Future<void> setInboxDelivery(
    String sessionID,
    String inboxID, {
    required Api2Delivery delivery,
  }) => _self._setInboxDelivery(sessionID, inboxID, delivery: delivery);
}

extension _ConnectionControllerFormsInboxImpl on ConnectionController {
  void _handleFormCreated(Map<String, dynamic> props) {
    final raw = props['form'];
    if (raw is! Map) return;
    final form = Api2FormInfo.fromJson(Map<String, dynamic>.from(raw));
    if (form == null || form.id.isEmpty) return;
    formsLoading = false;
    _resolvedFormIDs.remove(form.id);
    forms[form.id] = form;
    _formRevision += 1;
    _syncInputAlerts();
    _notifyListeners();
  }

  void _resolveForm(String formID) {
    formsLoading = false;
    _resolvedFormIDs.add(formID);
    _formRevision += 1;
    if (forms.remove(formID) != null) {
      _syncInputAlerts();
    }
    _notifyListeners();
  }

  /// The body of [refreshPendingForms].
  Future<void> _refreshPendingForms() async {
    final currentApi = api;
    final generation = _generation;
    if (currentApi == null || !currentApi.capabilities.forms) return;
    final refreshGeneration = ++_formRefreshGeneration;
    final revision = _formRevision;
    formsLoading = true;
    formsError = null;
    _notifyListeners();
    try {
      final pending = await currentApi.pendingForms();
      if (!_isCurrent(generation, currentApi) ||
          refreshGeneration != _formRefreshGeneration) {
        return;
      }
      final hydrated = {
        for (final form in pending)
          if (!_resolvedFormIDs.contains(form.id)) form.id: form,
      };
      if (revision != _formRevision) {
        // Events moved the set mid-fetch; they are fresher than the poll.
        hydrated.addAll(forms);
        hydrated.removeWhere((id, _) => _resolvedFormIDs.contains(id));
      }
      forms = hydrated;
      _observeAttentionRead(AttentionKind.form);
      formsLoading = false;
      _syncInputAlerts();
      _notifyListeners();
    } catch (error) {
      if (!_isCurrent(generation, currentApi) ||
          refreshGeneration != _formRefreshGeneration) {
        return;
      }
      formsLoading = false;
      formsError = error.toString();
      _notifyListeners();
    }
  }

  /// The body of [replyForm].
  Future<void> _replyForm(String formID, Map<String, dynamic> answer) async {
    final form = forms[formID];
    if (form == null) {
      if (_resolvedFormIDs.contains(formID)) return;
      throw StateError('Form request $formID is no longer pending');
    }
    final request = formRequestForForm(form);
    if (request == null) {
      throw const ProductException('This form is no longer available.');
    }
    await request.reply(answer);
  }

  /// The body of [cancelForm].
  Future<void> _cancelForm(String formID) async {
    final form = forms[formID];
    if (form == null) {
      if (_resolvedFormIDs.contains(formID)) return;
      throw const ProductException('This form is no longer available.');
    }
    final request = formRequestForForm(form);
    if (request == null) {
      throw const ProductException('This form is no longer available.');
    }
    await request.cancel();
  }

  void _handleInboxEnqueued(Map<String, dynamic> props) {
    final sessionID = props['sessionID']?.toString() ?? '';
    final inboxID = props['inboxID']?.toString() ?? '';
    final rawItem = props['item'];
    if (sessionID.isEmpty || inboxID.isEmpty || rawItem is! Map) return;
    final item = Api2InboxItem.fromJson({
      'id': inboxID,
      'sessionID': sessionID,
      'timeCreated': DateTime.now().millisecondsSinceEpoch,
      ...Map<String, dynamic>.from(rawItem),
    });
    if (item == null) return;
    _inboxTombstones[sessionID]?.remove(inboxID);
    (_inboxBySession[sessionID] ??= {})[inboxID] = item;
    _inboxEpochs[sessionID] = (_inboxEpochs[sessionID] ?? 0) + 1;
    inboxRevision += 1;
    _notifyListeners();
  }

  void _handleInboxRemoved(Map<String, dynamic> props) {
    final sessionID = props['sessionID']?.toString() ?? '';
    final inboxID = props['inboxID']?.toString() ?? '';
    if (sessionID.isEmpty || inboxID.isEmpty) return;
    // Recorded even when this client never held the item: a reconcile that
    // already has it in flight would otherwise re-add what the server just
    // dropped, and a cancelled send would look pending again.
    _noteInboxTombstone(sessionID, inboxID);
    _inboxEpochs[sessionID] = (_inboxEpochs[sessionID] ?? 0) + 1;
    final items = _inboxBySession[sessionID];
    if (items == null || items.remove(inboxID) == null) {
      _notifyListeners();
      return;
    }
    if (items.isEmpty) _inboxBySession.remove(sessionID);
    inboxRevision += 1;
    _notifyListeners();
  }

  void _handleInboxDeliveryChanged(Map<String, dynamic> props) {
    final sessionID = props['sessionID']?.toString() ?? '';
    final inboxID = props['inboxID']?.toString() ?? '';
    final delivery = Api2Delivery.parse(props['delivery']);
    if (sessionID.isEmpty || inboxID.isEmpty || delivery == null) return;
    // An event for an item this client has not seen still means the set
    // moved: bump the epoch so an older reconcile cannot overwrite it.
    _inboxEpochs[sessionID] = (_inboxEpochs[sessionID] ?? 0) + 1;
    final item = _inboxBySession[sessionID]?[inboxID];
    if (item == null) {
      _notifyListeners();
      return;
    }
    _inboxBySession[sessionID]![inboxID] = Api2InboxItem(
      id: item.id,
      sessionID: item.sessionID,
      timeCreated: item.timeCreated,
      type: item.type,
      payload: item.payload,
      delivery: delivery,
    );
    inboxRevision += 1;
    _notifyListeners();
  }

  /// The body of [refreshInbox].
  Future<void> _refreshInbox(String sessionID) async {
    final currentApi = api;
    final generation = _generation;
    if (currentApi == null || !currentApi.capabilities.inbox) return;
    // This session's own counter, not the global revision: another
    // conversation's event must not throw this read away, and this one's
    // must not be overtaken by a read that started before it.
    final epochAtStart = _inboxEpochs[sessionID] ?? 0;
    List<Api2InboxItem> items;
    try {
      items = await currentApi.inboxItems(sessionID);
    } catch (_) {
      // The strip is a convenience surface; a failed reconcile keeps the
      // event-projected state rather than erroring the chat.
      return;
    }
    if (!_isCurrent(generation, currentApi) ||
        epochAtStart != (_inboxEpochs[sessionID] ?? 0)) {
      // Events moved the set while this read ran. They are fresher; a
      // follow-up reconcile keeps the strip from staying behind for good.
      unawaited(_refreshInboxAfterEvents(sessionID, epochAtStart));
      return;
    }
    final tombstones = _inboxTombstones[sessionID];
    final next = {
      for (final item in items)
        if (tombstones == null || !tombstones.contains(item.id)) item.id: item,
    };
    if (next.isEmpty) {
      if (_inboxBySession.remove(sessionID) == null) return;
    } else {
      _inboxBySession[sessionID] = next;
    }
    inboxRevision += 1;
    _notifyListeners();
  }

  /// One bounded follow-up after a reconcile lost to events, so a session
  /// whose events arrived mid-read still ends up reconciled.
  Future<void> _refreshInboxAfterEvents(String sessionID, int lostEpoch) async {
    // Two attempts: the first may lose again to a burst of events, but a
    // strip that never reconciles is worse than one extra read.
    for (var attempt = 0; attempt < 2; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (_disposed) return;
      final epoch = _inboxEpochs[sessionID] ?? 0;
      if (epoch == lostEpoch) return;
      final currentApi = api;
      final generation = _generation;
      if (currentApi == null || !currentApi.capabilities.inbox) return;
      List<Api2InboxItem> items;
      try {
        items = await currentApi.inboxItems(sessionID);
      } catch (_) {
        return;
      }
      if (!_isCurrent(generation, currentApi) ||
          epoch != (_inboxEpochs[sessionID] ?? 0)) {
        lostEpoch = epoch;
        continue;
      }
      final tombstones = _inboxTombstones[sessionID];
      final next = {
        for (final item in items)
          if (tombstones == null || !tombstones.contains(item.id))
            item.id: item,
      };
      if (next.isEmpty) {
        _inboxBySession.remove(sessionID);
      } else {
        _inboxBySession[sessionID] = next;
      }
      inboxRevision += 1;
      _notifyListeners();
      return;
    }
  }

  /// The body of [cancelInboxItem].
  Future<InboxCancelResult> _cancelInboxItem(
    String sessionID,
    String inboxID,
  ) async {
    final item = _inboxBySession[sessionID]?[inboxID];
    final text = item?.promptText;
    // Without a local copy of the item there is nothing to be sure about:
    // the id may never have been pending here.
    if (item == null) {
      return InboxCancelResult(outcome: Api2InboxCancel.unknown, text: text);
    }
    final currentApi = await _requireActionTransport();
    try {
      await currentApi.cancelInboxItem(sessionID, inboxID);
    } on ApiException catch (error) {
      if (error.statusCode == 409 || error.statusCode == 404) {
        _handleInboxRemoved({'sessionID': sessionID, 'inboxID': inboxID});
        return InboxCancelResult(
          outcome: error.statusCode == 409
              ? Api2InboxCancel.delivered
              : Api2InboxCancel.unknown,
          text: text,
        );
      }
      rethrow;
    }
    final outcome = await _confirmInboxCancel(sessionID, inboxID);
    if (outcome == Api2InboxCancel.cancelled) {
      _handleInboxRemoved({'sessionID': sessionID, 'inboxID': inboxID});
    }
    return InboxCancelResult(outcome: outcome, text: text);
  }

  /// What the cancel achieved, read from the server rather than from the
  /// status code.
  ///
  /// An item still in the inbox was not cancelled. An item gone from the
  /// inbox with a projected user message under the same ID was delivered.
  /// Only "gone from the inbox and no message" is a cancel.
  Future<Api2InboxCancel> _confirmInboxCancel(
    String sessionID,
    String inboxID,
  ) async {
    final currentApi = api;
    if (currentApi == null) return Api2InboxCancel.unknown;
    try {
      final pending = await currentApi.inboxItems(sessionID);
      if (pending.any((item) => item.id == inboxID)) {
        return Api2InboxCancel.unknown;
      }
      String? cursor;
      final seen = <String>{};
      for (var page = 0; page < 20; page++) {
        final read = await currentApi.messagePage(sessionID, cursor: cursor);
        if (read.items.any(
          (message) =>
              message.info.id == inboxID && message.info.role == 'user',
        )) {
          return Api2InboxCancel.delivered;
        }
        cursor = read.nextCursor;
        if (cursor == null || !seen.add(cursor)) break;
      }
      return Api2InboxCancel.cancelled;
    } catch (_) {
      return Api2InboxCancel.unknown;
    }
  }

  /// The body of [setInboxDelivery].
  Future<void> _setInboxDelivery(
    String sessionID,
    String inboxID, {
    required Api2Delivery delivery,
  }) async {
    final currentApi = await _requireActionTransport();
    try {
      if (delivery == Api2Delivery.queue) {
        await currentApi.queueInboxItem(sessionID, inboxID);
      } else {
        await currentApi.steerInboxItem(sessionID, inboxID);
      }
    } on ApiException catch (error) {
      if (error.statusCode == 409 || error.statusCode == 404) {
        _handleInboxRemoved({'sessionID': sessionID, 'inboxID': inboxID});
      }
      rethrow;
    }
    _handleInboxDeliveryChanged({
      'sessionID': sessionID,
      'inboxID': inboxID,
      'delivery': delivery.wire,
    });
  }
}
