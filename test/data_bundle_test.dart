import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/data_transfer/data_bundle.dart';
import 'package:void_factor/models/food_entry.dart';
import 'package:void_factor/models/user_profile.dart';
import 'package:void_factor/models/weight_entry.dart';

FoodEntry food(String id, {DateTime? at, String name = 'Rice'}) => FoodEntry(
      id: id,
      name: name,
      nutrients: const Nutrients(calories: 200, proteinG: 5),
      quantity: 1,
      source: FoodSource.manual,
      loggedAt: at ?? DateTime(2026, 9, 1, 12),
    );

WeightEntry weight(String id, {DateTime? at, double kg = 70}) => WeightEntry(
      id: id,
      weightKg: kg,
      recordedAt: at ?? DateTime(2026, 9, 1, 8),
    );

DataBundle bundleOf({
  List<FoodEntry> foods = const [],
  List<WeightEntry> weights = const [],
  UserProfile? profile,
}) =>
    DataBundle(
      exportedAt: DateTime(2026, 9, 11),
      profile: profile,
      foodEntries: foods,
      weightEntries: weights,
    );

void main() {
  group('round trip', () {
    test('survives being written and read back', () {
      final original = bundleOf(
        foods: [food('a'), food('b')],
        weights: [weight('w1')],
        profile: UserProfile.empty().copyWith(height: 180, weight: 75, age: 30),
      );

      final parsed = DataBundle.tryParse(original.toJsonString())!;

      expect(parsed.foodEntries.map((e) => e.id), ['a', 'b']);
      expect(parsed.weightEntries.single.id, 'w1');
      expect(parsed.profile!.height, 180);
      expect(parsed.exportedAt, DateTime(2026, 9, 11));
    });

    test('carries the profile even though import will not restore it', () {
      // A user asking for their data should receive all of it, whatever import
      // chooses to do with it.
      final parsed = DataBundle.tryParse(
        bundleOf(profile: UserProfile.empty().copyWith(weight: 82)).toJsonString(),
      )!;
      expect(parsed.profile!.weight, 82);
    });
  });

  group('rejecting files that are not ours', () {
    test('refuses a file with no format marker', () {
      // Picking the wrong file from a share sheet is the common case. Importing
      // zero entries from it would look like success.
      expect(DataBundle.tryParse('{"foodEntries":[]}'), isNull);
    });

    test('refuses a foreign format marker', () {
      expect(DataBundle.tryParse('{"format":"some.other.app"}'), isNull);
    });

    test('refuses text that is not JSON', () {
      expect(DataBundle.tryParse('not json at all'), isNull);
    });

    test('refuses JSON that is not an object', () {
      expect(DataBundle.tryParse('[1,2,3]'), isNull);
    });
  });

  group('tolerating damage', () {
    test('skips an unreadable entry and keeps the rest', () {
      final raw = bundleOf(foods: [food('a'), food('b')]).toMap();
      (raw['foodEntries'] as List)[0] = {'garbage': true};

      final parsed = DataBundle.tryParse(jsonEncode(raw))!;

      expect(parsed.foodEntries.map((e) => e.id), ['b']);
    });

    test('treats missing lists as empty rather than failing', () {
      final parsed = DataBundle.tryParse(
        '{"format":"${DataBundle.formatMarker}"}',
      )!;
      expect(parsed.foodEntries, isEmpty);
      expect(parsed.weightEntries, isEmpty);
      expect(parsed.profile, isNull);
    });
  });

  group('mergeById', () {
    List<FoodEntry> merge(List<FoodEntry> a, List<FoodEntry> b) =>
        DataBundle.mergeById(a, b,
            idOf: (e) => e.id, timeOf: (e) => e.loggedAt);

    test('adds entries the device does not have', () {
      final merged = merge([food('a')], [food('b')]);
      expect(merged.map((e) => e.id).toSet(), {'a', 'b'});
    });

    test('importing the same bundle twice changes nothing', () {
      final once = merge([food('a')], [food('a'), food('b')]);
      final twice = merge(once, [food('a'), food('b')]);
      expect(twice.length, once.length);
    });

    test('keeps the device copy when an id exists on both sides', () {
      final merged = merge(
        [food('a', name: 'On device')],
        [food('a', name: 'In file')],
      );
      expect(merged.single.name, 'On device');
    });

    test('an old bundle cannot delete newer entries', () {
      final newer = food('new', at: DateTime(2026, 9, 10));
      final merged = merge([newer], [food('old', at: DateTime(2026, 1, 1))]);
      expect(merged.map((e) => e.id), contains('new'));
      expect(merged.length, 2);
    });

    test('returns newest first, interleaving both sides by time', () {
      final merged = merge(
        [food('mid', at: DateTime(2026, 5, 1))],
        [
          food('newest', at: DateTime(2026, 9, 1)),
          food('oldest', at: DateTime(2026, 1, 1)),
        ],
      );
      expect(merged.map((e) => e.id), ['newest', 'mid', 'oldest']);
    });

    test('merges weights on their own timestamp field', () {
      final merged = DataBundle.mergeById(
        [weight('w1', at: DateTime(2026, 5, 1))],
        [weight('w2', at: DateTime(2026, 9, 1))],
        idOf: (e) => e.id,
        timeOf: (e) => e.recordedAt,
      );
      expect(merged.map((e) => e.id), ['w2', 'w1']);
    });
  });

  group('ImportSummary', () {
    test('a bundle that was already fully present reports no change', () {
      const summary = ImportSummary(foodEntriesAdded: 0, weightEntriesAdded: 0);
      expect(summary.changedNothing, isTrue);
    });

    test('one new weigh-in alone counts as a change', () {
      const summary = ImportSummary(foodEntriesAdded: 0, weightEntriesAdded: 1);
      expect(summary.changedNothing, isFalse);
    });
  });
}
