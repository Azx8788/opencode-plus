part of '../usage_screen.dart';

class _UsageTrendCard extends StatefulWidget {
  const _UsageTrendCard({
    required this.snapshot,
    required this.plan,
    required this.points,
    required this.loading,
    required this.finished,
    this.onRetry,
  });
  final UsageSnapshot snapshot;
  final UsageTrendPlan? plan;
  final List<UsageTrendPoint> points;
  final bool loading;
  final int finished;
  final VoidCallback? onRetry;
  @override
  State<_UsageTrendCard> createState() => _UsageTrendCardState();
}

class _UsageTrendCardState extends State<_UsageTrendCard> {
  int? _selected;
  @override
  void didUpdateWidget(_UsageTrendCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.snapshot, widget.snapshot)) _selected = null;
  }

  String _bucketLabel(UsageBucket bucket, String locale) {
    final last = bucket.to.subtract(const Duration(milliseconds: 1));
    final from = DateFormat.yMMMd(locale).format(bucket.from);
    return usageDateKey(bucket.from) == usageDateKey(last)
        ? from
        : '$from – ${DateFormat.yMMMd(locale).format(last)}';
  }

  @override
  Widget build(BuildContext context) {
    final l = _strings(context);
    final t = KitTokens.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final points = widget.points;
    final selected = _selected != null && _selected! < points.length
        ? points[_selected!]
        : null;
    final tokens = selected == null
        ? widget.snapshot.statistics.tokens
        : selected.statistics?.tokens;
    final plan = widget.plan;
    final title = plan?.monthly == true
        ? l.statsMonthlyUsage
        : l.statsDailyUsage;
    final scaler = MediaQuery.textScalerOf(context);
    final axisStyle = KitText.styleOf(
      context,
      KitTextRole.caption,
      tone: KitTextTone.secondary,
    );
    final labelHeight = scaler.scale(axisStyle.fontSize ?? 12) * 1.6;
    final plotHeight = 180.0 + labelHeight * 2;
    final allUnknown =
        points.isEmpty || points.every((point) => point.statistics == null);
    return KitSurface.panel(
      key: const ValueKey('stats-trend-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          KitText(title, role: KitTextRole.headline),
          if (plan != null && (plan.days > 1 || plan.months > 1)) ...[
            SizedBox(height: t.space1),
            KitText(
              plan.monthly
                  ? l.statsGroupedMonths(plan.months)
                  : l.statsGroupedDays(plan.days),
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
            ),
          ],
          SizedBox(height: t.space3),
          KitText(
            selected == null
                ? l.statsPeriodTotal
                : _bucketLabel(selected.bucket, locale),
            key: const ValueKey('stats-trend-readout-date'),
            role: KitTextRole.caption,
            tone: KitTextTone.secondary,
          ),
          KitText(
            tokens == null
                ? l.statsNotRecorded
                : compactUsageCount(tokens.total),
            key: const ValueKey('stats-trend-readout-total'),
            role: KitTextRole.title,
            tabular: true,
          ),
          if (tokens != null)
            Wrap(
              spacing: t.space3,
              runSpacing: t.space1,
              children: [
                KitText(
                  '${l.usageInput} ${compactUsageCount(tokens.prompt)}',
                  role: KitTextRole.caption,
                ),
                KitText(
                  '${l.usageCacheRead} ${compactUsageCount(tokens.cacheRead)}',
                  role: KitTextRole.caption,
                ),
                KitText(
                  '${l.usageOutput} ${compactUsageCount(tokens.completion)}',
                  role: KitTextRole.caption,
                ),
              ],
            ),
          if (widget.loading)
            Padding(
              padding: EdgeInsetsDirectional.only(top: t.space2),
              child: KitText(
                l.statsLoadingBuckets(widget.finished, points.length),
                key: const ValueKey('stats-trend-loading'),
                role: KitTextRole.caption,
              ),
            ),
          SizedBox(height: t.space3),
          if (allUnknown && !widget.loading)
            KitText(
              widget.snapshot.statistics.tokens.total == 0
                  ? l.usageEmpty
                  : l.statsTrendUnavailable,
              role: KitTextRole.secondary,
            )
          else
            LayoutBuilder(
              builder: (context, box) {
                final maximum = points.fold<int>(
                  0,
                  (max, point) => math.max(max, point.total ?? 0),
                );
                final axis = _usageChartAxis(maximum);
                final label = TextPainter(
                  text: TextSpan(
                    text: compactUsageCount(axis),
                    style: axisStyle,
                  ),
                  textDirection: TextDirection.ltr,
                  textScaler: scaler,
                )..layout();
                final left = label.width + t.space2;
                label.dispose();
                final width = box.maxWidth;
                return Semantics(
                  image: true,
                  label: l.statsChartHint,
                  child: GestureDetector(
                    key: const ValueKey('stats-trend-plot'),
                    onTapUp: (tap) {
                      if (points.isEmpty ||
                          tap.localPosition.dx < left ||
                          width <= left) {
                        return;
                      }
                      final index =
                          ((tap.localPosition.dx - left) /
                                  (width - left) *
                                  points.length)
                              .floor()
                              .clamp(0, points.length - 1);
                      setState(
                        () => _selected = index == _selected ? null : index,
                      );
                    },
                    child: SizedBox(
                      height: plotHeight,
                      width: width,
                      child: CustomPaint(
                        painter: _UsageTrendPainter(
                          points: points,
                          selected: _selected,
                          accent: t.roles.accent,
                          grid: t.roles.hairline,
                          unknown: t.roles.text3,
                          text: axisStyle,
                          scaler: scaler,
                          locale: locale,
                          left: left,
                          labelHeight: labelHeight,
                          maximum: axis,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          if (points.any((point) => point.failed)) ...[
            SizedBox(height: t.space2),
            KitText(
              l.statsPartialTrend,
              role: KitTextRole.caption,
              tone: KitTextTone.secondary,
            ),
            if (widget.onRetry != null)
              KitButton.tertiary(
                label: l.commonRetry,
                key: const ValueKey('stats-trend-retry'),
                onPressed: widget.onRetry,
              ),
          ],
          if (points.isNotEmpty)
            KitButton.tertiary(
              key: const ValueKey('stats-trend-details'),
              label: l.statsTrendDetails,
              onPressed: () => showKitSheet<void>(
                context,
                title: title,
                itemCount: points.length,
                itemBuilder: (context, index) => KitRow(
                  key: ValueKey('stats-bucket-$index'),
                  title: _bucketLabel(points[index].bucket, locale),
                  supporting: TextSpan(
                    text: points[index].total == null
                        ? l.statsNotRecorded
                        : l.statsExactTokens('${points[index].total}'),
                  ),
                  onTap: () {
                    setState(() => _selected = index);
                    Navigator.of(context).pop();
                  },
                ),
              ),
            ),
          KitText(
            l.statsChartHint,
            role: KitTextRole.caption,
            tone: KitTextTone.tertiary,
          ),
        ],
      ),
    );
  }
}

int _usageChartAxis(int max) {
  if (max <= 0) return 1;
  final unit = math.pow(10, math.log(max) ~/ math.ln10).toInt();
  final scaled = max / unit;
  return (scaled <= 1
          ? 1
          : scaled <= 2
          ? 2
          : scaled <= 5
          ? 5
          : 10) *
      unit;
}

class _UsageTrendPainter extends CustomPainter {
  _UsageTrendPainter({
    required this.points,
    required this.selected,
    required this.accent,
    required this.grid,
    required this.unknown,
    required this.text,
    required this.scaler,
    required this.locale,
    required this.left,
    required this.labelHeight,
    required this.maximum,
  });
  final List<UsageTrendPoint> points;
  final int? selected;
  final Color accent, grid, unknown;
  final TextStyle text;
  final TextScaler scaler;
  final String locale;
  final double left, labelHeight;
  final int maximum;

  TextPainter _label(String value) => TextPainter(
    text: TextSpan(text: value, style: text),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final top = labelHeight / 2;
    final bottom = size.height - labelHeight * 1.5;
    final width = size.width - left;
    if (width <= 0 || bottom <= top) return;
    for (final value in [0, maximum / 2, maximum.toDouble()]) {
      final y = bottom - value / maximum * (bottom - top);
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width, y),
        Paint()..color = grid,
      );
      final label = _label(value == 0 ? '0' : compactUsageCount(value.round()));
      label.paint(canvas, Offset(left - label.width - 8, y - label.height / 2));
      label.dispose();
    }
    if (points.isEmpty) return;
    final slot = width / points.length;
    for (var index = 0; index < points.length; index++) {
      final total = points[index].total;
      final center = left + (index + .5) * slot;
      if (total == null) {
        canvas.drawLine(
          Offset(center - slot * .2, bottom - 3),
          Offset(center + slot * .2, bottom - 3),
          Paint()
            ..color = unknown
            ..strokeWidth = 2,
        );
      } else if (total > 0) {
        final height = total / maximum * (bottom - top);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              center - slot * .32,
              bottom - height,
              slot * .64,
              height,
            ),
            Radius.circular(math.min(3, slot * .2)),
          ),
          Paint()
            ..color = selected == null || selected == index
                ? accent
                : accent.withValues(alpha: .35),
        );
      }
    }
    final indices = points.length < 3
        ? List.generate(points.length, (i) => i)
        : [0, (points.length - 1) ~/ 2, points.length - 1];
    double end = -1;
    for (final index in indices) {
      final date = points[index].bucket.from;
      final label = _label(
        DateFormat(
          points[index].bucket.to.difference(date).inDays >= 28 ? 'y-M' : 'M/d',
          locale,
        ).format(date),
      );
      final center = left + (index + .5) * slot;
      final x = (center - label.width / 2)
          .clamp(left, math.max(left, size.width - label.width))
          .toDouble();
      if (x >= end) {
        label.paint(canvas, Offset(x, bottom + 6));
        end = x + label.width + 6;
      }
      label.dispose();
    }
  }

  @override
  bool shouldRepaint(_UsageTrendPainter old) => true;
}
