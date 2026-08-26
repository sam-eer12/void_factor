import 'user_profile.dart';

/// One plotted weight, at one day's resolution.
class WeightPoint {
  const WeightPoint({required this.day, required this.weightKg});

  /// Local midnight of the day this point sits on.
  final DateTime day;

  final double weightKg;
}

/// Where the rate driving the projection came from.
///
/// Surfaced in the UI rather than kept internal: the two bases deserve different
/// amounts of trust, and a date that hides which one produced it invites the user
/// to over-read a model estimate as a measurement.
enum ProjectionBasis {
  /// A least-squares slope through the user's own weigh-ins.
  ///
  /// Preferred whenever the series can support it, because it measures the body
  /// instead of modelling it — it absorbs whatever the energy model gets wrong
  /// about this particular person.
  measured,

  /// Energy balance: mean intake against estimated expenditure, converted at
  /// [ProjectionEngine.kcalPerKg]. Used until the weigh-in series is long
  /// enough to trust.
  energyBalance,

  /// Neither was available.
  none,
}

/// How the current trajectory compares with the goal the user set.
enum ProjectionStatus {
  /// Already within [ProjectionEngine.goalReachedToleranceKg] of target.
  goalReached,

  /// Moving the right way, at roughly the intended rate.
  onTrack,

  /// Moving the right way, faster than intended.
  ahead,

  /// Moving the right way, slower than intended.
  behind,

  /// Barely moving at all. For a `maintain` goal this is success, so that case
  /// reports [onTrack] instead.
  stalled,

  /// Moving away from the target.
  wrongDirection,

  /// Not enough logged data to say anything honest.
  insufficientData,
}

/// Everything the projections screen renders, computed in one pass.
///
/// A single immutable result rather than a bag of providers so the chart, the
/// goal card, the status chip, and the recommendations cannot disagree — they
/// are all reading one snapshot of one computation.
class Projection {
  const Projection({
    required this.observed,
    required this.projected,
    required this.currentWeightKg,
    required this.targetWeightKg,
    required this.goal,
    required this.ratePerWeekKg,
    required this.targetRatePerWeekKg,
    required this.basis,
    required this.status,
    required this.daysToGoal,
    required this.goalDate,
    required this.bmrKcal,
    required this.activeKcal,
    required this.tdeeKcal,
    required this.intakeKcal,
    required this.proteinGPerDay,
    required this.balanceKcal,
    required this.loggedDayCount,
    required this.intakeWindowDays,
    required this.weighInDayCount,
    required this.seriesSpanDays,
    required this.activeEnergyFromDevice,
  });

  /// The user's weigh-ins, one point per day, oldest first.
  final List<WeightPoint> observed;

  /// The extrapolation, oldest first. Begins at the last [observed] point so the
  /// two series join without a gap, and is empty when there is no rate to
  /// extrapolate.
  final List<WeightPoint> projected;

  final double currentWeightKg;
  final double targetWeightKg;

  /// Carried on the result so consumers never need the profile alongside it.
  /// `maintain` in particular changes what a near-zero rate *means*, and the
  /// recommendations read it to decide whether any deficit is wanted at all.
  final WeightGoal goal;

  /// Signed kg/week. Negative means losing.
  final double ratePerWeekKg;

  /// The rate the user asked for, always positive — `UserProfile.weeklyRate`.
  final double targetRatePerWeekKg;

  final ProjectionBasis basis;
  final ProjectionStatus status;

  /// Null whenever [status] makes a date meaningless — stalled, wrong direction,
  /// or not enough data.
  final int? daysToGoal;
  final DateTime? goalDate;

  // ── The energy figures behind an energyBalance projection ──
  // Reported even when [basis] is measured, because the recommendations are
  // built from them regardless of which rate won.

  final double bmrKcal;

  /// Mean active (non-basal) kcal/day.
  final double activeKcal;

  final double tdeeKcal;

  /// Mean kcal/day across days that have at least one logged meal.
  final double intakeKcal;

  /// Mean protein g/day across the same days.
  final double proteinGPerDay;

  /// [intakeKcal] − [tdeeKcal]. Negative is a deficit.
  final double balanceKcal;

  /// How many days in the intake window had at least one meal logged. The
  /// honesty check on [intakeKcal]: a mean over two days is not a habit.
  final int loggedDayCount;

  final int intakeWindowDays;

  /// Distinct days carrying a weigh-in.
  final int weighInDayCount;

  /// Days between the first and last weigh-in.
  final int seriesSpanDays;

  /// Whether [activeKcal] came from the platform's own energy figure, or was
  /// estimated from steps and workout minutes because that permission was never
  /// granted.
  final bool activeEnergyFromDevice;

  /// Whether there is enough behind this to show a date at all.
  bool get hasTrajectory =>
      status != ProjectionStatus.insufficientData && projected.isNotEmpty;

  /// Signed kg still to go. Negative means the target is below current weight.
  double get remainingKg => targetWeightKg - currentWeightKg;
}
