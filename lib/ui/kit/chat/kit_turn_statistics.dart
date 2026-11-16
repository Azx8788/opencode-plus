import 'package:flutter/material.dart';

import '../kit_tappable.dart';
import '../kit_text.dart';
import '../kit_tokens.dart';

/// One measured fact in a reply's compact statistics row. The host supplies
/// localized short text and an exact, accessible label.
@immutable
class KitTurnStat {
  const KitTurnStat({
    required this.icon,
    required this.text,
    required this.label,
    this.key,
  });

  final IconData icon;
  final String text;
  final String label;
  final Key? key;
}

/// Quiet facts under a reply's actions, wrapping at the actual available
/// width and text scale. A tap opens the host's detailed measurements.
/// It changes neither the app's theme nor its background.
class KitTurnStatistics extends StatelessWidget {
  const KitTurnStatistics({
    super.key,
    required this.items,
    required this.onTap,
    required this.label,
    this.rowKey,
  });

  final List<KitTurnStat> items;
  final VoidCallback onTap;
  final String label;
  final Key? rowKey;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final tokens = KitTokens.of(context);
    return KitTappable(
      tappableKey: rowKey,
      label: [label, ...items.map((item) => item.label)].join(', '),
      onTap: onTap,
      shape: KitShape.panel,
      surface: KitSurfaceLevel.ground,
      child: ExcludeSemantics(
        child: Padding(
          padding: EdgeInsetsDirectional.symmetric(vertical: tokens.space1),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: tokens.space3,
              runSpacing: tokens.space1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final item in items)
                  Row(
                    key: item.key,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        item.icon,
                        size: tokens.smallIconSize * .7,
                        color: tokens.roles.text3,
                      ),
                      SizedBox(width: tokens.space1),
                      Flexible(
                        child: KitText(
                          item.text,
                          role: KitTextRole.caption,
                          tone: KitTextTone.secondary,
                          tabular: true,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
