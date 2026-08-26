import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/app/routes.dart';
import 'package:void_factor/features/projection/gemma_model_service.dart';
import 'package:void_factor/features/projection/projection_providers.dart';
import 'package:void_factor/models/projection.dart';
import 'package:void_factor/models/recommendation.dart';
import 'package:void_factor/models/user_profile.dart';
import 'package:void_factor/screens/stats/log_weight_sheet.dart';
import 'package:void_factor/screens/stats/projections_screen.dart';
import 'package:void_factor/widgets/weight_trajectory_chart.dart';

/// Stands in for the model's install lifecycle.
///
/// The real notifier reaches the `flutter_gemma` plugin through platform
/// channels, which do not exist under `flutter_test`. These tests are about what
/// the screen offers for each stage, so the stage is simply handed to it.
class FakeGemmaModel extends GemmaModel {
  FakeGemmaModel(this.initial);

  final GemmaModelState initial;
  int downloadCalls = 0;

  @override
  Future<GemmaModelState> build() async => initial;

  @override
  Future<void> download() async => downloadCalls++;
}

void main() {
  final today = DateTime(2026, 8, 26);

  Projection projection({
    List<WeightPoint>? observed,
    List<WeightPoint>? projected,
    double currentWeightKg = 80,
    double targetWeightKg = 72,
    double ratePerWeekKg = -0.5,
    ProjectionBasis basis = ProjectionBasis.measured,
    ProjectionStatus status = ProjectionStatus.onTrack,
    int? daysToGoal = 47,
    DateTime? goalDate,
    int weighInDayCount = 6,
  }) {
    return Projection(
      observed: observed ??
          [
            WeightPoint(day: DateTime(2026, 8, 12), weightKg: 82),
            WeightPoint(day: today, weightKg: currentWeightKg),
          ],
      projected: projected ?? const [],
      currentWeightKg: currentWeightKg,
      targetWeightKg: targetWeightKg,
      goal: WeightGoal.lose,
      ratePerWeekKg: ratePerWeekKg,
      targetRatePerWeekKg: -0.5,
      basis: basis,
      status: status,
      daysToGoal: daysToGoal,
      goalDate: goalDate ?? DateTime(2026, 10, 12),
      bmrKcal: 1700,
      activeKcal: 300,
      tdeeKcal: 2340,
      intakeKcal: 1800,
      proteinGPerDay: 120,
      balanceKcal: -540,
      loggedDayCount: 12,
      intakeWindowDays: 14,
      weighInDayCount: weighInDayCount,
      seriesSpanDays: 14,
      activeEnergyFromDevice: true,
    );
  }

  Recommendation recommendation(
    RecommendationKind kind, {
    required String title,
    required String value,
    String body = 'Do the thing.',
    bool onTarget = false,
    bool narratedOnDevice = false,
  }) {
    return Recommendation(
      kind: kind,
      title: title,
      value: value,
      body: body,
      onTarget: onTarget,
      narratedOnDevice: narratedOnDevice,
    );
  }

  final defaultRecommendations = [
    recommendation(RecommendationKind.calorieGap,
        title: 'CALORIC DEFICIT', value: '-450 KCAL'),
    recommendation(RecommendationKind.proteinFloor,
        title: 'PROTEIN FLOOR', value: '120 G'),
    recommendation(RecommendationKind.weighInCadence,
        title: 'WEIGH-IN CADENCE', value: '2 / WK'),
  ];

  /// Route names the screen pushed, so navigation wiring can be asserted without
  /// building the destination — the real one reads secure storage.
  late List<String?> pushedRoutes;
  late FakeGemmaModel model;

  setUp(() {
    pushedRoutes = [];
    model = FakeGemmaModel(
      const GemmaModelState(stage: GemmaModelStage.ready),
    );
  });

  /// Pumps the screen with each async source pinned.
  ///
  /// A failure is thrown from inside the provider rather than handed in as a
  /// ready-made `Future.error`, which the test framework reports as an uncaught
  /// exception before Riverpod has attached to it. `pending` never completes, so
  /// it is the shape of the first frame.
  ///
  /// `settle` is off for the pending cases: `pumpAndSettle` never returns while a
  /// `CircularProgressIndicator` is on screen, because the spinner's animation
  /// never ends.
  Future<void> pumpScreen(
    WidgetTester tester, {
    Projection? withProjection,
    Object? projectionFailure,
    bool projectionPending = false,
    List<Recommendation>? withRecommendations,
    Object? recommendationsFailure,
    bool recommendationsPending = false,
    bool settle = true,
  }) async {
    // The screen is a long scroll, and a widget below the fold is not found by
    // `find.text`. A tall surface holds all of it.
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        projectionProvider.overrideWith((ref) async {
          if (projectionPending) return Completer<Projection>().future;
          final failure = projectionFailure;
          if (failure != null) throw failure;
          return withProjection ?? projection();
        }),
        recommendationsProvider.overrideWith((ref) async {
          if (recommendationsPending) {
            return Completer<List<Recommendation>>().future;
          }
          final failure = recommendationsFailure;
          if (failure != null) throw failure;
          return withRecommendations ?? defaultRecommendations;
        }),
        gemmaModelProvider.overrideWith(() => model),
      ],
      child: MaterialApp(
        home: const ProjectionsScreen(),
        onGenerateRoute: (settings) {
          pushedRoutes.add(settings.name);
          return MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('PUSHED')),
            settings: settings,
          );
        },
      ),
    ));

    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  group('trajectory', () {
    testWidgets('reports the figures the projection computed, not the mock',
        (tester) async {
      await pumpScreen(
        tester,
        withProjection: projection(
          currentWeightKg: 78.4,
          targetWeightKg: 72,
          ratePerWeekKg: -0.6,
        ),
      );

      expect(find.text('78.4'), findsOneWidget);
      expect(find.text('72'), findsOneWidget);
      expect(find.text('-0.6'), findsOneWidget);
      expect(find.text('NOW (KG)'), findsOneWidget);
      expect(find.text('RATE (KG/WK)'), findsOneWidget);
    });

    testWidgets('names the status and where it came from', (tester) async {
      await pumpScreen(
        tester,
        withProjection: projection(
          status: ProjectionStatus.behind,
          basis: ProjectionBasis.measured,
          weighInDayCount: 6,
        ),
      );

      expect(find.text('BEHIND'), findsOneWidget);
      // The mock's chip said ON TRACK to everyone, always.
      expect(find.text('ON TRACK'), findsNothing);
      expect(
        find.text('PROJECTION STATUS · FROM 6 WEIGH-INS'),
        findsOneWidget,
      );
    });

    testWidgets('says an estimate is an estimate', (tester) async {
      await pumpScreen(
        tester,
        withProjection: projection(basis: ProjectionBasis.energyBalance),
      );

      expect(
        find.text('PROJECTION STATUS · FROM ENERGY BALANCE'),
        findsOneWidget,
      );
    });

    testWidgets('counts the days to the goal and dates them', (tester) async {
      await pumpScreen(
        tester,
        withProjection: projection(
          daysToGoal: 47,
          goalDate: DateTime(2026, 10, 12),
          basis: ProjectionBasis.energyBalance,
        ),
      );

      expect(find.text('47 DAYS'), findsOneWidget);
      expect(find.text('12 OCT 2026 · FROM ENERGY BALANCE'), findsOneWidget);
      // The literal the mock shipped.
      expect(find.text('68 DAYS'), findsNothing);
    });

    testWidgets('shows a dash rather than a zero for a weight it does not have',
        (tester) async {
      await pumpScreen(
        tester,
        withProjection: projection(
          currentWeightKg: 0,
          targetWeightKg: 0,
          basis: ProjectionBasis.none,
          status: ProjectionStatus.insufficientData,
          daysToGoal: null,
        ),
      );

      // Two weights and the rate: a rate with no basis behind it is unknown,
      // not zero.
      expect(find.text('--'), findsNWidgets(3));
      expect(find.text('0.0'), findsNothing);
    });

    testWidgets('asks for a weigh-in instead of drawing an empty chart',
        (tester) async {
      await pumpScreen(
        tester,
        withProjection: projection(observed: const []),
      );

      expect(find.text(WeightTrajectoryChart.emptyTitle), findsOneWidget);
    });
  });

  group('when the projection cannot be built', () {
    testWidgets('offers a retry and keeps the weigh-in path open',
        (tester) async {
      await pumpScreen(
        tester,
        projectionFailure: Exception('profile unreadable'),
      );

      expect(find.text(ProjectionsScreen.errorProjection), findsOneWidget);
      expect(find.text('TRY AGAIN'), findsOneWidget);
      // A weigh-in is stored by a different path than the one that just failed,
      // and it is the thing most likely to fill the projection in.
      expect(find.text('LOG WEIGHT'), findsOneWidget);
      // The exception names nothing the user can act on.
      expect(find.textContaining('profile unreadable'), findsNothing);
    });

    testWidgets('titles the card and holds its height while the logs are read',
        (tester) async {
      // Nothing here ever completes: the shape of the first frame.
      await pumpScreen(
        tester,
        projectionPending: true,
        recommendationsPending: true,
        settle: false,
      );

      expect(find.text('READING YOUR LOGS'), findsOneWidget);
      expect(find.text('WEIGHT TRAJECTORY'), findsOneWidget);
      expect(find.text(ProjectionsScreen.errorProjection), findsNothing);
      // The card that holds the figures is the same height either way, so the
      // page does not jump when they arrive.
      expect(
        tester.getSize(find.byType(CircularProgressIndicator).first).height,
        32,
      );
    });
  });

  group('recommendations', () {
    testWidgets('renders the three it was given', (tester) async {
      await pumpScreen(tester);

      expect(find.text(ProjectionsScreen.protocolsTitle), findsOneWidget);
      expect(find.text('CALORIC DEFICIT'), findsOneWidget);
      expect(find.text('-450 KCAL'), findsOneWidget);
      expect(find.text('WEIGH-IN CADENCE'), findsOneWidget);
    });

    testWidgets('says when the built-in wording wrote them', (tester) async {
      await pumpScreen(tester);

      expect(find.text(ProjectionsScreen.narratedByTemplate), findsOneWidget);
      expect(find.text(ProjectionsScreen.narratedOnDevice), findsNothing);
    });

    testWidgets('says when the on-device model wrote them', (tester) async {
      await pumpScreen(
        tester,
        withRecommendations: [
          for (final card in defaultRecommendations)
            card.copyWith(narratedOnDevice: true),
        ],
      );

      expect(find.text(ProjectionsScreen.narratedOnDevice), findsOneWidget);
    });

    testWidgets('does not claim on-device wording for a partial narration',
        (tester) async {
      // Cannot happen through `GemmaNarrator`, which falls the whole list back
      // rather than mixing voices. Asserted because the claim is about
      // provenance, and the safe answer if it ever mixed is the modest one.
      await pumpScreen(
        tester,
        withRecommendations: [
          defaultRecommendations.first.copyWith(narratedOnDevice: true),
          defaultRecommendations[1],
        ],
      );

      expect(find.text(ProjectionsScreen.narratedByTemplate), findsOneWidget);
    });

    testWidgets('says so when they could not be worked out', (tester) async {
      await pumpScreen(
        tester,
        recommendationsFailure: Exception('narrator exploded'),
      );

      expect(find.text(ProjectionsScreen.errorRecommendations), findsOneWidget);
      // The projection above is unaffected — the two providers are separate on
      // purpose.
      expect(find.text('WEIGHT TRAJECTORY'), findsOneWidget);
    });

    testWidgets('does not attribute an error to a wording source',
        (tester) async {
      await pumpScreen(
        tester,
        recommendationsFailure: Exception('narrator exploded'),
      );

      expect(find.text(ProjectionsScreen.narratedByTemplate), findsNothing);
      expect(find.text(ProjectionsScreen.narratedOnDevice), findsNothing);
    });
  });

  group('the on-device model offer', () {
    testWidgets('is absent once the model is installed', (tester) async {
      await pumpScreen(tester);

      expect(find.text('ON-DEVICE WORDING'), findsNothing);
      expect(find.text('DOWNLOAD MODEL'), findsNothing);
    });

    testWidgets('sends the user to the token screen when there is no token',
        (tester) async {
      model = FakeGemmaModel(
        const GemmaModelState(stage: GemmaModelStage.needsToken),
      );
      await pumpScreen(tester);

      expect(find.text('ON-DEVICE WORDING'), findsOneWidget);
      await tester.tap(find.text('ADD TOKEN'));
      await tester.pumpAndSettle();

      expect(pushedRoutes, contains(AppRoutes.onDeviceModel));
    });

    testWidgets('offers the download, and says what it costs', (tester) async {
      model = FakeGemmaModel(
        const GemmaModelState(stage: GemmaModelStage.notInstalled),
      );
      await pumpScreen(tester);

      // The size is stated before the tap, not after it starts.
      expect(find.textContaining('HALF A GIGABYTE'), findsOneWidget);

      await tester.tap(find.text('DOWNLOAD MODEL'));
      await tester.pumpAndSettle();

      expect(model.downloadCalls, 1);
    });

    testWidgets('reports progress while downloading', (tester) async {
      model = FakeGemmaModel(const GemmaModelState(
        stage: GemmaModelStage.downloading,
        progress: 42,
      ));
      await pumpScreen(tester);

      expect(find.text('DOWNLOADING — 42%'), findsOneWidget);
      // No second offer to start what is already running.
      expect(find.text('DOWNLOAD MODEL'), findsNothing);
    });

    testWidgets('names what failed and offers another go', (tester) async {
      model = FakeGemmaModel(const GemmaModelState(
        stage: GemmaModelStage.failed,
        message: GemmaModel.errorDownloadFailed,
      ));
      await pumpScreen(tester);

      expect(find.text(GemmaModel.errorDownloadFailed), findsOneWidget);
      await tester.tap(find.text('TRY AGAIN'));
      await tester.pumpAndSettle();

      expect(model.downloadCalls, 1);
    });

    testWidgets('never blocks the recommendations behind itself',
        (tester) async {
      model = FakeGemmaModel(
        const GemmaModelState(stage: GemmaModelStage.needsToken),
      );
      await pumpScreen(tester);

      // The figures are computed by the app either way; only the wording is at
      // stake.
      expect(find.text('CALORIC DEFICIT'), findsOneWidget);
      expect(find.text(ProjectionsScreen.narratedByTemplate), findsOneWidget);
    });
  });

  group('logging a weight', () {
    testWidgets('opens the sheet seeded with the current weight',
        (tester) async {
      await pumpScreen(
        tester,
        withProjection: projection(currentWeightKg: 78.4),
      );

      await tester.tap(find.text('LOG WEIGHT'));
      await tester.pumpAndSettle();

      expect(find.byType(LogWeightSheet), findsOneWidget);
      // A weigh-in is a nudge from the last one, not a number typed from
      // scratch.
      expect(find.widgetWithText(TextFormField, '78.4'), findsOneWidget);
    });

    testWidgets('seeds nothing when there is no weight to start from',
        (tester) async {
      await pumpScreen(
        tester,
        withProjection: projection(currentWeightKg: 0),
      );

      await tester.tap(find.text('LOG WEIGHT'));
      await tester.pumpAndSettle();

      // A field pre-filled with a value that fails its own validator is worse
      // than an empty one.
      expect(find.text('0'), findsNothing);
      expect(find.text('E.G. 74.5'), findsOneWidget);
    });
  });
}
