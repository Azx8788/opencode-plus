import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../l10n/app_localizations.dart';
import '../kit/kit.dart';

/// A per-request timeline of one conversation, built only from the server's
/// recorded request timestamps. No API-key lane is invented: OpenCode's
/// client does not report which named key a completed request actually used,
/// so the lanes are models. Missing timestamps stay out of the chart.
class SessionRequestTimelineScreen extends StatelessWidget {
  const SessionRequestTimelineScreen({super.key, required this.messages});
  final List<MessageWithParts> messages;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = KitTokens.of(context);
    final requests = <_Request>[];
    for (final message in messages) {
      final time = message.info.time;
      final start = time?.created;
      final end = time?.completed ?? time?.streamed ?? time?.firstToken;
      if (message.info.role != 'assistant' ||
          time?.recorded != true ||
          start == null ||
          start <= 0 ||
          end == null ||
          end <= start) {
        continue;
      }
      final model = [
        message.info.providerID,
        message.info.modelID,
      ].where((part) => part?.isNotEmpty == true).join('/');
      requests.add(
        _Request(
          start: start,
          end: end,
          model: model.isEmpty ? l.requestTimelineUnknownModel : model,
        ),
      );
    }
    requests.sort((a, b) => a.start.compareTo(b.start));
    final lanes = <String, int>{};
    for (final request in requests) {
      lanes.putIfAbsent(request.model, () => lanes.length);
    }
    final first = requests.isEmpty ? null : requests.first.start;
    final last = requests.isEmpty
        ? null
        : requests.fold<int>(
            0,
            (max, request) => request.end > max ? request.end : max,
          );
    final span = first != null && last != null ? last - first : 0;

    return KitScreen(
      topBar: KitTopBar(title: l.requestTimeline),
      width: KitScreenWidth.reading,
      body: SingleChildScrollView(
        padding: KitScreen.padding(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KitText(l.requestTimelineIntro, role: KitTextRole.secondary),
            SizedBox(height: t.space3),
            if (requests.isEmpty)
              KitSurface.panel(
                child: KitText(
                  l.requestTimelineEmpty,
                  role: KitTextRole.headline,
                ),
              )
            else
              KitSurface.panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final lane in lanes.keys) ...[
                      Row(
                        children: [
                          Expanded(
                            child: KitText(
                              lane,
                              key: ValueKey('request-lane-$lane'),
                              role: KitTextRole.caption,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: t.space1),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: SizedBox(
                          height: 12,
                          child: CustomPaint(
                            key: ValueKey('request-bars-$lane'),
                            painter: _LanePainter(
                              requests: requests
                                  .where((r) => r.model == lane)
                                  .toList(),
                              lane: lanes[lane]!,
                              first: first!,
                              span: span,
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
                          _clock(DateTime.fromMillisecondsSinceEpoch(first!)),
                          role: KitTextRole.caption,
                          tone: KitTextTone.secondary,
                          tabular: true,
                        ),
                        KitText(
                          _clock(DateTime.fromMillisecondsSinceEpoch(last!)),
                          role: KitTextRole.caption,
                          tone: KitTextTone.secondary,
                          tabular: true,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            SizedBox(height: t.space3),
            KitText(
              l.requestTimelineNote(requests.length),
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
            ),
          ],
        ),
      ),
    );
  }
}

String _clock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}:'
    '${time.second.toString().padLeft(2, '0')}';

class _Request {
  const _Request({required this.start, required this.end, required this.model});
  final int start, end;
  final String model;
}

class _LanePainter extends CustomPainter {
  const _LanePainter({
    required this.requests,
    required this.lane,
    required this.first,
    required this.span,
    required this.roles,
  });
  final List<_Request> requests;
  final int lane, first, span;
  final ThemeRoles roles;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4)),
      Paint()..color = roles.surface3,
    );
    final palette = [roles.accent, roles.partner, roles.success, roles.text2];
    final paint = Paint()..color = palette[lane % palette.length];
    for (final request in requests) {
      final left = (request.start - first) / span * size.width;
      final width = (request.end - request.start) / span * size.width;
      if (width <= 0) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            left,
            0,
            width.clamp(2.0, size.width - left),
            size.height,
          ),
          const Radius.circular(3),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LanePainter old) =>
      old.requests != requests || old.lane != lane || old.first != first;
}
