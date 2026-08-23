import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/models/food_entry.dart';

void main() {
  group('Nutrients.fromApi', () {
    test('reads the microservice snake_case shape', () {
      final n = Nutrients.fromApi({
        'calories': 450,
        'protein_g': 42,
        'carbs_g': 30.5,
        'fats_g': 12,
      });

      expect(n.calories, 450);
      expect(n.proteinG, 42);
      expect(n.carbsG, 30.5);
      expect(n.fatsG, 12);
    });

    test('coerces null macros to zero', () {
      // This is the real normalize() output when the model omits a macro:
      // parsing.py uses nutrients.get(...), which yields null.
      final n = Nutrients.fromApi({
        'calories': 200,
        'protein_g': null,
        'carbs_g': null,
        'fats_g': null,
      });

      expect(n.calories, 200);
      expect(n.proteinG, 0);
      expect(n.carbsG, 0);
      expect(n.fatsG, 0);
    });

    test('coerces an entirely empty map to zeros', () {
      final n = Nutrients.fromApi(const {});

      expect(n.calories, 0);
      expect(n.proteinG, 0);
      expect(n.carbsG, 0);
      expect(n.fatsG, 0);
    });

    test('parses numeric strings a model may emit', () {
      final n = Nutrients.fromApi({
        'calories': '450',
        'protein_g': '42.5',
        'carbs_g': 'not a number',
        'fats_g': null,
      });

      expect(n.calories, 450);
      expect(n.proteinG, 42.5);
      expect(n.carbsG, 0);
      expect(n.fatsG, 0);
    });
  });

  group('Nutrients storage format', () {
    test('writes camelCase keys, distinct from the wire format', () {
      const n = Nutrients(
        calories: 450,
        proteinG: 42,
        carbsG: 30,
        fatsG: 12,
      );

      final map = n.toMap();

      expect(map['proteinG'], 42);
      expect(map['carbsG'], 30);
      expect(map['fatsG'], 12);
      // The snake_case wire keys must not leak into storage.
      expect(map.containsKey('protein_g'), isFalse);
      expect(map.containsKey('carbs_g'), isFalse);
      expect(map.containsKey('fats_g'), isFalse);
    });

    test('round-trips snake_case in to camelCase out and back', () {
      final fromWire = Nutrients.fromApi({
        'calories': 450,
        'protein_g': 42,
        'carbs_g': 30,
        'fats_g': 12,
      });

      final restored = Nutrients.fromMap(fromWire.toMap());

      expect(restored.calories, 450);
      expect(restored.proteinG, 42);
      expect(restored.carbsG, 30);
      expect(restored.fatsG, 12);
    });

    test('fromMap defaults missing fields to zero', () {
      final n = Nutrients.fromMap(const {'calories': 100});

      expect(n.calories, 100);
      expect(n.proteinG, 0);
    });
  });

  group('FoodSource.fromWire', () {
    test('parses the two known values', () {
      expect(FoodSource.fromWire('vision'), FoodSource.vision);
      expect(FoodSource.fromWire('manual'), FoodSource.manual);
    });

    test('is tolerant of case and surrounding whitespace', () {
      expect(FoodSource.fromWire('  VISION '), FoodSource.vision);
    });

    test('defaults to manual on garbage or null', () {
      expect(FoodSource.fromWire('nonsense'), FoodSource.manual);
      expect(FoodSource.fromWire(null), FoodSource.manual);
      expect(FoodSource.fromWire(42), FoodSource.manual);
    });

    test('wireValue round-trips through fromWire', () {
      for (final source in FoodSource.values) {
        expect(FoodSource.fromWire(source.wireValue), source);
      }
    });
  });

  group('FoodEntry quantity scaling', () {
    test('totals are per-serving nutrients times quantity', () {
      final entry = FoodEntry.create(
        name: 'Grilled Chicken',
        nutrients: const Nutrients(
          calories: 200,
          proteinG: 30,
          carbsG: 10,
          fatsG: 5,
        ),
        quantity: 2.0,
        source: FoodSource.manual,
      );

      expect(entry.totalCalories, 400);
      expect(entry.totalProteinG, 60);
      expect(entry.totalCarbsG, 20);
      expect(entry.totalFatsG, 10);
    });

    test('a half serving halves the totals', () {
      final entry = FoodEntry.create(
        name: 'Protein Shake',
        nutrients: const Nutrients(calories: 300, proteinG: 40),
        quantity: 0.5,
        source: FoodSource.manual,
      );

      expect(entry.totalCalories, 150);
      expect(entry.totalProteinG, 20);
    });

    test('quantity is stored separately and never multiplied into nutrients',
        () {
      final entry = FoodEntry.create(
        name: 'Rice Bowl',
        nutrients: const Nutrients(calories: 500),
        quantity: 3.0,
        source: FoodSource.vision,
      );

      // The AI's original per-serving reading survives verbatim.
      expect(entry.nutrients.calories, 500);
      expect(entry.totalCalories, 1500);

      // And it still survives a storage round-trip.
      final restored = FoodEntry.tryFromMap(entry.toMap())!;
      expect(restored.nutrients.calories, 500);
      expect(restored.quantity, 3.0);
    });
  });

  group('FoodEntry.create', () {
    test('generates a 32-character hex id', () {
      final entry = FoodEntry.create(
        name: 'Oatmeal',
        nutrients: const Nutrients(calories: 300),
        quantity: 1.0,
        source: FoodSource.manual,
      );

      expect(entry.id, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('generates a distinct id per entry so a double-tap cannot collide', () {
      final ids = List.generate(
        50,
        (_) => FoodEntry.create(
          name: 'Same Food',
          nutrients: const Nutrients(calories: 100),
          quantity: 1.0,
          source: FoodSource.manual,
        ).id,
      ).toSet();

      expect(ids.length, 50);
    });
  });

  group('FoodEntry storage round-trip', () {
    test('round-trips every field', () {
      final entry = FoodEntry.create(
        name: 'Salmon & Brown Rice',
        nutrients: const Nutrients(
          calories: 520,
          proteinG: 38,
          carbsG: 45,
          fatsG: 18,
        ),
        quantity: 1.5,
        source: FoodSource.vision,
        loggedAt: DateTime(2026, 8, 22, 19, 30),
      );

      final restored = FoodEntry.tryFromMap(entry.toMap())!;

      expect(restored.id, entry.id);
      expect(restored.name, 'Salmon & Brown Rice');
      expect(restored.nutrients.calories, 520);
      expect(restored.nutrients.proteinG, 38);
      expect(restored.nutrients.carbsG, 45);
      expect(restored.nutrients.fatsG, 18);
      expect(restored.quantity, 1.5);
      expect(restored.source, FoodSource.vision);
      expect(restored.loggedAt, DateTime(2026, 8, 22, 19, 30));
      expect(restored.schemaVersion, FoodEntry.currentSchemaVersion);
    });

    test('loggedAt is written without an offset suffix and reads back local',
        () {
      final entry = FoodEntry.create(
        name: 'Lunch',
        nutrients: const Nutrients(calories: 400),
        quantity: 1.0,
        source: FoodSource.manual,
        loggedAt: DateTime(2026, 8, 22, 12, 30),
      );

      final raw = entry.toMap()['loggedAt'] as String;

      // A local DateTime serializes with no 'Z' and no +hh:mm — that is what
      // makes the wall-clock reading stable across a timezone change.
      expect(raw, '2026-08-22T12:30:00.000');
      expect(raw.endsWith('Z'), isFalse);

      final restored = FoodEntry.tryFromMap(entry.toMap())!;
      expect(restored.loggedAt.isUtc, isFalse);
      expect(restored.loggedAt.hour, 12);
      expect(restored.loggedAt.minute, 30);
    });

    test('stamps the current schema version on write', () {
      final entry = FoodEntry.create(
        name: 'Eggs',
        nutrients: const Nutrients(calories: 150),
        quantity: 1.0,
        source: FoodSource.manual,
      );

      expect(entry.toMap()['schemaVersion'], 1);
    });
  });

  group('FoodEntry.tryFromMap tolerance', () {
    test('defaults a missing quantity to one serving', () {
      final entry = FoodEntry.tryFromMap({
        'id': 'abc123',
        'name': 'Toast',
        'nutrients': {'calories': 100},
        'loggedAt': '2026-08-22T08:00:00.000',
      });

      expect(entry, isNotNull);
      expect(entry!.quantity, 1.0);
    });

    test('defaults missing nutrients to zeros rather than dropping the entry',
        () {
      final entry = FoodEntry.tryFromMap({
        'id': 'abc123',
        'name': 'Mystery Meal',
        'loggedAt': '2026-08-22T08:00:00.000',
      });

      expect(entry, isNotNull);
      expect(entry!.nutrients.calories, 0);
    });

    test('synthesizes an id when one is missing', () {
      final entry = FoodEntry.tryFromMap({
        'name': 'Toast',
        'nutrients': {'calories': 100},
        'loggedAt': '2026-08-22T08:00:00.000',
      });

      expect(entry, isNotNull);
      expect(entry!.id, isNotEmpty);
    });

    test('rejects an entry with an unparseable loggedAt', () {
      // Without a timestamp there is no day bucket for it to render in.
      final entry = FoodEntry.tryFromMap({
        'id': 'abc123',
        'name': 'Toast',
        'nutrients': {'calories': 100},
        'loggedAt': 'not a date',
      });

      expect(entry, isNull);
    });

    test('rejects an entry with a missing loggedAt', () {
      final entry = FoodEntry.tryFromMap({
        'id': 'abc123',
        'name': 'Toast',
        'nutrients': {'calories': 100},
      });

      expect(entry, isNull);
    });

    test('rejects an entry whose name is empty or whitespace', () {
      // A nameless entry renders as a blank row.
      expect(
        FoodEntry.tryFromMap({
          'id': 'abc123',
          'name': '   ',
          'loggedAt': '2026-08-22T08:00:00.000',
        }),
        isNull,
      );
    });

    test('trims surrounding whitespace from the name', () {
      final entry = FoodEntry.tryFromMap({
        'id': 'abc123',
        'name': '  Toast  ',
        'loggedAt': '2026-08-22T08:00:00.000',
      });

      expect(entry!.name, 'Toast');
    });

    test('clamps an out-of-range stored quantity into bounds', () {
      final tooSmall = FoodEntry.tryFromMap({
        'id': 'a',
        'name': 'Toast',
        'quantity': 0,
        'loggedAt': '2026-08-22T08:00:00.000',
      });
      final tooLarge = FoodEntry.tryFromMap({
        'id': 'b',
        'name': 'Toast',
        'quantity': 9999,
        'loggedAt': '2026-08-22T08:00:00.000',
      });

      expect(tooSmall!.quantity, FoodEntry.minQuantity);
      expect(tooLarge!.quantity, FoodEntry.maxQuantity);
    });

    test('defaults an unknown source to manual', () {
      final entry = FoodEntry.tryFromMap({
        'id': 'abc123',
        'name': 'Toast',
        'source': 'telepathy',
        'loggedAt': '2026-08-22T08:00:00.000',
      });

      expect(entry!.source, FoodSource.manual);
    });

    test('rejects a nutrients value of the wrong type without throwing', () {
      final entry = FoodEntry.tryFromMap({
        'id': 'abc123',
        'name': 'Toast',
        'nutrients': 'not a map',
        'loggedAt': '2026-08-22T08:00:00.000',
      });

      // Tolerant: the entry survives with zeroed nutrients.
      expect(entry, isNotNull);
      expect(entry!.nutrients.calories, 0);
    });
  });

  group('FoodEntry.copyWith', () {
    test('replaces quantity while preserving the per-serving basis', () {
      final entry = FoodEntry.create(
        name: 'Yogurt',
        nutrients: const Nutrients(calories: 180, proteinG: 15),
        quantity: 1.0,
        source: FoodSource.manual,
      );

      final doubled = entry.copyWith(quantity: 2.0);

      expect(doubled.id, entry.id);
      expect(doubled.nutrients.calories, 180);
      expect(doubled.totalCalories, 360);
    });
  });

  group('FoodEntry quantity bounds', () {
    test('exposes the stepper bounds from the design', () {
      expect(FoodEntry.minQuantity, 0.5);
      expect(FoodEntry.quantityStep, 0.5);
      expect(FoodEntry.maxQuantity, 20);
    });
  });
}
