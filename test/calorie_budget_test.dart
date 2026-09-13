import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/calorie_budget.dart';
import 'package:void_factor/features/projection/projection_engine.dart';
import 'package:void_factor/models/projection.dart';
import 'package:void_factor/models/user_profile.dart';

void main() {
  /// A projection built field-by-field, as in `recommendation_engine_test`:
  /// the target depends on four figures, and reaching a specific combination of
  /// them through the engine would mean constructing logs that happen to produce
  /// it. The defaults describe a 2,550 kcal/day user losing 0.5 kg/week.
  Projection projectionOf({
    double currentWeightKg = 80,
    double targetWeightKg = 75,
    WeightGoal goal = WeightGoal.lose,
    double targetRatePerWeekKg = 0.5,
    double bmrKcal = 1750,
    double tdeeKcal = 2550,
  }) {
    return Projection(
      observed: const [],
      projected: const [],
      currentWeightKg: currentWeightKg,
      targetWeightKg: targetWeightKg,
      goal: goal,
      ratePerWeekKg: -0.5,
      targetRatePerWeekKg: targetRatePerWeekKg,
      basis: ProjectionBasis.measured,
      status: ProjectionStatus.onTrack,
      daysToGoal: 70,
      goalDate: DateTime(2026, 11, 4),
      bmrKcal: bmrKcal,
      activeKcal: 400,
      tdeeKcal: tdeeKcal,
      intakeKcal: 2000,
      proteinGPerDay: 160,
      balanceKcal: -550,
      loggedDayCount: 14,
      intakeWindowDays: ProjectionEngine.intakeWindowDays,
      weighInDayCount: 12,
      seriesSpanDays: 28,
      activeEnergyFromDevice: true,
    );
  }

  group('daily calorie target', () {
    test('a maintain goal eats its expenditure, whatever rate is stored', () {
      // The rate field keeps whatever was last picked in Goals & Diet, so a user
      // who switched to maintain must not inherit the old deficit.
      final target = ProjectionEngine.dailyCalorieTargetKcal(
        projectionOf(goal: WeightGoal.maintain, targetRatePerWeekKg: 0.75),
      );

      expect(target, 2550);
    });

    test('losing subtracts the requested rate, converted at 7700 kcal/kg', () {
      // 0.5 kg/week is 550 kcal/day.
      final target = ProjectionEngine.dailyCalorieTargetKcal(projectionOf());

      expect(target, closeTo(2000, 0.001));
    });

    test('gaining adds it', () {
      final target = ProjectionEngine.dailyCalorieTargetKcal(projectionOf(
        goal: WeightGoal.gain,
        currentWeightKg: 70,
        targetWeightKg: 76,
      ));

      expect(target, closeTo(3100, 0.001));
    });

    test('a lose goal already past target stops prescribing a deficit', () {
      // Direction comes from the remaining kilograms, not from the goal enum:
      // someone who overshot downwards is told to eat more, not less.
      final target = ProjectionEngine.dailyCalorieTargetKcal(projectionOf(
        currentWeightKg: 74,
        targetWeightKg: 75,
      ));

      expect(target, closeTo(3100, 0.001));
    });

    test('no requested rate means no adjustment', () {
      final target =
          ProjectionEngine.dailyCalorieTargetKcal(projectionOf(targetRatePerWeekKg: 0));

      expect(target, 2550);
    });

    test('never prescribes below the resting requirement', () {
      // 0.75 kg/week is an 825 kcal/day deficit. Against a 1,800 kcal expenditure
      // that subtracts to 975 — a number no one should be shown as a goal.
      final target = ProjectionEngine.dailyCalorieTargetKcal(projectionOf(
        targetRatePerWeekKg: 0.75,
        tdeeKcal: 1800,
        bmrKcal: 1500,
      ));

      expect(target, 1500);
    });

    test('is null when there is no expenditure model to build on', () {
      // tdee is zero until height, age and weight are all known.
      final target =
          ProjectionEngine.dailyCalorieTargetKcal(projectionOf(tdeeKcal: 0));

      expect(target, isNull);
    });
  });

  group('CalorieBudget', () {
    test('fills the ring by the share of the target eaten', () {
      const budget = CalorieBudget(consumedKcal: 1000, targetKcal: 2000);

      expect(budget.fillFraction, 0.5);
      expect(budget.overshootFraction, 0);
      expect(budget.remainingKcal, 1000);
      expect(budget.isOver, isFalse);
    });

    test('a full ring and a separate overshoot once the target is passed', () {
      const budget = CalorieBudget(consumedKcal: 2500, targetKcal: 2000);

      expect(budget.fillFraction, 1.0);
      expect(budget.overshootFraction, 0.25);
      expect(budget.remainingKcal, -500);
      expect(budget.isOver, isTrue);
    });

    test('the overshoot stops at one lap', () {
      // Otherwise a sweep past 2π would wrap and draw 2.5 targets as half of one.
      const budget = CalorieBudget(consumedKcal: 9000, targetKcal: 2000);

      expect(budget.fillFraction, 1.0);
      expect(budget.overshootFraction, 1.0);
    });

    test('no target leaves the ring empty rather than guessing at one', () {
      const budget = CalorieBudget(consumedKcal: 1400, targetKcal: null);

      expect(budget.hasTarget, isFalse);
      expect(budget.fillFraction, 0);
      expect(budget.overshootFraction, 0);
    });

    test('takes its target from the projection, and none without one', () {
      final withProjection = CalorieBudget.from(
        consumedKcal: 500,
        entryCount: 2,
        projection: projectionOf(),
      );
      final stillLoading = CalorieBudget.from(
        consumedKcal: 500,
        entryCount: 2,
        projection: null,
      );

      expect(withProjection.targetKcal, closeTo(2000, 0.001));
      expect(stillLoading.targetKcal, isNull);
      // The intake survives either way — that is the point of not awaiting it.
      expect(stillLoading.consumedKcal, 500);
    });
  });

  group('labels', () {
    test('groups thousands', () {
      expect(calorieLabel(420), '420');
      expect(calorieLabel(1850.4), '1,850');
      expect(calorieLabel(12345), '12,345');
      expect(calorieLabel(0), '0');
    });

    test('names what is left, or what is over', () {
      expect(
        calorieBudgetLabel(
            const CalorieBudget(consumedKcal: 420, targetKcal: 2000)),
        '1,580 LEFT OF 2,000',
      );
      expect(
        calorieBudgetLabel(
            const CalorieBudget(consumedKcal: 2310, targetKcal: 2000)),
        '310 OVER 2,000',
      );
    });

    test('distinguishes an unlogged day from an untargeted one', () {
      expect(
        calorieBudgetLabel(
            const CalorieBudget(consumedKcal: 0, targetKcal: null)),
        'NOTHING LOGGED YET',
      );
      expect(
        calorieBudgetLabel(const CalorieBudget(
            consumedKcal: 600, targetKcal: null, entryCount: 1)),
        'NO TARGET YET',
      );
    });

    test('the hint says whether to wait or to go and fix the profile', () {
      expect(calorieTargetHintLabel(null), 'READING YOUR PROFILE');
      expect(
        calorieTargetHintLabel(projectionOf(tdeeKcal: 0)),
        'ADD HEIGHT, AGE & WEIGHT IN SETTINGS',
      );
    });
  });
}
