import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/models/user_profile.dart';

void main() {
  group('UserProfile.fromMap', () {
    test('round-trips through toMap/fromMap', () {
      const original = UserProfile(
        height: 180,
        weight: 82.5,
        age: 30,
        gender: 'MALE',
        goal: WeightGoal.lose,
        targetWeight: 75,
        weeklyRate: 0.75,
        allergies: ['Peanuts', 'Dairy'],
      );

      final restored = UserProfile.fromMap(original.toMap());

      expect(restored.height, 180);
      expect(restored.weight, 82.5);
      expect(restored.age, 30);
      expect(restored.gender, 'MALE');
      expect(restored.goal, WeightGoal.lose);
      expect(restored.targetWeight, 75);
      expect(restored.weeklyRate, 0.75);
      expect(restored.allergies, ['Peanuts', 'Dairy']);
    });

    test('round-trips through JSON string', () {
      const original = UserProfile(
        height: 165,
        weight: 60,
        age: 24,
        gender: 'FEMALE',
        goal: WeightGoal.gain,
        targetWeight: 65,
        weeklyRate: 0.25,
        allergies: ['Soy'],
      );

      final restored = UserProfile.fromJsonString(original.toJsonString());

      expect(restored, isNotNull);
      expect(restored!.goal, WeightGoal.gain);
      expect(restored.targetWeight, 65);
      expect(restored.allergies, ['Soy']);
    });

    test('toMap stamps the current schema version', () {
      final map = UserProfile.empty().toMap();
      expect(map['schemaVersion'], UserProfile.currentSchemaVersion);
    });

    test('legacy doc (v1, missing new fields) fills sensible defaults', () {
      // A pre-migration document only had the four physical metrics, all
      // encoded as strings by the old local store.
      final legacy = <String, dynamic>{
        'height': '175',
        'weight': '70',
        'age': '28',
        'gender': 'OTHER',
      };

      final profile = UserProfile.fromMap(legacy);

      expect(profile.height, 175);
      expect(profile.weight, 70);
      expect(profile.age, 28);
      expect(profile.gender, 'OTHER');
      // New fields default; target weight defaults to current weight.
      expect(profile.goal, WeightGoal.maintain);
      expect(profile.targetWeight, 70);
      expect(profile.weeklyRate, 0.5);
      expect(profile.allergies, isEmpty);
    });

    test('parses mixed numeric encodings (num from Firestore)', () {
      final fromFirestore = <String, dynamic>{
        'height': 172.0, // double
        'weight': 68, // int
        'age': 26,
        'gender': 'MALE',
        'targetWeight': 64.0,
        'weeklyRate': 0.5,
        'goal': 'lose',
        'allergies': ['Gluten'],
        'schemaVersion': 2,
      };

      final profile = UserProfile.fromMap(fromFirestore);

      expect(profile.height, 172.0);
      expect(profile.weight, 68);
      expect(profile.age, 26);
      expect(profile.targetWeight, 64.0);
    });

    test('empty map yields a fully-defaulted profile without throwing', () {
      final profile = UserProfile.fromMap(<String, dynamic>{});
      expect(profile.gender, 'MALE');
      expect(profile.goal, WeightGoal.maintain);
      expect(profile.weeklyRate, 0.5);
      expect(profile.allergies, isEmpty);
    });
  });

  group('WeightGoal.fromWire', () {
    test('parses known values', () {
      expect(WeightGoal.fromWire('lose'), WeightGoal.lose);
      expect(WeightGoal.fromWire('maintain'), WeightGoal.maintain);
      expect(WeightGoal.fromWire('gain'), WeightGoal.gain);
    });

    test('is case/whitespace tolerant', () {
      expect(WeightGoal.fromWire('  GAIN '), WeightGoal.gain);
    });

    test('unknown or null falls back to maintain', () {
      expect(WeightGoal.fromWire('bulk'), WeightGoal.maintain);
      expect(WeightGoal.fromWire(null), WeightGoal.maintain);
      expect(WeightGoal.fromWire(42), WeightGoal.maintain);
    });
  });

  group('UserProfile.fromJsonString', () {
    test('returns null for null/empty/corrupt input', () {
      expect(UserProfile.fromJsonString(null), isNull);
      expect(UserProfile.fromJsonString(''), isNull);
      expect(UserProfile.fromJsonString('not json {{'), isNull);
      // Valid JSON that is not an object.
      expect(UserProfile.fromJsonString('[1,2,3]'), isNull);
    });
  });

  group('UserProfile.copyWith', () {
    test('overrides only the given fields', () {
      final base = UserProfile.empty();
      final updated = base.copyWith(goal: WeightGoal.gain, targetWeight: 80);

      expect(updated.goal, WeightGoal.gain);
      expect(updated.targetWeight, 80);
      // Untouched fields preserved.
      expect(updated.gender, base.gender);
      expect(updated.weeklyRate, base.weeklyRate);
    });
  });
}
