part of '../usage_screen.dart';

class _UsageActivityHeatmap extends StatefulWidget {
  const _UsageActivityHeatmap({
    required this.snapshot,
    required this.now,
    required this.loading,
    required this.failed,
  });
  final UsageSnapshot? snapshot;
  final DateTime now;
  final bool loading, failed;
  @override
  State<_UsageActivityHeatmap> createState() => _UsageActivityHeatmapState();
}

class _UsageActivityHeatmapState extends State<_UsageActivityHeatmap> {
  final _scroll = ScrollController();
  String? _calendar;
  DateTime? _selected;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = KitTokens.of(context);
    final l = _strings(context);
    final stats = widget.snapshot?.statistics;
    final days = usageHeatmapDays(widget.now);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final activity = <String, int>{};
    for (final day in stats?.activity ?? const <UsageActivity>[]) {
      activity.update(
        day.date,
        (value) => value + day.steps,
        ifAbsent: () => day.steps,
      );
    }
    final calendar = usageDateKey(widget.now);
    if (stats != null && _calendar != calendar) {
      _calendar = calendar;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients)
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    final scaler = MediaQuery.textScalerOf(context);
    final cell = math.max(t.space3, scaler.scale(t.space3));
    final gap = t.space1 / 2;
    final slot = cell + gap;
    final labelHeight = scaler.scale(16) + t.space2;
    final height = labelHeight + slot * 7;
    int? value(DateTime day) {
      if (stats == null || day.isAfter(widget.now)) return null;
      final next = DateTime(day.year, day.month, day.day + 1);
      if (next.millisecondsSinceEpoch <= stats.from ||
          day.millisecondsSinceEpoch >= stats.to)
        return null;
      return activity[usageDateKey(day)] ?? 0;
    }

    String selectedWords(DateTime day) {
      final count = value(day);
      return '${DateFormat.yMMMd(locale).format(day)} · ${count == null ? l.statsNotRecorded : l.statsRequests(count)}';
    }

    return KitSurface.panel(
      key: const ValueKey('stats-heatmap'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          KitText(l.statsHeatmap, role: KitTextRole.headline),
          SizedBox(height: t.space1),
          KitText(
            l.statsHeatmapHint,
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
          SizedBox(height: t.space3),
          if (stats == null)
            KitText(
              widget.failed ? l.statsSummaryFailed : l.usageLoading,
              role: KitTextRole.secondary,
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: labelHeight),
                    for (var index = 0; index < 7; index++)
                      SizedBox(
                        height: slot,
                        child: index.isEven
                            ? KitText(
                                DateFormat.E(locale).format(days[index]),
                                role: KitTextRole.caption,
                                tone: KitTextTone.secondary,
                              )
                            : null,
                      ),
                  ],
                ),
                SizedBox(width: t.space2),
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('stats-heatmap-scroll'),
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    child: Semantics(
                      image: true,
                      label: l.statsHeatmapHint,
                      child: GestureDetector(
                        key: const ValueKey('stats-heatmap-grid'),
                        onTapUp: (tap) {
                          final week = (tap.localPosition.dx / slot).floor();
                          final day =
                              ((tap.localPosition.dy - labelHeight) / slot)
                                  .floor();
                          if (week < 0 || week >= 53 || day < 0 || day > 6)
                            return;
                          setState(() => _selected = days[week * 7 + day]);
                        },
                        child: SizedBox(
                          width: 53 * slot,
                          height: height,
                          child: CustomPaint(
                            painter: _HeatmapPainter(
                              days: days,
                              values: [for (final day in days) value(day)],
                              cell: cell,
                              gap: gap,
                              labelHeight: labelHeight,
                              accent: t.roles.accent,
                              empty: t.roles.surface3,
                              selected: _selected == null
                                  ? null
                                  : usageDateKey(_selected!),
                              text: KitText.styleOf(
                                context,
                                KitTextRole.caption,
                                tone: KitTextTone.secondary,
                              ),
                              scaler: scaler,
                              locale: locale,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: t.space2),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: t.space1,
              children: [
                KitText(l.statsLess, role: KitTextRole.caption),
                for (final alpha in [0.0, .25, .5, .75, 1.0])
                  SizedBox.square(
                    dimension: t.space3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color.alphaBlend(
                          t.roles.accent.withValues(alpha: alpha),
                          t.roles.surface3,
                        ),
                        borderRadius: BorderRadius.circular(t.space1),
                      ),
                    ),
                  ),
                KitText(l.statsMore, role: KitTextRole.caption),
              ],
            ),
            if (_selected != null) ...[
              SizedBox(height: t.space2),
              KitText(
                selectedWords(_selected!),
                key: const ValueKey('stats-heatmap-selected'),
                role: KitTextRole.secondary,
                tabular: true,
              ),
            ],
            KitButton.tertiary(
              key: const ValueKey('stats-activity-details'),
              label: l.statsActivityDetails,
              onPressed: () => showKitSheet<void>(
                context,
                title: l.statsHeatmap,
                itemCount: days.where((day) => !day.isAfter(widget.now)).length,
                itemBuilder: (context, index) {
                  final day = days
                      .where((day) => !day.isAfter(widget.now))
                      .toList()
                      .reversed
                      .elementAt(index);
                  return KitRow(
                    title: DateFormat.yMMMd(locale).format(day),
                    supporting: TextSpan(
                      text: value(day) == null
                          ? l.statsNotRecorded
                          : l.statsRequests(value(day)!),
                    ),
                  );
                },
              ),
            ),
          ],
          if (widget.loading && stats != null)
            KitText(l.usageLoading, role: KitTextRole.caption),
          if (widget.failed && stats != null)
            KitText(l.usagePreviousResult, role: KitTextRole.caption),
        ],
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({
    required this.days,
    required this.values,
    required this.cell,
    required this.gap,
    required this.labelHeight,
    required this.accent,
    required this.empty,
    required this.text,
    required this.scaler,
    required this.locale,
    this.selected,
  });
  final List<DateTime> days;
  final List<int?> values;
  final double cell, gap, labelHeight;
  final Color accent, empty;
  final TextStyle text;
  final TextScaler scaler;
  final String locale;
  final String? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final active = values.whereType<int>().where((value) => value > 0).toList()
      ..sort();
    double intensity(int? count) {
      if (count == null || count == 0) return 0;
      if (active.isEmpty) return 0;
      for (var q = 1; q <= 3; q++) {
        if (count <= active[((active.length - 1) * q / 4).floor()])
          return q / 4;
      }
      return 1;
    }

    var lastLabelEnd = -1.0;
    for (var index = 0; index < days.length; index++) {
      final week = index ~/ 7;
      final row = index % 7;
      final x = week * (cell + gap);
      final y = labelHeight + row * (cell + gap);
      final value = values[index];
      final color = value == null
          ? empty.withValues(alpha: .35)
          : Color.alphaBlend(accent.withValues(alpha: intensity(value)), empty);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, cell, cell),
        Radius.circular(gap * 1.5),
      );
      canvas.drawRRect(rect, Paint()..color = color);
      if (selected == usageDateKey(days[index])) {
        canvas.drawRRect(
          rect.deflate(.5),
          Paint()
            ..color = text.color ?? accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (days[index].day == 1 && x >= lastLabelEnd) {
        final label = days[index].month == 1
            ? '${days[index].year}'
            : DateFormat.MMM(locale).format(days[index]);
        final painter = TextPainter(
          text: TextSpan(text: label, style: text),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout();
        painter.paint(canvas, Offset(x, 0));
        lastLabelEnd = x + painter.width + cell;
        painter.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) => true;
}
