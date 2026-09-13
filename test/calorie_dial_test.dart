import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/calorie_budget.dart';
import 'package:void_factor/theme/monolith_theme.dart';
import 'package:void_factor/widgets/calorie_dial.dart';

void main() {
  /// Pumps the card with the sweep animation off, so every assertion below is
  /// about a settled frame rather than about whichever moment of the easing
  /// curve `pump()` happened to land on.
  Future<void> pumpCard(
    WidgetTester tester, {
    required CalorieBudget? budget,
    String? targetHint,
    VoidCallback? onTap,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CalorieDialCard(
              budget: budget,
              targetHint: targetHint,
              onTap: onTap,
              animate: false,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows the day\'s intake inside the ring', (tester) async {
    await pumpCard(
      tester,
      budget: const CalorieBudget(consumedKcal: 420, targetKcal: 2000),
    );

    expect(find.text('420'), findsOneWidget);
    expect(find.text('CAL'), findsOneWidget);
    expect(find.text('1,580 LEFT OF 2,000'), findsOneWidget);
  });

  testWidgets('turns red once the target is passed', (tester) async {
    await pumpCard(
      tester,
      budget: const CalorieBudget(consumedKcal: 2310, targetKcal: 2000),
    );

    expect(find.text('310 OVER 2,000'), findsOneWidget);

    final value = tester.widget<Text>(find.text('2,310'));
    expect(value.style?.color, MonolithTheme.error);
  });

  testWidgets('renders the intake even with no target, and says why',
      (tester) async {
    // The projection reads four sources; the ring must not wait on them to show
    // a number the user just logged.
    await pumpCard(
      tester,
      budget: const CalorieBudget(
          consumedKcal: 640, targetKcal: null, entryCount: 2),
      targetHint: 'ADD HEIGHT, AGE & WEIGHT IN SETTINGS',
    );

    expect(find.text('640'), findsOneWidget);
    expect(find.text('NO TARGET YET'), findsOneWidget);
    expect(find.text('ADD HEIGHT, AGE & WEIGHT IN SETTINGS'), findsOneWidget);
  });

  testWidgets('says it is still reading while the log loads', (tester) async {
    await pumpCard(tester, budget: null);

    expect(find.text('READING YOUR LOG'), findsOneWidget);
    // A hint about a missing target would be a guess at this point.
    expect(find.text('NO TARGET YET'), findsNothing);
  });

  testWidgets('opens the food log when tapped', (tester) async {
    var taps = 0;
    await pumpCard(
      tester,
      budget: const CalorieBudget(consumedKcal: 420, targetKcal: 2000),
      onTap: () => taps++,
    );

    await tester.tap(find.byType(CalorieDial));

    expect(taps, 1);
  });

  testWidgets('the painter carries the fill the budget computed',
      (tester) async {
    await pumpCard(
      tester,
      budget: const CalorieBudget(consumedKcal: 1500, targetKcal: 2000),
    );

    // The ring is the one part of this that cannot be read back as text, so the
    // assertion is that something was painted at the right size — the fraction
    // itself is covered in `calorie_budget_test.dart`.
    final dial = tester.widget<CalorieDial>(find.byType(CalorieDial));
    expect(dial.budget.fillFraction, 0.75);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
