import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/projection_engine.dart';
import 'package:void_factor/features/projection/recommendation_engine.dart';
import 'package:void_factor/models/projection.dart';
import 'package:void_factor/models/recommendation.dart';
import 'package:void_factor/models/user_profile.dart';

void main() {
  /// A projection built field-by-field rather than through
  /// [ProjectionEngine.compute].
  ///
  /// The ranking cares about a dozen independent figures, and reaching a specific
  /// combination of them through the engine would mean constructing logs that
  /// happen to produce it. Building the result directly keeps each test about one
  /// variable — and it is honest, because [RecommendationEngine] genuinely takes a
  /// `Projection` and nothing else.
  ///
  /// The defaults describe a user doing everything right, so any single override
  /// is the only thing wrong in that test.
  Projection projectionOf({
    double currentWeightKg = 80,
    double targetWeightKg = 75,
    WeightGoal goal = WeightGoal.lose,
    double targetRatePerWeekKg = 0.5,
    double ratePerWeekKg = -0.5,
    ProjectionBasis basis = ProjectionBasis.measured,
    ProjectionStatus status = ProjectionStatus.onTrack,
    double activeKcal = 400,
    double intakeKcal = 2000,
    double proteinGPerDay = 160,
    double balanceKcal = -550,
    int loggedDayCount = 14,
    int weighInDayCount = 12,
    int seriesSpanDays = 28,
  }) {
    return Projection(
      observed: const [],
      projected: const [],
      currentWeightKg: currentWeightKg,
      targetWeightKg: targetWeightKg,
      goal: goal,
      ratePerWeekKg: ratePerWeekKg,
      targetRatePerWeekKg: targetRatePerWeekKg,
      basis: basis,
      status: status,
      daysToGoal: 70,
      goalDate: DateTime(2026, 11, 4),
      bmrKcal: 1750,
      activeKcal: activeKcal,
      tdeeKcal: 2550,
      intakeKcal: intakeKcal,
      proteinGPerDay: proteinGPerDay,
      balanceKcal: balanceKcal,
      loggedDayCount: loggedDayCount,
      intakeWindowDays: ProjectionEngine.intakeWindowDays,
      weighInDayCount: weighInDayCount,
      seriesSpanDays: seriesSpanDays,
      activeEnergyFromDevice: true,
    );
  }

  List<RecommendationKind> kindsOf(List<RecommendationCandidate> candidates) =>
      candidates.map((c) => c.kind).toList();

  RecommendationCandidate kind(
    List<RecommendationCandidate> candidates,
    RecommendationKind wanted,
  ) =>
      candidates.firstWhere((c) => c.kind == wanted);

  group('requiredDailyBalanceKcal', () {
    test('a lose goal implies a deficit sized to the requested rate', () {
      // 0.5 kg/week ÷ 7 × 7700 = 550 kcal/day.
      final required = RecommendationEngine.requiredDailyBalanceKcal(
        projectionOf(goal: WeightGoal.lose, targetRatePerWeekKg: 0.5),
      );
      expect(required, closeTo(-550, 0.01));
    });

    test('a gain goal implies a surplus', () {
      final required = RecommendationEngine.requiredDailyBalanceKcal(
        projectionOf(
          goal: WeightGoal.gain,
          currentWeightKg: 70,
          targetWeightKg: 75,
          targetRatePerWeekKg: 0.25,
        ),
      );
      expect(required, closeTo(275, 0.01));
    });

    test('a maintain goal implies zero even when a weekly rate is stored', () {
      // Goals & Diet keeps the last rate the user picked, so a maintain profile
      // routinely still carries 0.5. Honouring it would prescribe a deficit to
      // someone who asked to hold steady.
      final required = RecommendationEngine.requiredDailyBalanceKcal(
        projectionOf(
          goal: WeightGoal.maintain,
          targetRatePerWeekKg: 0.5,
          currentWeightKg: 80,
          targetWeightKg: 80,
        ),
      );
      expect(required, 0);
    });

    test('no requested rate implies no prescribed balance', () {
      final required = RecommendationEngine.requiredDailyBalanceKcal(
        projectionOf(targetRatePerWeekKg: 0),
      );
      expect(required, 0);
    });

    test('the sign follows the direction of travel, not the goal enum', () {
      // A lose-goal user already below target has to eat *more* to get back up
      // to it. Reading the goal alone would prescribe a deficit that moves them
      // further away.
      final required = RecommendationEngine.requiredDailyBalanceKcal(
        projectionOf(
          goal: WeightGoal.lose,
          currentWeightKg: 70,
          targetWeightKg: 75,
        ),
      );
      expect(required, greaterThan(0));
    });
  });

  group('top always returns three', () {
    test('for a user doing everything right', () {
      expect(RecommendationEngine.top(projectionOf()).length, 3);
    });

    test('for a user with no data at all', () {
      final candidates = RecommendationEngine.top(projectionOf(
        basis: ProjectionBasis.none,
        status: ProjectionStatus.insufficientData,
        loggedDayCount: 0,
        weighInDayCount: 0,
        activeKcal: 0,
        balanceKcal: 0,
        proteinGPerDay: 0,
      ));
      expect(candidates.length, 3);
    });

    test('for a user missing every target', () {
      final candidates = RecommendationEngine.top(projectionOf(
        loggedDayCount: 2,
        weighInDayCount: 1,
        activeKcal: 20,
        proteinGPerDay: 30,
        balanceKcal: 600,
        status: ProjectionStatus.wrongDirection,
      ));
      expect(candidates.length, 3);
    });

    test('the count matches the constant the screen renders', () {
      expect(RecommendationEngine.count, 3);
      expect(
        RecommendationEngine.top(projectionOf()).length,
        RecommendationEngine.count,
      );
    });
  });

  group('suppression', () {
    test('no basis drops the calorie gap — there is no expenditure model', () {
      final ranked = RecommendationEngine.rank(projectionOf(
        basis: ProjectionBasis.none,
        status: ProjectionStatus.insufficientData,
      ));
      expect(kindsOf(ranked), isNot(contains(RecommendationKind.calorieGap)));
    });

    test('too few logged days drops the protein floor', () {
      final ranked = RecommendationEngine.rank(projectionOf(loggedDayCount: 2));
      expect(kindsOf(ranked), isNot(contains(RecommendationKind.proteinFloor)));
    });

    test('the minimum logged days matches the engine that computes intake', () {
      // One day above the floor keeps it. Guards against the two constants
      // drifting apart, which would show a protein figure the projection itself
      // refused to trust.
      final ranked = RecommendationEngine.rank(
        projectionOf(loggedDayCount: ProjectionEngine.minLoggedDays),
      );
      expect(kindsOf(ranked), contains(RecommendationKind.proteinFloor));
    });

    test('the three unconditional candidates always survive', () {
      final ranked = RecommendationEngine.rank(projectionOf(
        basis: ProjectionBasis.none,
        status: ProjectionStatus.insufficientData,
        loggedDayCount: 0,
      ));
      expect(
        kindsOf(ranked),
        containsAll([
          RecommendationKind.loggingAdherence,
          RecommendationKind.weighInCadence,
          RecommendationKind.exerciseVolume,
        ]),
      );
    });
  });

  group('onTarget', () {
    test('logging is met at the adherence floor, not at the full window', () {
      // 70% of 14 is 9.8, so ten days is success. Requiring all fourteen would
      // keep a solved problem at the top of the list forever.
      final met = kind(
        RecommendationEngine.rank(projectionOf(loggedDayCount: 10)),
        RecommendationKind.loggingAdherence,
      );
      expect(met.onTarget, isTrue);

      final missed = kind(
        RecommendationEngine.rank(projectionOf(loggedDayCount: 9)),
        RecommendationKind.loggingAdherence,
      );
      expect(missed.onTarget, isFalse);
    });

    test('exercise is met at the active-energy floor', () {
      expect(
        kind(
          RecommendationEngine.rank(
            projectionOf(activeKcal: RecommendationEngine.activeKcalFloor),
          ),
          RecommendationKind.exerciseVolume,
        ).onTarget,
        isTrue,
      );
      expect(
        kind(
          RecommendationEngine.rank(projectionOf(activeKcal: 299)),
          RecommendationKind.exerciseVolume,
        ).onTarget,
        isFalse,
      );
    });

    test('protein scales with body weight', () {
      // 1.6 g/kg of 100 kg is 160 g — the same intake that passes at 80 kg fails
      // at 100.
      expect(
        kind(
          RecommendationEngine.rank(
            projectionOf(currentWeightKg: 80, proteinGPerDay: 130),
          ),
          RecommendationKind.proteinFloor,
        ).onTarget,
        isTrue,
      );
      expect(
        kind(
          RecommendationEngine.rank(
            projectionOf(currentWeightKg: 100, proteinGPerDay: 130),
          ),
          RecommendationKind.proteinFloor,
        ).onTarget,
        isFalse,
      );
    });

    test('a calorie gap inside the tolerance counts as met', () {
      // Required is -550. Being 90 kcal off is inside both the BMR estimate's
      // error and the user's own portion logging, so "fix it" would be false
      // precision.
      expect(
        kind(
          RecommendationEngine.rank(projectionOf(balanceKcal: -460)),
          RecommendationKind.calorieGap,
        ).onTarget,
        isTrue,
      );
      expect(
        kind(
          RecommendationEngine.rank(projectionOf(balanceKcal: -400)),
          RecommendationKind.calorieGap,
        ).onTarget,
        isFalse,
      );
    });

    test('a maintain user in balance is on target', () {
      expect(
        kind(
          RecommendationEngine.rank(projectionOf(
            goal: WeightGoal.maintain,
            currentWeightKg: 80,
            targetWeightKg: 80,
            balanceKcal: -40,
          )),
          RecommendationKind.calorieGap,
        ).onTarget,
        isTrue,
      );
    });

    test('a maintain user running a deficit is not', () {
      expect(
        kind(
          RecommendationEngine.rank(projectionOf(
            goal: WeightGoal.maintain,
            currentWeightKg: 80,
            targetWeightKg: 80,
            balanceKcal: -600,
          )),
          RecommendationKind.calorieGap,
        ).onTarget,
        isFalse,
      );
    });
  });

  group('ranking', () {
    test('a live shortfall always outranks every on-target candidate', () {
      // Protein carries the lowest base score of all five, so if even it can beat
      // a perfect logging record, the floor on shortfall priority holds.
      final ranked = RecommendationEngine.rank(projectionOf(
        currentWeightKg: 80,
        proteinGPerDay: 120,
      ));
      final protein = kind(ranked, RecommendationKind.proteinFloor);
      final others = ranked.where((c) => c.kind != RecommendationKind.proteinFloor);
      expect(others.every((c) => c.onTarget), isTrue);
      expect(ranked.first.kind, RecommendationKind.proteinFloor);
      expect(protein.priority, greaterThan(others.map((c) => c.priority).reduce(
            (a, b) => a > b ? a : b,
          )));
    });

    test('logging outranks the calorie gap when both are missed', () {
      // Every other figure is computed from the log, so a confident deficit
      // recommendation built on four logged days is worse than no
      // recommendation.
      final ranked = RecommendationEngine.rank(projectionOf(
        loggedDayCount: 4,
        balanceKcal: 200,
      ));
      expect(ranked.first.kind, RecommendationKind.loggingAdherence);
    });

    test('a thinner log discounts the intake-derived cards further', () {
      double gapPriority(int loggedDays) => kind(
            RecommendationEngine.rank(projectionOf(
              loggedDayCount: loggedDays,
              balanceKcal: 200,
            )),
            RecommendationKind.calorieGap,
          ).priority;

      expect(gapPriority(4), lessThan(gapPriority(8)));
    });

    test('hitting the adherence floor removes the discount entirely', () {
      // Ten of fourteen days is the floor. The gap must not keep scaling up to a
      // full window, or a user who logs every single day would be the only one
      // ever shown an undiscounted figure.
      double gapPriority(int loggedDays) => kind(
            RecommendationEngine.rank(projectionOf(
              loggedDayCount: loggedDays,
              balanceKcal: 200,
            )),
            RecommendationKind.calorieGap,
          ).priority;

      expect(gapPriority(10), closeTo(gapPriority(14), 1e-9));
    });

    test('an energy-balance basis promotes the weigh-in candidate', () {
      final measured = kind(
        RecommendationEngine.rank(projectionOf(
          basis: ProjectionBasis.measured,
          weighInDayCount: 4,
        )),
        RecommendationKind.weighInCadence,
      );
      final estimated = kind(
        RecommendationEngine.rank(projectionOf(
          basis: ProjectionBasis.energyBalance,
          weighInDayCount: 4,
        )),
        RecommendationKind.weighInCadence,
      );
      // Same shortfall, higher priority: more weigh-ins would replace an estimate
      // with a measurement, which is worth more than the raw shortfall says.
      expect(estimated.priority, greaterThan(measured.priority));
    });

    test('moving away from target promotes the calorie gap', () {
      final onTrack = kind(
        RecommendationEngine.rank(projectionOf(balanceKcal: 100)),
        RecommendationKind.calorieGap,
      );
      final wrongWay = kind(
        RecommendationEngine.rank(projectionOf(
          balanceKcal: 100,
          status: ProjectionStatus.wrongDirection,
        )),
        RecommendationKind.calorieGap,
      );
      expect(wrongWay.priority, greaterThan(onTrack.priority));
    });

    test('a bigger miss ranks above a smaller one on the same dimension', () {
      final small = kind(
        RecommendationEngine.rank(projectionOf(activeKcal: 250)),
        RecommendationKind.exerciseVolume,
      );
      final large = kind(
        RecommendationEngine.rank(projectionOf(activeKcal: 20)),
        RecommendationKind.exerciseVolume,
      );
      expect(large.priority, greaterThan(small.priority));
    });

    test('the order is stable across identical runs', () {
      // A list that reshuffles between rebuilds reads as a bug, and float ties
      // are otherwise resolved by whatever order sort happened to see.
      final first = kindsOf(RecommendationEngine.rank(projectionOf()));
      final second = kindsOf(RecommendationEngine.rank(projectionOf()));
      expect(first, second);
    });

    test('an all-on-target ranking follows the base importance order', () {
      final ranked = kindsOf(RecommendationEngine.rank(projectionOf()));
      expect(ranked.take(3), [
        RecommendationKind.loggingAdherence,
        RecommendationKind.calorieGap,
        RecommendationKind.weighInCadence,
      ]);
    });
  });

  group('candidate shortfall', () {
    test('is zero for an on-target candidate', () {
      final met = kind(
        RecommendationEngine.rank(projectionOf()),
        RecommendationKind.exerciseVolume,
      );
      expect(met.shortfall, 0);
    });

    test('reaches one when the user is at nothing', () {
      final none = kind(
        RecommendationEngine.rank(projectionOf(activeKcal: 0)),
        RecommendationKind.exerciseVolume,
      );
      expect(none.shortfall, 1);
    });

    test('is a fraction in between', () {
      final half = kind(
        RecommendationEngine.rank(projectionOf(activeKcal: 150)),
        RecommendationKind.exerciseVolume,
      );
      expect(half.shortfall, closeTo(0.5, 0.001));
    });
  });
}
