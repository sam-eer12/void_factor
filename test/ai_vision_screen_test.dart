import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:void_factor/features/food_log/food_analysis_client.dart';
import 'package:void_factor/features/food_log/food_log_providers.dart';
import 'package:void_factor/models/food_entry.dart';
import 'package:void_factor/screens/vision/ai_vision_screen.dart';

/// Stands in for the real controller.
///
/// The controller's own suite drives the picker, the compressor and the temp
/// file with real `dart:io`, which a widget test cannot do — `testWidgets` runs
/// inside `fake_async`, where a `dart:io` future never completes. Faking it here
/// leaves these tests about what the screen does with each outcome.
class FakeVisionController extends VisionAnalysisController {
  FakeVisionController({this.result, this.failure});

  FoodAnalysis? result;
  Object? failure;

  /// Every source the screen asked for, in order.
  final List<ImageSource> requested = [];

  /// Set to hold `capture` open so the loading state can be observed.
  Completer<void>? gate;

  @override
  Future<FoodAnalysis?> build() async => null;

  @override
  Future<FoodAnalysis?> capture(ImageSource source) async {
    requested.add(source);
    state = const AsyncLoading();
    if (gate != null) await gate!.future;

    final error = failure;
    if (error != null) {
      state = AsyncError(error, StackTrace.current);
      throw error;
    }
    state = AsyncData(result);
    return result;
  }
}

/// One model answer: a name, per-serving figures, and how many of that serving
/// were on the plate.
FoodAnalysis analysis(
  String name,
  Nutrients nutrients, {
  double quantity = 1,
}) =>
    (name: name, nutrients: nutrients, quantity: quantity);

class FakeRecentFoodLog extends RecentFoodLog {
  FakeRecentFoodLog(this.entries);

  final List<FoodEntry> entries;

  @override
  Future<List<FoodEntry>> build() async => entries;
}

void main() {
  FoodEntry entry(
    String name, {
    double calories = 100,
    DateTime? loggedAt,
  }) {
    return FoodEntry.create(
      name: name,
      nutrients: Nutrients(calories: calories),
      quantity: 1.0,
      source: FoodSource.vision,
      loggedAt: loggedAt ?? DateTime.now(),
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    FakeVisionController? vision,
    List<FoodEntry> log = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        visionAnalysisProvider
            .overrideWith(() => vision ?? FakeVisionController()),
        recentFoodLogProvider.overrideWith(() => FakeRecentFoodLog(log)),
      ],
      child: const MaterialApp(home: AiVisionScreen()),
    ));
    await tester.pumpAndSettle();
  }

  /// Pumps the screen under a route child that can be swapped out and back.
  ///
  /// [visible] stands in for AuthGate: while the session re-check is in flight
  /// it renders a spinner instead of the shell, which unmounts every screen
  /// inside it. The Navigator above stays put throughout, exactly as it does in
  /// the app.
  Future<void> pumpThroughResume(
    WidgetTester tester, {
    required FakeVisionController vision,
    required ValueNotifier<bool> visible,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        visionAnalysisProvider.overrideWith(() => vision),
        recentFoodLogProvider.overrideWith(() => FakeRecentFoodLog(const [])),
      ],
      child: MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, shown, _) => shown
              ? const AiVisionScreen()
              : const Scaffold(body: Center(child: CircularProgressIndicator())),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('capturing', () {
    testWidgets('CAPTURE asks for the camera', (tester) async {
      final vision = FakeVisionController();
      await pumpScreen(tester, vision: vision);

      await tester.tap(find.text('CAPTURE'));
      await tester.pumpAndSettle();

      expect(vision.requested, [ImageSource.camera]);
    });

    testWidgets('GALLERY asks for the photo library', (tester) async {
      final vision = FakeVisionController();
      await pumpScreen(tester, vision: vision);

      await tester.tap(find.text('GALLERY'));
      await tester.pumpAndSettle();

      expect(vision.requested, [ImageSource.gallery]);
    });

    testWidgets('says it is working while the analysis is in flight',
        (tester) async {
      final vision = FakeVisionController(
        result: analysis('Toast', const Nutrients(calories: 200)),
      )..gate = Completer<void>();
      await pumpScreen(tester, vision: vision);

      await tester.tap(find.text('CAPTURE'));
      await tester.pump();

      // A provider round-trip takes seconds; an unchanged screen reads as a tap
      // that did not register.
      expect(find.text(AiVisionScreen.analysingLabel), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      vision.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('will not fire a second scan while one is running',
        (tester) async {
      final vision = FakeVisionController(
        result: analysis('Toast', const Nutrients(calories: 200)),
      )..gate = Completer<void>();
      await pumpScreen(tester, vision: vision);

      await tester.tap(find.text('CAPTURE'));
      await tester.pump();
      await tester.tap(find.text('GALLERY'));
      await tester.pump();

      // Every scan costs one of ten requests a minute, and two in flight would
      // race to push a form.
      expect(vision.requested, [ImageSource.camera]);

      vision.gate!.complete();
      await tester.pumpAndSettle();
    });
  });

  group('what happens with the result', () {
    testWidgets('opens the form prefilled with what the model read',
        (tester) async {
      final vision = FakeVisionController(
        result: analysis(
          'Grilled Chicken Salad',
          const Nutrients(calories: 450, proteinG: 42),
        ),
      );
      await pumpScreen(tester, vision: vision);

      await tester.tap(find.text('CAPTURE'));
      await tester.pumpAndSettle();

      expect(find.text('CONFIRM ENTRY'), findsOneWidget);
      expect(find.text('Grilled Chicken Salad'), findsOneWidget);
      expect(find.text('450'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
    });

    testWidgets('stays put in silence when the picker was dismissed',
        (tester) async {
      // result stays null: the user backed out rather than failing.
      final vision = FakeVisionController();
      await pumpScreen(tester, vision: vision);

      await tester.tap(find.text('CAPTURE'));
      await tester.pumpAndSettle();

      expect(find.text('CONFIRM ENTRY'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('CAPTURE'), findsOneWidget);
    });

    testWidgets('shows the failure in the words the client chose',
        (tester) async {
      final vision = FakeVisionController(
        failure: const FoodAnalysisException(FoodAnalysisClient.errorNoKey),
      );
      await pumpScreen(tester, vision: vision);

      await tester.tap(find.text('CAPTURE'));
      await tester.pumpAndSettle();

      expect(find.text(FoodAnalysisClient.errorNoKey), findsOneWidget);
      expect(find.text('CONFIRM ENTRY'), findsNothing);
    });

    testWidgets('opens the form on the servings the model counted',
        (tester) async {
      final vision = FakeVisionController(
        result: analysis(
          'Samosa',
          const Nutrients(calories: 262),
          quantity: 3,
        ),
      );
      await pumpScreen(tester, vision: vision);

      await tester.tap(find.text('CAPTURE'));
      await tester.pumpAndSettle();

      // The figures are per piece, so a plate of three opened at 1.0x would
      // log a third of what was eaten.
      expect(find.text('3.0x'), findsOneWidget);
      expect(find.text('262'), findsOneWidget);
      expect(find.text('786 KCAL'), findsOneWidget);
    });

    testWidgets('opens on a single serving when that is all there was',
        (tester) async {
      final vision = FakeVisionController(
        result: analysis('Rice Bowl', const Nutrients(calories: 520)),
      );
      await pumpScreen(tester, vision: vision);

      await tester.tap(find.text('CAPTURE'));
      await tester.pumpAndSettle();

      expect(find.text('1.0x'), findsOneWidget);
    });

    testWidgets('still opens the form when the app resumed mid-scan',
        (tester) async {
      final visible = ValueNotifier<bool>(true);
      addTearDown(visible.dispose);
      final vision = FakeVisionController(
        result: analysis('Rice Bowl', const Nutrients(calories: 520)),
      )..gate = Completer<void>();
      await pumpThroughResume(tester, vision: vision, visible: visible);

      await tester.tap(find.text('CAPTURE'));
      await tester.pump();

      // The picker backgrounds the app, so returning from it is an app resume —
      // and AuthGate re-checks the session on resume, swapping the whole shell
      // out for a spinner and back in. The screen that started this scan is
      // gone by the time the answer lands.
      visible.value = false;
      await tester.pump();
      visible.value = true;
      await tester.pump();

      vision.gate!.complete();
      await tester.pumpAndSettle();

      // The photograph was taken, uploaded and read, and one of the ten
      // requests a minute was spent on it. Dropping the result because the
      // widget that asked for it no longer exists is the failure this guards.
      expect(find.text('CONFIRM ENTRY'), findsOneWidget);
      expect(find.text('Rice Bowl'), findsOneWidget);
      expect(find.text('520'), findsOneWidget);
    });

    testWidgets('offers another go after a failure', (tester) async {
      final vision = FakeVisionController(
        failure: const FoodAnalysisException(FoodAnalysisClient.errorNoKey),
      );
      await pumpScreen(tester, vision: vision);
      await tester.tap(find.text('CAPTURE'));
      await tester.pumpAndSettle();

      vision.failure = null;
      vision.result = analysis('Toast', const Nutrients(calories: 200));
      await tester.tap(find.text('CAPTURE'));
      await tester.pumpAndSettle();

      expect(find.text('CONFIRM ENTRY'), findsOneWidget);
    });
  });

  group('recent logs', () {
    testWidgets('lists what is in the log rather than a fixed sample',
        (tester) async {
      await pumpScreen(tester, log: [
        entry('Rice Bowl', calories: 520),
      ]);

      expect(find.text('RICE BOWL'), findsOneWidget);
      expect(find.text('520 KCAL'), findsOneWidget);
      // The screen used to show these four regardless of what was logged.
      expect(find.text('GRILLED CHICKEN SALAD'), findsNothing);
      expect(find.text('PROTEIN SHAKE'), findsNothing);
    });

    testWidgets('labels an entry with its day and time', (tester) async {
      final now = DateTime.now();
      final yesterday = DateTime(now.year, now.month, now.day - 1, 19, 45);
      await pumpScreen(tester, log: [entry('Rice Bowl', loggedAt: yesterday)]);

      expect(find.text('YESTERDAY · 07:45 PM'), findsOneWidget);
    });

    testWidgets('shows the total for a multi-serving entry', (tester) async {
      final scaled = FoodEntry.create(
        name: 'Rice Bowl',
        nutrients: const Nutrients(calories: 500),
        quantity: 1.5,
        source: FoodSource.manual,
      );
      await pumpScreen(tester, log: [scaled]);

      // What was eaten, not what one serving holds.
      expect(find.text('750 KCAL'), findsOneWidget);
    });

    testWidgets('says the log is empty rather than showing nothing',
        (tester) async {
      await pumpScreen(tester);

      expect(find.text(AiVisionScreen.emptyLogLabel), findsOneWidget);
    });

    testWidgets('keeps the list short, since this is not the history screen',
        (tester) async {
      await pumpScreen(tester, log: [
        for (var i = 0; i < 10; i++) entry('Meal $i'),
      ]);

      // Counted by name rather than with a substring match, which would also
      // catch the panel's own copy.
      final shown = [
        for (var i = 0; i < 10; i++)
          if (find.text('MEAL $i').evaluate().isNotEmpty) i,
      ];
      expect(shown.length, AiVisionScreen.recentLogLimit);
    });
  });
}
