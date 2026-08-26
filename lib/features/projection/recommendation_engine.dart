import '../../models/projection.dart';
import '../../models/recommendation.dart';
import '../../models/user_profile.dart';
import 'projection_engine.dart';

/// Decides *which* three things the user should hear about, and in what order.
///
/// Pure functions over a [Projection]. No copy, no icons, no model — those
/// belong to `RecommendationNarrator`, and keeping them out is what makes this
/// testable by asserting on kinds and ordering rather than on sentences.
///
/// Every kind is always a candidate, including the ones the user is already doing
/// well. An on-target candidate simply ranks near the bottom. That is how three
/// cards are guaranteed without ever inventing a problem: someone doing
/// everything right gets three "keep doing this" cards, not filler.
class RecommendationEngine {
  RecommendationEngine._();

  /// How many recommendations the screen shows.
  static const int count = 3;

  /// Fraction of the window that should carry a logged meal before intake is
  /// considered a habit rather than a sample. 70% — ten days of fourteen.
  static const double loggingAdherenceFloor = 0.7;

  /// Daily active-energy floor, kcal. Roughly a brisk half-hour walk on top of
  /// ordinary movement.
  static const double activeKcalFloor = 300;

  /// Protein floor in grams per kg of body weight.
  ///
  /// 1.6 g/kg — the low end of the range consistently associated with preserving
  /// lean mass in a deficit, chosen as a floor rather than a target so the
  /// recommendation fires only when intake is genuinely low.
  static const double proteinGPerKg = 1.6;

  /// Weigh-ins wanted inside the weight window. Eight in thirty days is roughly
  /// twice a week — the cadence that unlocks
  /// [ProjectionBasis.measured].
  static const int weighInFloorDays = 8;

  /// Below this absolute kcal difference, the calorie gap counts as met. A
  /// hundred kcal is inside the error of both the BMR estimate and the user's
  /// own portion logging, so "fix it" would be false precision.
  static const double calorieGapToleranceKcal = 100;

  // Base importance, before urgency. Ordering these is a product judgement:
  // logging outranks everything because every other number is computed from it,
  // and a confident recommendation built on three logged days is worse than no
  // recommendation at all.
  static const double _baseLogging = 1.00;
  static const double _baseCalorieGap = 0.95;
  static const double _baseWeighIn = 0.70;
  static const double _baseExercise = 0.60;
  static const double _baseProtein = 0.50;

  /// Multiplier on the weigh-in candidate while the projection is still running
  /// on the energy model — more weigh-ins would replace an estimate with a
  /// measurement, which is worth more than the raw shortfall suggests.
  static const double _unlocksMeasuredBoost = 1.35;

  /// Multiplier on the calorie gap when the user is moving away from target.
  /// Intake is the fastest lever they have.
  static const double _wrongDirectionBoost = 1.5;

  /// The daily energy balance the user's requested rate implies.
  ///
  /// Zero for a `maintain` goal regardless of the stored weekly rate: the rate
  /// field still holds whatever was last picked in Goals & Diet, and honouring it
  /// here would prescribe a deficit to someone who asked to hold steady.
  static double requiredDailyBalanceKcal(Projection projection) {
    if (projection.goal == WeightGoal.maintain) return 0;
    if (projection.targetRatePerWeekKg <= 0) return 0;
    final direction = projection.remainingKg.isNegative ? -1.0 : 1.0;
    return direction *
        projection.targetRatePerWeekKg /
        7 *
        ProjectionEngine.kcalPerKg;
  }

  /// Every candidate, ranked, highest priority first.
  ///
  /// Exposed separately from [top] so a test can assert the full ordering rather
  /// than only what survived the cut.
  static List<RecommendationCandidate> rank(Projection projection) {
    final candidates = <RecommendationCandidate>[
      _logging(projection),
      _weighIn(projection),
      _exercise(projection),
      // Suppressed when there is nothing honest to say. A calorie gap needs an
      // expenditure model, and a protein figure needs enough logged days to be
      // more than one lunch. Both are covered by the logging candidate instead,
      // which is the real problem in that state.
      if (projection.basis != ProjectionBasis.none) _calorieGap(projection),
      if (projection.loggedDayCount >= ProjectionEngine.minLoggedDays)
        _protein(projection),
    ];

    candidates.sort((a, b) {
      final byPriority = b.priority.compareTo(a.priority);
      // Ties broken by declaration order of the enum, so the same projection
      // always produces the same three cards in the same order — a list that
      // reshuffles between rebuilds reads as a bug.
      return byPriority != 0
          ? byPriority
          : a.kind.index.compareTo(b.kind.index);
    });
    return candidates;
  }

  /// The [count] highest-priority candidates.
  ///
  /// The three unconditional candidates guarantee this is always full, so the
  /// screen never has to render a gap.
  static List<RecommendationCandidate> top(Projection projection) {
    final ranked = rank(projection);
    return ranked.sublist(0, ranked.length < count ? ranked.length : count);
  }

  // ──────────────────────────────────────────────
  // Candidates
  // ──────────────────────────────────────────────

  static RecommendationCandidate _logging(Projection projection) {
    final target = projection.intakeWindowDays * loggingAdherenceFloor;
    final onTarget = projection.loggedDayCount >= target;
    return RecommendationCandidate(
      kind: RecommendationKind.loggingAdherence,
      magnitude: projection.loggedDayCount.toDouble(),
      target: projection.intakeWindowDays.toDouble(),
      onTarget: onTarget,
      priority: _priority(
        base: _baseLogging,
        onTarget: onTarget,
        // Measured against the floor, not the window: logging ten of fourteen
        // days is success, and scoring it as a 29% shortfall would keep a solved
        // problem at the top of the list forever.
        shortfall: _ratioShortfall(projection.loggedDayCount.toDouble(), target),
      ),
    );
  }

  static RecommendationCandidate _weighIn(Projection projection) {
    final onTarget = projection.weighInDayCount >= weighInFloorDays;
    final base = projection.basis == ProjectionBasis.measured
        ? _baseWeighIn
        : _baseWeighIn * _unlocksMeasuredBoost;
    return RecommendationCandidate(
      kind: RecommendationKind.weighInCadence,
      magnitude: projection.weighInDayCount.toDouble(),
      target: weighInFloorDays.toDouble(),
      onTarget: onTarget,
      priority: _priority(
        base: base,
        onTarget: onTarget,
        shortfall: _ratioShortfall(
          projection.weighInDayCount.toDouble(),
          weighInFloorDays.toDouble(),
        ),
      ),
    );
  }

  static RecommendationCandidate _exercise(Projection projection) {
    final onTarget = projection.activeKcal >= activeKcalFloor;
    return RecommendationCandidate(
      kind: RecommendationKind.exerciseVolume,
      magnitude: projection.activeKcal,
      target: activeKcalFloor,
      onTarget: onTarget,
      priority: _priority(
        base: _baseExercise,
        onTarget: onTarget,
        shortfall: _ratioShortfall(projection.activeKcal, activeKcalFloor),
      ),
    );
  }

  static RecommendationCandidate _protein(Projection projection) {
    final target = proteinGPerKg * projection.currentWeightKg;
    final onTarget = projection.proteinGPerDay >= target;
    return RecommendationCandidate(
      kind: RecommendationKind.proteinFloor,
      magnitude: projection.proteinGPerDay,
      target: target,
      onTarget: onTarget,
      priority: _priority(
        base: _baseProtein * _intakeConfidence(projection),
        onTarget: onTarget,
        shortfall: _ratioShortfall(projection.proteinGPerDay, target),
      ),
    );
  }

  static RecommendationCandidate _calorieGap(Projection projection) {
    final required = requiredDailyBalanceKcal(projection);
    final gap = required - projection.balanceKcal;
    final onTarget = gap.abs() <= calorieGapToleranceKcal;

    final base = projection.status == ProjectionStatus.wrongDirection
        ? _baseCalorieGap * _wrongDirectionBoost
        : _baseCalorieGap;

    return RecommendationCandidate(
      kind: RecommendationKind.calorieGap,
      // The user's own balance, so the copy can quote where they are before
      // saying where to go.
      magnitude: projection.balanceKcal,
      target: required,
      onTarget: onTarget,
      priority: _priority(
        base: base * _intakeConfidence(projection),
        onTarget: onTarget,
        // Scaled against a 550 kcal/day reference — the balance a 0.5 kg/week
        // goal implies — so "miss by 500" reads as a full shortfall rather than
        // being flattened by whatever the user's own target happens to be.
        shortfall: (gap.abs() / 550).clamp(0, 1).toDouble(),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Scoring
  // ──────────────────────────────────────────────

  /// Combines standing importance with how badly this dimension is missed.
  ///
  /// An on-target candidate keeps a small non-zero score rather than dropping to
  /// zero, so the ordering among "you are fine here" cards still follows [base]
  /// and stays stable instead of depending on float ties.
  static double _priority({
    required double base,
    required bool onTarget,
    required double shortfall,
  }) {
    if (onTarget) return base * 0.05;
    // Floored at 0.3 of base so any live shortfall outranks every on-target
    // candidate, however small the miss.
    return base * (0.3 + 0.7 * shortfall.clamp(0, 1));
  }

  static double _ratioShortfall(double actual, double target) {
    if (target <= 0) return 0;
    final missing = target - actual;
    if (missing <= 0) return 0;
    return (missing / target).clamp(0, 1).toDouble();
  }

  /// How much to trust a figure averaged over only the days the user logged.
  ///
  /// [Projection.intakeKcal] and [Projection.proteinGPerDay] are means over logged
  /// days alone, so at four days of fourteen they describe a sample of someone's
  /// eating rather than their diet. Prescribing a 750 kcal correction on that
  /// basis is a confident claim resting on thin evidence, and the logging card —
  /// which fixes the evidence — is the one that should lead.
  ///
  /// Scaled linearly with adherence rather than suppressed outright: a
  /// thinly-evidenced gap is still worth showing once nothing more urgent wants
  /// the slot, and dropping it would leave the screen with nothing to say about
  /// intake at all. Reaches 1 at the adherence floor, not at a full window, so
  /// hitting the logging target removes the discount entirely.
  static double _intakeConfidence(Projection projection) {
    final floor = projection.intakeWindowDays * loggingAdherenceFloor;
    if (floor <= 0) return 1;
    return (projection.loggedDayCount / floor).clamp(0.0, 1.0).toDouble();
  }
}
