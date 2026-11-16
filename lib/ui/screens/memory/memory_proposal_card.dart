import 'package:flutter/material.dart';

import '../../../domain/long_term_memory.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state/long_term_memory.dart';
import '../../kit/kit.dart';

class MemoryProposalCard extends StatelessWidget {
  const MemoryProposalCard({
    super.key,
    required this.request,
    required this.store,
    required this.proposalID,
    this.onReview,
  });
  final MemoryWriteRequest request;
  final LongTermMemoryStore store;
  final String proposalID;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final t = KitTokens.of(context);
      final saved = store.snapshot.entries.any(
        (e) => e.sourceCallID == proposalID,
      );
      return KitSurface.panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KitText(
              saved ? l.memorySaved : l.memoryPending,
              role: KitTextRole.headline,
            ),
            SizedBox(height: t.space2),
            KitText(
              l.memoryReviewIntro,
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
            ),
            for (final text in request.memories) ...[
              SizedBox(height: t.space2),
              KitText(text, role: KitTextRole.body),
            ],
            if (!saved && onReview != null) ...[
              SizedBox(height: t.space3),
              KitButton.secondary(
                key: const ValueKey('memory-proposal-review'),
                label: l.memoryReview,
                onPressed: onReview,
              ),
            ],
          ],
        ),
      );
    },
  );
}
