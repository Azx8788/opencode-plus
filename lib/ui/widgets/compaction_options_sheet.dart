import 'package:flutter/material.dart';

import '../../domain/server_gateway.dart' show CompactOptions, ServerCapabilities;
import '../../l10n/app_localizations.dart';
import '../app_iconography.dart';
import '../kit/kit.dart';

/// Collects what a compaction should keep and how it should summarize.
///
/// Only shown for servers that advertise [ServerCapabilities.compactionOptions]
/// or [ServerCapabilities.compactionKeepTurns]; every other server keeps the
/// existing one-question confirmation and the empty request body.
Future<CompactOptions?> showCompactionOptionsSheet(
  BuildContext context, {
  required ServerCapabilities capabilities,
}) async {
  if (!capabilities.compactionOptions && !capabilities.compactionKeepTurns) {
    return const CompactOptions();
  }
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  final draft = _CompactionDraft(
    instructions: capabilities.compactionOptions,
    keepTurns: capabilities.compactionKeepTurns,
  );
  try {
    return await showKitSheet<CompactOptions>(
      context,
      sheetKey: const ValueKey('compaction-options-sheet'),
      title: l10n.chatUiCompactSession,
      subtitle: capabilities.compactionKeepTurns
          ? l10n.chatUiCompactionKeepTurnsHint
          : null,
      icon: AppIconography.collapse,
      primary: KitAction(
        key: const ValueKey('compaction-options-confirm'),
        label: l10n.chatUiCompactConfirmAction,
        onPressed: () => KitSheet.close(context, draft.options),
      ),
      body: (_) => _CompactionOptionsBody(draft: draft, l10n: l10n),
    );
  } finally {
    // The sheet's route finishes its exit after this returns; dispose the
    // controller on the next frame so nothing reads it while it closes.
    WidgetsBinding.instance.addPostFrameCallback((_) => draft.dispose());
  }
}

class _CompactionDraft {
  _CompactionDraft({required this.instructions, required this.keepTurns})
    : keep = keepTurns ? 1 : 0;

  final bool instructions;
  final bool keepTurns;
  int keep;
  final controller = TextEditingController();

  CompactOptions get options => CompactOptions(
    instructions: instructions ? controller.text.trim() : '',
    keepTurns: keepTurns ? keep : null,
  );

  void dispose() => controller.dispose();
}

class _CompactionOptionsBody extends StatefulWidget {
  const _CompactionOptionsBody({
    required this.draft,
    required this.l10n,
  });

  final _CompactionDraft draft;
  final AppLocalizations l10n;

  @override
  State<_CompactionOptionsBody> createState() => _CompactionOptionsBodyState();
}

class _CompactionOptionsBodyState extends State<_CompactionOptionsBody> {
  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final draft = widget.draft;
    final l10n = widget.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (draft.keepTurns) ...[
          KitSectionLabel(l10n.chatUiCompactionKeepTurns),
          KitSegmented<int>(
            segments: [
              for (final count in const [0, 1, 2, 3])
                KitSegment(value: count, label: '$count'),
            ],
            selected: draft.keep,
            onChanged: (value) => setState(() => draft.keep = value),
            semanticsLabel: l10n.chatUiCompactionKeepTurns,
          ),
          SizedBox(height: tokens.space2),
          KitText(
            l10n.chatUiCompactionKeepTurnsHint,
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
          SizedBox(height: tokens.space3),
        ],
        if (draft.instructions) ...[
          KitField(
            label: l10n.chatUiCompactionInstruction,
            hint: l10n.chatUiCompactionInstructionHint,
            controller: draft.controller,
            maxLines: 4,
            optional: true,
          ),
          SizedBox(height: tokens.space3),
        ],
        KitText(
          l10n.sessionContextCompactKept,
          role: KitTextRole.caption,
          tone: KitTextTone.secondary,
        ),
      ],
    );
  }
}