/// Today's intake measured against today's target — the two numbers the dial
/// draws, and the arithmetic between them.
///
/// Separated from the widget for the reason `projection_format.dart` is: these
/// are assertions a test wants to make without pumping a CustomPaint, and a ring
/// whose fill disagrees with the caption under it is the one bug that would make
/// the whole dial untrustworthy.
library;

import '../../models/projection.dart';
import 'projection_engine.dart';

/// One day's calorie budget.
class CalorieBudget {
  const CalorieBudget({
    required this.consumedKcal,
    required this.targetKcal,
    this.entryCount = 0,
  });

  /// Nothing logged, and no target to measure it against.
  static const CalorieBudget empty =
      CalorieBudget(consumedKcal: 0, targetKcal: null);

  /// What today's meals add up to.
  final double consumedKcal;

  /// What the app says today should be, or null when the profile cannot support
  /// a figure. See [ProjectionEngine.dailyCalorieTargetKcal].
  final double? targetKcal;

  /// How many meals produced [consumedKcal]. Tells a logged zero-calorie day
  /// apart from a day with nothing logged, which look identical from the number.
  final int entryCount;

  /// Builds the day's budget from the projection that carries the target.
  ///
  /// [projection] is nullable because the dial must render the moment intake is
  /// known: the projection reads four sources, and a user who just logged lunch
  /// should not watch an empty ring while a profile document loads.
  factory CalorieBudget.from({
    required double consumedKcal,
    required int entryCount,
    required Projection? projection,
  }) {
    return CalorieBudget(
      consumedKcal: consumedKcal,
      targetKcal: projection == null
          ? null
          : ProjectionEngine.dailyCalorieTargetKcal(projection),
      entryCount: entryCount,
    );
  }

  bool get hasTarget => targetKcal != null && targetKcal! > 0;

  bool get isEmpty => entryCount == 0;

  /// Signed kcal still available. Negative once the target is passed.
  double get remainingKcal => hasTarget ? targetKcal! - consumedKcal : 0;

  bool get isOver => hasTarget && consumedKcal > targetKcal!;

  /// How much of the ring is filled, 0..1.
  ///
  /// Clamped rather than allowed past 1: the arc has nowhere to go, and letting
  /// the sweep wrap would draw 1.5 targets as though it were half of one.
  double get fillFraction {
    if (!hasTarget || consumedKcal <= 0) return 0;
    return (consumedKcal / targetKcal!).clamp(0.0, 1.0).toDouble();
  }

  /// The second sweep, 0..1, drawn over a full ring once the target is passed.
  ///
  /// Its own fraction rather than a longer fill, because "you are over" is a
  /// different fact from "you are nearly there" and a ring that simply looked
  /// full would say the second one.
  double get overshootFraction {
    if (!isOver) return 0;
    return ((consumedKcal - targetKcal!) / targetKcal!)
        .clamp(0.0, 1.0)
        .toDouble();
  }
}

/// `420`, `1,850` — the number inside the ring.
String calorieLabel(double kcal) {
  final s = kcal.round().abs().toString();
  final buf = StringBuffer();
  if (kcal.round() < 0) buf.write('-');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

/// The line under the dial: where today stands, in one phrase.
///
/// Every branch names a number the user can act on. "On target" alone would be
/// the kind of encouragement that tells them nothing about what to eat next.
String calorieBudgetLabel(CalorieBudget budget) {
  if (!budget.hasTarget) {
    return budget.isEmpty ? 'NOTHING LOGGED YET' : 'NO TARGET YET';
  }
  final target = calorieLabel(budget.targetKcal!);
  if (budget.isOver) {
    return '${calorieLabel(-budget.remainingKcal)} OVER $target';
  }
  return '${calorieLabel(budget.remainingKcal)} LEFT OF $target';
}

/// Why there is no target, phrased as the thing to go and do.
///
/// Only two things can be missing, and they are fixed in different places: the
/// energy model needs height, age and weight, and it needs them from the profile
/// rather than from anything the user can log today.
String calorieTargetHintLabel(Projection? projection) {
  if (projection == null) return 'READING YOUR PROFILE';
  return 'ADD HEIGHT, AGE & WEIGHT IN SETTINGS';
}
