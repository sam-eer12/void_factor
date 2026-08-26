import 'package:flutter/material.dart';

import '../features/projection/projection_engine.dart';
import '../features/projection/projection_format.dart';
import '../models/projection.dart';
import '../theme/monolith_theme.dart';

/// The weigh-in series and where it is heading.
///
/// Replaces a `CustomPaint` whose path was eight hardcoded offsets. The motif is
/// deliberately inherited from it — 2.5px stroke, 8px square dots, faint
/// horizontal rules — because that motif is the app's, and the change here is
/// that the line now describes the user.
///
/// Three things are drawn and they must be told apart at a glance in a palette
/// with no colour to spare, so each gets its own encoding: measured weight is a
/// solid line with filled squares, the projection is a dashed line with hollow
/// squares, and the target is a thin dashed rule across the plot. The legend
/// underneath names all three rather than leaving the reader to infer them.
class WeightTrajectoryChart extends StatelessWidget {
  const WeightTrajectoryChart({super.key, required this.projection});

  final Projection projection;

  /// Matches the height the mock established, so the card's proportions survive
  /// the rebuild.
  static const double height = 180;

  /// Width reserved for the kilogram labels, left of the plot.
  ///
  /// Shared with the axis row below, which is padded by the same amount so its
  /// first and last ticks sit exactly at the ends of the plotted range.
  static const double gutter = 38;

  /// Copy for a user who has never weighed in.
  ///
  /// An empty chart frame with a flat line through it would be a chart claiming
  /// the user's weight has not changed. Saying there is nothing yet is both true
  /// and the only version that tells them what to do about it.
  static const String emptyTitle = 'NO WEIGH-INS YET';
  static const String emptyBody = 'LOG YOUR WEIGHT AND THE TRAJECTORY DRAWS '
      'ITSELF FROM HERE.';

  @override
  Widget build(BuildContext context) {
    if (projection.observed.isEmpty) return _empty();

    final first = projection.observed.first.day;
    final last = (projection.projected.isNotEmpty
            ? projection.projected.last
            : projection.observed.last)
        .day;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: height,
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border.all(color: MonolithTheme.primary, width: 1),
          ),
          child: CustomPaint(
            painter: _TrajectoryPainter(
              observed: projection.observed,
              projected: projection.projected,
              targetWeightKg: projection.targetWeightKg,
              labelStyle: MonolithTheme.labelSmall
                  .copyWith(color: MonolithTheme.outline),
            ),
            size: const Size(double.infinity, height),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          // Aligned with the plot, not the card, so the dates name the ends of
          // the line rather than the ends of the box.
          padding: const EdgeInsets.only(left: gutter),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(projectionDayLabel(first),
                  style: MonolithTheme.labelSmall),
              // Suppressed when both ends are the same day: one weigh-in and no
              // projection is a single dot, and printing its date twice would
              // imply a range.
              if (last != first)
                Text(projectionDayLabel(last),
                    style: MonolithTheme.labelSmall),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _legend(),
      ],
    );
  }

  Widget _empty() {
    return Container(
      height: height,
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border.all(color: MonolithTheme.primary, width: 1),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emptyTitle, style: MonolithTheme.labelLarge),
          const SizedBox(height: 8),
          Text(
            emptyBody,
            style: MonolithTheme.bodyMedium
                .copyWith(color: MonolithTheme.outline),
          ),
        ],
      ),
    );
  }

  /// Names the three encodings, using the same paint that draws them.
  ///
  /// The projected swatch omits its own dashed line: a 16px run of dashes and a
  /// hollow square in the same swatch reads as noise at this size, and the
  /// hollow square is the distinguishing mark.
  Widget _legend() {
    final style = MonolithTheme.labelSmall.copyWith(
      color: MonolithTheme.outline,
    );
    return Row(
      children: [
        _legendItem(
          const _Swatch(kind: _SwatchKind.observed),
          'LOGGED',
          style,
        ),
        const SizedBox(width: 16),
        _legendItem(
          const _Swatch(kind: _SwatchKind.projected),
          'PROJECTED',
          style,
        ),
        const SizedBox(width: 16),
        _legendItem(
          const _Swatch(kind: _SwatchKind.target),
          'TARGET',
          style,
        ),
      ],
    );
  }

  Widget _legendItem(Widget swatch, String label, TextStyle style) {
    return Row(
      children: [
        swatch,
        const SizedBox(width: 6),
        Text(label, style: style),
      ],
    );
  }
}

enum _SwatchKind { observed, projected, target }

/// A legend marker, drawn to the same dimensions the plot uses.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.kind});

  final _SwatchKind kind;

  @override
  Widget build(BuildContext context) {
    switch (kind) {
      case _SwatchKind.observed:
        return Container(
          width: _TrajectoryPainter.dotSize,
          height: _TrajectoryPainter.dotSize,
          color: MonolithTheme.primary,
        );
      case _SwatchKind.projected:
        return Container(
          width: _TrajectoryPainter.dotSize,
          height: _TrajectoryPainter.dotSize,
          decoration: BoxDecoration(
            color: MonolithTheme.surface,
            border: Border.all(color: MonolithTheme.primary, width: 1.5),
          ),
        );
      case _SwatchKind.target:
        return const SizedBox(
          width: 16,
          height: _TrajectoryPainter.dotSize,
          child: CustomPaint(painter: _TargetSwatchPainter()),
        );
    }
  }
}

/// The target rule at swatch scale — the same dash routine as the plot, so the
/// legend cannot drift from what it describes.
class _TargetSwatchPainter extends CustomPainter {
  const _TargetSwatchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    _TrajectoryPainter.drawDashedLine(
      canvas,
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()
        ..color = MonolithTheme.primary
        ..strokeWidth = _TrajectoryPainter.targetStrokeWidth,
      dash: 3,
      gap: 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _TrajectoryPainter extends CustomPainter {
  _TrajectoryPainter({
    required this.observed,
    required this.projected,
    required this.targetWeightKg,
    required this.labelStyle,
  });

  final List<WeightPoint> observed;
  final List<WeightPoint> projected;
  final double targetWeightKg;

  /// Resolved by the widget and passed in: `MonolithTheme.labelSmall` builds a
  /// `TextStyle` through `GoogleFonts` on every read, and `paint` runs far more
  /// often than the widget rebuilds.
  final TextStyle labelStyle;

  /// The square-dot motif, inherited from the mock this replaces.
  static const double dotSize = 8;
  static const double seriesStrokeWidth = 2.5;
  static const double targetStrokeWidth = 1.5;

  /// Padding inside the frame. Half a dot plus a little, so a point sitting at
  /// the very top of the range is not clipped by the border.
  static const double inset = 8;

  /// The narrowest kilogram range the y axis will show.
  ///
  /// Without a floor, a series that moved 200 g across a fortnight would be
  /// scaled until it filled the frame, and ordinary daily water swing would be
  /// rendered as a dramatic trend. A 2 kg minimum keeps a flat line looking
  /// flat.
  static const double minSpanKg = 2;

  /// Breathing room above and below the extremes, as a fraction of the span.
  static const double rangePadding = 0.08;

  @override
  void paint(Canvas canvas, Size size) {
    if (observed.isEmpty) return;

    final plot = Rect.fromLTRB(
      WeightTrajectoryChart.gutter,
      inset,
      size.width - inset,
      size.height - inset,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    final all = [...observed, ...projected];
    final origin = all.first.day;
    final spanDays = ProjectionEngine.dayIndex(all.last.day, origin);

    final (yMin, yMax) = _range(all);

    double xFor(DateTime day) {
      // A single day of data has no span to scale against; centring it is the
      // only placement that does not imply a direction.
      if (spanDays <= 0) return plot.center.dx;
      final t = ProjectionEngine.dayIndex(day, origin) / spanDays;
      return plot.left + t * plot.width;
    }

    double yFor(double kg) {
      final t = (kg - yMin) / (yMax - yMin);
      return plot.bottom - t * plot.height;
    }

    _paintGrid(canvas, plot, yMin, yMax);
    _paintTarget(canvas, plot, yFor);
    _paintProjected(canvas, xFor, yFor);
    _paintObserved(canvas, xFor, yFor);
  }

  /// The visible kilogram range: every plotted point, plus the target.
  ///
  /// The target is included so the gap still to close is visible rather than
  /// implied — a chart of a weight-loss trend that crops out the goal line looks
  /// identical whether the goal is 1 kg or 20 kg away. It costs little, because
  /// the projected ray already reaches most of the way there.
  (double, double) _range(List<WeightPoint> points) {
    var min = points.first.weightKg;
    var max = min;
    for (final point in points) {
      if (point.weightKg < min) min = point.weightKg;
      if (point.weightKg > max) max = point.weightKg;
    }
    if (targetWeightKg > 0) {
      if (targetWeightKg < min) min = targetWeightKg;
      if (targetWeightKg > max) max = targetWeightKg;
    }

    final span = max - min;
    if (span < minSpanKg) {
      final centre = (max + min) / 2;
      min = centre - minSpanKg / 2;
      max = centre + minSpanKg / 2;
    }

    final pad = (max - min) * rangePadding;
    return (min - pad, max + pad);
  }

  /// Three rules across the plot, each labelled with the weight it sits at.
  ///
  /// The mock drew four unlabelled rules at fifths. Labelling them is what turns
  /// the same texture into a readable axis; three rather than four so the labels
  /// have room not to collide.
  void _paintGrid(Canvas canvas, Rect plot, double yMin, double yMax) {
    final gridPaint = Paint()
      ..color = MonolithTheme.primary.withValues(alpha: 0.1)
      ..strokeWidth = 1;

    for (final fraction in const [0.25, 0.5, 0.75]) {
      final y = plot.top + plot.height * fraction;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);

      final kg = yMax - (yMax - yMin) * fraction;
      final label = TextPainter(
        text: TextSpan(text: projectionKgLabel(kg), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        // Right-aligned against the plot edge, vertically centred on its rule.
        Offset(plot.left - 6 - label.width, y - label.height / 2),
      );
    }
  }

  void _paintTarget(Canvas canvas, Rect plot, double Function(double) yFor) {
    if (targetWeightKg <= 0) return;
    final y = yFor(targetWeightKg);
    drawDashedLine(
      canvas,
      Offset(plot.left, y),
      Offset(plot.right, y),
      Paint()
        ..color = MonolithTheme.primary.withValues(alpha: 0.55)
        ..strokeWidth = targetStrokeWidth,
      dash: 6,
      gap: 4,
    );
  }

  void _paintProjected(
    Canvas canvas,
    double Function(DateTime) xFor,
    double Function(double) yFor,
  ) {
    if (projected.length < 2) return;

    final points = [
      for (final point in projected)
        Offset(xFor(point.day), yFor(point.weightKg)),
    ];

    final linePaint = Paint()
      ..color = MonolithTheme.primary
      ..strokeWidth = seriesStrokeWidth
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < points.length - 1; i++) {
      drawDashedLine(canvas, points[i], points[i + 1], linePaint,
          dash: 6, gap: 4);
    }

    // Hollow squares, filled with the surface colour first so the dashed line
    // does not show through the middle of a marker.
    final fill = Paint()
      ..color = MonolithTheme.surface
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = MonolithTheme.primary
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    // From index 1: the first projected point *is* the last observed one, and
    // drawing a hollow marker over that filled square would erase a real
    // measurement.
    for (var i = 1; i < points.length; i++) {
      final rect = Rect.fromCenter(
        center: points[i],
        width: dotSize,
        height: dotSize,
      );
      canvas
        ..drawRect(rect, fill)
        ..drawRect(rect, stroke);
    }
  }

  void _paintObserved(
    Canvas canvas,
    double Function(DateTime) xFor,
    double Function(double) yFor,
  ) {
    final points = [
      for (final point in observed)
        Offset(xFor(point.day), yFor(point.weightKg)),
    ];

    if (points.length >= 2) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = MonolithTheme.primary
          ..strokeWidth = seriesStrokeWidth
          ..style = PaintingStyle.stroke,
      );
    }

    final dotPaint = Paint()
      ..color = MonolithTheme.primary
      ..style = PaintingStyle.fill;
    for (final point in points) {
      canvas.drawRect(
        Rect.fromCenter(center: point, width: dotSize, height: dotSize),
        dotPaint,
      );
    }
  }

  /// Walks from [from] to [to] laying down [dash]-long strokes separated by
  /// [gap].
  ///
  /// Static and shared with the legend swatch so the dashes in the key are the
  /// dashes on the chart.
  static void drawDashedLine(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    final delta = to - from;
    final length = delta.distance;
    if (length <= 0) return;

    final step = delta / length;
    var travelled = 0.0;
    while (travelled < length) {
      final end = (travelled + dash).clamp(0.0, length);
      canvas.drawLine(from + step * travelled, from + step * end, paint);
      travelled = end + gap;
    }
  }

  /// The series lists are rebuilt whenever the projection is recomputed and are
  /// never mutated in place, so identity is a sound test for "same data".
  @override
  bool shouldRepaint(covariant _TrajectoryPainter old) {
    return old.observed != observed ||
        old.projected != projected ||
        old.targetWeightKg != targetWeightKg ||
        old.labelStyle != labelStyle;
  }
}
