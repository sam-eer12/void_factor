import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/profile/profile_repository.dart';
import 'package:void_factor/features/weight_log/weight_log_providers.dart';
import 'package:void_factor/features/weight_log/weight_log_store.dart';
import 'package:void_factor/models/user_profile.dart';
import 'package:void_factor/models/weight_entry.dart';

/// A store whose writes can be made to fail.
///
/// Subclassed rather than faked wholesale so the passing paths exercise the real
/// file, which is what makes "persisted before committing" a claim about disk
/// rather than about a list in memory.
class FailingWeightLogStore extends WeightLogStore {
  FailingWeightLogStore({required super.dir, required super.uid});

  bool failWrites = false;

  @override
  Future<void> writeAll(List<WeightEntry> entries) async {
    if (failWrites) {
      throw const FileSystemException('no space left on device');
    }
    return super.writeAll(entries);
  }
}

/// Stands in for the Firestore-backed repository.
///
/// `implements` rather than `extends`: the real constructor's defaults reach for
/// `FirebaseAuth.instance`, which throws in a test with no Firebase app.
class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({UserProfile? profile})
      : profile = profile ?? UserProfile.empty();

  UserProfile profile;
  bool failSaves = false;
  int saveCount = 0;

  @override
  Future<UserProfile> load() async => profile;

  @override
  Future<void> save(UserProfile next) async {
    saveCount++;
    if (failSaves) throw Exception('offline');
    profile = next;
  }

  @override
  Future<void> clearLocal() async {}

  @override
  Future<UserProfile> reconcileSchema(Map<String, dynamic> remoteData) async =>
      profile;
}

void main() {
  late Directory dir;
  late FailingWeightLogStore store;
  late FakeProfileRepository profiles;

  /// A profile complete enough for the write-through to be attempted.
  UserProfile completeProfile({double weight = 80}) => UserProfile.empty()
      .copyWith(height: 178, weight: weight, age: 30, gender: 'MALE');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('weight_log_providers_test');
    store = FailingWeightLogStore(dir: dir, uid: 'uid-1');
    profiles = FakeProfileRepository(profile: completeProfile());
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  WeightEntry entry(double kg, DateTime at) =>
      WeightEntry.create(weightKg: kg, recordedAt: at);

  ProviderContainer containerWith() {
    final container = ProviderContainer(overrides: [
      weightLogStoreProvider.overrideWith((ref) async => store),
      profileRepositoryProvider.overrideWithValue(profiles),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  group('build', () {
    test('starts empty for a user with no file', () async {
      expect(await containerWith().read(weightLogProvider.future), isEmpty);
    });

    test('returns the stored history newest first, whatever order it was '
        'written in', () async {
      await store.writeAll([
        entry(80, DateTime(2026, 8, 20)),
        entry(82, DateTime(2026, 8, 24)),
        entry(81, DateTime(2026, 8, 22)),
      ]);

      final entries = await containerWith().read(weightLogProvider.future);

      expect(entries.map((e) => e.weightKg), [82, 81, 80]);
    });
  });

  group('add', () {
    test('puts a newer weigh-in at the front', () async {
      await store.writeAll([entry(80, DateTime(2026, 8, 20))]);
      final container = containerWith();
      await container.read(weightLogProvider.future);

      await container
          .read(weightLogProvider.notifier)
          .add(entry(79, DateTime(2026, 8, 25)));

      expect(
        container.read(weightLogProvider).requireValue.map((e) => e.weightKg),
        [79, 80],
      );
    });

    test('sorts a backdated weigh-in into place rather than to the front',
        () async {
      await store.writeAll([
        entry(80, DateTime(2026, 8, 25)),
        entry(82, DateTime(2026, 8, 15)),
      ]);
      final container = containerWith();
      await container.read(weightLogProvider.future);

      await container
          .read(weightLogProvider.notifier)
          .add(entry(81, DateTime(2026, 8, 20)));

      expect(
        container.read(weightLogProvider).requireValue.map((e) => e.weightKg),
        [80, 81, 82],
      );
    });

    test('keeps a second weigh-in on the same day', () async {
      final container = containerWith();
      await container.read(weightLogProvider.future);
      final notifier = container.read(weightLogProvider.notifier);

      await notifier.add(entry(80.4, DateTime(2026, 8, 25, 7)));
      await notifier.add(entry(80.9, DateTime(2026, 8, 25, 21)));

      expect(container.read(weightLogProvider).requireValue, hasLength(2));
    });

    test('writes the entry to the file, not only to memory', () async {
      final container = containerWith();
      await container.read(weightLogProvider.future);

      await container
          .read(weightLogProvider.notifier)
          .add(entry(77.5, DateTime(2026, 8, 25)));

      // Read through a fresh store: the file is the only copy that survives a
      // relaunch.
      final reread = await WeightLogStore(dir: dir, uid: 'uid-1').readAll();
      expect(reread.map((e) => e.weightKg), [77.5]);
    });
  });

  group('add when the file cannot be written', () {
    test('throws with copy the sheet can show', () async {
      final container = containerWith();
      await container.read(weightLogProvider.future);
      store.failWrites = true;

      expect(
        () => container
            .read(weightLogProvider.notifier)
            .add(entry(77, DateTime(2026, 8, 25))),
        throwsA(isA<WeightLogException>().having(
          (e) => e.message,
          'message',
          WeightLog.errorSaveFailed,
        )),
      );
    });

    test('leaves the list untouched, so the screen never shows an entry that '
        'is not on disk', () async {
      await store.writeAll([entry(80, DateTime(2026, 8, 20))]);
      final container = containerWith();
      await container.read(weightLogProvider.future);
      store.failWrites = true;

      await expectLater(
        container
            .read(weightLogProvider.notifier)
            .add(entry(77, DateTime(2026, 8, 25))),
        throwsA(isA<WeightLogException>()),
      );

      expect(
        container.read(weightLogProvider).requireValue.map((e) => e.weightKg),
        [80],
      );
    });

    test('does not touch the profile', () async {
      final container = containerWith();
      await container.read(weightLogProvider.future);
      store.failWrites = true;

      await expectLater(
        container
            .read(weightLogProvider.notifier)
            .add(entry(77, DateTime(2026, 8, 25))),
        throwsA(isA<WeightLogException>()),
      );

      expect(profiles.saveCount, 0);
    });
  });

  group('profile write-through', () {
    test('mirrors the newest weight and reports a full save', () async {
      final container = containerWith();
      await container.read(weightLogProvider.future);

      final outcome = await container
          .read(weightLogProvider.notifier)
          .add(entry(77.5, DateTime(2026, 8, 25)));

      expect(outcome, WeightSaveOutcome.saved);
      expect(profiles.profile.weight, 77.5);
    });

    test('preserves the rest of the profile', () async {
      profiles.profile = completeProfile().copyWith(
        goal: WeightGoal.lose,
        targetWeight: 70,
        weeklyRate: 0.5,
      );
      final container = containerWith();
      await container.read(weightLogProvider.future);

      await container
          .read(weightLogProvider.notifier)
          .add(entry(77.5, DateTime(2026, 8, 25)));

      expect(profiles.profile.targetWeight, 70);
      expect(profiles.profile.weeklyRate, 0.5);
      expect(profiles.profile.height, 178);
    });

    test('a failed mirror still counts as saved on this device', () async {
      profiles.failSaves = true;
      final container = containerWith();
      await container.read(weightLogProvider.future);

      final outcome = await container
          .read(weightLogProvider.notifier)
          .add(entry(77.5, DateTime(2026, 8, 25)));

      expect(outcome, WeightSaveOutcome.savedWithoutSync);
      // The measurement is what matters, and it is on disk.
      final reread = await WeightLogStore(dir: dir, uid: 'uid-1').readAll();
      expect(reread.single.weightKg, 77.5);
    });

    test('an un-onboarded profile is left alone rather than half-written',
        () async {
      profiles.profile = UserProfile.empty();
      final container = containerWith();
      await container.read(weightLogProvider.future);

      final outcome = await container
          .read(weightLogProvider.notifier)
          .add(entry(77.5, DateTime(2026, 8, 25)));

      expect(outcome, WeightSaveOutcome.savedWithoutSync);
      expect(profiles.saveCount, 0);
    });

    test('a backdated weigh-in does not drag the profile weight backwards',
        () async {
      await store.writeAll([entry(78, DateTime(2026, 8, 25))]);
      final container = containerWith();
      await container.read(weightLogProvider.future);

      final outcome = await container
          .read(weightLogProvider.notifier)
          .add(entry(84, DateTime(2026, 8, 10)));

      expect(outcome, WeightSaveOutcome.saved);
      expect(profiles.saveCount, 0);
      expect(profiles.profile.weight, 80);
    });
  });

  group('currentWeightKg', () {
    test('prefers the newest weigh-in over the profile', () {
      final weights = [
        entry(77, DateTime(2026, 8, 25)),
        entry(80, DateTime(2026, 8, 1)),
      ];

      expect(currentWeightKg(weights, completeProfile(weight: 99)), 77);
    });

    test('falls back to the profile when nothing has been logged', () {
      expect(currentWeightKg(const [], completeProfile(weight: 99)), 99);
    });
  });
}
