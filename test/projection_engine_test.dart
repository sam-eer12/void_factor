import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/projection_engine.dart';
import 'package:void_factor/models/energy_window.dart';
import 'package:void_factor/models/food_entry.dart';
import 'package:void_factor/models/projection.dart';
import 'package:void_factor/models/user_profile.dart';
import 'package:void_factor/models/weight_entry.dart';

void main() {
  // A fixed "today" so every window boundary in these tests is exact.
  final now = DateTime(2026, 8, 26, 9, 0);

  DateTime daysAgo(int n) => ProjectionEngine.addDays(
        ProjectionEngine.dayOf(now),
        -n,
      );

  WeightEntry weighIn(double kg, int daysBack, {int hour = 7}) {
    final day = daysAgo(daysBack);
    return WeightEntry(
      id: 'w-$daysBack-$hour-$kg',
      weightKg: kg,
      recordedAt: DateTime(day.year, day.month, day.day, hour),
    );
  }

  FoodEntry meal(double kcal, int daysBack, {double quantity = 1}) {
    final day = daysAgo(daysBack);
    return FoodEntry(
      id: 'f-$daysBack-$kcal-$quantity',
      name: 'Meal',
      nutrients: Nutrients(calories: kcal),
      quantity: quantity,
      source: FoodSource.manual,
      loggedAt: DateTime(day.year, day.month, day.day, 12),
    );
  }

  UserProfile profile({
    double height = 180,
    double weight = 80,
    int age = 30,
    String gender = 'MALE',
    WeightGoal goal = WeightGoal.lose,
    double targetWeight = 75,
    double weeklyRate = 0.5,
  }) {
    return UserProfile(
      height: height,
      weight: weight,
      age: age,
      gender: gender,
      goal: goal,
      targetWeight: targetWeight,
      weeklyRate: weeklyRate,
      allergies: const [],
    );
  }

  EnergyWindow energyOf({
    int days = 14,
    int steps = 0,
    int workoutMinutes = 0,
    double activeKcal = 0,
  }) {
    return EnergyWindow(
      days: [
        for (var i = days - 1; i >= 0; i--)
          DailyEnergy(
            day: daysAgo(i),
            steps: steps,
            workoutMinutes: workoutMinutes,
            activeKcal: activeKcal,
          ),
      ],
    );
  }

  group('dailySeries', () {
    test('is empty with no weigh-ins', () {
      expect(ProjectionEngine.dailySeries([], now: now), isEmpty);
    });

    test('returns one point per day, oldest first', () {
      final series = ProjectionEngine.dailySeries(
        [weighIn(80, 0), weighIn(82, 4), weighIn(81, 2)],
        now: now,
      );

      expect(series.map((p) => p.weightKg), [82, 81, 80]);
      expect(series.first.day, daysAgo(4));
      expect(series.last.day, daysAgo(0));
    });

    test('averages two weigh-ins on the same day', () {
      // Both are real measurements and morning-to-evening weight swings by up to
      // a kilo, so the mean is the steadier estimate for that day.
      final series = ProjectionEngine.dailySeries(
        [weighIn(80.0, 1, hour: 7), weighIn(81.0, 1, hour: 21)],
        now: now,
      );

      expect(series, hasLength(1));
      expect(series.single.weightKg, 80.5);
    });

    test('excludes weigh-ins older than the window', () {
      final series = ProjectionEngine.dailySeries(
        [weighIn(90, ProjectionEngine.seriesWindowDays), weighIn(80, 0)],
        now: now,
      );

      expect(series.map((p) => p.weightKg), [80]);
    });

    test('keeps the oldest day inside the window', () {
      final series = ProjectionEngine.dailySeries(
        [weighIn(90, ProjectionEngine.seriesWindowDays - 1)],
        now: now,
      );

      expect(series, hasLength(1));
    });

    test('files a future-dated weigh-in under today', () {
      // Only reachable via a device clock that ran ahead and was corrected.
      final tomorrow = ProjectionEngine.addDays(ProjectionEngine.dayOf(now), 1);
      final series = ProjectionEngine.dailySeries(
        [WeightEntry(id: 'x', weightKg: 79, recordedAt: tomorrow)],
        now: now,
      );

      expect(series.single.day, ProjectionEngine.dayOf(now));
    });
  });

  group('slopeKgPerDay', () {
    test('is null for no points and for one point', () {
      expect(ProjectionEngine.slopeKgPerDay([]), isNull);
      expect(
        ProjectionEngine.slopeKgPerDay([
          WeightPoint(day: daysAgo(0), weightKg: 80),
        ]),
        isNull,
      );
    });

    test('recovers an exact downward slope', () {
      final series = [
        WeightPoint(day: daysAgo(21), weightKg: 85.0),
        WeightPoint(day: daysAgo(14), weightKg: 84.3),
        WeightPoint(day: daysAgo(7), weightKg: 83.6),
        WeightPoint(day: daysAgo(0), weightKg: 82.9),
      ];

      expect(ProjectionEngine.slopeKgPerDay(series), closeTo(-0.1, 1e-9));
    });

    test('recovers an exact upward slope', () {
      final series = [
        WeightPoint(day: daysAgo(10), weightKg: 70.0),
        WeightPoint(day: daysAgo(0), weightKg: 71.0),
      ];

      expect(ProjectionEngine.slopeKgPerDay(series), closeTo(0.1, 1e-9));
    });

    test('is zero for a flat series', () {
      final series = [
        WeightPoint(day: daysAgo(14), weightKg: 80),
        WeightPoint(day: daysAgo(7), weightKg: 80),
        WeightPoint(day: daysAgo(0), weightKg: 80),
      ];

      expect(ProjectionEngine.slopeKgPerDay(series), 0);
    });

    test('fits a line through noisy points rather than the endpoints', () {
      // Endpoint-to-endpoint would read -0.05/day; least squares sees the trend.
      final series = [
        WeightPoint(day: daysAgo(20), weightKg: 80.0),
        WeightPoint(day: daysAgo(10), weightKg: 79.0),
        WeightPoint(day: daysAgo(0), weightKg: 79.0),
      ];

      final slope = ProjectionEngine.slopeKgPerDay(series)!;

      expect(slope, lessThan(0));
      expect(slope, closeTo(-0.05, 1e-9));
    });
  });

  group('dayIndex', () {
    test('counts whole calendar days', () {
      expect(
        ProjectionEngine.dayIndex(DateTime(2026, 8, 26), DateTime(2026, 8, 19)),
        7,
      );
    });

    test('survives a spring-forward boundary', () {
      // Local midnights 24h apart can be 23h apart in wall time; comparing them
      // as UTC midnights is what keeps adjacent days one apart.
      expect(
        ProjectionEngine.dayIndex(DateTime(2026, 3, 9), DateTime(2026, 3, 8)),
        1,
      );
    });

    test('is negative going backwards', () {
      expect(
        ProjectionEngine.dayIndex(DateTime(2026, 8, 19), DateTime(2026, 8, 26)),
        -7,
      );
    });
  });

  group('basalMetabolicRate', () {
    test('applies the male constant', () {
      // 10(80) + 6.25(180) - 5(30) + 5
      expect(
        ProjectionEngine.basalMetabolicRate(
            weightKg: 80, heightCm: 180, age: 30, gender: 'MALE'),
        closeTo(1780, 1e-9),
      );
    });

    test('applies the female constant', () {
      expect(
        ProjectionEngine.basalMetabolicRate(
            weightKg: 80, heightCm: 180, age: 30, gender: 'FEMALE'),
        closeTo(1614, 1e-9),
      );
    });

    test('uses the midpoint for anything else', () {
      // Neither equation fits, and picking one would be a worse answer than the
      // average of the two.
      final other = ProjectionEngine.basalMetabolicRate(
          weightKg: 80, heightCm: 180, age: 30, gender: 'OTHER');

      expect(other, closeTo(1697, 1e-9));
      expect(other, closeTo((1780 + 1614) / 2, 1e-9));
    });

    test('is case- and whitespace-insensitive about gender', () {
      expect(
        ProjectionEngine.basalMetabolicRate(
            weightKg: 80, heightCm: 180, age: 30, gender: ' female '),
        closeTo(1614, 1e-9),
      );
    });
  });

  group('meanDailyIntake', () {
    test('reports nothing logged as zero days', () {
      final intake = ProjectionEngine.meanDailyIntake([], now: now);

      expect(intake.loggedDays, 0);
      expect(intake.kcal, 0);
    });

    test('sums a day and averages across logged days only', () {
      // Three logged days out of a fourteen-day window: the mean is over three,
      // not fourteen. Counting the eleven silent days as fasts would invent a
      // deficit the body never saw.
      final intake = ProjectionEngine.meanDailyIntake(
        [meal(600, 0), meal(400, 0), meal(1200, 1), meal(800, 2)],
        now: now,
      );

      expect(intake.loggedDays, 3);
      expect(intake.kcal, closeTo((1000 + 1200 + 800) / 3, 1e-9));
    });

    test('scales a serving by its quantity', () {
      final intake =
          ProjectionEngine.meanDailyIntake([meal(300, 0, quantity: 2.5)], now: now);

      expect(intake.kcal, closeTo(750, 1e-9));
    });

    test('excludes meals older than the intake window', () {
      final intake = ProjectionEngine.meanDailyIntake(
        [meal(9999, ProjectionEngine.intakeWindowDays), meal(1000, 0)],
        now: now,
      );

      expect(intake.loggedDays, 1);
      expect(intake.kcal, closeTo(1000, 1e-9));
    });
  });

  group('activeEnergy', () {
    test('prefers the platform figure and says so', () {
      final active = ProjectionEngine.activeEnergy(
        energyOf(steps: 8000, activeKcal: 450),
        weightKg: 80,
      );

      expect(active.kcal, closeTo(450, 1e-9));
      expect(active.fromDevice, isTrue);
    });

    test('estimates from steps when energy was never granted', () {
      // The case the Health Connect re-authorize banner describes.
      final active = ProjectionEngine.activeEnergy(
        energyOf(steps: 10000),
        weightKg: 70,
      );

      expect(active.fromDevice, isFalse);
      expect(active.kcal, closeTo(10000 * 0.0004 * 70, 1e-9)); // 280
    });

    test('takes the larger of steps and workouts, never the sum', () {
      // A run appears as both; adding them bills the same effort twice.
      final active = ProjectionEngine.activeEnergy(
        energyOf(steps: 10000, workoutMinutes: 30),
        weightKg: 70,
      );

      final fromSteps = 10000 * 0.0004 * 70; // 280
      final fromWorkouts = 30 * 6.0 * 3.5 * 70 / 200; // 220.5

      expect(active.kcal, closeTo(fromSteps, 1e-9));
      expect(active.kcal, lessThan(fromSteps + fromWorkouts));
    });

    test('is zero when too few days were measured to average', () {
      final active = ProjectionEngine.activeEnergy(
        EnergyWindow(days: [DailyEnergy(day: daysAgo(0), steps: 30000)]),
        weightKg: 80,
      );

      expect(active.kcal, 0);
      expect(active.fromDevice, isFalse);
    });

    test('is zero for an empty window', () {
      final active =
          ProjectionEngine.activeEnergy(EnergyWindow.empty(), weightKg: 80);

      expect(active.kcal, 0);
    });
  });

  group('statusFor', () {
    ProjectionStatus status({
      WeightGoal goal = WeightGoal.lose,
      required double remainingKg,
      required double ratePerWeekKg,
      double targetRatePerWeekKg = 0.5,
      ProjectionBasis basis = ProjectionBasis.measured,
    }) {
      return ProjectionEngine.statusFor(
        goal: goal,
        remainingKg: remainingKg,
        ratePerWeekKg: ratePerWeekKg,
        targetRatePerWeekKg: targetRatePerWeekKg,
        basis: basis,
      );
    }

    test('no basis means no claim', () {
      expect(
        status(
            remainingKg: -5,
            ratePerWeekKg: -0.5,
            basis: ProjectionBasis.none),
        ProjectionStatus.insufficientData,
      );
    });

    test('within tolerance of target is already reached', () {
      expect(status(remainingKg: -0.2, ratePerWeekKg: -0.5),
          ProjectionStatus.goalReached);
      expect(status(remainingKg: 0.3, ratePerWeekKg: 0),
          ProjectionStatus.goalReached);
    });

    test('losing at the requested rate is on track', () {
      expect(status(remainingKg: -5, ratePerWeekKg: -0.5),
          ProjectionStatus.onTrack);
    });

    test('the tolerance band is inclusive at both edges', () {
      expect(status(remainingKg: -5, ratePerWeekKg: -0.625),
          ProjectionStatus.onTrack);
      expect(status(remainingKg: -5, ratePerWeekKg: -0.375),
          ProjectionStatus.onTrack);
    });

    test('faster than requested is ahead', () {
      expect(status(remainingKg: -5, ratePerWeekKg: -0.9),
          ProjectionStatus.ahead);
    });

    test('slower than requested is behind', () {
      expect(status(remainingKg: -5, ratePerWeekKg: -0.2),
          ProjectionStatus.behind);
    });

    test('barely moving is stalled, not behind', () {
      expect(status(remainingKg: -5, ratePerWeekKg: -0.01),
          ProjectionStatus.stalled);
      expect(status(remainingKg: -5, ratePerWeekKg: 0),
          ProjectionStatus.stalled);
    });

    test('gaining while trying to lose is the wrong direction', () {
      expect(status(remainingKg: -5, ratePerWeekKg: 0.4),
          ProjectionStatus.wrongDirection);
    });

    test('losing while trying to gain is the wrong direction', () {
      expect(
        status(
            goal: WeightGoal.gain, remainingKg: 5, ratePerWeekKg: -0.4),
        ProjectionStatus.wrongDirection,
      );
    });

    test('gaining at the requested rate is on track', () {
      expect(status(goal: WeightGoal.gain, remainingKg: 5, ratePerWeekKg: 0.5),
          ProjectionStatus.onTrack);
    });

    test('holding steady is success for a maintain goal', () {
      // The same near-zero rate that is a stall for a lose goal.
      expect(
        status(
            goal: WeightGoal.maintain, remainingKg: -5, ratePerWeekKg: -0.01),
        ProjectionStatus.onTrack,
      );
    });

    test('drifting is off-target for a maintain goal', () {
      expect(
        status(goal: WeightGoal.maintain, remainingKg: -5, ratePerWeekKg: -0.4),
        ProjectionStatus.wrongDirection,
      );
    });

    test('with no requested rate, moving the right way is all it claims', () {
      expect(
        status(remainingKg: -5, ratePerWeekKg: -1.5, targetRatePerWeekKg: 0),
        ProjectionStatus.onTrack,
      );
    });
  });

  group('compute — the energy-balance basis', () {
    Projection subject({
      List<WeightEntry>? weights,
      List<FoodEntry>? foods,
      EnergyWindow? energy,
      UserProfile? user,
    }) {
      return ProjectionEngine.compute(
        profile: user ?? profile(),
        weights: weights ?? [weighIn(80, 0)],
        foods: foods ?? [meal(1600, 0), meal(1600, 1), meal(1600, 2)],
        energy: energy ?? EnergyWindow.empty(),
        now: now,
      );
    }

    test('is used when the weigh-in series is too short to trust', () {
      expect(subject().basis, ProjectionBasis.energyBalance);
    });

    test('computes BMR, TDEE and the balance from the logs', () {
      final p = subject();

      expect(p.bmrKcal, closeTo(1780, 1e-9));
      expect(p.tdeeKcal, closeTo(1780 * 1.2, 1e-9)); // 2136, no activity
      expect(p.intakeKcal, closeTo(1600, 1e-9));
      expect(p.balanceKcal, closeTo(1600 - 2136, 1e-9)); // -536
    });

    test('adds measured activity to expenditure', () {
      final p = subject(energy: energyOf(activeKcal: 400));

      expect(p.activeKcal, closeTo(400, 1e-9));
      expect(p.tdeeKcal, closeTo(1780 * 1.2 + 400, 1e-9));
      expect(p.activeEnergyFromDevice, isTrue);
    });

    test('turns the deficit into a date', () {
      final p = subject();

      // 5 kg to go at 536 kcal/day ÷ 7700 kcal/kg = 71.83 days. Rounds up to 72:
      // the epsilon that fixes the exact-integer case must not shorten a
      // genuinely fractional day.
      expect(p.daysToGoal, 72);
      expect(p.goalDate, ProjectionEngine.addDays(daysAgo(0), 72));
      expect(p.status, ProjectionStatus.onTrack);
    });

    test('refuses a balance built on too few logged days', () {
      // Two days is a sample, not a habit.
      final p = subject(foods: [meal(1600, 0), meal(1600, 1)]);

      expect(p.loggedDayCount, 2);
      expect(p.basis, ProjectionBasis.none);
      expect(p.status, ProjectionStatus.insufficientData);
      expect(p.daysToGoal, isNull);
    });

    test('a surplus while trying to lose reports the wrong direction', () {
      final p = subject(foods: [meal(3200, 0), meal(3200, 1), meal(3200, 2)]);

      expect(p.balanceKcal, greaterThan(0));
      expect(p.status, ProjectionStatus.wrongDirection);
      expect(p.daysToGoal, isNull);
      expect(p.goalDate, isNull);
    });
  });

  group('compute — the measured basis', () {
    // Four weigh-ins across three weeks, losing 0.1 kg/day.
    final series = [weighIn(85.0, 21), weighIn(84.3, 14), weighIn(83.6, 7), weighIn(82.9, 0)];

    test('supersedes energy balance once the series qualifies', () {
      final p = ProjectionEngine.compute(
        profile: profile(targetWeight: 80, weeklyRate: 0.75),
        weights: series,
        // Intake that would imply a wildly different rate, to prove which won.
        foods: [meal(500, 0), meal(500, 1), meal(500, 2)],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.basis, ProjectionBasis.measured);
      expect(p.ratePerWeekKg, closeTo(-0.7, 1e-9));
    });

    test('reads current weight from the series, not the profile field', () {
      // The write-through keeps them equal in the normal case; when it failed,
      // the series is the one that is current.
      final p = ProjectionEngine.compute(
        profile: profile(weight: 99, targetWeight: 80, weeklyRate: 0.75),
        weights: series,
        foods: const [],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.currentWeightKg, closeTo(82.9, 1e-9));
    });

    test('dates the goal from the measured slope', () {
      final p = ProjectionEngine.compute(
        profile: profile(targetWeight: 80, weeklyRate: 0.75),
        weights: series,
        foods: const [],
        energy: EnergyWindow.empty(),
        now: now,
      );

      // 2.9 kg to go at 0.1 kg/day. Also the float-rounding guard: `80 - 82.9`
      // is -2.9000000000000057, so an unguarded ceil() reports 30 here and
      // promises an extra day the arithmetic never asked for.
      expect(p.daysToGoal, 29);
      expect(p.status, ProjectionStatus.onTrack);
      expect(p.weighInDayCount, 4);
      expect(p.seriesSpanDays, 21);
    });

    test('holds off on the measured slope with too few points', () {
      final p = ProjectionEngine.compute(
        profile: profile(),
        weights: [weighIn(85, 21), weighIn(83, 0)], // long span, only 2 points
        foods: [meal(1600, 0), meal(1600, 1), meal(1600, 2)],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.basis, ProjectionBasis.energyBalance);
    });

    test('holds off on the measured slope with too short a span', () {
      final p = ProjectionEngine.compute(
        profile: profile(),
        // Four points, but only a week apart end to end — mostly hydration.
        weights: [weighIn(81, 6), weighIn(80.8, 4), weighIn(80.6, 2), weighIn(80.4, 0)],
        foods: [meal(1600, 0), meal(1600, 1), meal(1600, 2)],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.basis, ProjectionBasis.energyBalance);
    });
  });

  group('compute — the projected ray', () {
    final series = [weighIn(85.0, 21), weighIn(84.3, 14), weighIn(83.6, 7), weighIn(82.9, 0)];

    test('starts where the observed series ends, so the two join', () {
      final p = ProjectionEngine.compute(
        profile: profile(targetWeight: 80, weeklyRate: 0.75),
        weights: series,
        foods: const [],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.projected.first.day, p.observed.last.day);
      expect(p.projected.first.weightKg, p.observed.last.weightKg);
    });

    test('ends on the goal weight when the goal is inside the horizon', () {
      final p = ProjectionEngine.compute(
        profile: profile(targetWeight: 80, weeklyRate: 0.75),
        weights: series,
        foods: const [],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.projected.last.weightKg, closeTo(80, 0.05));
      expect(p.projected.last.day, ProjectionEngine.addDays(daysAgo(0), 29));
    });

    test('stops at the horizon when the goal is further out', () {
      final p = ProjectionEngine.compute(
        profile: profile(targetWeight: 60, weeklyRate: 0.75),
        weights: series,
        foods: const [],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.daysToGoal, greaterThan(ProjectionEngine.maxProjectionDays));
      expect(
        p.projected.last.day,
        ProjectionEngine.addDays(daysAgo(0), ProjectionEngine.maxProjectionDays),
      );
    });

    test('is empty when there is nothing to extrapolate', () {
      final p = ProjectionEngine.compute(
        profile: profile(),
        weights: const [],
        foods: const [],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.projected, isEmpty);
      expect(p.hasTrajectory, isFalse);
    });
  });

  group('compute — nothing to say', () {
    test('no logs at all is insufficient, not zero', () {
      final p = ProjectionEngine.compute(
        profile: profile(),
        weights: const [],
        foods: const [],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.status, ProjectionStatus.insufficientData);
      expect(p.basis, ProjectionBasis.none);
      expect(p.daysToGoal, isNull);
      expect(p.goalDate, isNull);
    });

    test('an unfilled profile cannot be modelled', () {
      final p = ProjectionEngine.compute(
        profile: UserProfile.empty(),
        weights: const [],
        foods: [meal(1600, 0), meal(1600, 1), meal(1600, 2)],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.bmrKcal, 0);
      expect(p.tdeeKcal, 0);
      expect(p.status, ProjectionStatus.insufficientData);
    });

    test('no target weight means no date, even with plenty of data', () {
      // Reporting a countdown to 0 kg would be grotesque.
      final p = ProjectionEngine.compute(
        profile: profile(targetWeight: 0),
        weights: [weighIn(85, 21), weighIn(84.3, 14), weighIn(83.6, 7), weighIn(82.9, 0)],
        foods: [meal(1600, 0), meal(1600, 1), meal(1600, 2)],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.status, ProjectionStatus.insufficientData);
      expect(p.daysToGoal, isNull);
    });

    test('already at target reports arrival, with no ray to draw', () {
      final p = ProjectionEngine.compute(
        profile: profile(targetWeight: 80),
        weights: [weighIn(80.1, 0)],
        foods: [meal(1600, 0), meal(1600, 1), meal(1600, 2)],
        energy: EnergyWindow.empty(),
        now: now,
      );

      expect(p.status, ProjectionStatus.goalReached);
      expect(p.daysToGoal, 0);
      expect(p.projected, isEmpty);
    });
  });
}
