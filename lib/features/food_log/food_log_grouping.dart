import '../../models/food_entry.dart';

/// One calendar day's worth of entries, ready to render as a header plus rows.
class DayGroup {
  /// `'TODAY'`, `'YESTERDAY'` or `'2 DAYS AGO'`.
  final String label;

  /// Local midnight of the day this group covers.
  final DateTime date;

  /// The day's entries, newest first.
  final List<FoodEntry> entries;

  const DayGroup({
    required this.label,
    required this.date,
    required this.entries,
  });
}

/// How many calendar days the history screen shows.
const int foodLogWindowDays = 3;

/// Local midnight of the oldest day the history screen shows.
///
/// A calendar boundary, not a rolling 72 hours. With a rolling window, the day
/// labelled "2 DAYS AGO" would hold only part of that day — and which part would
/// change every minute as the window slid forward.
///
/// This is a display bound only. Nothing is deleted when an entry falls behind
/// it; `FoodLogStore` keeps the whole file.
DateTime foodLogWindowStart(DateTime now) {
  // Counted in calendar days via the constructor, which normalises an
  // out-of-range day. Subtracting a Duration would be wrong across a DST
  // change: midnight less 48 hours can land at 23:00 on the day before.
  return DateTime(now.year, now.month, now.day - (foodLogWindowDays - 1));
}

/// Buckets [entries] into the three display days, newest day first.
///
/// Days with no entries are omitted: a bare "YESTERDAY" header with nothing
/// under it reads as a rendering bug rather than as "you logged nothing".
List<DayGroup> groupByDay(List<FoodEntry> entries, {required DateTime now}) {
  final today = DateTime(now.year, now.month, now.day);
  final windowStart = foodLogWindowStart(now);

  final buckets = <DateTime, List<FoodEntry>>{};
  for (final entry in entries) {
    final loggedAt = entry.loggedAt;
    if (loggedAt.isBefore(windowStart)) continue;

    final day = DateTime(loggedAt.year, loggedAt.month, loggedAt.day);
    // An entry dated ahead of now is only reachable through a device clock that
    // ran ahead and was corrected. Filing it under today keeps a real meal
    // visible instead of hiding it behind a boundary the user never crossed.
    final bucketDay = day.isAfter(today) ? today : day;

    buckets.putIfAbsent(bucketDay, () => []).add(entry);
  }

  final days = buckets.keys.toList()..sort((a, b) => b.compareTo(a));

  return days.map((day) {
    // Sorted on a copy: the caller's list is the notifier's state, and sorting
    // in place would mutate state outside a state assignment.
    final dayEntries = List<FoodEntry>.from(buckets[day]!)
      ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    return DayGroup(
      label: _labelFor(day, today),
      date: day,
      entries: dayEntries,
    );
  }).toList();
}

String _labelFor(DateTime day, DateTime today) {
  final daysBack = today.difference(day).inDays;
  switch (daysBack) {
    case 0:
      return 'TODAY';
    case 1:
      return 'YESTERDAY';
    default:
      return '$daysBack DAYS AGO';
  }
}

/// The clock time an entry was logged, as `'08:15 AM'`.
///
/// Both food screens label a row with its day and time, so the formatting lives
/// next to the day labels rather than being written twice. Hand-rolled instead
/// of pulling in `intl`: this is one fixed format, not localisation, and the
/// 12-hour clock here matches the rest of the app's copy.
String foodLogTimeLabel(DateTime at) {
  // Hour 0 and hour 12 both read as 12 on a 12-hour clock — the modulo alone
  // would render midnight as "00:05 AM".
  final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final suffix = at.hour < 12 ? 'AM' : 'PM';
  return '${hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')} $suffix';
}

/// A calorie or macro figure as a row displays it: `750`, `7.5`, `33.3`.
///
/// A whole number loses its decimal point, and everything else keeps one place.
/// A serving multiplier makes thirds easy to reach, and the raw `33.333333333`
/// would push the rest of a row off screen.
String foodLogAmountLabel(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

