import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/food_log_providers.dart';
import 'package:void_factor/models/food_entry.dart';
import 'package:void_factor/screens/food_log/manual_food_log_screen.dart';
import 'package:void_factor/widgets/monolith_card.dart';

/// Stands in for the log itself.
///
/// The real notifier reads and rewrites a JSON file, which a widget test cannot
/// drive — `testWidgets` runs inside `fake_async`, where a `dart:io` future never
/// completes. `test/food_log_providers_test.dart` covers that half with real IO;
/// these tests are about what the screen renders for each outcome.
class FakeRecentFoodLog extends RecentFoodLog {
  FakeRecentFoodLog(this.entries, {this.failure});

  final List<FoodEntry> entries;
  final Object? failure;

  @override
  Future<List<FoodEntry>> build() async {
    final error = failure;
    if (error != null) throw error;
    return entries;
  }
}

void main() {
  final now = DateTime.now();

  FoodEntry entry(
    String name, {
    double calories = 100,
    double proteinG = 0,
    double quantity = 1.0,
    FoodSource source = FoodSource.manual,
    DateTime? loggedAt,
  }) {
    return FoodEntry.create(
      name: name,
      nutrients: Nutrients(calories: calories, proteinG: proteinG),
      quantity: quantity,
      source: source,
      loggedAt: loggedAt ?? now,
    );
  }

  /// Local time on a day inside the window, so the day label is unambiguous.
  DateTime daysAgo(int days, int hour, int minute) =>
      DateTime(now.year, now.month, now.day - days, hour, minute);

  Finder rowIcon(IconData icon) =>
      find.descendant(of: find.byType(MonolithCard), matching: find.byIcon(icon));

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<FoodEntry> log = const [],
    Object? failure,
  }) async {
    // The default 800x600 surface cuts the list off, and an off-screen row is
    // not found by `find.text`. A tall surface holds the whole history.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        recentFoodLogProvider
            .overrideWith(() => FakeRecentFoodLog(log, failure: failure)),
      ],
      child: const MaterialApp(home: ManualFoodLogScreen()),
    ));
    await tester.pumpAndSettle();
  }

  group('adding an entry', () {
    testWidgets('the add button opens a blank form', (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      // 'ADD ENTRY' rather than 'CONFIRM ENTRY': the form was told this is a
      // manual entry, with nothing for the user to confirm.
      expect(find.text('ADD ENTRY'), findsOneWidget);
      expect(find.text('WHAT DID YOU EAT?'), findsOneWidget);
    });
  });

  group('history', () {
    testWidgets('lists what is in the log rather than a fixed sample',
        (tester) async {
      await pumpScreen(tester, log: [entry('Rice Bowl', calories: 520)]);

      expect(find.text('RICE BOWL'), findsOneWidget);
      expect(find.text('520 KCAL'), findsOneWidget);
      // The screen used to show these to everyone, logged or not.
      expect(find.text('GRILLED CHICKEN BREAST'), findsNothing);
      expect(find.text('SALMON & BROWN RICE'), findsNothing);
    });

    testWidgets('files each entry under its own day', (tester) async {
      await pumpScreen(tester, log: [
        entry('Lunch Today', loggedAt: daysAgo(0, 12, 45)),
        entry('Dinner Yesterday', loggedAt: daysAgo(1, 19, 30)),
        entry('Breakfast Before', loggedAt: daysAgo(2, 8, 0)),
      ]);

      expect(find.text('TODAY'), findsOneWidget);
      expect(find.text('YESTERDAY'), findsOneWidget);
      expect(find.text('2 DAYS AGO'), findsOneWidget);
    });

    testWidgets('leaves out a day that holds nothing', (tester) async {
      await pumpScreen(tester, log: [
        entry('Lunch Today', loggedAt: daysAgo(0, 12, 45)),
        entry('Breakfast Before', loggedAt: daysAgo(2, 8, 0)),
      ]);

      // A bare header with no rows under it reads as a rendering bug.
      expect(find.text('YESTERDAY'), findsNothing);
    });

    testWidgets('orders the days newest first', (tester) async {
      await pumpScreen(tester, log: [
        entry('Breakfast Before', loggedAt: daysAgo(2, 8, 0)),
        entry('Lunch Today', loggedAt: daysAgo(0, 12, 45)),
      ]);

      final today = tester.getTopLeft(find.text('TODAY')).dy;
      final older = tester.getTopLeft(find.text('2 DAYS AGO')).dy;
      expect(today, lessThan(older));
    });

    testWidgets('labels a row with its time and protein', (tester) async {
      await pumpScreen(tester, log: [
        entry('Rice Bowl', proteinG: 42, loggedAt: daysAgo(0, 12, 45)),
      ]);

      expect(find.text('42G PROTEIN · 12:45 PM'), findsOneWidget);
    });

    testWidgets('reports the totals for a multi-serving entry',
        (tester) async {
      await pumpScreen(tester, log: [
        entry(
          'Rice Bowl',
          calories: 500,
          proteinG: 20,
          quantity: 1.5,
          loggedAt: daysAgo(0, 12, 45),
        ),
      ]);

      // What was eaten, not what one serving holds.
      expect(find.text('750 KCAL'), findsOneWidget);
      expect(find.text('30G PROTEIN · 12:45 PM'), findsOneWidget);
    });

    testWidgets('marks how an entry was logged', (tester) async {
      await pumpScreen(tester, log: [
        entry('Scanned Plate', source: FoodSource.vision),
        entry('Typed Plate', source: FoodSource.manual),
      ]);

      // Scoped to the rows: the bottom nav also carries a scan icon, and it
      // renders each item twice for its selection animation.
      expect(rowIcon(Icons.center_focus_strong), findsOneWidget);
      expect(rowIcon(Icons.restaurant), findsOneWidget);
    });

    testWidgets('shows the whole day, not a handful of rows', (tester) async {
      // The vision tab caps its list; this is the screen that shows everything.
      await pumpScreen(tester, log: [
        for (var i = 0; i < 7; i++)
          entry('Meal $i', loggedAt: daysAgo(0, 8 + i, 0)),
      ]);

      for (var i = 0; i < 7; i++) {
        expect(find.text('MEAL $i'), findsOneWidget);
      }
    });

    testWidgets('says the log is empty rather than showing nothing',
        (tester) async {
      await pumpScreen(tester);

      expect(find.text(ManualFoodLogScreen.emptyLogLabel), findsOneWidget);
    });

    testWidgets('says the log is empty when everything is older than the window',
        (tester) async {
      await pumpScreen(tester, log: [entry('Old Meal', loggedAt: daysAgo(9, 12, 0))]);

      expect(find.text('OLD MEAL'), findsNothing);
      expect(find.text(ManualFoodLogScreen.emptyLogLabel), findsOneWidget);
    });

    testWidgets('says so when the log could not be read', (tester) async {
      await pumpScreen(tester, failure: Exception('disk gone'));

      expect(find.text(ManualFoodLogScreen.logUnavailableLabel), findsOneWidget);
      // The reason belongs in the log, not on screen: it names nothing the user
      // can act on.
      expect(find.textContaining('disk gone'), findsNothing);
    });

    testWidgets('describes the window in the days it actually covers',
        (tester) async {
      await pumpScreen(tester);

      // Three calendar days, not a rolling 72 hours — the old subtitle said the
      // opposite of what `groupByDay` does.
      expect(find.text('LAST 3 DAYS'), findsOneWidget);
      expect(find.text('LAST 72H'), findsNothing);
    });
  });
}
