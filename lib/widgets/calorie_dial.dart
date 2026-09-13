import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../features/projection/calorie_budget.dart';
import '../theme/monolith_theme.dart';

/// The ring, on its own, with the day's figure inside it.
///
/// Drawn rather than composed from a `CircularProgressIndicator` because that
/// widget cannot say "past full": the overshoot is a second sweep laid over a
/// complete ring, and an indicator clamped at 1.0 would render a user who ate
/// 3,000 against a 2,000 target identically to one who landed exactly on it.
///
/// Square caps, no rounded ends. The rest of the app is 2px borders and hard
/// shadows; a softened arc would be the only curve in the design system that
/// apologised for itself.
class CalorieDial extends StatelessWidget {
  const CalorieDial({
    super.key,
    required this.budget,
    this.diameter = 176,
    this.strokeWidth = 14,
    this.animate = true,
  });

  final CalorieBudget budget;
  final double diameter;
  final double strokeWidth;

  /// Off in tests that assert on a settled frame rather than pump one.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final fill = budget.fillFraction;
    final overshoot = budget.overshootFraction;

    return Semantics(
      label: budget.hasTarget
          ? '${calorieLabel(budget.consumedKcal)} of '
              '${calorieLabel(budget.targetKcal!)} calories, '
              '${calorieBudgetLabel(budget).toLowerCase()}'
          : '${calorieLabel(budget.consumedKcal)} calories today, no target set',
      child: ExcludeSemantics(
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // One tween drives both sweeps: they are two halves of a single
              // quantity, and animating them independently would let the
              // overshoot arrive before the ring it sits on was full.
              TweenAnimationBuilder<double>(
                tween: Tween(begin: animate ? 0 : 1, end: 1),
                duration: Duration(milliseconds: animate ? 650 : 0),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => CustomPaint(
                  size: Size.square(diameter),
                  painter: _DialPainter(
                    fill: fill * t,
                    overshoot: overshoot * t,
                    strokeWidth: strokeWidth,
                  ),
                ),
              ),
              Padding(
                // Keeps a five-figure day off the ring it is measured against.
                padding: EdgeInsets.all(strokeWidth + 12),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        calorieLabel(budget.consumedKcal),
                        style: MonolithTheme.displayLarge.copyWith(
                          color: budget.isOver
                              ? MonolithTheme.error
                              : MonolithTheme.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'CAL',
                        style: MonolithTheme.labelMedium.copyWith(
                          color: MonolithTheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  const _DialPainter({
    required this.fill,
    required this.overshoot,
    required this.strokeWidth,
  });

  final double fill;
  final double overshoot;
  final double strokeWidth;

  /// Twelve o'clock. Flutter measures arcs from three, so every sweep below is
  /// offset by a quarter turn — a dial that started on the right would read as
  /// broken to anyone who has seen a clock.
  static const double _start = -math.pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final circle = Rect.fromCircle(center: center, radius: radius);

    Paint stroke(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    canvas.drawCircle(
      center,
      radius,
      stroke(MonolithTheme.surfaceContainerHigh),
    );

    if (fill > 0) {
      canvas.drawArc(
        circle,
        _start,
        2 * math.pi * fill,
        false,
        stroke(MonolithTheme.primary),
      );
    }

    // Laid over the full ring, from the top again, so the eye reads it as a
    // second lap rather than as more of the first.
    if (overshoot > 0) {
      canvas.drawArc(
        circle,
        _start,
        2 * math.pi * overshoot,
        false,
        stroke(MonolithTheme.error),
      );
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.fill != fill ||
      old.overshoot != overshoot ||
      old.strokeWidth != strokeWidth;
}

/// The dial as the dashboard shows it: titled, captioned, in a Monolith card.
///
/// [budget] is null only while the food log is still being read — the target is
/// allowed to be missing on a budget that exists, and says so in the caption
/// rather than by withholding the ring.
class CalorieDialCard extends StatelessWidget {
  const CalorieDialCard({
    super.key,
    required this.budget,
    this.targetHint,
    this.onTap,
    this.animate = true,
  });

  final CalorieBudget? budget;

  /// Shown in place of the caption's second line when there is no target, to
  /// name what is missing. See [calorieTargetHintLabel].
  final String? targetHint;

  final VoidCallback? onTap;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final value = budget ?? CalorieBudget.empty;
    final loading = budget == null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        decoration: MonolithTheme.cardDecoration,
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'CALORIES TODAY',
                  style: MonolithTheme.labelMedium,
                ),
                const Icon(
                  Icons.local_fire_department,
                  color: MonolithTheme.primary,
                  size: 20,
                ),
              ],
            ),
            const SizedBox(height: 16),
            CalorieDial(budget: value, animate: animate && !loading),
            const SizedBox(height: 16),
            Text(
              loading ? 'READING YOUR LOG' : calorieBudgetLabel(value),
              style: MonolithTheme.labelLarge.copyWith(
                color: value.isOver ? MonolithTheme.error : MonolithTheme.primary,
              ),
              textAlign: TextAlign.center,
            ),
            if (!loading && !value.hasTarget && targetHint != null) ...[
              const SizedBox(height: 4),
              Text(
                targetHint!,
                style: MonolithTheme.labelSmall.copyWith(
                  color: MonolithTheme.outline,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
