part of '../chat_screen.dart';

extension _ChatMemory on _ChatScreenState {
  Future<void> _summarizeMemory() async {
    if (_sending || _sendInFlight || _watching || _conn.isIsolated) return;
    final l = _chatL10n(context);
    final location = _conn.locationRevision;
    final identity = (_conn.profile?.id, _conn.profile?.baseUrl);
    final confirmed = await showKitConfirm(
      context,
      title: l.memorySummarize,
      body: l.memorySummaryIntro,
      confirmLabel: l.memorySummarize,
      icon: AppIconography.database,
    );
    if (!confirmed || !mounted) return;
    if (location != _conn.locationRevision ||
        identity != (_conn.profile?.id, _conn.profile?.baseUrl)) {
      _showActionError(const MemoryException(MemoryFailure.changed));
      return;
    }
    // The ordinary conversation send preserves model, mode and draft. No
    // separate extraction API, copied transcript or hidden model selection.
    await _sendInsteadOfDraft(l.memorySummaryPrompt);
  }

  String _memoryProposalID(Part part) => memoryProposalKey(
    _conn.profile?.id ?? '',
    _conn.profile?.baseUrl ?? '',
    widget.sessionID,
    part.callID!,
  );

  Widget _memoryProposalRow(Part part, MemoryWriteRequest request) =>
      MemoryProposalCard(
        key: ValueKey('memory-proposal-${part.callID}'),
        request: request,
        store: _conn.store.longTermMemory,
        proposalID: _memoryProposalID(part),
        onReview: _watching || _conn.isIsolated
            ? null
            : () => unawaited(_reviewMemory(part, request)),
      );

  Future<void> _reviewMemory(Part part, MemoryWriteRequest request) async {
    final location = _conn.locationRevision;
    final identity = (_conn.profile?.id, _conn.profile?.baseUrl);
    final proposalID = _memoryProposalID(part);
    bool current() =>
        mounted &&
        location == _conn.locationRevision &&
        identity == (_conn.profile?.id, _conn.profile?.baseUrl);
    try {
      final store = _conn.store.longTermMemory;
      await store.load();
      MemoryProject? project;
      try {
        project = await readMemoryProject(_conn, widget.sessionID);
      } catch (_) {
        /* The review explicitly shows unknown; project save stays disabled. */
      }
      if (!current() || !mounted) {
        throw const MemoryException(MemoryFailure.changed);
      }
      await pushKitPage<void>(
        context,
        (_) => MemoryReviewScreen(
          store: store,
          request: request,
          sessionID: widget.sessionID,
          proposalID: proposalID,
          project: project,
          isCurrent: current,
        ),
      );
    } catch (error) {
      if (mounted) _showActionError(error);
    }
  }
}
