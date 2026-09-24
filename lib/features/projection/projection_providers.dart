import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/projection.dart';
import '../../models/recommendation.dart';
import '../auth/session_provider.dart';
import '../food_log/food_log_providers.dart';
import '../health/health_providers.dart';
import '../weight_log/weight_log_providers.dart';
import 'calorie_budget.dart';
import 'gemma_model_service.dart';
import 'projection_engine.dart';
import 'recommendation_engine.dart';
import 'recommendation_narrator.dart';

/// The clock the projection reads.
///
/// A provider rather than a direct `DateTime.now()` because every window in
/// [ProjectionEngine] is measured backwards from today, so a test that cannot set
/// the date cannot test a window boundary at all — and the boundary is where the
/// interesting bugs live.
final projectionClockProvider = Provider<DateTime Function()>((ref) {
  return DateTime.now;
});

/// The whole projection, from every source at once.
///
/// One provider rather than several so the chart, the goal card, the status chip,
/// and the recommendations are all reading a single snapshot. Four independent
/// providers would each settle at their own moment, and a screen where the chart
/// disagrees with the date above it is worse than one that waits.
///
/// Every source is awaited through `.future`, so this reports loading until all
/// four have arrived and surfaces the first failure rather than rendering a
/// projection built from a partial picture.
final projectionProvider = FutureProvider<Projection>((ref) async {
  final profile = await ref.watch(profileProvider.future);
  final weights = await ref.watch(weightLogProvider.future);
  final foods = await ref.watch(recentFoodLogProvider.future);
  final energy = await ref.watch(energyWindowProvider.future);

  return ProjectionEngine.compute(
    profile: profile,
    weights: weights,
    foods: foods,
    energy: energy,
    now: ref.read(projectionClockProvider)(),
  );
});

/// Today's intake against today's target — what the dashboard dial draws.
///
/// The totals are awaited; the projection is not. Reading it as a settled value
/// means the ring renders as soon as the food log does, and the target appears a
/// moment later when the profile, weigh-ins and energy window have all arrived.
/// Awaiting both would hold the number the user just logged hostage to four
/// sources, and a failure in any of them would blank a dial that has a perfectly
/// good intake to show — a projection that cannot be built is a missing target,
/// not a missing day.
final calorieBudgetProvider = FutureProvider<CalorieBudget>((ref) async {
  final totals = await ref.watch(todayTotalsProvider.future);
  final projection = ref.watch(projectionProvider).value;

  return CalorieBudget.from(
    consumedKcal: totals.calories,
    entryCount: totals.entryCount,
    projection: projection,
  );
});

final recommendationNarratorProvider = Provider<RecommendationNarrator>((ref) {
  return GemmaNarrator(gateway: ref.watch(gemmaGatewayProvider));
});

/// The three cards the lower section renders.
///
/// Separated from [projectionProvider] so the numbers above are never waiting on
/// the model: the projection resolves in microseconds of pure Dart, while this
/// may spend half a minute in on-device inference. Watching one provider for both
/// would hold the chart hostage to the narrator.
///
/// Ranking happens here, once, and the narrator receives the result. It cannot
/// change which recommendations were chosen — only how they are worded.
final recommendationsProvider =
    FutureProvider<List<Recommendation>>((ref) async {
  final projection = await ref.watch(projectionProvider.future);

  // Watched, not read: downloading the model must re-narrate the cards the user
  // is already looking at, or the download appears to have done nothing.
  //
  // Only readiness, though. A download publishes a new state for every percent,
  // and watching the whole state would re-rank and re-word the cards a hundred
  // times on the way to the one change that matters.
  final isReady =
      await ref.watch(gemmaModelProvider.selectAsync((model) => model.isReady));

  final candidates = RecommendationEngine.top(projection);
  final narrator =
      isReady ? ref.read(recommendationNarratorProvider) : const TemplateNarrator();

  return narrator.narrate(projection: projection, candidates: candidates);
});
