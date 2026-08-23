import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/food_log_providers.dart';
import 'package:void_factor/features/food_log/food_log_store.dart';
import 'package:void_factor/models/food_entry.dart';
import 'package:void_factor/screens/food_log/food_entry_form_screen.dart';
import 'package:void_factor/widgets/monolith_text_field.dart';

/// In-memory stand-in for the real store.
///
/// A widget test runs inside `fake_async`, which never completes a `dart:io`
/// future, so touching a real file here hangs the test rather than failing it.
/// The real store's own suite covers the file behaviour with real IO; this fake
/// exists so these tests are about the form.
class FakeFoodLogStore extends FoodLogStore {
  FakeFoodLogStore() : super(dir: Directory.systemTemp, uid: 'uid-1');

  final List<FoodEntry> saved = [];
  bool failWrites = false;

  @override
  Future<List<FoodEntry>> readAll() async => List.of(saved);

  @override
  Future<void> writeAll(List<FoodEntry> entries) async {
    if (failWrites) {
      throw const FileSystemException('no space left on device');
    }
    saved
      ..clear()
      ..addAll(entries);
  }
}

void main() {
  const saveLabel = 'SAVE ENTRY';
  late FakeFoodLogStore store;

  setUp(() => store = FakeFoodLogStore());

  /// Pushes the form onto a host route, the way both real callers do. Pushing
  /// rather than mounting it as `home` is what makes a pop after save real.
  Future<void> pumpForm(
    WidgetTester tester, {
    String initialName = '',
    Nutrients initialNutrients = const Nutrients(),
    FoodSource source = FoodSource.manual,
  }) async {
    // The default 800x600 test surface is shorter than the form, which puts SAVE
    // off-screen. Scrolling it into range does not work while a field has focus:
    // the caret scrolls itself back into view every frame. A surface tall enough
    // to hold the form removes the fight entirely.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        foodLogStoreProvider.overrideWith((ref) async => store),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FoodEntryFormScreen(
                    initialName: initialName,
                    initialNutrients: initialNutrients,
                    source: source,
                  ),
                ),
              ),
              child: const Text('HOST'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('HOST'));
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.text(saveLabel));
    await tester.pumpAndSettle();
  }

  /// The label sits above the field rather than inside it, so reach the editable
  /// widget through the shared `MonolithTextField` ancestor.
  Finder fieldFor(String label) => find.descendant(
        of: find.ancestor(
          of: find.text(label),
          matching: find.byType(MonolithTextField),
        ),
        matching: find.byType(TextFormField),
      );

  group('prefilling from a vision result', () {
    testWidgets('fills every field with what the model read', (tester) async {
      await pumpForm(
        tester,
        initialName: 'Grilled Chicken Salad',
        initialNutrients: const Nutrients(
          calories: 450,
          proteinG: 42,
          carbsG: 30,
          fatsG: 12,
        ),
        source: FoodSource.vision,
      );

      expect(find.text('Grilled Chicken Salad'), findsOneWidget);
      expect(find.text('450'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('leaves fields blank for a manual entry rather than showing 0',
        (tester) async {
      await pumpForm(tester);

      // A prefilled "0" has to be cleared before typing; an empty field does
      // not.
      expect(find.text('0'), findsNothing);
    });

    testWidgets('drops the trailing decimal on a whole number', (tester) async {
      await pumpForm(
        tester,
        initialName: 'Toast',
        initialNutrients: const Nutrients(calories: 200, proteinG: 7.5),
      );

      expect(find.text('200'), findsOneWidget);
      expect(find.text('7.5'), findsOneWidget);
    });

    testWidgets('offers all five fields, every one editable', (tester) async {
      await pumpForm(tester);

      for (final label in ['NAME', 'KCAL', 'PROTEIN', 'CARBS', 'FATS']) {
        expect(fieldFor(label), findsOneWidget, reason: '$label is missing');
      }
    });
  });

  group('live total', () {
    testWidgets('starts at one serving', (tester) async {
      await pumpForm(
        tester,
        initialName: 'Rice Bowl',
        initialNutrients: const Nutrients(calories: 500),
      );

      expect(find.text('1.0x'), findsOneWidget);
      expect(find.text('500 KCAL'), findsOneWidget);
    });

    testWidgets('scales with the quantity stepper', (tester) async {
      await pumpForm(
        tester,
        initialName: 'Rice Bowl',
        initialNutrients: const Nutrients(calories: 500),
      );

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();

      expect(find.text('750 KCAL'), findsOneWidget);
    });

    testWidgets('follows an edit to the per-serving calories', (tester) async {
      await pumpForm(
        tester,
        initialName: 'Rice Bowl',
        initialNutrients: const Nutrients(calories: 500),
      );

      await tester.enterText(fieldFor('KCAL'), '300');
      await tester.pump();

      // The total is the thing the user is actually deciding about, so it must
      // track the field rather than the value the model first proposed.
      expect(find.text('300 KCAL'), findsOneWidget);
    });

    testWidgets('shows the scaled macros alongside the calories',
        (tester) async {
      await pumpForm(
        tester,
        initialName: 'Chicken',
        initialNutrients: const Nutrients(
          calories: 200,
          proteinG: 30,
          carbsG: 10,
          fatsG: 5,
        ),
      );

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();

      expect(find.text('300 KCAL'), findsOneWidget);
      expect(find.textContaining('45G PROTEIN'), findsOneWidget);
    });

    testWidgets('treats an emptied calorie field as zero without crashing',
        (tester) async {
      await pumpForm(
        tester,
        initialName: 'Rice Bowl',
        initialNutrients: const Nutrients(calories: 500),
      );

      await tester.enterText(fieldFor('KCAL'), '');
      await tester.pump();

      expect(find.text('0 KCAL'), findsOneWidget);
    });
  });

  group('validation', () {
    testWidgets('refuses to save without a name', (tester) async {
      await pumpForm(
        tester,
        initialNutrients: const Nutrients(calories: 400),
      );

      await tapSave(tester);

      expect(store.saved, isEmpty);
      // Asserting the complaint, not just the absence of a write: a save that
      // never got attempted would satisfy `isEmpty` on its own.
      expect(find.text('REQUIRED'), findsOneWidget);
      expect(find.text(saveLabel), findsOneWidget);
    });

    testWidgets('refuses to save with zero calories', (tester) async {
      await pumpForm(tester, initialName: 'Mystery Meal');

      await tapSave(tester);

      expect(store.saved, isEmpty);
      expect(find.text('REQUIRED'), findsOneWidget);
      expect(find.text(saveLabel), findsOneWidget);
    });

    testWidgets('accepts zero macros — only calories are required',
        (tester) async {
      await pumpForm(
        tester,
        initialName: 'Black Coffee',
        initialNutrients: const Nutrients(calories: 5),
      );

      await tapSave(tester);

      expect(store.saved.single.name, 'Black Coffee');
      expect(store.saved.single.nutrients.proteinG, 0);
    });

    testWidgets('rejects a name that is only whitespace', (tester) async {
      await pumpForm(
        tester,
        initialNutrients: const Nutrients(calories: 400),
      );
      await tester.enterText(fieldFor('NAME'), '   ');

      await tapSave(tester);

      expect(store.saved, isEmpty);
      expect(find.text('REQUIRED'), findsOneWidget);
    });
  });

  group('saving', () {
    testWidgets('writes the per-serving nutrients and the quantity separately',
        (tester) async {
      await pumpForm(
        tester,
        initialName: 'Rice Bowl',
        initialNutrients: const Nutrients(calories: 500, proteinG: 20),
      );

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tapSave(tester);

      final saved = store.saved.single;
      // The AI's per-serving reading is preserved verbatim; the multiplier lives
      // beside it so the user can revisit either.
      expect(saved.nutrients.calories, 500);
      expect(saved.quantity, 1.5);
      expect(saved.totalCalories, 750);
    });

    testWidgets('records the source it was opened with', (tester) async {
      await pumpForm(
        tester,
        initialName: 'Scanned Plate',
        initialNutrients: const Nutrients(calories: 300),
        source: FoodSource.vision,
      );

      await tapSave(tester);

      expect(store.saved.single.source, FoodSource.vision);
    });

    testWidgets('records a manual entry as manual', (tester) async {
      await pumpForm(tester, initialName: 'Typed Meal');
      await tester.enterText(fieldFor('KCAL'), '250');

      await tapSave(tester);

      expect(store.saved.single.source, FoodSource.manual);
    });

    testWidgets('trims the name before saving', (tester) async {
      await pumpForm(
        tester,
        initialNutrients: const Nutrients(calories: 300),
      );
      await tester.enterText(fieldFor('NAME'), '  Oatmeal  ');

      await tapSave(tester);

      expect(store.saved.single.name, 'Oatmeal');
    });

    testWidgets('accepts an edited value over the one the model proposed',
        (tester) async {
      await pumpForm(
        tester,
        initialName: 'Grilled Chicken',
        initialNutrients: const Nutrients(calories: 450, proteinG: 42),
        source: FoodSource.vision,
      );

      await tester.enterText(fieldFor('KCAL'), '380');
      await tester.enterText(fieldFor('NAME'), 'Grilled Chicken Thigh');

      await tapSave(tester);

      final saved = store.saved.single;
      expect(saved.name, 'Grilled Chicken Thigh');
      expect(saved.nutrients.calories, 380);
      // Untouched fields keep the model's reading.
      expect(saved.nutrients.proteinG, 42);
    });

    testWidgets('leaves the screen once the entry is persisted',
        (tester) async {
      await pumpForm(
        tester,
        initialName: 'Toast',
        initialNutrients: const Nutrients(calories: 100),
      );

      await tapSave(tester);

      // Popping is how the caller learns the save landed.
      expect(find.text(saveLabel), findsNothing);
      expect(store.saved.single.name, 'Toast');
    });
  });

  group('a failed save', () {
    testWidgets('keeps the user on the form with their input intact',
        (tester) async {
      await pumpForm(
        tester,
        initialName: 'Toast',
        initialNutrients: const Nutrients(calories: 100),
      );
      store.failWrites = true;

      await tapSave(tester);

      // Navigating away would report a save that did not happen.
      expect(find.text(saveLabel), findsOneWidget);
      expect(find.text('Toast'), findsOneWidget);
    });

    testWidgets('says why, in the words the design specifies', (tester) async {
      await pumpForm(
        tester,
        initialName: 'Toast',
        initialNutrients: const Nutrients(calories: 100),
      );
      store.failWrites = true;

      await tapSave(tester);

      expect(find.text(RecentFoodLog.errorSaveFailed), findsOneWidget);
    });

    testWidgets('can be retried once the cause clears', (tester) async {
      await pumpForm(
        tester,
        initialName: 'Toast',
        initialNutrients: const Nutrients(calories: 100),
      );
      store.failWrites = true;
      await tapSave(tester);

      // A one-off write failure must not leave the button dead.
      store.failWrites = false;
      await tapSave(tester);

      expect(store.saved.single.name, 'Toast');
      expect(find.text(saveLabel), findsNothing);
    });
  });

  group('chrome', () {
    testWidgets('titles itself by how the entry was captured', (tester) async {
      await pumpForm(tester, source: FoodSource.vision);

      expect(find.text('CONFIRM ENTRY'), findsOneWidget);
    });

    testWidgets('titles a manual entry differently', (tester) async {
      await pumpForm(tester);

      expect(find.text('ADD ENTRY'), findsOneWidget);
    });
  });
}
