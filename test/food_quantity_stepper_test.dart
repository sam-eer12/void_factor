import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/models/food_entry.dart';
import 'package:void_factor/widgets/food_quantity_stepper.dart';

void main() {
  /// Pumps the stepper with parent-held state, the way the form uses it.
  Future<double> pumpStepper(
    WidgetTester tester, {
    required double initial,
  }) async {
    var current = initial;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => FoodQuantityStepper(
            quantity: current,
            onChanged: (value) => setState(() => current = value),
          ),
        ),
      ),
    ));
    return current;
  }

  Finder plus() => find.byIcon(Icons.add);
  Finder minus() => find.byIcon(Icons.remove);

  group('display', () {
    testWidgets('shows the quantity with one decimal and an x suffix',
        (tester) async {
      await pumpStepper(tester, initial: 1.0);

      expect(find.text('1.0x'), findsOneWidget);
    });

    testWidgets('shows a half serving as 0.5x', (tester) async {
      await pumpStepper(tester, initial: 0.5);

      expect(find.text('0.5x'), findsOneWidget);
    });

    testWidgets('shows a whole number of servings with its decimal',
        (tester) async {
      await pumpStepper(tester, initial: 3.0);

      expect(find.text('3.0x'), findsOneWidget);
    });
  });

  group('stepping', () {
    testWidgets('plus adds half a serving', (tester) async {
      await pumpStepper(tester, initial: 1.0);

      await tester.tap(plus());
      await tester.pump();

      expect(find.text('1.5x'), findsOneWidget);
    });

    testWidgets('minus removes half a serving', (tester) async {
      await pumpStepper(tester, initial: 2.0);

      await tester.tap(minus());
      await tester.pump();

      expect(find.text('1.5x'), findsOneWidget);
    });

    testWidgets('steps repeatedly without drifting', (tester) async {
      await pumpStepper(tester, initial: 1.0);

      for (var i = 0; i < 4; i++) {
        await tester.tap(plus());
        await tester.pump();
      }

      // Half-serving steps are exact in binary, so 1.0 + 4 * 0.5 must read
      // exactly 3.0 rather than 2.9999999999999996.
      expect(find.text('3.0x'), findsOneWidget);
    });

    testWidgets('reports each new value to its parent', (tester) async {
      final reported = <double>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FoodQuantityStepper(
            quantity: 1.0,
            onChanged: reported.add,
          ),
        ),
      ));

      await tester.tap(plus());
      await tester.pump();

      // The parent owns the value: the form needs it to recompute the live
      // total, so the stepper reports rather than stores.
      expect(reported, [1.5]);
    });

    testWidgets('does not change its own display without a parent rebuild',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FoodQuantityStepper(quantity: 1.0, onChanged: (_) {}),
        ),
      ));

      await tester.tap(plus());
      await tester.pump();

      expect(find.text('1.0x'), findsOneWidget);
    });
  });

  group('bounds', () {
    testWidgets('will not go below the minimum serving', (tester) async {
      await pumpStepper(tester, initial: FoodEntry.minQuantity);

      await tester.tap(minus());
      await tester.pump();

      expect(find.text('0.5x'), findsOneWidget);
    });

    testWidgets('reports nothing when already at the minimum', (tester) async {
      final reported = <double>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FoodQuantityStepper(
            quantity: FoodEntry.minQuantity,
            onChanged: reported.add,
          ),
        ),
      ));

      await tester.tap(minus());
      await tester.pump();

      expect(reported, isEmpty);
    });

    testWidgets('will not go above the maximum serving', (tester) async {
      await pumpStepper(tester, initial: FoodEntry.maxQuantity);

      await tester.tap(plus());
      await tester.pump();

      expect(find.text('20.0x'), findsOneWidget);
    });

    testWidgets('reports nothing when already at the maximum', (tester) async {
      final reported = <double>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FoodQuantityStepper(
            quantity: FoodEntry.maxQuantity,
            onChanged: reported.add,
          ),
        ),
      ));

      await tester.tap(plus());
      await tester.pump();

      expect(reported, isEmpty);
    });

    testWidgets('clamps an out-of-range quantity it was handed', (tester) async {
      await pumpStepper(tester, initial: 99.0);

      expect(find.text('20.0x'), findsOneWidget);
    });
  });

  group('disabled state', () {
    testWidgets('greys out minus at the minimum but leaves plus live',
        (tester) async {
      await pumpStepper(tester, initial: FoodEntry.minQuantity);

      // A control that cannot do anything should not look like it can.
      expect(
        tester.widget<Icon>(minus()).color,
        FoodQuantityStepper.disabledColor,
      );
      expect(
        tester.widget<Icon>(plus()).color,
        isNot(FoodQuantityStepper.disabledColor),
      );
    });

    testWidgets('greys out plus at the maximum but leaves minus live',
        (tester) async {
      await pumpStepper(tester, initial: FoodEntry.maxQuantity);

      expect(
        tester.widget<Icon>(plus()).color,
        FoodQuantityStepper.disabledColor,
      );
      expect(
        tester.widget<Icon>(minus()).color,
        isNot(FoodQuantityStepper.disabledColor),
      );
    });

    testWidgets('leaves both live in the middle of the range', (tester) async {
      await pumpStepper(tester, initial: 2.0);

      expect(
        tester.widget<Icon>(plus()).color,
        isNot(FoodQuantityStepper.disabledColor),
      );
      expect(
        tester.widget<Icon>(minus()).color,
        isNot(FoodQuantityStepper.disabledColor),
      );
    });
  });
}
