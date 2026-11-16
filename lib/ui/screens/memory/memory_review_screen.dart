import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../domain/long_term_memory.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/long_term_memory.dart';
import '../../kit/kit.dart';
import '../../widgets/product_states.dart';

/// Local review only. Summarization already happened in the original chat;
/// opening, editing or saving this screen never makes another model request.
class MemoryReviewScreen extends StatefulWidget {
  const MemoryReviewScreen({
    super.key,
    required this.store,
    required this.request,
    required this.sessionID,
    required this.proposalID,
    required this.isCurrent,
    this.project,
  });
  final LongTermMemoryStore store;
  final MemoryWriteRequest request;
  final String sessionID, proposalID;
  final MemoryProject? project;
  final bool Function() isCurrent;

  @override
  State<MemoryReviewScreen> createState() => _MemoryReviewScreenState();
}

class _MemoryReviewScreenState extends State<MemoryReviewScreen> {
  late final List<String> _candidates = List.of(widget.request.memories);
  late bool _projectScope = widget.request.projectScoped;
  final _selected = <int>{};
  bool _busy = false;
  Object? _error;
  bool get _saved => widget.store.snapshot.entries.any(
    (e) => e.sourceCallID == widget.proposalID,
  );

  Future<void> _edit(int index) async {
    final l = AppLocalizations.of(context);
    final result = await showKitInputDialog(
      context,
      title: l.memoryEdit,
      label: l.memoryText,
      confirmLabel: l.commonSave,
      initial: _candidates[index],
      maxLines: 5,
      validate: (text) =>
          text.trim().isEmpty ||
              utf8.encode(text.trim()).length > MemoryEntry.maxTextBytes
          ? l.memoryLimit
          : null,
    );
    if (mounted && result != null) {
      setState(() => _candidates[index] = result.trim());
    }
  }

  Future<void> _save() async {
    if (_busy ||
        _selected.isEmpty ||
        _saved ||
        (_projectScope && widget.project == null)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store.saveCandidates(
        [
          for (var i = 0; i < _candidates.length; i++)
            if (_selected.contains(i)) _candidates[i],
        ],
        project: _projectScope ? widget.project : null,
        sourceSessionID: widget.sessionID,
        sourceCallID: widget.proposalID,
        isCurrent: widget.isCurrent,
      );
      if (mounted) setState(_selected.clear);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final t = KitTokens.of(context);
      final current = widget.isCurrent();
      final unknownProject = _projectScope && widget.project == null;
      final saved = _saved;
      return KitScreen(
        topBar: KitTopBar(title: l.memoryReview),
        width: KitScreenWidth.reading,
        loading: _busy,
        loadingLabel: l.memorySaving,
        bottom: saved
            ? null
            : KitActionBlock(
                primary: KitAction(
                  key: const ValueKey('memory-review-save'),
                  label: l.memorySaveSelected,
                  working: _busy,
                  onPressed:
                      _busy || _selected.isEmpty || !current || unknownProject
                      ? null
                      : () => unawaited(_save()),
                  disabledReason: !current
                      ? l.memoryChanged
                      : unknownProject
                      ? l.memoryProjectUnknown
                      : null,
                ),
              ),
        body: SingleChildScrollView(
          padding: KitScreen.padding(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KitText(l.memoryReviewIntro, role: KitTextRole.secondary),
              SizedBox(height: t.space3),
              if (_error != null)
                KitNotice.error(
                  title: l.memoryTitle,
                  message: productErrorText(_error!, l10n: l),
                ),
              if (!current)
                KitNotice.error(title: l.memoryTitle, message: l.memoryChanged),
              if (saved)
                KitText(
                  l.memorySaved,
                  key: const ValueKey('memory-review-saved'),
                  role: KitTextRole.headline,
                )
              else ...[
                KitSegmented<String>(
                  selected: _projectScope ? 'project' : 'global',
                  semanticsLabel: l.memoryScope,
                  onChanged: (value) {
                    if (!_busy) {
                      setState(() => _projectScope = value == 'project');
                    }
                  },
                  segments: [
                    KitSegment(
                      value: 'global',
                      label: l.memoryGlobal,
                      enabled: !_busy,
                      disabledReason: _busy ? l.memorySaving : null,
                    ),
                    KitSegment(
                      value: 'project',
                      label: l.memoryProject,
                      enabled: !_busy && widget.project != null,
                      disabledReason: _busy
                          ? l.memorySaving
                          : l.memoryProjectUnknown,
                    ),
                  ],
                ),
                if (_projectScope) ...[
                  SizedBox(height: t.space2),
                  KitText(
                    widget.project?.label ?? l.memoryProjectUnknown,
                    role: KitTextRole.caption,
                    tone: KitTextTone.secondary,
                  ),
                ],
                for (var i = 0; i < _candidates.length; i++) ...[
                  SizedBox(height: t.space3),
                  KitSurface.panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        KitSwitchRow(
                          key: ValueKey('memory-candidate-$i'),
                          title: l.memoryCandidate(i + 1),
                          value: _selected.contains(i),
                          onChanged: _busy
                              ? null
                              : (on) => setState(() {
                                  if (on) {
                                    _selected.add(i);
                                  } else {
                                    _selected.remove(i);
                                  }
                                }),
                          disabledReason: _busy ? l.memorySaving : null,
                        ),
                        KitText(_candidates[i], role: KitTextRole.body),
                        KitButton.tertiary(
                          key: ValueKey('memory-candidate-edit-$i'),
                          label: l.memoryEdit,
                          onPressed: _busy ? null : () => unawaited(_edit(i)),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
              SizedBox(height: t.space3),
              KitText(
                l.memoryHistoryNotice,
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
              ),
            ],
          ),
        ),
      );
    },
  );
}
