import 'package:flutter/material.dart';

import '../../../domain/subagent_settings.dart';
import '../../../state/subagent_settings_controller.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import 'subagent_settings_copy.dart';

/// An explicit multi-select editor, not a launch approval. Missing catalogue
/// entries stay visible and removable; search never changes the selected set.
class SubagentModelPoolScreen extends StatefulWidget {
  const SubagentModelPoolScreen({
    super.key,
    required this.controller,
    required this.edit,
  });
  final SubagentSettingsController controller;
  final SubagentPoolEdit edit;

  @override
  State<SubagentModelPoolScreen> createState() =>
      _SubagentModelPoolScreenState();
}

class _SubagentModelPoolScreenState extends State<SubagentModelPoolScreen> {
  late Set<SubagentModelCandidate> _selected;
  late Map<SubagentModelCandidate, String> _offered;
  late List<SubagentModelCandidate> _choices;
  late final String _scope;
  final _search = TextEditingController();
  String _query = '';
  bool _submitted = false;
  bool _allowExit = false;
  bool _confirmingExit = false;
  SubagentSettingsFailure? _error;

  bool get _dirty =>
      _selected.length != widget.edit.pool.candidates.length ||
      !_selected.containsAll(widget.edit.pool.candidates);

  @override
  void initState() {
    super.initState();
    _selected = widget.edit.pool.candidates.toSet();
    _offered = widget.controller.catalog?.candidates ?? {};
    _choices = {..._selected, ..._offered.keys}.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    _scope =
        '${widget.controller.server?.name ?? ''} · '
        '${widget.controller.projectID ?? widget.controller.server?.profileID ?? ''}';
  }

  Future<void> _save() async {
    if (_submitted || !widget.controller.isEditCurrent(widget.edit)) return;
    setState(() => _submitted = true);
    try {
      final saved = await widget.controller.savePool(
        widget.edit,
        SubagentModelPool(_selected),
      );
      if (!mounted) return;
      if (saved) {
        _allowExit = true;
        Navigator.of(context).pop();
      } else {
        setState(
          () => _error =
              widget.controller.error ?? SubagentSettingsFailure.staleTarget,
        );
      }
    } on FormatException {
      if (mounted) {
        setState(() => _error = SubagentSettingsFailure.storageFailed);
      }
    }
  }

  Future<void> _requestExit() async {
    if (_confirmingExit || widget.controller.saving) return;
    if (_dirty && !_allowExit) {
      _confirmingExit = true;
      final copy = SubagentSettingsCopy(context);
      final discard = await showKitChoiceSheet<bool>(
        context,
        title: copy.text('Discard this edit?', '放弃本次编辑？'),
        choices: [
          KitChoice(
            value: true,
            title: copy.text('Discard unsaved choices', '放弃未保存的选择'),
          ),
        ],
      );
      _confirmingExit = false;
      if (discard != true || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _allowExit = true);
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final copy = SubagentSettingsCopy(context),
          tokens = KitTokens.of(context);
      final current = widget.controller.isEditCurrent(widget.edit);
      final busy = widget.controller.saving;
      final terms = _query
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((part) => part.isNotEmpty);
      final visible = _choices.where((candidate) {
        final text = '${candidate.label} ${_offered[candidate] ?? ''}'
            .toLowerCase();
        return terms.every(text.contains);
      }).toList();
      return PopScope(
        canPop: _allowExit || (!_dirty && !busy),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _requestExit();
        },
        child: KitScreen(
          topBar: KitTopBar(
            title: copy.pool,
            subtitle: _scope,
            onExit: _requestExit,
          ),
          width: KitScreenWidth.reading,
          bottom: KitButton.primary(
            key: const ValueKey('subagents-pool-save'),
            label: busy ? copy.saving : copy.save,
            working: busy,
            onPressed: !current || busy || _submitted ? null : _save,
          ),
          body: CustomScrollView(
            key: const ValueKey('subagents-model-choices'),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: tokens.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KitText(copy.draft, role: KitTextRole.secondary),
                      KitText(
                        copy.count(_selected.length),
                        role: KitTextRole.secondary,
                      ),
                      if (!current)
                        KitNotice(
                          key: const ValueKey('subagents-editor-stale'),
                          message: copy.editChanged,
                        ),
                      if (_error case final failure?)
                        KitNotice.error(
                          key: const ValueKey('subagents-pool-error'),
                          message: copy.failure(failure),
                        ),
                      KitSearchField(
                        label: copy.search,
                        controller: _search,
                        fieldKey: const ValueKey('subagents-pool-search'),
                        onChanged: (value) => setState(() => _query = value),
                      ),
                    ],
                  ),
                ),
              ),
              if (visible.isEmpty)
                SliverToBoxAdapter(
                  child: KitStateView(
                    icon: AppIconography.model,
                    title: copy.noMatches,
                  ),
                )
              else
                SliverList.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final candidate = visible[index];
                    final status = _offered.containsKey(candidate)
                        ? (candidate.variant ?? copy.defaultVariant)
                        : widget.controller.catalog == null
                        ? copy.unknown
                        : copy.notListed;
                    return KitChoiceRow<SubagentModelCandidate>(
                      rowKey: ValueKey('subagents-candidate-${candidate.key}'),
                      choice: KitChoice(
                        value: candidate,
                        title: _offered[candidate] ?? candidate.modelID,
                        supporting: '${candidate.label}\n$status',
                      ),
                      selected: _selected.contains(candidate),
                      mark: KitChoiceMark.check,
                      onTap: !current || busy || _submitted
                          ? null
                          : () => setState(() {
                              if (!_selected.remove(candidate)) {
                                _selected.add(candidate);
                              }
                            }),
                    );
                  },
                ),
              SliverToBoxAdapter(child: SizedBox(height: tokens.space4)),
            ],
          ),
        ),
      );
    },
  );
}
