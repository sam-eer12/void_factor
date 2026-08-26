/// Display strings for the projection.
///
/// Separated from the widgets for the reason `food_log_grouping.dart` separates
/// its own labels: these are assertions a test wants to make without pumping a
/// widget, and the screen, the chart, and the goal card must all spell a figure
/// the same way. Two places formatting kilograms is how one of them ends up
/// showing `78.0` beside the other's `78`.
///
/// Hand-rolled rather than `intl`: these are a handful of fixed formats in the
/// app's own uppercase voice, not localisation, and the food log already made
/// that call.
library;

import '../../models/projection.dart';

const List<String> _monthAbbreviations = [
  'JAN',
  'FEB',
  'MAR',
  'APR',
  'MAY',
  'JUN',
  'JUL',
  'AUG',
  'SEP',
  'OCT',
  'NOV',
  'DEC',
];

/// `12 AUG` — a chart axis tick.
///
/// No year: both ends of the axis are inside a four-month span, so the year
/// would be the same word twice and the axis is the one place with no room for
/// it.
String projectionDayLabel(DateTime day) =>
    '${day.day} ${_monthAbbreviations[day.month - 1]}';

/// `12 AUG 2026` — a date the user might write down.
///
/// The year is carried here because a goal date can cross a new year, and
/// "reaches target on 4 JAN" is ambiguous in a way an axis tick is not.
String projectionDateLabel(DateTime day) =>
    '${projectionDayLabel(day)} ${day.year}';

/// `82.4`, `78` — a weight, with the decimal point dropped when it says nothing.
///
/// Same rule as `foodLogAmountLabel`, so a kilogram reads the same way
/// throughout the app, with one difference: the test for a whole number is made
/// against the *rounded* value, not the raw one. The chart's axis labels are
/// computed from a fitted range rather than typed by anyone, so `79.999` is a
/// value that really occurs, and testing the raw double would print it as `80.0`
/// beside a `78` on the rule above it. Round first, then decide — the same order
/// [projectionRateLabel] keeps its sign honest with.
String projectionKgLabel(double kg) {
  final rounded = double.parse(kg.toStringAsFixed(1));
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

/// `-0.6`, `+0.4`, `0.0` — a signed weekly rate.
///
/// Always one decimal, unlike [projectionKgLabel]: a rate of `0.5 kg/week` and
/// one of `0 kg/week` are the difference between progress and a stall, and
/// dropping the decimal would render `0.0` and `0` identically at a glance.
///
/// The sign is always shown, because the direction is the whole point — an
/// unsigned `0.6` beside a "losing weight" goal leaves the reader to guess.
String projectionRateLabel(double kgPerWeek) {
  final rounded = double.parse(kgPerWeek.toStringAsFixed(1));
  // `-0.04` formats as `-0.0`, which reads as a loss that is not happening.
  // Rounding first, then testing for zero, keeps the sign honest.
  if (rounded == 0) return '0.0';
  final magnitude = rounded.abs().toStringAsFixed(1);
  return rounded > 0 ? '+$magnitude' : '-$magnitude';
}

/// The status chip's text. Short by necessity — it sits beside a headline.
///
/// The detail each of these leaves out is carried by the goal card underneath,
/// which has the room for a sentence.
String projectionStatusLabel(ProjectionStatus status) {
  switch (status) {
    case ProjectionStatus.goalReached:
      return 'GOAL REACHED';
    case ProjectionStatus.onTrack:
      return 'ON TRACK';
    case ProjectionStatus.ahead:
      return 'AHEAD';
    case ProjectionStatus.behind:
      return 'BEHIND';
    case ProjectionStatus.stalled:
      return 'STALLED';
    case ProjectionStatus.wrongDirection:
      return 'WRONG WAY';
    case ProjectionStatus.insufficientData:
      return 'NO DATA';
  }
}

/// Where the projected date came from: `FROM 18 WEIGH-INS`.
///
/// On screen rather than internal, and next to the date rather than buried in a
/// details view. A measured slope and an energy-balance estimate deserve
/// different amounts of trust, and a date that hides which one produced it
/// invites the user to plan around a population average as though it were a
/// measurement of their own body.
String projectionBasisLabel(Projection projection) {
  switch (projection.basis) {
    case ProjectionBasis.measured:
      final count = projection.weighInDayCount;
      return 'FROM $count WEIGH-IN${count == 1 ? '' : 'S'}';
    case ProjectionBasis.energyBalance:
      return 'FROM ENERGY BALANCE';
    case ProjectionBasis.none:
      return 'NOT ENOUGH DATA';
  }
}

/// The big number on the goal card, and the line under it.
///
/// Every status that cannot honestly produce a date gets its own explanation
/// rather than a shared "unavailable". A user whose weight is flat and a user
/// who has logged nothing are in completely different situations, and the fix
/// differs; collapsing both into one message would hide which one they are in.
({String value, String caption}) projectionGoalCopy(Projection projection) {
  switch (projection.status) {
    case ProjectionStatus.goalReached:
      return (value: 'TARGET MET', caption: 'YOU ARE AT YOUR TARGET WEIGHT');

    case ProjectionStatus.stalled:
      return (
        value: 'NO DATE YET',
        caption: 'YOUR WEIGHT IS HOLDING STEADY — NOTHING TO PROJECT FROM',
      );

    case ProjectionStatus.wrongDirection:
      return (
        value: 'NO DATE YET',
        caption: 'THE TREND IS MOVING AWAY FROM YOUR TARGET',
      );

    case ProjectionStatus.insufficientData:
      return (
        value: 'NO DATE YET',
        caption: 'LOG A FEW MEALS AND WEIGH-INS AND THIS FILLS IN',
      );

    case ProjectionStatus.onTrack:
    case ProjectionStatus.ahead:
    case ProjectionStatus.behind:
      final days = projection.daysToGoal;
      final date = projection.goalDate;
      // Belt and braces: the engine guarantees a date for these three, and a
      // silent `0 DAYS` if that ever changed would be worse than saying so.
      if (days == null || date == null) {
        return (
          value: 'NO DATE YET',
          caption: 'NOT ENOUGH TO PROJECT FROM YET',
        );
      }
      return (
        value: '$days DAY${days == 1 ? '' : 'S'}',
        caption: '${projectionDateLabel(date)} · '
            '${projectionBasisLabel(projection)}',
      );
  }
}
