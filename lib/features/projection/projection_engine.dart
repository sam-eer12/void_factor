import 'dart:math';

import '../../models/energy_window.dart';
import '../../models/food_entry.dart';
import '../../models/projection.dart';
import '../../models/user_profile.dart';
import '../../models/weight_entry.dart';

/// Turns the user's logs into a weight trajectory and a goal date.
///
/// Pure functions over plain values — no I/O, no providers, no clock of its own.
/// Everything time-dependent arrives as `now`. That is what makes every branch
/// here reachable from a unit test without a single mock, which matters more for
/// this file than for any other in the feature: it is the one place that produces
/// a number the user will plan around.
///
/// Deliberately *not* an LLM's job. Every figure below is arithmetic with a
/// defined answer; a language model asked to compute it would produce a different
/// date on each run and be confidently wrong on some of them. The model's role
/// begins after this class ends — see `RecommendationNarrator`.
class ProjectionEngine {
  ProjectionEngine._();

  /// Energy in a kilogram of body mass, kcal.
  ///
  /// The conventional 7700 (≈3500 kcal/lb). A population estimate for mixed
  /// fat-and-lean loss, not a physical constant — which is exactly why
  /// [ProjectionBasis.measured] outranks the energy basis once real weigh-ins
  /// exist: a measured slope quietly absorbs however wrong this is for one body.
  static const double kcalPerKg = 7700;

  /// How far back weigh-ins are read for the chart and the trend.
  static const int seriesWindowDays = 30;

  /// How far back meals are read for the intake average.
  ///
  /// Shorter than the weight window on purpose: intake describes current
  /// behaviour, and a month-old week of eating no longer does.
  static const int intakeWindowDays = 14;

  /// Basal multiplier for a sedentary baseline.
  ///
  /// Exercise is added separately from measured activity, so this must stay the
  /// *sedentary* factor. Using a higher "moderately active" multiplier here and
  /// then adding active energy on top would bill the user's exercise twice and
  /// invent a deficit that does not exist.
  static const double sedentaryFactor = 1.2;

  /// Minimum weigh-in days before the measured slope is trusted.
  static const int measuredMinPoints = 4;

  /// Minimum first-to-last span, in days, before the measured slope is trusted.
  ///
  /// Two weeks. Day-to-day body weight swings by up to a kilo on water alone, so
  /// a slope fitted across four days is mostly measuring hydration.
  static const int measuredMinSpanDays = 14;

  /// Minimum logged days before the intake average is trusted.
  static const int minLoggedDays = 3;

  /// Below this absolute weekly rate, progress is reported as stalled rather
  /// than given a date — `0.01 kg/week` would otherwise project decades.
  static const double stalledRatePerWeekKg = 0.05;

  /// How far the measured rate may sit from the requested rate and still count
  /// as on track. ±25%.
  static const double onTrackTolerance = 0.25;

  /// Drift a `maintain` goal tolerates before it is reported as off-target.
  static const double maintainDriftPerWeekKg = 0.15;

  /// Within this distance of target, the goal is already met.
  static const double goalReachedToleranceKg = 0.3;

  /// How far the chart extrapolates, and the step between projected points.
  static const int maxProjectionDays = 84; // 12 weeks
  static const int projectionStepDays = 7;

  /// Slack absorbed before rounding a day count up.
  ///
  /// `80 - 82.9` is `-2.9000000000000057` in binary floating point, so dividing
  /// by an exact rate lands at `29.000000000000057` and a naive `ceil()` promises
  /// 30 days for a goal reached on day 29. Subtracting this before rounding keeps
  /// the arithmetic honest without ever shortening a genuinely fractional day.
  static const double _dayRoundingEpsilon = 1e-6;

  /// Active kcal per step, per kg of body mass.
  ///
  /// Used only when the platform's own energy figure is unavailable. Deliberately
  /// conservative — it lands a 70 kg walker at roughly 280 kcal per 10 000 steps,
  /// below the ~400 kcal a gross estimate would give, because the gross figure
  /// includes basal energy that [sedentaryFactor] has already counted.
  static const double kcalPerStepPerKg = 0.0004;

  /// Assumed intensity of a logged workout, in METs. Moderate effort.
  static const double workoutMet = 6.0;

  // ──────────────────────────────────────────────
  // The whole computation
  // ──────────────────────────────────────────────

  static Projection compute({
    required UserProfile profile,
    required List<WeightEntry> weights,
    required List<FoodEntry> foods,
    required EnergyWindow energy,
    required DateTime now,
  }) {
    final observed = dailySeries(weights, now: now);

    // The series wins over the profile field. The write-through keeps them equal
    // in the normal case; when it failed, the series is the one that is current.
    final currentWeightKg =
        observed.isNotEmpty ? observed.last.weightKg : profile.weight;
    final targetWeightKg = profile.targetWeight;

    final canModelEnergy =
        currentWeightKg > 0 && profile.height > 0 && profile.age > 0;
    final bmrKcal = canModelEnergy
        ? basalMetabolicRate(
            weightKg: currentWeightKg,
            heightCm: profile.height,
            age: profile.age,
            gender: profile.gender,
          )
        : 0.0;

    final active = activeEnergy(energy, weightKg: currentWeightKg);
    final tdeeKcal = canModelEnergy ? bmrKcal * sedentaryFactor + active.kcal : 0.0;

    final intake = meanDailyIntake(foods, now: now);

    // A balance is only meaningful with both halves: an expenditure model and
    // enough logged days to call the intake a habit rather than a sample.
    final hasBalance = tdeeKcal > 0 && intake.loggedDays >= minLoggedDays;
    final balanceKcal = hasBalance ? intake.kcal - tdeeKcal : 0.0;

    final seriesSpanDays = observed.length >= 2
        ? dayIndex(observed.last.day, observed.first.day)
        : 0;

    final measuredSlope = slopeKgPerDay(observed);
    final canUseMeasured = measuredSlope != null &&
        observed.length >= measuredMinPoints &&
        seriesSpanDays >= measuredMinSpanDays;

    final double? ratePerDay;
    final ProjectionBasis basis;
    if (canUseMeasured) {
      ratePerDay = measuredSlope;
      basis = ProjectionBasis.measured;
    } else if (hasBalance) {
      ratePerDay = balanceKcal / kcalPerKg;
      basis = ProjectionBasis.energyBalance;
    } else {
      ratePerDay = null;
      basis = ProjectionBasis.none;
    }

    final ratePerWeekKg = (ratePerDay ?? 0) * 7;
    final remainingKg = targetWeightKg - currentWeightKg;

    // No target set is as unanswerable as no data: there is nothing to project
    // towards, and reporting a date to 0 kg would be grotesque.
    final hasTarget = targetWeightKg > 0 && currentWeightKg > 0;

    final status = !hasTarget
        ? ProjectionStatus.insufficientData
        : statusFor(
            goal: profile.goal,
            remainingKg: remainingKg,
            ratePerWeekKg: ratePerWeekKg,
            targetRatePerWeekKg: profile.weeklyRate,
            basis: basis,
          );

    final (daysToGoal, goalDate) = _goalArrival(
      status: status,
      remainingKg: remainingKg,
      ratePerDay: ratePerDay,
      now: now,
    );

    return Projection(
      observed: observed,
      projected: _projectedSeries(
        observed: observed,
        ratePerDay: status == ProjectionStatus.insufficientData ? null : ratePerDay,
        currentWeightKg: currentWeightKg,
        now: now,
        daysToGoal: daysToGoal,
      ),
      currentWeightKg: currentWeightKg,
      targetWeightKg: targetWeightKg,
      goal: profile.goal,
      ratePerWeekKg: ratePerWeekKg,
      targetRatePerWeekKg: profile.weeklyRate,
      basis: basis,
      status: status,
      daysToGoal: daysToGoal,
      goalDate: goalDate,
      bmrKcal: bmrKcal,
      activeKcal: active.kcal,
      tdeeKcal: tdeeKcal,
      intakeKcal: intake.kcal,
      proteinGPerDay: intake.proteinG,
      balanceKcal: balanceKcal,
      loggedDayCount: intake.loggedDays,
      intakeWindowDays: intakeWindowDays,
      weighInDayCount: observed.length,
      seriesSpanDays: seriesSpanDays,
      activeEnergyFromDevice: active.fromDevice,
    );
  }

  // ──────────────────────────────────────────────
  // Pieces, each independently testable
  // ──────────────────────────────────────────────

  /// The weigh-ins as one point per day, oldest first, within
  /// [seriesWindowDays] of [now].
  ///
  /// Two weigh-ins on one day are **averaged**, not deduplicated to the latest.
  /// Both are real measurements, and morning-to-evening weight moves by up to a
  /// kilogram on food and water alone; the mean is the steadier estimate of that
  /// day and keeps the regression from chasing time-of-day noise.
  static List<WeightPoint> dailySeries(
    List<WeightEntry> entries, {
    required DateTime now,
    int windowDays = seriesWindowDays,
  }) {
    final today = dayOf(now);
    final windowStart = addDays(today, -(windowDays - 1));

    final sums = <DateTime, double>{};
    final counts = <DateTime, int>{};
    for (final entry in entries) {
      // A day ahead of now is only reachable through a device clock that ran
      // ahead and was corrected. Filing it under today keeps a real measurement
      // on the chart instead of hiding it past the edge.
      var day = entry.day;
      if (day.isAfter(today)) day = today;
      if (day.isBefore(windowStart)) continue;

      sums[day] = (sums[day] ?? 0) + entry.weightKg;
      counts[day] = (counts[day] ?? 0) + 1;
    }

    final days = sums.keys.toList()..sort();
    return [
      for (final day in days)
        WeightPoint(day: day, weightKg: sums[day]! / counts[day]!),
    ];
  }

  /// Least-squares slope through [series], in kg/day.
  ///
  /// Null when there are fewer than two distinct days — a single point has no
  /// direction, and reporting one would be inventing a trend.
  static double? slopeKgPerDay(List<WeightPoint> series) {
    if (series.length < 2) return null;

    final origin = series.first.day;
    var sumX = 0.0;
    var sumY = 0.0;
    for (final point in series) {
      sumX += dayIndex(point.day, origin);
      sumY += point.weightKg;
    }
    final meanX = sumX / series.length;
    final meanY = sumY / series.length;

    var covariance = 0.0;
    var variance = 0.0;
    for (final point in series) {
      final dx = dayIndex(point.day, origin) - meanX;
      covariance += dx * (point.weightKg - meanY);
      variance += dx * dx;
    }

    // Every point on the same day: a vertical fit with no slope to report.
    if (variance == 0) return null;
    return covariance / variance;
  }

  /// Mifflin–St Jeor resting energy expenditure, kcal/day.
  ///
  /// The `OTHER` constant (−78) is the midpoint of the male (+5) and female
  /// (−161) terms. There is no published equation for a non-binary body, and
  /// silently applying one of the two would be a worse answer than the average of
  /// them.
  static double basalMetabolicRate({
    required double weightKg,
    required double heightCm,
    required int age,
    required String gender,
  }) {
    final base = 10 * weightKg + 6.25 * heightCm - 5 * age;
    switch (gender.trim().toUpperCase()) {
      case 'MALE':
        return base + 5;
      case 'FEMALE':
        return base - 161;
      default:
        return base - 78;
    }
  }

  /// Mean daily active energy, and whether it came from the device.
  ///
  /// Prefers the platform's own figure. Falls back to an estimate from steps and
  /// workout minutes when that permission was never granted, so a user who
  /// connected health before the energy type was requested still gets a
  /// projection that credits their exercise — see `HealthRepository`'s
  /// authorized-types version.
  static ({double kcal, bool fromDevice}) activeEnergy(
    EnergyWindow window, {
    required double weightKg,
  }) {
    final measured = window.meanActiveKcal;
    if (measured > 0) return (kcal: measured, fromDevice: true);

    if (!window.isUsable || weightKg <= 0) {
      return (kcal: 0.0, fromDevice: false);
    }

    final fromSteps = window.meanSteps * kcalPerStepPerKg * weightKg;
    final fromWorkouts =
        window.meanWorkoutMinutes * workoutMet * 3.5 * weightKg / 200;

    // The larger of the two, never the sum. A run shows up both as steps and as
    // a workout, and adding them would bill the same effort twice.
    return (kcal: max(fromSteps, fromWorkouts), fromDevice: false);
  }

  /// Mean kcal and protein per day across days that carry at least one meal,
  /// plus how many days those were.
  ///
  /// Days with nothing logged are **excluded**, not counted as zero. A day the
  /// user forgot to log is missing data; treating it as a fast would drag the
  /// mean down and manufacture a deficit the body never saw. [loggedDays] is
  /// what lets the caller judge whether the mean deserves any weight —
  /// see [minLoggedDays].
  static ({double kcal, double proteinG, int loggedDays}) meanDailyIntake(
    List<FoodEntry> entries, {
    required DateTime now,
    int windowDays = intakeWindowDays,
  }) {
    final today = dayOf(now);
    final windowStart = addDays(today, -(windowDays - 1));

    final kcalPerDay = <DateTime, double>{};
    final proteinPerDay = <DateTime, double>{};
    for (final entry in entries) {
      var day = dayOf(entry.loggedAt);
      if (day.isAfter(today)) day = today;
      if (day.isBefore(windowStart)) continue;

      kcalPerDay[day] = (kcalPerDay[day] ?? 0) + entry.totalCalories;
      proteinPerDay[day] = (proteinPerDay[day] ?? 0) + entry.totalProteinG;
    }

    if (kcalPerDay.isEmpty) {
      return (kcal: 0.0, proteinG: 0.0, loggedDays: 0);
    }
    final days = kcalPerDay.length;
    final totalKcal = kcalPerDay.values.fold<double>(0, (sum, v) => sum + v);
    final totalProtein =
        proteinPerDay.values.fold<double>(0, (sum, v) => sum + v);
    return (
      kcal: totalKcal / days,
      proteinG: totalProtein / days,
      loggedDays: days,
    );
  }

  /// How the trajectory compares with the goal.
  static ProjectionStatus statusFor({
    required WeightGoal goal,
    required double remainingKg,
    required double ratePerWeekKg,
    required double targetRatePerWeekKg,
    required ProjectionBasis basis,
  }) {
    if (basis == ProjectionBasis.none) return ProjectionStatus.insufficientData;
    if (remainingKg.abs() <= goalReachedToleranceKg) {
      return ProjectionStatus.goalReached;
    }

    // Holding steady is the whole objective here, so near-zero movement is
    // success rather than the stall it would be for a lose or gain goal.
    if (goal == WeightGoal.maintain) {
      return ratePerWeekKg.abs() <= maintainDriftPerWeekKg
          ? ProjectionStatus.onTrack
          : ProjectionStatus.wrongDirection;
    }

    if (ratePerWeekKg.abs() < stalledRatePerWeekKg) {
      return ProjectionStatus.stalled;
    }
    if (ratePerWeekKg.sign != remainingKg.sign) {
      return ProjectionStatus.wrongDirection;
    }

    final requested = targetRatePerWeekKg.abs();
    // No requested rate to compare against — moving the right way is all that
    // can be said, so say only that.
    if (requested <= 0) return ProjectionStatus.onTrack;

    final actual = ratePerWeekKg.abs();
    if (actual > requested * (1 + onTrackTolerance)) {
      return ProjectionStatus.ahead;
    }
    if (actual < requested * (1 - onTrackTolerance)) {
      return ProjectionStatus.behind;
    }
    return ProjectionStatus.onTrack;
  }

  /// Days until target and the date that lands on, or `(null, null)` when the
  /// status makes a date meaningless.
  static (int?, DateTime?) _goalArrival({
    required ProjectionStatus status,
    required double remainingKg,
    required double? ratePerDay,
    required DateTime now,
  }) {
    if (status == ProjectionStatus.goalReached) return (0, dayOf(now));

    // Stalled, wrong-direction, and insufficient-data all have no honest arrival
    // date. Extrapolating one anyway is how a screen ends up promising a result
    // the data does not support.
    const datable = {
      ProjectionStatus.onTrack,
      ProjectionStatus.ahead,
      ProjectionStatus.behind,
    };
    if (!datable.contains(status)) return (null, null);
    if (ratePerDay == null || ratePerDay == 0) return (null, null);

    final days = (remainingKg / ratePerDay - _dayRoundingEpsilon).ceil();
    if (days < 0) return (null, null);
    return (days, addDays(dayOf(now), days));
  }

  /// The extrapolated ray, oldest first, starting at the last observed point.
  ///
  /// Stops at the goal when it falls inside [maxProjectionDays], otherwise at the
  /// horizon. Empty when there is no rate to extrapolate.
  static List<WeightPoint> _projectedSeries({
    required List<WeightPoint> observed,
    required double? ratePerDay,
    required double currentWeightKg,
    required DateTime now,
    required int? daysToGoal,
  }) {
    if (ratePerDay == null) return const [];

    final startDay = observed.isNotEmpty ? observed.last.day : dayOf(now);
    final startWeight =
        observed.isNotEmpty ? observed.last.weightKg : currentWeightKg;
    if (startWeight <= 0) return const [];

    final horizon = min(daysToGoal ?? maxProjectionDays, maxProjectionDays);
    if (horizon <= 0) return const [];

    final points = <WeightPoint>[
      WeightPoint(day: startDay, weightKg: startWeight),
    ];
    for (var day = projectionStepDays; day < horizon; day += projectionStepDays) {
      points.add(WeightPoint(
        day: addDays(startDay, day),
        weightKg: startWeight + ratePerDay * day,
      ));
    }
    // The horizon always gets an exact point, so the ray ends on the goal rather
    // than at whichever weekly tick happened to fall nearest it.
    points.add(WeightPoint(
      day: addDays(startDay, horizon),
      weightKg: startWeight + ratePerDay * horizon,
    ));
    return points;
  }

  // ──────────────────────────────────────────────
  // Calendar helpers
  // ──────────────────────────────────────────────

  static DateTime dayOf(DateTime at) => DateTime(at.year, at.month, at.day);

  /// [day] shifted by [delta] calendar days.
  ///
  /// Through the constructor, which normalises an out-of-range day, rather than
  /// by adding a Duration — midnight plus 24 hours lands at 01:00 or 23:00 across
  /// a DST change, and the point would then belong to the neighbouring day.
  static DateTime addDays(DateTime day, int delta) =>
      DateTime(day.year, day.month, day.day + delta);

  /// Whole calendar days from [origin] to [day].
  ///
  /// Compared as UTC midnights. `difference().inDays` on local midnights returns
  /// 0 for a 23-hour DST day and would collapse two distinct days into one x
  /// position, quietly flattening the regression.
  static int dayIndex(DateTime day, DateTime origin) {
    return DateTime.utc(day.year, day.month, day.day)
        .difference(DateTime.utc(origin.year, origin.month, origin.day))
        .inDays;
  }
}
