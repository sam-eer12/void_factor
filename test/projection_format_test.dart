import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/projection_format.dart';
import 'package:void_factor/models/projection.dart';
import 'package:void_factor/models/user_profile.dart';

/// A projection with every figure at a neutral default, so each test sets only
/// the fields its assertion is about.
Projection projection({
  ProjectionStatus status = ProjectionStatus.onTrack,
  ProjectionBasis basis = ProjectionBasis.energyBalance,
  int? daysToGoal = 47,
  DateTime? goalDate,
  int weighInDayCount = 0,
  double ratePerWeekKg = -0.5,
}) {
  return Projection(
    observed: const [],
    projected: const [],
    currentWeightKg: 80,
    targetWeightKg: 72,
    goal: WeightGoal.lose,
    ratePerWeekKg: ratePerWeekKg,
    targetRatePerWeekKg: -0.5,
    basis: basis,
    status: status,
    daysToGoal: daysToGoal,
    goalDate: goalDate ?? DateTime(2026, 10, 12),
    bmrKcal: 1700,
    activeKcal: 300,
    tdeeKcal: 2340,
    intakeKcal: 1800,
    proteinGPerDay: 120,
    balanceKcal: -540,
    loggedDayCount: 12,
    intakeWindowDays: 14,
    weighInDayCount: weighInDayCount,
    seriesSpanDays: 20,
    activeEnergyFromDevice: true,
  );
}

void main() {
  group('projectionDayLabel', () {
    test('names the day and the month', () {
      expect(projectionDayLabel(DateTime(2026, 8, 12)), '12 AUG');
    });

    test('does not pad a single-digit day', () {
      expect(projectionDayLabel(DateTime(2026, 1, 4)), '4 JAN');
    });

    test('reads December as DEC, not off the end of the month table', () {
      expect(projectionDayLabel(DateTime(2026, 12, 31)), '31 DEC');
    });
  });

  group('projectionDateLabel', () {
    test('carries the year, because a goal date can cross one', () {
      expect(projectionDateLabel(DateTime(2027, 1, 4)), '4 JAN 2027');
    });
  });

  group('projectionKgLabel', () {
    test('drops a decimal point that says nothing', () {
      expect(projectionKgLabel(78), '78');
    });

    test('keeps one decimal when there is one', () {
      expect(projectionKgLabel(82.4), '82.4');
    });

    test('rounds to one decimal rather than printing scale noise', () {
      expect(projectionKgLabel(82.4499), '82.4');
    });

    test('renders a value that rounds to a whole number without the decimal',
        () {
      expect(projectionKgLabel(79.999), '80');
    });
  });

  group('projectionRateLabel', () {
    test('signs a loss', () {
      expect(projectionRateLabel(-0.6), '-0.6');
    });

    test('signs a gain, which an unsigned number would not distinguish', () {
      expect(projectionRateLabel(0.4), '+0.4');
    });

    test('keeps the decimal on a whole rate, so a stall reads differently from '
        'half a kilo', () {
      expect(projectionRateLabel(1), '+1.0');
    });

    test('renders a rate that rounds to nothing as an unsigned zero', () {
      // `-0.04` would otherwise print as `-0.0`: a loss that is not happening.
      expect(projectionRateLabel(-0.04), '0.0');
      expect(projectionRateLabel(0.04), '0.0');
      expect(projectionRateLabel(0), '0.0');
    });
  });

  group('projectionStatusLabel', () {
    test('gives every status a chip short enough to sit beside a headline', () {
      for (final status in ProjectionStatus.values) {
        final label = projectionStatusLabel(status);
        expect(label, isNotEmpty);
        expect(label.length, lessThanOrEqualTo(12), reason: '$status');
        expect(label, label.toUpperCase(), reason: '$status');
      }
    });

    test('names the states a user acts on', () {
      expect(projectionStatusLabel(ProjectionStatus.onTrack), 'ON TRACK');
      expect(
          projectionStatusLabel(ProjectionStatus.wrongDirection), 'WRONG WAY');
      expect(projectionStatusLabel(ProjectionStatus.insufficientData),
          'NO DATA');
    });
  });

  group('projectionBasisLabel', () {
    test('counts the weigh-ins a measured trend was drawn from', () {
      expect(
        projectionBasisLabel(projection(
          basis: ProjectionBasis.measured,
          weighInDayCount: 18,
        )),
        'FROM 18 WEIGH-INS',
      );
    });

    test('says WEIGH-IN, singular, for one', () {
      expect(
        projectionBasisLabel(projection(
          basis: ProjectionBasis.measured,
          weighInDayCount: 1,
        )),
        'FROM 1 WEIGH-IN',
      );
    });

    test('names an estimate as an estimate', () {
      expect(
        projectionBasisLabel(projection(basis: ProjectionBasis.energyBalance)),
        'FROM ENERGY BALANCE',
      );
    });

    test('says so when there is no basis at all', () {
      expect(
        projectionBasisLabel(projection(basis: ProjectionBasis.none)),
        'NOT ENOUGH DATA',
      );
    });
  });

  group('projectionGoalCopy', () {
    test('counts the days and names the date and its basis', () {
      final copy = projectionGoalCopy(projection(
        daysToGoal: 47,
        goalDate: DateTime(2026, 10, 12),
        basis: ProjectionBasis.measured,
        weighInDayCount: 18,
      ));

      expect(copy.value, '47 DAYS');
      expect(copy.caption, '12 OCT 2026 · FROM 18 WEIGH-INS');
    });

    test('says DAY, singular, for tomorrow', () {
      expect(projectionGoalCopy(projection(daysToGoal: 1)).value, '1 DAY');
    });

    test('congratulates rather than counting when the target is met', () {
      final copy =
          projectionGoalCopy(projection(status: ProjectionStatus.goalReached));

      expect(copy.value, 'TARGET MET');
      expect(copy.caption, contains('TARGET WEIGHT'));
    });

    test('gives a stall and an empty log different explanations', () {
      final stalled =
          projectionGoalCopy(projection(status: ProjectionStatus.stalled));
      final empty = projectionGoalCopy(
          projection(status: ProjectionStatus.insufficientData));

      expect(stalled.value, 'NO DATE YET');
      expect(empty.value, 'NO DATE YET');
      // The two situations need different fixes, so they must not share copy.
      expect(stalled.caption, isNot(empty.caption));
      expect(stalled.caption, contains('HOLDING STEADY'));
      expect(empty.caption, contains('LOG'));
    });

    test('says the trend is going the wrong way rather than projecting a date',
        () {
      final copy = projectionGoalCopy(
          projection(status: ProjectionStatus.wrongDirection));

      expect(copy.value, 'NO DATE YET');
      expect(copy.caption, contains('AWAY FROM YOUR TARGET'));
    });

    test('refuses to print a day count without a date behind it', () {
      // Cannot happen through the engine; the guard exists so that if it ever
      // could, the card says "no date yet" instead of "0 DAYS".
      final copy = projectionGoalCopy(projection(daysToGoal: null));

      expect(copy.value, 'NO DATE YET');
      expect(copy.caption, isNot(contains('·')));
    });

    test('every status produces copy, so the card can never render blank', () {
      for (final status in ProjectionStatus.values) {
        final copy = projectionGoalCopy(projection(status: status));
        expect(copy.value, isNotEmpty, reason: '$status');
        expect(copy.caption, isNotEmpty, reason: '$status');
      }
    });
  });
}
