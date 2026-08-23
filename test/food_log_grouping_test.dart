import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/food_log/food_log_grouping.dart';
import 'package:void_factor/models/food_entry.dart';

void main() {
  FoodEntry at(DateTime when, {String name = 'Meal'}) {
    return FoodEntry.create(
      name: name,
      nutrients: const Nutrients(calories: 100),
      quantity: 1.0,
      source: FoodSource.manual,
      loggedAt: when,
    );
  }

  // A mid-afternoon "now" so the day boundary is unambiguous.
  final now = DateTime(2026, 8, 23, 14, 30);

  group('day labels', () {
    test('labels the three days in the window', () {
      final groups = groupByDay([
        at(DateTime(2026, 8, 23, 12, 0), name: 'Today Lunch'),
        at(DateTime(2026, 8, 22, 12, 0), name: 'Yesterday Lunch'),
        at(DateTime(2026, 8, 21, 12, 0), name: 'Two Days Ago Lunch'),
      ], now: now);

      expect(groups.map((g) => g.label), ['TODAY', 'YESTERDAY', '2 DAYS AGO']);
    });

    test('orders groups newest day first', () {
      final groups = groupByDay([
        at(DateTime(2026, 8, 21, 12, 0)),
        at(DateTime(2026, 8, 23, 12, 0)),
        at(DateTime(2026, 8, 22, 12, 0)),
      ], now: now);

      expect(groups.first.label, 'TODAY');
      expect(groups.last.label, '2 DAYS AGO');
    });

    test('exposes each group\'s calendar day at midnight', () {
      final groups = groupByDay([at(DateTime(2026, 8, 22, 19, 45))], now: now);

      expect(groups.single.date, DateTime(2026, 8, 22));
    });
  });

  group('day boundaries', () {
    test('an entry just after midnight belongs to that new day', () {
      final groups = groupByDay([
        at(DateTime(2026, 8, 23, 0, 1), name: 'Midnight Snack'),
      ], now: now);

      expect(groups.single.label, 'TODAY');
    });

    test('an entry just before midnight belongs to the previous day', () {
      final groups = groupByDay([
        at(DateTime(2026, 8, 22, 23, 59), name: 'Late Snack'),
      ], now: now);

      expect(groups.single.label, 'YESTERDAY');
    });

    test('the window starts at midnight, not 72 rolling hours ago', () {
      // 08-20 23:00 is 63.5 hours before now, so a rolling 72h window would
      // include it. The window is three calendar days, so it must not appear:
      // otherwise a day labelled "2 DAYS AGO" would hold part of a fourth day.
      final groups = groupByDay([
        at(DateTime(2026, 8, 20, 23, 0), name: 'Too Old'),
        at(DateTime(2026, 8, 21, 0, 30), name: 'Just Inside'),
      ], now: now);

      expect(groups.single.label, '2 DAYS AGO');
      expect(groups.single.entries.map((e) => e.name), ['Just Inside']);
    });

    test('the window holds three days regardless of the time of day', () {
      // Just after midnight: the window is still 08-21..08-23, not a 72h span
      // reaching back into 08-20.
      final justAfterMidnight = DateTime(2026, 8, 23, 0, 5);

      final groups = groupByDay([
        at(DateTime(2026, 8, 20, 23, 0), name: 'Too Old'),
        at(DateTime(2026, 8, 21, 8, 0), name: 'Oldest Shown'),
      ], now: justAfterMidnight);

      expect(groups.single.label, '2 DAYS AGO');
      expect(groups.single.entries.map((e) => e.name), ['Oldest Shown']);
    });
  });

  group('entry ordering within a day', () {
    test('sorts newest first', () {
      final groups = groupByDay([
        at(DateTime(2026, 8, 23, 7, 15), name: 'Breakfast'),
        at(DateTime(2026, 8, 23, 19, 30), name: 'Dinner'),
        at(DateTime(2026, 8, 23, 12, 30), name: 'Lunch'),
      ], now: now);

      expect(
        groups.single.entries.map((e) => e.name),
        ['Dinner', 'Lunch', 'Breakfast'],
      );
    });
  });

  group('exclusions', () {
    test('omits a day with no entries rather than showing an empty header', () {
      // A bare "YESTERDAY" header with nothing under it reads as a rendering
      // bug, not as "you logged nothing".
      final groups = groupByDay([
        at(DateTime(2026, 8, 23, 12, 0)),
        at(DateTime(2026, 8, 21, 12, 0)),
      ], now: now);

      expect(groups.map((g) => g.label), ['TODAY', '2 DAYS AGO']);
    });

    test('returns no groups for an empty log', () {
      expect(groupByDay(const [], now: now), isEmpty);
    });

    test('returns no groups when everything is older than the window', () {
      final groups = groupByDay([
        at(DateTime(2026, 7, 1, 12, 0)),
        at(DateTime(2026, 8, 19, 12, 0)),
      ], now: now);

      expect(groups, isEmpty);
    });

    test('does not modify the list it was given', () {
      final entries = [
        at(DateTime(2026, 8, 23, 7, 0), name: 'First'),
        at(DateTime(2026, 8, 23, 19, 0), name: 'Second'),
      ];

      groupByDay(entries, now: now);

      // The caller's list is the notifier's state; sorting it in place would
      // mutate state outside a state assignment.
      expect(entries.map((e) => e.name), ['First', 'Second']);
    });
  });

  group('entries dated ahead of now', () {
    test('shows a future-dated entry under TODAY rather than hiding it', () {
      // Only reachable via a device clock that ran ahead and was corrected.
      // Dropping the entry would silently lose a real meal; TODAY keeps it
      // visible and, being the newest, at the top.
      final groups = groupByDay([
        at(DateTime(2026, 8, 24, 9, 0), name: 'Clock Skew'),
        at(DateTime(2026, 8, 23, 12, 0), name: 'Real Lunch'),
      ], now: now);

      expect(groups.single.label, 'TODAY');
      expect(
        groups.single.entries.map((e) => e.name),
        ['Clock Skew', 'Real Lunch'],
      );
    });
  });

  group('windowStart', () {
    test('is midnight two days before the given day', () {
      expect(foodLogWindowStart(now), DateTime(2026, 8, 21));
    });

    test('crosses a month boundary correctly', () {
      expect(
        foodLogWindowStart(DateTime(2026, 9, 1, 10, 0)),
        DateTime(2026, 8, 30),
      );
    });
  });

  group('timeLabel', () {
    test('reads a morning time on a 12-hour clock', () {
      expect(foodLogTimeLabel(DateTime(2026, 8, 23, 8, 15)), '08:15 AM');
    });

    test('reads an afternoon time on a 12-hour clock', () {
      expect(foodLogTimeLabel(DateTime(2026, 8, 23, 19, 45)), '07:45 PM');
    });

    test('calls midnight 12 AM rather than 0 AM', () {
      expect(foodLogTimeLabel(DateTime(2026, 8, 23, 0, 5)), '12:05 AM');
    });

    test('calls noon 12 PM rather than 0 PM', () {
      expect(foodLogTimeLabel(DateTime(2026, 8, 23, 12, 30)), '12:30 PM');
    });

    test('pads a single-digit minute', () {
      expect(foodLogTimeLabel(DateTime(2026, 8, 23, 9, 5)), '09:05 AM');
    });
  });

  group('amountLabel', () {
    test('drops a pointless decimal', () {
      expect(foodLogAmountLabel(750), '750');
    });

    test('keeps a real fraction', () {
      expect(foodLogAmountLabel(7.5), '7.5');
    });

    test('rounds to one place rather than spilling digits', () {
      // A serving multiplier makes thirds easy to reach, and '33.333333' in a
      // row would push the rest of the line off screen.
      expect(foodLogAmountLabel(100 / 3), '33.3');
    });

    test('writes zero as a digit, not an empty string', () {
      expect(foodLogAmountLabel(0), '0');
    });
  });
}
