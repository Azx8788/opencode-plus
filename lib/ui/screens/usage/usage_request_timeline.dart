part of '../usage_screen.dart';

/// Cross-session request timeline from the local log. It shows only prompts
/// this app actually dispatched since the feature arrived; it never
/// reconstructs history or pretends to know which API key a request used.
class UsageRequestTimeline extends StatefulWidget {
  const UsageRequestTimeline({super.key, required this.controller});
  final ConnectionController controller;

  @override
  State<UsageRequestTimeline> createState() => _UsageRequestTimelineState();
}

class _UsageRequestTimelineState extends State<UsageRequestTimeline> {
  late final RequestLogStore _log = widget.controller.store.requestLog;
  late Duration _window = const Duration(minutes: 60);

  @override
  void initState() {
    super.initState();
    unawaited(_log.load().catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _log,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final t = KitTokens.of(context);
      final profileID = widget.controller.profile?.id ?? '';
      final now = DateTime.now().millisecondsSinceEpoch;
      final from = now - _window.inMilliseconds;
      final matches = _log.loaded && profileID.isNotEmpty
          ? _log.snapshot.entries
                .where(
                  (e) =>
                      e.profileID == profileID && e.at >= from && e.at <= now,
                )
                .toList()
          : <RequestLogEntry>[];
      final lanes = <String, int>{};
      for (final entry in matches) {
        final label = entry.modelLabel;
        lanes.putIfAbsent(
          label.isEmpty ? l.requestTimelineUnknownModel : label,
          () => lanes.length,
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KitText(l.requestTimeline, role: KitTextRole.headline),
          SizedBox(height: t.space2),
          KitText(l.requestTimelineIntro, role: KitTextRole.secondary),
          SizedBox(height: t.space3),
          KitSegmented<Duration>(
            semanticsLabel: l.requestTimelineWindow,
            selected: _window,
            onChanged: (value) => setState(() => _window = value),
            segments: [
              KitSegment(
                value: const Duration(minutes: 15),
                label: l.requestTimeline15m,
              ),
              KitSegment(
                value: const Duration(minutes: 60),
                label: l.requestTimeline1h,
              ),
              KitSegment(
                value: const Duration(hours: 6),
                label: l.requestTimeline6h,
              ),
            ],
          ),
          SizedBox(height: t.space3),
          if (!_log.loaded)
            KitText(l.usageLoading, role: KitTextRole.secondary)
          else if (matches.isEmpty)
            KitSurface.panel(
              child: KitText(
                l.requestTimelineEmpty,
                role: KitTextRole.secondary,
              ),
            )
          else
            KitSurface.panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final lane in lanes.keys) ...[
                    KitText(
                      lane,
                      key: ValueKey('usage-request-lane-$lane'),
                      role: KitTextRole.caption,
                      maxLines: 1,
                    ),
                    SizedBox(height: t.space1),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        height: 10,
                        child: CustomPaint(
                          key: ValueKey('usage-request-bars-$lane'),
                          painter: _RequestPainter(
                            entries: matches
                                .where(
                                  (e) =>
                                      (e.modelLabel.isEmpty
                                          ? l.requestTimelineUnknownModel
                                          : e.modelLabel) ==
                                      lane,
                                )
                                .toList(),
                            lane: lanes[lane]!,
                            from: from,
                            span: now - from,
                            roles: t.roles,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: t.space2),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      KitText(
                        _clock(DateTime.fromMillisecondsSinceEpoch(from)),
                        role: KitTextRole.caption,
                        tone: KitTextTone.secondary,
                        tabular: true,
                      ),
                      KitText(
                        _clock(DateTime.fromMillisecondsSinceEpoch(now)),
                        role: KitTextRole.caption,
                        tone: KitTextTone.secondary,
                        tabular: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          SizedBox(height: t.space2),
          KitText(
            l.requestTimelineCount(matches.length),
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
        ],
      );
    },
  );
}

String _clock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

class _RequestPainter extends CustomPainter {
  const _RequestPainter({
    required this.entries,
    required this.lane,
    required this.from,
    required this.span,
    required this.roles,
  });
  final List<RequestLogEntry> entries;
  final int lane, from, span;
  final ThemeRoles roles;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)),
      Paint()..color = roles.surface3,
    );
    final palette = [roles.accent, roles.partner, roles.success, roles.text2];
    final paint = Paint()..color = palette[lane % palette.length];
    for (final entry in entries) {
      final x = (entry.at - from) / span * size.width;
      if (x < 0 || x > size.width) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 0, 3, size.height),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_RequestPainter old) =>
      old.entries != entries || old.from != from;
}
