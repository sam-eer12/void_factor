import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/gemma_model_service.dart';
import 'package:void_factor/features/projection/projection_engine.dart';
import 'package:void_factor/features/projection/projection_providers.dart';
import 'package:void_factor/features/projection/recommendation_narrator.dart';
import 'package:void_factor/models/projection.dart';
import 'package:void_factor/models/user_profile.dart';

/// The model's state, stepped by hand the way a download steps it.
class _SteppingModel extends GemmaModel {
  @override
  Future<GemmaModelState> build() async =>
      const GemmaModelState(stage: GemmaModelStage.downloading);

  void report(GemmaModelState next) => state = AsyncData(next);
}

void main() {
  final projection = Projection(
    observed: const [],
    projected: const [],
    currentWeightKg: 80,
    targetWeightKg: 75,
    goal: WeightGoal.lose,
    ratePerWeekKg: -0.2,
    targetRatePerWeekKg: 0.5,
    basis: ProjectionBasis.measured,
    status: ProjectionStatus.behind,
    daysToGoal: 70,
    goalDate: DateTime(2026, 11, 4),
    bmrKcal: 1750,
    activeKcal: 150,
    tdeeKcal: 2250,
    intakeKcal: 2450,
    proteinGPerDay: 90,
    balanceKcal: 200,
    loggedDayCount: 4,
    intakeWindowDays: ProjectionEngine.intakeWindowDays,
    weighInDayCount: 9,
    seriesSpanDays: 28,
    activeEnergyFromDevice: true,
  );

  test('a download ticking through its percentages leaves the cards alone',
      () async {
    final model = _SteppingModel();
    final container = ProviderContainer(overrides: [
      projectionProvider.overrideWith((ref) async => projection),
      gemmaModelProvider.overrideWith(() => model),
      recommendationNarratorProvider
          .overrideWithValue(const TemplateNarrator()),
    ]);
    addTearDown(container.dispose);
    await container.read(recommendationsProvider.future);

    var rebuilds = 0;
    container.listen(recommendationsProvider, (_, _) => rebuilds++);
    for (var progress = 1; progress <= 50; progress++) {
      model.report(GemmaModelState(
        stage: GemmaModelStage.downloading,
        progress: progress,
      ));
      await Future<void>.delayed(Duration.zero);
    }

    expect(rebuilds, 0);

    // The one change that matters still re-words them.
    model.report(const GemmaModelState(stage: GemmaModelStage.ready));
    await Future<void>.delayed(Duration.zero);
    await container.read(recommendationsProvider.future);
    expect(rebuilds, greaterThan(0));
  });
}
