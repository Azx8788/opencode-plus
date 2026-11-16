import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../domain/long_term_memory.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/long_term_memory.dart';
import '../../app_iconography.dart';
import '../../kit/kit.dart';
import '../../widgets/product_states.dart';

class MemoryEditor extends StatefulWidget {
  const MemoryEditor({
    super.key,
    required this.store,
    this.entry,
    this.project,
    this.initialText = '',
    this.sourceSessionID,
    required this.isCurrent,
  });
  final LongTermMemoryStore store;
  final MemoryEntry? entry;
  final MemoryProject? project;
  final String initialText;
  final String? sourceSessionID;
  final bool Function() isCurrent;
  @override
  State<MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<MemoryEditor> {
  late final _text = TextEditingController(
    text: widget.entry?.text ?? widget.initialText,
  );
  late MemoryProject? _project = widget.entry?.project;
  late bool _enabled = widget.entry?.enabled ?? true;
  bool _busy = false, _allowLeave = false;
  Object? _error;
  bool get _dirty =>
      _text.text != (widget.entry?.text ?? widget.initialText) ||
      _project?.key != widget.entry?.project?.key ||
      _enabled != (widget.entry?.enabled ?? true);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    setState(() => _allowLeave = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _discard() async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    if (await showKitConfirm(
          context,
          title: l.memoryDiscard,
          body: l.sessionNoteDiscardDetail,
          confirmLabel: l.sessionNoteDiscardAction,
          kind: KitConfirmKind.discard,
          icon: AppIconography.note,
        ) &&
        mounted) {
      await _leave();
    }
  }

  Future<void> _save({bool remove = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!widget.isCurrent()) {
        throw const MemoryException(MemoryFailure.changed);
      }
      if (remove) {
        await widget.store.remove(widget.entry!);
      } else {
        await widget.store.save(
          text: _text.text,
          previous: widget.entry,
          project: _project,
          enabled: _enabled,
          sourceSessionID: widget.sourceSessionID,
          isCurrent: widget.isCurrent,
        );
      }
      if (mounted) await _leave();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final l = AppLocalizations.of(context);
    if (await showKitConfirm(
          context,
          title: l.memoryDelete,
          body: l.memoryDeleteBody,
          confirmLabel: l.memoryDelete,
          kind: KitConfirmKind.destructive,
          icon: AppIconography.delete,
        ) &&
        mounted) {
      await _save(remove: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = KitTokens.of(context);
    final valid =
        _text.text.trim().isNotEmpty &&
        utf8.encode(_text.text.trim()).length <= MemoryEntry.maxTextBytes;
    final projects = {
      if (widget.project != null) widget.project!.key: widget.project!,
      if (widget.entry?.project != null)
        widget.entry!.project!.key: widget.entry!.project!,
    };
    return PopScope(
      canPop: _allowLeave || (!_dirty && !_busy),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_discard());
      },
      child: KitScreen(
        topBar: KitTopBar(
          title: widget.entry == null ? l.memoryAdd : l.memoryEdit,
        ),
        width: KitScreenWidth.reading,
        loading: _busy,
        loadingLabel: l.usageLoading,
        bottom: KitActionBlock(
          primary: KitAction(
            key: const ValueKey('memory-save'),
            label: l.commonSave,
            working: _busy,
            onPressed: valid && !_busy ? () => unawaited(_save()) : null,
            disabledReason: valid ? null : l.memoryLimit,
          ),
          tertiary: [
            if (widget.entry != null)
              KitAction(
                label: l.memoryDelete,
                key: const ValueKey('memory-delete'),
                icon: AppIconography.delete,
                destructive: true,
                onPressed: _busy ? null : () => unawaited(_delete()),
              ),
          ],
        ),
        body: SingleChildScrollView(
          padding: KitScreen.padding(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KitField(
                label: l.memoryText,
                hint: l.memoryHint,
                controller: _text,
                fieldKey: const ValueKey('memory-text'),
                kind: KitFieldKind.multiline,
                enabled: !_busy,
                disabledReason: _busy ? l.usageLoading : null,
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: t.space2),
              KitText(
                '${utf8.encode(_text.text).length} / ${MemoryEntry.maxTextBytes} B',
                role: KitTextRole.caption,
                tabular: true,
                tone: KitTextTone.secondary,
              ),
              SizedBox(height: t.space3),
              KitPickerRow<String>(
                rowKey: const ValueKey('memory-scope'),
                title: l.memoryScope,
                selected: _project?.key ?? 'global',
                choices: [
                  KitChoice(value: 'global', title: l.memoryGlobal),
                  for (final project in projects.values)
                    KitChoice(value: project.key, title: project.label),
                ],
                onSelected: _busy
                    ? null
                    : (key) => setState(() => _project = projects[key]),
                disabledReason: _busy ? l.memorySaving : null,
              ),
              KitSwitchRow(
                key: const ValueKey('memory-entry-use'),
                title: l.memoryEntryUse,
                value: _enabled,
                onChanged: _busy ? null : (on) => setState(() => _enabled = on),
                disabledReason: _busy ? l.usageLoading : null,
              ),
              if (_error != null)
                KitNotice.error(
                  title: l.memoryTitle,
                  message: productErrorText(_error!, l10n: l),
                ),
              SizedBox(height: t.space3),
              KitText(
                l.memoryIntro,
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
              ),
              SizedBox(height: t.space2),
              KitText(
                l.memoryHistoryNotice,
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
