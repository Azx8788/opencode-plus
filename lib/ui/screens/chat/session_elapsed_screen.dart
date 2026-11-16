import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/turn_elapsed.dart';
import '../../l10n/app_localizations.dart';
import '../kit/kit.dart';

/// The conversation's elapsed-time page: a ring of recorded phases, the
/// stage totals and one bar per reply. It draws with the app's own theme
/// roles and follows the appearance settings; nothing here starts a
/// request or changes the conversation.
class SessionElapsedScreen extends StatelessWidget {
  const SessionElapsedScreen({super.key, required this.messages});
  final List<MessageWithParts> messages;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = KitTokens.of(context);
    final elapsed = SessionElapsed.fromMessages(messages);
    final turns = [
      for (var index = 0; index < elapsed.turns.length; index++)
        (index: index, turn: elapsed.turns[index]),
    ];
    final wall = elapsed.wall;
    return KitScreen(
      topBar: KitTopBar(title: l.sessionElapsedTitle),
      width: KitScreenWidth.reading,
      body: SingleChildScrollView(
        padding: KitScreen.padding(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (elapsed.turns.every((turn) => turn.isEmpty))
              KitSurface.panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KitText(l.sessionElapsedEmpty, role: KitTextRole.headline),
                    SizedBox(height: t.space2),
                    KitText(
                      l.sessionElapsedExplanation,
                      role: KitTextRole.secondary,
                      tone: KitTextTone.secondary,
                    ),
                  ],
                ),
              )
            else ...[
              KitSurface.panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ElapsedRing(elapsed: elapsed),
                    SizedBox(height: t.space3),
                    _StageList(elapsed: elapsed),
                  ],
                ),
              ),
              SizedBox(height: t.space3),
              KitText(l.sessionElapsedTimeline, role: KitTextRole.headline),
              SizedBox(height: t.space2),
              for (final entry in turns) ...[
                _TurnBar(
                  key: ValueKey('elapsed-turn-${entry.index}'),
                  label: l.sessionElapsedTurn(entry.index + 1),
                  elapsed: entry.turn,
                ),
                SizedBox(height: t.space2),
              ],
              SizedBox(height: t.space2),
              if (wall != null)
                KitText(
                  l.sessionElapsedSteps(
                    elapsed.steps,
                    l.chatStatsSeconds(_seconds(wall)),
                  ),
                  role: KitTextRole.secondary,
                  tone: KitTextTone.secondary,
                ),
              SizedBox(height: t.space2),
              KitText(
                l.sessionElapsedExplanation,
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _seconds(Duration duration) =>
    (duration.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(
      1,
    );

List<(Color, Duration)> _segments(TurnElapsed elapsed, ThemeRoles roles) => [
  (roles.text3, elapsed.wait),
  (roles.accent, elapsed.thinking),
  (roles.success, elapsed.output),
  (roles.partner, elapsed.toolExecution),
];

class _ElapsedRing extends StatelessWidget {
  const _ElapsedRing({required this.elapsed});
  final SessionElapsed elapsed;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = KitTokens.of(context);
    final wall = elapsed.wall;
    return Center(
      child: Column(
        children: [
          CustomPaint(
            key: const ValueKey('elapsed-ring'),
            size: const Size(160, 160),
            painter: _RingPainter(elapsed: elapsed, roles: t.roles),
          ),
          SizedBox(height: t.space2),
          KitText(
            wall == null
                ? l.chatStatsNotReported
                : l.chatStatsSeconds(_seconds(wall)),
            key: const ValueKey('elapsed-ring-total'),
            role: KitTextRole.headline,
            tabular: true,
          ),
          KitText(
            l.sessionElapsedRecorded(_seconds(elapsed.recorded)),
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
            tabular: true,
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.elapsed, required this.roles});
  final SessionElapsed elapsed;
  final ThemeRoles roles;

  @override
  void paint(Canvas canvas, Size size) {
    final total = elapsed.recorded;
    if (total == Duration.zero) return;
    final stroke = size.width / 6;
    final ring = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width - stroke,
      height: size.height - stroke,
    );
    var start = -math.pi / 2;
    final gap = .03;
    for (final segment in _segments(elapsed, roles)) {
      if (segment.$2 == Duration.zero) continue;
      final sweep =
          segment.$2.inMicroseconds / total.inMicroseconds * 2 * math.pi;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = segment.$1;
      canvas.drawArc(ring, start, math.max(sweep - gap, .01), false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.elapsed != elapsed;
}

class _StageList extends StatelessWidget {
  const _StageList({required this.elapsed});
  final SessionElapsed elapsed;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = KitTokens.of(context);
    final total = elapsed.recorded;
    String value(Duration phase) {
      if (phase == Duration.zero) return l.chatStatsNotReported;
      final percent = total == Duration.zero
          ? 0
          : (phase.inMicroseconds * 100 / total.inMicroseconds).round();
      return '${l.chatStatsSeconds(_seconds(phase))} · $percent%';
    }

    return KitKeyValue(
      rows: [
        KitKeyValueRow(label: l.sessionElapsedWait, value: value(elapsed.wait)),
        KitKeyValueRow(
          label: l.sessionElapsedThinking,
          value: value(elapsed.thinking),
        ),
        KitKeyValueRow(
          label: l.sessionElapsedOutput,
          value: value(elapsed.output),
        ),
        KitKeyValueRow(
          label: l.sessionElapsedTool,
          value: value(elapsed.toolExecution),
        ),
      ],
    );
  }
}

class _TurnBar extends StatelessWidget {
  const _TurnBar({super.key, required this.label, required this.elapsed});
  final String label;
  final TurnElapsed elapsed;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = KitTokens.of(context);
    final wall = elapsed.wall;
    return KitSurface.panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: KitText(label, role: KitTextRole.rowTitle)),
              KitText(
                wall == null
                    ? l.chatStatsNotReported
                    : l.chatStatsSeconds(_seconds(wall)),
                role: KitTextRole.caption,
                tone: KitTextTone.secondary,
                tabular: true,
              ),
            ],
          ),
          SizedBox(height: t.space2),
          CustomPaint(
            key: ValueKey('elapsed-bar-$label'),
            size: const Size(double.infinity, 10),
            painter: _BarPainter(elapsed: elapsed, roles: t.roles),
          ),
        ],
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  const _BarPainter({required this.elapsed, required this.roles});
  final TurnElapsed elapsed;
  final ThemeRoles roles;

  @override
  void paint(Canvas canvas, Size size) {
    final total = elapsed.recorded;
    final paint = Paint()..color = roles.surface3;
    final radius = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      paint,
    );
    if (total == Duration.zero) return;
    var start = 0.0;
    for (final segment in _segments(elapsed, roles)) {
      if (segment.$2 == Duration.zero) continue;
      final width =
          segment.$2.inMicroseconds / total.inMicroseconds * size.width;
      final rect = Rect.fromLTWH(start, 0, width, size.height);
      if (rect.width > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, radius),
          paint..color = segment.$1,
        );
      }
      start += width;
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.elapsed != elapsed;
}
