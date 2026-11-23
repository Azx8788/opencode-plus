part of '../connection.dart';

// Cached session inventory and transcript tails for a fast first paint.

/// A shared newest-page read with the event version it started at.
typedef SessionTailRead = ({ServerPage<MessageWithParts> page, int startedAt});

/// [ConnectionController]'s session inventory and transcript caches.
mixin _ConnectionControllerSessionCache on ChangeNotifier {
  ConnectionController get _self;

  /// Last-known read-only labels for Work/session opening shells. Separate
  /// from sessionsById: these rows never establish existence, running state,
  /// capabilities, permission decisions or a connected transport.
  SessionInventoryPreview? get cachedSessionInventory =>
      _self._cachedSessionInventory;
  final _sessionTailReads =
      <(int, String, int, String?), Future<SessionTailRead>>{};

  /// A read-only text excerpt for the opening frame. It has no pagination or
  /// message-state authority; replace it with the normal live hydration result.
  SessionTailPreview? cachedSessionTail(String sessionID) =>
      _self._cachedSessionTail(sessionID);

  /// Re-saves the opening excerpt from a chat's in-memory history, which live
  /// events keep newer than the last read. Call when the person leaves the
  /// chat or the app goes to the background. Best effort; it never saves
  /// while a revert is staged.
  void saveSessionTailSnapshot(
    String sessionID,
    List<MessageWithParts> messages,
  ) => _self._saveSessionTailSnapshot(sessionID, messages);

  /// Whether [loadSessionTail] can read [sessionID] now. Chat hydration uses
  /// the shared read when it can and reads the gateway itself otherwise (an
  /// isolated or test host with a gateway but no saved, connected server).
  bool canLoadSessionTail(String sessionID) =>
      _self._canLoadSessionTail(sessionID);

  /// Authoritative newest page; prefetch and route hydration share an in-flight
  /// read. UI still applies its event-version merge and uses gateway.messagePage
  /// for older cursors. Failures retain existing product-error handling.
  Future<ServerPage<MessageWithParts>> loadSessionTail(String sessionID) async =>
      (await _self._loadSessionTail(sessionID, null)).page;

  /// The same read, stamped with the event version of the caller that
  /// started it.
  ///
  /// A shared read can be reused by a hydration that began later, after
  /// events the read never saw. Merging its result against the *later*
  /// caller's baseline made those events look older than the snapshot and
  /// the snapshot won — the transcript stepped back to stale text and a new
  /// message could disappear. The merge must use the version the data
  /// actually reflects.
  Future<SessionTailRead> loadSessionTailStamped(
    String sessionID,
    int version,
  ) => _self._loadSessionTail(sessionID, version);

  /// Invoke only for the next intentional navigation, never every visible row.
  /// A failed speculative read cannot surface a toast or raw transport error.
  Future<void> prefetchSessionTail(String sessionID) async {
    try {
      await loadSessionTail(sessionID);
    } catch (_) {}
  }
}

extension _ConnectionControllerSessionCacheImpl on ConnectionController {
  /// The body of [cachedSessionInventory].
  SessionInventoryPreview? get _cachedSessionInventory {
    final owner = _connectedProfile ?? profile;
    if (owner == null || !isProfileReadable(owner.id)) return null;
    final saved = store.locationFor(owner.id);
    final restoring = api == null || _restoringSavedLocation;
    final previewDirectory = restoring
        ? (owner.usesAgentSocket ? owner.codexDirectory : saved?.directory)
        : directory;
    final previewWorkspace = restoring
        ? (owner.usesAgentSocket ? null : saved?.workspace)
        : workspace;
    return _sessionInventoryCache.read(
      owner.id,
      SessionInventoryCache.scopeFor(owner, previewDirectory, previewWorkspace),
    );
  }

  /// The body of [cachedSessionTail].
  SessionTailPreview? _cachedSessionTail(String sessionID) {
    final owner = _connectedProfile ?? profile;
    if (owner == null ||
        !isProfileReadable(owner.id) ||
        _deletedSessionIDs.contains(sessionID) ||
        sessionsById[sessionID]?.stagedRevert != null) {
      return null;
    }
    return _sessionTailCache.read(owner.id, _tailScope(owner), sessionID);
  }

  /// The inventory scope the opening excerpt is keyed to.
  String _tailScope(ServerProfile owner) {
    final saved = store.locationFor(owner.id);
    final restoring = api == null || _restoringSavedLocation;
    return SessionInventoryCache.scopeFor(
      owner,
      restoring
          ? (owner.usesAgentSocket ? owner.codexDirectory : saved?.directory)
          : directory,
      restoring ? (owner.usesAgentSocket ? null : saved?.workspace) : workspace,
    );
  }

  /// The body of [saveSessionTailSnapshot].
  void _saveSessionTailSnapshot(
    String sessionID,
    List<MessageWithParts> messages,
  ) {
    final owner = _connectedProfile ?? profile;
    if (owner == null ||
        messages.isEmpty ||
        !isProfileReadable(owner.id) ||
        _deletedSessionIDs.contains(sessionID) ||
        sessionsById[sessionID]?.stagedRevert != null) {
      return;
    }
    final generation = _generation;
    final deletionRevision = _profileDeletionRevisions[owner.id];
    unawaited(
      _sessionTailCache.save(
        owner.id,
        _tailScope(owner),
        sessionID,
        messages,
        isCurrent: () =>
            _generation == generation &&
            isProfileReadable(owner.id) &&
            _profileDeletionRevisions[owner.id] == deletionRevision &&
            sessionsById[sessionID]?.stagedRevert == null &&
            !_deletedSessionIDs.contains(sessionID),
      ),
    );
  }

  /// The body of [canLoadSessionTail].
  bool _canLoadSessionTail(String sessionID) {
    final owner = _connectedProfile ?? profile;
    return owner != null &&
        api != null &&
        hasConnectedServer &&
        isProfileReadable(owner.id) &&
        !_deletedSessionIDs.contains(sessionID);
  }

  /// The body of [loadSessionTail] and [loadSessionTailStamped]. [version] is
  /// the caller's event version; null means the caller does not merge and
  /// does not care where the read started.
  Future<SessionTailRead> _loadSessionTail(String sessionID, int? version) {
    final owner = _connectedProfile ?? profile;
    final currentApi = api;
    final generation = _generation;
    if (owner == null || currentApi == null || !canLoadSessionTail(sessionID)) {
      return Future.error(const ProductException('OpenCode is reconnecting.'));
    }
    final historyRevision = sessionHistoryRevision(sessionID);
    final boundary = sessionsById[sessionID]?.stagedRevert?.messageID;
    final key = (generation, sessionID, historyRevision, boundary);
    final existing = _sessionTailReads[key];
    if (existing != null) return existing;
    final scope = SessionInventoryCache.scopeFor(owner, directory, workspace);
    final deletionRevision = _profileDeletionRevisions[owner.id];
    bool current() =>
        _isCurrent(generation, currentApi) &&
        isProfileReadable(owner.id) &&
        _profileDeletionRevisions[owner.id] == deletionRevision &&
        sessionHistoryRevision(sessionID) == historyRevision &&
        sessionsById[sessionID]?.stagedRevert?.messageID == boundary &&
        !_deletedSessionIDs.contains(sessionID);
    late final Future<SessionTailRead> read;
    read = () async {
      try {
        final page = await readHistoryAtStagedBoundary(
          currentApi,
          sessionID,
          boundary: boundary,
          isCurrent: current,
        );
        if (!current()) throw const ProductException('The session changed.');
        _genUiObserve(sessionID, page.items, complete: boundary == null);
        if (boundary == null && busySessions.contains(sessionID)) {
          final marker = widgetRunMarker(page.items);
          if (marker != null) _widgetRunMarkers[sessionID] = marker;
        }
        // Disk caching is best effort and never delays authoritative hydration.
        if (boundary == null) {
          unawaited(
            _sessionTailCache
                .save(
                  owner.id,
                  scope,
                  sessionID,
                  page.items,
                  isCurrent: current,
                )
                .then((_) {
                  if (current()) _notifyListeners();
                }),
          );
        }
        return (page: page, startedAt: version ?? 0);
      } finally {
        // Only this read's own entry: a newer read under a different key must
        // not be removed by an older one finishing.
        if (identical(_sessionTailReads[key], read)) {
          _sessionTailReads.remove(key);
        }
      }
    }();
    _sessionTailReads[key] = read;
    return read;
  }

  void _saveSessionInventoryPreview() {
    final owner = _connectedProfile ?? profile;
    final currentApi = api;
    final generation = _generation;
    if (owner == null || currentApi == null || !isProfileReadable(owner.id)) {
      return;
    }
    final deletionRevision = _profileDeletionRevisions[owner.id];
    unawaited(
      _sessionInventoryCache.save(
        owner.id,
        SessionInventoryCache.scopeFor(owner, directory, workspace),
        sortedSessions(),
        isCurrent: () =>
            _isCurrent(generation, currentApi) &&
            isProfileReadable(owner.id) &&
            _profileDeletionRevisions[owner.id] == deletionRevision,
      ),
    );
  }
}
