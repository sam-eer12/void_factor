import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/food_log_grouping.dart';
import 'package:void_factor/models/food_entry.dart';

FoodEntry entry({
  required DateTime at,
  double calories = 100,
  double protein = 10,
  double carbs = 20,
  double fats = 5,
  double quantity = 1,
}) =>
    FoodEntry.create(
      name: 'Meal',
      nutrients: Nutrients(
        calories: calories,
        proteinG: protein,
        carbsG: carbs,
        fatsG: fats,
      ),
      quantity: quantity,
      source: FoodSource.manual,
      loggedAt: at,
    );

void main() {
  final today = DateTime(2026, 9, 11, 14, 30);

  test('sums every entry logged on the day', () {
    final totals = totalsForDay([
      entry(at: DateTime(2026, 9, 11, 8)),
      entry(at: DateTime(2026, 9, 11, 13)),
    ], day: today);

    expect(totals.calories, 200);
    expect(totals.proteinG, 20);
    expect(totals.entryCount, 2);
  });

  test('scales by the serving multiplier rather than counting servings once',
      () {
    // The stored nutrients are per serving; two servings is what was eaten.
    final totals =
        totalsForDay([entry(at: today, calories: 250, quantity: 2)], day: today);

    expect(totals.calories, 500);
  });

  test('ignores yesterday', () {
    final totals = totalsForDay([
      entry(at: DateTime(2026, 9, 10, 23, 59)),
      entry(at: today),
    ], day: today);

    expect(totals.entryCount, 1);
  });

  test('ignores tomorrow', () {
    final totals = totalsForDay([
      entry(at: DateTime(2026, 9, 12, 0, 1)),
      entry(at: today),
    ], day: today);

    expect(totals.entryCount, 1);
  });

  test('counts a meal logged at one minute past midnight', () {
    // The calendar-day boundary is the only place this can be wrong, so it is
    // the only place worth asserting on both sides of.
    final totals =
        totalsForDay([entry(at: DateTime(2026, 9, 11, 0, 1))], day: today);
    expect(totals.entryCount, 1);
  });

  test('counts a meal logged at one minute to midnight', () {
    final totals =
        totalsForDay([entry(at: DateTime(2026, 9, 11, 23, 59))], day: today);
    expect(totals.entryCount, 1);
  });

  test('an empty log is empty, not zero', () {
    // A day with nothing logged and a day of zero-calorie drinks produce the
    // same numbers; only one of them means "you are on target".
    expect(totalsForDay(const [], day: today).isEmpty, isTrue);
    expect(
      totalsForDay([entry(at: today, calories: 0, protein: 0)], day: today)
          .isEmpty,
      isFalse,
    );
  });
}
