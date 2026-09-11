import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/data_transfer/data_bundle.dart';
import 'package:void_factor/features/data_transfer/data_transfer_providers.dart';
import 'package:void_factor/features/food_log/food_log_providers.dart';
import 'package:void_factor/features/food_log/food_log_store.dart';
import 'package:void_factor/features/profile/profile_repository.dart';
import 'package:void_factor/features/weight_log/weight_log_providers.dart';
import 'package:void_factor/features/weight_log/weight_log_store.dart';
import 'package:void_factor/models/food_entry.dart';
import 'package:void_factor/models/user_profile.dart';
import 'package:void_factor/models/weight_entry.dart';

/// Records what was shared and replays what should be picked.
class FakeGateway implements DataFileGateway {
  String? sharedContents;
  String? sharedFilename;
  String? pickReturns;
  Object? shareThrows;
  int pickCount = 0;

  @override
  Future<void> share(String contents, String filename) async {
    if (shareThrows != null) throw shareThrows!;
    sharedContents = contents;
    sharedFilename = filename;
  }

  @override
  Future<String?> pick() async {
    pickCount++;
    return pickReturns;
  }
}

/// `implements` rather than `extends`: the real constructor reaches for
/// `FirebaseAuth.instance`, which throws with no Firebase app.
class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository(this.profile);

  UserProfile profile;

  @override
  Future<UserProfile> load() async => profile;

  @override
  Future<void> save(UserProfile next) async => profile = next;

  @override
  Future<void> clearLocal() async {}

  @override
  Future<UserProfile> reconcileSchema(Map<String, dynamic> remote) async =>
      profile;
}

void main() {
  late Directory dir;
  late FoodLogStore foodStore;
  late WeightLogStore weightStore;
  late FakeGateway gateway;
  late FakeProfileRepository profiles;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('data_transfer_test');
    foodStore = FoodLogStore(dir: dir, uid: 'uid-1');
    weightStore = WeightLogStore(dir: dir, uid: 'uid-1');
    gateway = FakeGateway();
    profiles = FakeProfileRepository(
      UserProfile.empty().copyWith(height: 178, weight: 80, age: 30),
    );
  });

  tearDown(() async {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ProviderContainer containerWith() {
    final container = ProviderContainer(overrides: [
      foodLogStoreProvider.overrideWith((ref) async => foodStore),
      weightLogStoreProvider.overrideWith((ref) async => weightStore),
      profileRepositoryProvider.overrideWithValue(profiles),
      dataFileGatewayProvider.overrideWithValue(gateway),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  FoodEntry meal(String name, {DateTime? at}) => FoodEntry.create(
        name: name,
        nutrients: const Nutrients(calories: 300, proteinG: 20),
        quantity: 1,
        source: FoodSource.manual,
        loggedAt: at ?? DateTime(2026, 9, 1, 12),
      );

  WeightEntry weighIn(double kg, {DateTime? at}) => WeightEntry.create(
        weightKg: kg,
        recordedAt: at ?? DateTime(2026, 9, 1, 8),
      );

  group('export', () {
    test('hands the share sheet everything the device holds', () async {
      await foodStore.writeAll([meal('Dal'), meal('Rice')]);
      await weightStore.writeAll([weighIn(79)]);

      await containerWith().read(dataTransferProvider.notifier).export();

      final bundle = DataBundle.tryParse(gateway.sharedContents!)!;
      expect(bundle.foodEntries.map((e) => e.name), ['Dal', 'Rice']);
      expect(bundle.weightEntries.single.weightKg, 79);
      expect(bundle.profile!.height, 178);
    });

    test('names the file by its export date so a folder of them sorts', () {
      expect(
        DataTransferController.filenameFor(DateTime(2026, 9, 7)),
        'void-factor-2026-09-07.json',
      );
    });

    test('exports an empty device without complaint', () async {
      await containerWith().read(dataTransferProvider.notifier).export();
      expect(DataBundle.tryParse(gateway.sharedContents!)!.foodEntries, isEmpty);
    });

    test('reports a failure in words rather than leaking the cause', () async {
      gateway.shareThrows = const FileSystemException('no space');
      final notifier = containerWith().read(dataTransferProvider.notifier);

      await expectLater(
        notifier.export(),
        throwsA(isA<DataTransferException>().having((e) => e.message, 'message',
            DataTransferController.errorExportFailed)),
      );
    });
  });

  group('import', () {
    String bundleOf({
      List<FoodEntry> foods = const [],
      List<WeightEntry> weights = const [],
    }) =>
        DataBundle(
          exportedAt: DateTime(2026, 9, 11),
          profile: null,
          foodEntries: foods,
          weightEntries: weights,
        ).toJsonString();

    test('adds entries the device does not have', () async {
      final incoming = meal('Paneer');
      gateway.pickReturns = bundleOf(foods: [incoming]);
      final container = containerWith();

      final summary =
          await container.read(dataTransferProvider.notifier).import();

      expect(summary!.foodEntriesAdded, 1);
      expect(
        (await container.read(recentFoodLogProvider.future)).single.name,
        'Paneer',
      );
    });

    test('survives being run twice on the same file', () async {
      gateway.pickReturns = bundleOf(foods: [meal('Paneer')]);
      final container = containerWith();
      final notifier = container.read(dataTransferProvider.notifier);

      await notifier.import();
      final second = await notifier.import();

      expect(second!.foodEntriesAdded, 0);
      expect(second.changedNothing, isTrue);
      expect((await container.read(recentFoodLogProvider.future)).length, 1);
    });

    test('an old bundle cannot delete what is already on the device', () async {
      await foodStore.writeAll([meal('Today', at: DateTime(2026, 9, 10))]);
      gateway.pickReturns =
          bundleOf(foods: [meal('Ancient', at: DateTime(2025, 1, 1))]);
      final container = containerWith();

      await container.read(dataTransferProvider.notifier).import();

      final names =
          (await container.read(recentFoodLogProvider.future)).map((e) => e.name);
      expect(names, ['Today', 'Ancient']);
    });

    test('restores both logs from one file', () async {
      gateway.pickReturns =
          bundleOf(foods: [meal('Dal')], weights: [weighIn(77)]);
      final container = containerWith();

      final summary =
          await container.read(dataTransferProvider.notifier).import();

      expect(summary!.foodEntriesAdded, 1);
      expect(summary.weightEntriesAdded, 1);
      expect(
        (await container.read(weightLogProvider.future)).single.weightKg,
        77,
      );
    });

    test('the merged log reaches disk, not just memory', () async {
      gateway.pickReturns = bundleOf(foods: [meal('Dal')]);

      await containerWith().read(dataTransferProvider.notifier).import();

      // Read through a fresh store: state that never reached the file would
      // vanish on next launch with no indication it was lost.
      expect((await foodStore.readAll()).single.name, 'Dal');
    });

    test('a dismissed picker changes nothing and says nothing', () async {
      gateway.pickReturns = null;
      final container = containerWith();

      expect(
        await container.read(dataTransferProvider.notifier).import(),
        isNull,
      );
      expect((await container.read(recentFoodLogProvider.future)), isEmpty);
    });

    test('a file that is not an export is named as such', () async {
      gateway.pickReturns = '{"some":"other file"}';
      final notifier = containerWith().read(dataTransferProvider.notifier);

      await expectLater(
        notifier.import(),
        throwsA(isA<DataTransferException>().having((e) => e.message, 'message',
            DataTransferController.errorUnreadableFile)),
      );
    });

    test('leaves the existing log untouched when the file is rejected',
        () async {
      await foodStore.writeAll([meal('Mine')]);
      gateway.pickReturns = 'not json';
      final container = containerWith();

      await expectLater(
        container.read(dataTransferProvider.notifier).import(),
        throwsA(isA<DataTransferException>()),
      );
      expect((await foodStore.readAll()).single.name, 'Mine');
    });

    test('ignores the profile in the bundle', () async {
      // The profile is mirrored to Firestore and returns on login, so it was
      // never at risk. Restoring it could overwrite a newer one to rescue
      // something that did not need rescuing.
      gateway.pickReturns = DataBundle(
        exportedAt: DateTime(2026, 1, 1),
        profile: UserProfile.empty().copyWith(height: 1, weight: 1, age: 99),
        foodEntries: const [],
        weightEntries: const [],
      ).toJsonString();

      await containerWith().read(dataTransferProvider.notifier).import();

      expect(profiles.profile.height, 178);
      expect(profiles.profile.age, 30);
    });
  });
}
