/// What a recommendation is about.
///
/// The kind, not the wording. Copy lives in `RecommendationNarrator`, and the
/// icon is chosen by the widget — which is what lets the same ranked candidate be
/// phrased by a template or by an on-device model without the ranking changing.
enum RecommendationKind {
  /// Intake against the deficit or surplus the requested rate needs.
  calorieGap,

  /// How many days in the window carried a logged meal.
  loggingAdherence,

  /// Active energy against a daily floor.
  exerciseVolume,

  /// Protein against g-per-kg of body weight.
  proteinFloor,

  /// How often the user weighs in, which is what decides whether the projection
  /// can use a measured slope at all.
  weighInCadence,
}

/// A ranked recommendation before anyone has chosen words for it.
///
/// Data only: which dimension, how urgent, where the user is, and where they
/// should be. Separating this from the copy is what keeps the ranking testable
/// without asserting on sentences, and what lets a language model rephrase a
/// recommendation without any power to change which ones were selected or why.
class RecommendationCandidate {
  const RecommendationCandidate({
    required this.kind,
    required this.priority,
    required this.magnitude,
    required this.target,
    required this.onTarget,
  });

  final RecommendationKind kind;

  /// Higher sorts first. Comparable only against other candidates from the same
  /// run — it is a ranking score, not a percentage of anything.
  final double priority;

  /// Where the user is now, in [kind]'s own unit.
  final double magnitude;

  /// Where they should be, same unit.
  final double target;

  /// Whether [magnitude] already satisfies [target].
  ///
  /// Every kind is always a candidate, including the ones the user is doing
  /// fine on — an on-target candidate simply ranks low. That is what guarantees
  /// three recommendations exist without inventing filler when someone is doing
  /// everything right; the third card becomes "keep doing this" rather than a
  /// fabricated problem.
  final bool onTarget;

  /// How far short of [target] this is, from `0` (met) to `1` (nothing at all).
  double get shortfall {
    if (onTarget || target == 0) return 0;
    final ratio = (target - magnitude).abs() / target.abs();
    return ratio.clamp(0, 1).toDouble();
  }
}

/// A recommendation as the screen renders it.
class Recommendation {
  const Recommendation({
    required this.kind,
    required this.title,
    required this.value,
    required this.body,
    required this.onTarget,
    this.narratedOnDevice = false,
  });

  final RecommendationKind kind;

  /// Short label, e.g. `CALORIC DEFICIT`.
  final String title;

  /// The headline figure, e.g. `-450 KCAL`.
  final String value;

  /// One or two sentences of explanation.
  final String body;

  /// Carried through from the candidate so the UI can mark a "doing fine" card
  /// differently from a corrective one.
  final bool onTarget;

  /// Whether an on-device model wrote this copy, or the deterministic templates
  /// did.
  ///
  /// Surfaced in the UI. A user told a model is advising them deserves to know
  /// when it actually was — and when the fallback quietly took over instead.
  final bool narratedOnDevice;

  Recommendation copyWith({
    String? title,
    String? value,
    String? body,
    bool? narratedOnDevice,
  }) {
    return Recommendation(
      kind: kind,
      title: title ?? this.title,
      value: value ?? this.value,
      body: body ?? this.body,
      onTarget: onTarget,
      narratedOnDevice: narratedOnDevice ?? this.narratedOnDevice,
    );
  }
}
