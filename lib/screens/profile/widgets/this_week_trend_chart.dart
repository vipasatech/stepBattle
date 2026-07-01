import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `intl` re-exports a `TextDirection` enum that shadows Flutter's
// `dart:ui.TextDirection`; hide it so `TextPainter(textDirection:
// TextDirection.ltr)` resolves to the right one.
import 'package:intl/intl.dart' hide TextDirection;

import '../../../config/colors.dart';
import '../../../providers/profile_trend_provider.dart';
import '../../../sheets/calendar_picker_sheet.dart';

/// Profile → "This Week" trendline chart.
///
/// Header ("This Week" + calendar icon) sits above a step-count line
/// chart. Horizontal drag on the chart body reveals translucent
/// distance + calorie overlays; releasing the drag fades them back
/// out.
///
/// State kept local:
///   • `_selected` — the 3–7 days currently plotted. Defaults to the
///     last 7 calendar days on every mount (matches the "reset every
///     Profile open" spec).
///   • `_revealController` — 0→1 while the user is actively dragging
///     the chart, drives the overlay-line alpha.
///
/// Data source: [last28DaysMetricsProvider]. The chart filters the
/// provider's 28-entry list down to `_selected` at paint time.
class ThisWeekTrendChart extends ConsumerStatefulWidget {
  const ThisWeekTrendChart({super.key});

  @override
  ConsumerState<ThisWeekTrendChart> createState() =>
      _ThisWeekTrendChartState();
}

class _ThisWeekTrendChartState extends ConsumerState<ThisWeekTrendChart>
    with SingleTickerProviderStateMixin {
  /// Applied day selection driving the chart. Sorted oldest → newest.
  late List<DateTime> _selected;

  late final AnimationController _revealController;

  @override
  void initState() {
    super.initState();
    _selected = _defaultLast7Days();
    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _revealController.dispose();
    super.dispose();
  }

  static List<DateTime> _defaultLast7Days() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return List.generate(
      7,
      (i) => today.subtract(Duration(days: 6 - i)),
    );
  }

  Future<void> _openCalendar() async {
    final picked = await showCalendarPickerSheet(
      context,
      initialSelection: _selected,
    );
    if (picked != null && mounted) {
      setState(() => _selected = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asyncMetrics = ref.watch(last28DaysMetricsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header row — title + calendar affordance. Stays inside the
        // 24 dp Profile section inset (see `_padded` in profile_screen)
        // so it visually aligns with the other section headers.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'This Week',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Pick days',
                icon: const Icon(Icons.calendar_month),
                color: AppColors.primary,
                onPressed: _openCalendar,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Asymmetric inset — 0 dp on the left so the trace runs
        // flush to the screen edge, 5 dp on the right so the y-axis
        // labels have a hair of screen-edge breathing room. The
        // header above stays at 24 dp so section headers still align
        // across the Profile.
        Padding(
          padding: const EdgeInsets.only(right: 5),
          child: SizedBox(
          height: 170,
          child: asyncMetrics.when(
            data: (points) => _ChartBody(
              points: points,
              selected: _selected,
              revealController: _revealController,
            ),
            loading: () => Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: AppColors.primary,
                ),
              ),
            ),
            error: (e, _) => Center(
              child: Text(
                'Could not load trend',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Chart body — GestureDetector wraps CustomPaint. Horizontal drag maps
// to the reveal controller; the painter reads its value to fade the
// distance + calorie overlays in and out.
// =============================================================================

class _ChartBody extends StatelessWidget {
  final List<DailyMetricPoint> points;
  final List<DateTime> selected;
  final AnimationController revealController;

  const _ChartBody({
    required this.points,
    required this.selected,
    required this.revealController,
  });

  @override
  Widget build(BuildContext context) {
    // Filter provider's 28-entry list down to the selected days,
    // preserving chronological order.
    final selectedSet = selected.toSet();
    final plotted = points
        .where((p) => selectedSet.contains(_normalize(p.date)))
        .toList();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Horizontal-only detector so vertical scrolls on the surrounding
      // page still land on the outer ListView.
      onHorizontalDragStart: (_) => revealController.forward(),
      onHorizontalDragEnd: (_) => revealController.reverse(),
      onHorizontalDragCancel: () => revealController.reverse(),
      child: AnimatedBuilder(
        animation: revealController,
        builder: (context, _) {
          return CustomPaint(
            painter: _TrendChartPainter(
              points: plotted,
              revealProgress: revealController.value,
              stepsColor: AppColors.primary,
              distanceColor: const Color(0xFF22C55E),
              caloriesColor: AppColors.amber,
              axisColor: AppColors.onSurfaceVariant.withValues(alpha: 0.35),
              labelColor: AppColors.onSurfaceVariant,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }

  static DateTime _normalize(DateTime d) =>
      DateTime(d.year, d.month, d.day);
}

// =============================================================================
// The painter — steps line + area fill + markers + optional overlay
// traces for distance and calories.
// =============================================================================

class _TrendChartPainter extends CustomPainter {
  final List<DailyMetricPoint> points;

  /// 0..1. At 0 only the steps line is painted; at 1 the distance +
  /// calorie overlays are at their peak opacity (0.4).
  final double revealProgress;

  final Color stepsColor;
  final Color distanceColor;
  final Color caloriesColor;
  final Color axisColor;
  final Color labelColor;

  _TrendChartPainter({
    required this.points,
    required this.revealProgress,
    required this.stepsColor,
    required this.distanceColor,
    required this.caloriesColor,
    required this.axisColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) {
      _drawEmpty(canvas, size);
      return;
    }

    // ---- Layout ------------------------------------------------------
    // padLeft = 5 — leftmost marker (5-px radius) sits flush without
    // clipping. padRight = 44 leaves room for the 12-px halo around
    // the rightmost data point + the 16-px label offset so the
    // number never draws on top of the glow (was 34, halo overlapped
    // the label by ~11 px).
    const double padLeft = 5;
    const double padRight = 44;
    const double padTop = 16;
    const double padBottom = 22;
    final chartRect = Rect.fromLTWH(
      padLeft,
      padTop,
      size.width - padLeft - padRight,
      size.height - padTop - padBottom,
    );

    // ---- Per-metric max (round up so grid lines land on nice numbers).
    final maxSteps =
        _roundUpSteps(points.map((p) => p.steps).fold<int>(0, _max));
    final maxDistance = _roundUpDistance(
        points.map((p) => p.distanceMeters).fold<double>(0, _maxD));
    final maxCalories = _roundUpCalories(
        points.map((p) => p.calories).fold<int>(0, _max));

    // ---- Grid + right-side labels (steps is the primary axis) --------
    _paintGrid(canvas, chartRect, maxSteps);

    // ---- Optional overlays (distance + kcal) below the steps line so
    // the primary trace paints on top -------------------------------
    if (revealProgress > 0) {
      _paintMetricLine(
        canvas,
        chartRect,
        points.map((p) => p.distanceMeters / (maxDistance == 0 ? 1 : maxDistance)).toList(),
        distanceColor.withValues(alpha: 0.4 * revealProgress),
      );
      _paintMetricLine(
        canvas,
        chartRect,
        points.map((p) => p.calories / (maxCalories == 0 ? 1 : maxCalories)).toList(),
        caloriesColor.withValues(alpha: 0.4 * revealProgress),
      );
      _paintLegend(canvas, chartRect);
    }

    // ---- Primary steps trace -----------------------------------------
    final stepsNorm = points
        .map((p) => p.steps / (maxSteps == 0 ? 1 : maxSteps))
        .toList();
    _paintSteps(canvas, chartRect, stepsNorm);

    // ---- X-axis day labels -------------------------------------------
    _paintDayLabels(canvas, chartRect, size);
  }

  // -------------------------------------------------------------------
  // Drawing helpers
  // -------------------------------------------------------------------

  void _drawEmpty(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: 'No days selected',
        style: TextStyle(color: labelColor, fontSize: 13),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(
        (size.width - tp.width) / 2,
        (size.height - tp.height) / 2,
      ),
    );
  }

  void _paintGrid(Canvas canvas, Rect chart, int maxSteps) {
    final linePaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    // Three grid rows: max, half, base. Matches the reference (6 km /
    // 3 km / 0 km) but expressed in steps for our chart.
    for (int i = 0; i < 3; i++) {
      final y = chart.top + chart.height * i / 2;
      canvas.drawLine(
        Offset(chart.left, y),
        Offset(chart.right, y),
        linePaint,
      );
      final value = (maxSteps * (1 - i / 2)).round();
      _paintText(
        canvas,
        _fmtSteps(value),
        // 16 dp gap between chart edge and label — has to clear the
        // 12-px halo around the latest data point + a 4 px buffer.
        Offset(chart.right + 16, y - 7),
        color: labelColor,
        fontSize: 12,
        weight: FontWeight.w700,
      );
    }
  }

  void _paintSteps(Canvas canvas, Rect chart, List<double> norm) {
    final xs = _xPositions(chart, norm.length);
    final ys = norm
        .map((v) => chart.bottom - v.clamp(0.0, 1.0) * chart.height)
        .toList();

    // Area fill — vertical gradient of primary → transparent.
    final fillPath = Path()..moveTo(xs.first, chart.bottom);
    for (int i = 0; i < xs.length; i++) {
      fillPath.lineTo(xs[i], ys[i]);
    }
    fillPath.lineTo(xs.last, chart.bottom);
    fillPath.close();
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          // 0.28 top alpha (was 0.35) — Strava's fade sits closer to
          // this value; the earlier tint read a touch too bold.
          stepsColor.withValues(alpha: 0.28),
          stepsColor.withValues(alpha: 0.02),
        ],
      ).createShader(chart);
    canvas.drawPath(fillPath, fillPaint);

    // Stroke — 4 px matches Strava's chunkier trace weight; the
    // earlier 3 px read as thin against the halo at the endpoint.
    final strokePaint = Paint()
      ..color = stepsColor
      ..strokeWidth = 4
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final linePath = Path()..moveTo(xs.first, ys.first);
    for (int i = 1; i < xs.length; i++) {
      linePath.lineTo(xs[i], ys[i]);
    }
    canvas.drawPath(linePath, strokePaint);

    // Markers — every point a small filled circle. The rightmost
    // (latest day) gets a bigger halo per the reference.
    final markerFill = Paint()..color = stepsColor;
    final markerRing = Paint()
      ..color = stepsColor.withValues(alpha: 0.25)
      ..style = PaintingStyle.fill;
    for (int i = 0; i < xs.length; i++) {
      final isLatest = i == xs.length - 1;
      // Halo shrunk 16 → 12 (with a matching inner dot 7 → 6) so it
      // stops overlapping the y-axis labels on the right edge.
      canvas.drawCircle(
        Offset(xs[i], ys[i]),
        isLatest ? 12 : 5,
        isLatest ? markerRing : markerFill,
      );
      if (isLatest) {
        canvas.drawCircle(Offset(xs[i], ys[i]), 6, markerFill);
      }
    }
  }

  /// Paint an overlay trace (distance or calories) using the same
  /// x-positions as the steps line. Alpha is baked into [color].
  void _paintMetricLine(
      Canvas canvas, Rect chart, List<double> norm, Color color) {
    if (norm.isEmpty) return;
    final xs = _xPositions(chart, norm.length);
    final ys = norm
        .map((v) => chart.bottom - v.clamp(0.0, 1.0) * chart.height)
        .toList();
    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(xs.first, ys.first);
    for (int i = 1; i < xs.length; i++) {
      path.lineTo(xs[i], ys[i]);
    }
    canvas.drawPath(path, strokePaint);
    final dotPaint = Paint()..color = color;
    for (int i = 0; i < xs.length; i++) {
      canvas.drawCircle(Offset(xs[i], ys[i]), 3, dotPaint);
    }
  }

  void _paintLegend(Canvas canvas, Rect chart) {
    // Compact "Distance • Kcal" hint at the top-left so the user
    // knows what the overlay lines represent.
    _paintDot(canvas, Offset(chart.left + 2, chart.top - 6),
        distanceColor.withValues(alpha: 0.9 * revealProgress));
    _paintText(
      canvas,
      'Distance',
      Offset(chart.left + 12, chart.top - 14),
      color: labelColor.withValues(alpha: revealProgress),
      fontSize: 10,
      weight: FontWeight.w700,
    );
    _paintDot(canvas, Offset(chart.left + 76, chart.top - 6),
        caloriesColor.withValues(alpha: 0.9 * revealProgress));
    _paintText(
      canvas,
      'Kcal',
      Offset(chart.left + 86, chart.top - 14),
      color: labelColor.withValues(alpha: revealProgress),
      fontSize: 10,
      weight: FontWeight.w700,
    );
  }

  void _paintDayLabels(Canvas canvas, Rect chart, Size size) {
    final xs = _xPositions(chart, points.length);
    for (int i = 0; i < xs.length; i++) {
      // Day-of-month only — the "d MMM" version overflowed adjacent
      // labels on a 7-point chart (visible as `25 Jun26 Jun`). The
      // user picked these days so they know the month; the numeric
      // sequence disambiguates a Jun → Jul crossover.
      final label = DateFormat('d').format(points[i].date);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: labelColor,
            fontFamily: 'Manrope',
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          (xs[i] - tp.width / 2).clamp(0.0, size.width - tp.width),
          chart.bottom + 8,
        ),
      );
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset origin, {
    required Color color,
    required double fontSize,
    FontWeight weight = FontWeight.w700,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: weight,
          fontFamily: 'Manrope',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, origin);
  }

  void _paintDot(Canvas canvas, Offset centre, Color color) {
    final paint = Paint()..color = color;
    canvas.drawCircle(centre, 4, paint);
  }

  // -------------------------------------------------------------------
  // Layout math
  // -------------------------------------------------------------------

  /// Equally-spaced x positions across the chart width. Two points →
  /// endpoints only; 7 points → 7 evenly-spaced positions.
  List<double> _xPositions(Rect chart, int count) {
    if (count == 1) return [chart.left + chart.width / 2];
    return List<double>.generate(
      count,
      (i) => chart.left + chart.width * i / (count - 1),
    );
  }

  // -------------------------------------------------------------------
  // Rounding + formatting
  // -------------------------------------------------------------------

  static int _max(int a, int b) => a > b ? a : b;
  static double _maxD(double a, double b) => a > b ? a : b;

  /// Round the peak step count up to a friendly grid value so the
  /// three y-axis rows land on numbers a user can read at a glance.
  /// Below 5K we snap to 5K (typical resting-day peaks); above 5K we
  /// snap to the next 2K so the mid grid line stays clean (e.g. peak
  /// 9K → max 10K → mid 5K; peak 11K → max 12K → mid 6K) and the
  /// trace uses the vertical space instead of hugging the baseline.
  int _roundUpSteps(int peak) {
    if (peak <= 5000) return 5000;
    return ((peak / 2000).ceil()) * 2000;
  }

  double _roundUpDistance(double peakMeters) {
    if (peakMeters <= 0) return 1000;
    // Round up to the nearest kilometre.
    return ((peakMeters / 1000).ceil()) * 1000.0;
  }

  int _roundUpCalories(int peak) {
    if (peak <= 0) return 100;
    return ((peak / 100).ceil()) * 100;
  }

  String _fmtSteps(int n) {
    if (n < 1000) return '$n';
    final k = n / 1000.0;
    if (k < 10) return '${k.toStringAsFixed(1)}K';
    return '${k.round()}K';
  }

  @override
  bool shouldRepaint(_TrendChartPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.revealProgress != revealProgress;
  }
}
