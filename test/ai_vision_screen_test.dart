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

  (String, Nutrients)? result;
  Object? failure;

  /// Every source the screen asked for, in order.
  final List<ImageSource> requested = [];

  /// Set to hold `capture` open so the loading state can be observed.
  Completer<void>? gate;

  @override
  Future<(String, Nutrients)?> build() async => null;

  @override
  Future<(String, Nutrients)?> capture(ImageSource source) async {
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
        result: ('Toast', const Nutrients(calories: 200)),
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
        result: ('Toast', const Nutrients(calories: 200)),
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
        result: (
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

    testWidgets('offers another go after a failure', (tester) async {
      final vision = FakeVisionController(
        failure: const FoodAnalysisException(FoodAnalysisClient.errorNoKey),
      );
      await pumpScreen(tester, vision: vision);
      await tester.tap(find.text('CAPTURE'));
      await tester.pumpAndSettle();

      vision.failure = null;
      vision.result = ('Toast', const Nutrients(calories: 200));
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
