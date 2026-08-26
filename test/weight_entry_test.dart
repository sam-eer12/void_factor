import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/models/weight_entry.dart';

void main() {
  group('create', () {
    test('generates an id and defaults the timestamp to now', () {
      final before = DateTime.now();
      final entry = WeightEntry.create(weightKg: 82.4);

      expect(entry.id, isNotEmpty);
      expect(entry.weightKg, 82.4);
      expect(
        entry.recordedAt.isBefore(before.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('gives every entry a distinct id', () {
      final ids = List.generate(
        50,
        (_) => WeightEntry.create(weightKg: 70).id,
      ).toSet();

      expect(ids, hasLength(50));
    });

    test('clamps a weight outside the plausible range', () {
      expect(WeightEntry.create(weightKg: 900).weightKg, WeightEntry.maxKg);
      expect(WeightEntry.create(weightKg: 1).weightKg, WeightEntry.minKg);
    });
  });

  group('isPlausible', () {
    test('accepts ordinary body weights', () {
      for (final kg in [20.0, 45.5, 82.4, 150.0, 500.0]) {
        expect(WeightEntry.isPlausible(kg), isTrue, reason: '$kg');
      }
    });

    test('rejects values outside the range, so the sheet can refuse them', () {
      // Refused rather than clamped: clamping 750 to 500 would store a weight
      // the user never typed and never saw.
      for (final kg in [0.0, 19.9, 500.1, 750.0, -80.0]) {
        expect(WeightEntry.isPlausible(kg), isFalse, reason: '$kg');
      }
    });

    test('rejects non-finite values', () {
      expect(WeightEntry.isPlausible(double.nan), isFalse);
      expect(WeightEntry.isPlausible(double.infinity), isFalse);
    });
  });

  group('day', () {
    test('is local midnight of the recording', () {
      final entry = WeightEntry(
        id: 'a',
        weightKg: 80,
        recordedAt: DateTime(2026, 8, 26, 23, 59, 59),
      );

      expect(entry.day, DateTime(2026, 8, 26));
    });

    test('buckets two weigh-ins on the same day together', () {
      final morning = WeightEntry(
        id: 'a',
        weightKg: 80,
        recordedAt: DateTime(2026, 8, 26, 7, 0),
      );
      final evening = WeightEntry(
        id: 'b',
        weightKg: 81,
        recordedAt: DateTime(2026, 8, 26, 21, 30),
      );

      expect(morning.day, evening.day);
    });
  });

  group('tryFromMap', () {
    Map<String, dynamic> valid() => {
          'id': 'entry-1',
          'weightKg': 78.6,
          'recordedAt': '2026-08-26T07:30:00.000',
          'schemaVersion': 1,
        };

    test('reads a well-formed entry', () {
      final entry = WeightEntry.tryFromMap(valid());

      expect(entry, isNotNull);
      expect(entry!.id, 'entry-1');
      expect(entry.weightKg, 78.6);
      expect(entry.recordedAt, DateTime(2026, 8, 26, 7, 30));
    });

    test('reads a weight stored as a string', () {
      final entry = WeightEntry.tryFromMap(valid()..['weightKg'] = ' 78.6 ');

      expect(entry?.weightKg, 78.6);
    });

    test('reads a weight stored as an int', () {
      final entry = WeightEntry.tryFromMap(valid()..['weightKg'] = 79);

      expect(entry?.weightKg, 79.0);
    });

    test('synthesizes an id rather than discarding a real measurement', () {
      final entry = WeightEntry.tryFromMap(valid()..remove('id'));

      expect(entry, isNotNull);
      expect(entry!.id, isNotEmpty);
    });

    test('drops an entry with no parseable timestamp', () {
      // There is no day to plot it on.
      expect(WeightEntry.tryFromMap(valid()..remove('recordedAt')), isNull);
      expect(
        WeightEntry.tryFromMap(valid()..['recordedAt'] = 'not a date'),
        isNull,
      );
    });

    test('drops an entry with no weight at all', () {
      // A weight entry *is* one number; defaulting it to 0 would bend the
      // regression through a point the user never recorded.
      expect(WeightEntry.tryFromMap(valid()..remove('weightKg')), isNull);
      expect(WeightEntry.tryFromMap(valid()..['weightKg'] = null), isNull);
      expect(WeightEntry.tryFromMap(valid()..['weightKg'] = 'heavy'), isNull);
    });

    test('drops an implausible stored weight instead of clamping it', () {
      expect(WeightEntry.tryFromMap(valid()..['weightKg'] = 0), isNull);
      expect(WeightEntry.tryFromMap(valid()..['weightKg'] = 4000), isNull);
      expect(WeightEntry.tryFromMap(valid()..['weightKg'] = -80), isNull);
    });

    test('defaults a missing schema version rather than failing', () {
      final entry = WeightEntry.tryFromMap(valid()..remove('schemaVersion'));

      expect(entry?.schemaVersion, 1);
    });
  });

  group('toMap', () {
    test('round-trips through tryFromMap', () {
      final original = WeightEntry(
        id: 'entry-9',
        weightKg: 91.25,
        recordedAt: DateTime(2026, 8, 26, 6, 15),
      );

      final restored = WeightEntry.tryFromMap(original.toMap());

      expect(restored!.id, original.id);
      expect(restored.weightKg, original.weightKg);
      expect(restored.recordedAt, original.recordedAt);
    });

    test('writes the timestamp with no offset so it reads back as local', () {
      final entry = WeightEntry(
        id: 'a',
        weightKg: 80,
        recordedAt: DateTime(2026, 8, 26, 7, 30),
      );

      final written = entry.toMap()['recordedAt'] as String;

      expect(written, '2026-08-26T07:30:00.000');
      expect(written, isNot(endsWith('Z')));
      expect(DateTime.parse(written).isUtc, isFalse);
    });

    test('always writes the current schema version', () {
      final entry = WeightEntry(
        id: 'a',
        weightKg: 80,
        recordedAt: DateTime(2026, 8, 26),
        schemaVersion: 0,
      );

      expect(
        entry.toMap()['schemaVersion'],
        WeightEntry.currentSchemaVersion,
      );
    });
  });

  group('copyWith', () {
    test('keeps the id and clamps a replacement weight', () {
      final original = WeightEntry.create(weightKg: 80);

      final updated = original.copyWith(weightKg: 900);

      expect(updated.id, original.id);
      expect(updated.weightKg, WeightEntry.maxKg);
    });

    test('leaves untouched fields alone', () {
      final original = WeightEntry.create(weightKg: 80);

      final updated = original.copyWith();

      expect(updated.weightKg, original.weightKg);
      expect(updated.recordedAt, original.recordedAt);
    });
  });
}
