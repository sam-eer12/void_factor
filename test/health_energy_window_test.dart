import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/health/health_repository.dart';
import 'package:void_factor/models/energy_window.dart';

/// In-memory fake for the secure-storage seam, as `health_repository_test` uses.
class FakeStore implements HealthKeyValueStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

/// Gateway that records the window it was asked for and hands back canned days.
class FakeGateway implements HealthGateway {
  FakeGateway({this.energyDays = const [], this.throwOnRead = false});

  List<DailyEnergy> energyDays;
  bool throwOnRead;
  final List<({DateTime start, DateTime end})> energyRequests = [];

  @override
  Future<void> configure() async {}
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> requestAuthorization(List<Object> types) async => true;
  @override
  Future<int> totalSteps(DateTime start, DateTime end) async => 0;
  @override
  Future<double> totalWaterMl(DateTime start, DateTime end) async => 0;
  @override
  Future<double> totalWorkoutSeconds(DateTime start, DateTime end) async => 0;

  @override
  Future<List<DailyEnergy>> dailyEnergy(DateTime start, DateTime end) async {
    energyRequests.add((start: start, end: end));
    if (throwOnRead) throw Exception('read failed');
    return energyDays;
  }
}

void main() {
  final now = DateTime(2026, 8, 26, 18, 30);

  DailyEnergy day(int dayOfMonth, {int steps = 6000, double kcal = 400}) {
    return DailyEnergy(
      day: DateTime(2026, 8, dayOfMonth),
      steps: steps,
      workoutMinutes: 30,
      activeKcal: kcal,
    );
  }

  group('readEnergyWindow', () {
    test('asks for a window that ends today and is inclusive of it', () async {
      final gateway = FakeGateway();
      final repo = HealthRepository(gateway: gateway, store: FakeStore());

      await repo.readEnergyWindow(now: now);

      final request = gateway.energyRequests.single;
      expect(request.end, now);
      // 14 days means today plus the 13 before it, so the 26th back to the 13th.
      expect(request.start, DateTime(2026, 8, 13));
      expect(
        request.end.difference(request.start).inDays,
        HealthRepository.energyWindowDays - 1,
      );
    });

    test('returns the days oldest first, whatever order the platform gave them',
        () async {
      final gateway = FakeGateway(energyDays: [day(26), day(24), day(25)]);
      final repo = HealthRepository(gateway: gateway, store: FakeStore());

      final window = await repo.readEnergyWindow(now: now);

      expect(window.days.map((d) => d.day.day), [24, 25, 26]);
    });

    test('stamps when it synced, so a cached window can be dated', () async {
      final repo = HealthRepository(
        gateway: FakeGateway(energyDays: [day(26)]),
        store: FakeStore(),
      );

      expect((await repo.readEnergyWindow(now: now)).lastSynced, now);
    });

    test('caches the window it read', () async {
      final store = FakeStore();
      final repo = HealthRepository(
        gateway: FakeGateway(energyDays: [day(25), day(26)]),
        store: store,
      );

      await repo.readEnergyWindow(now: now);

      final cached = EnergyWindow.fromJsonString(
        await store.read(HealthRepository.energyWindowKey),
      );
      expect(cached, isNotNull);
      expect(cached!.days, hasLength(2));
    });
  });

  group('readEnergyWindow when the platform will not answer', () {
    test('falls back to the cached window rather than failing the screen',
        () async {
      final store = FakeStore();
      final warm = HealthRepository(
        gateway: FakeGateway(energyDays: [day(25, kcal: 500), day(26)]),
        store: store,
      );
      await warm.readEnergyWindow(now: now);

      // A second repository over the same store, with a gateway that now throws:
      // the shape of a later launch with health unavailable.
      final cold = HealthRepository(
        gateway: FakeGateway(throwOnRead: true),
        store: store,
      );
      final window = await cold.readEnergyWindow(now: now);

      expect(window.days, hasLength(2));
      expect(window.days.first.activeKcal, 500);
    });

    test('returns an empty window when there is nothing cached either',
        () async {
      final repo = HealthRepository(
        gateway: FakeGateway(throwOnRead: true),
        store: FakeStore(),
      );

      final window = await repo.readEnergyWindow(now: now);

      expect(window.days, isEmpty);
      // Empty, not usable: the projection must fall back to its own estimate
      // rather than treat this as a measured zero burn.
      expect(window.isUsable, isFalse);
      expect(window.meanActiveKcal, 0);
    });

    test('a corrupt cache blob reads as absent, not as a crash', () async {
      final store = FakeStore();
      await store.write(HealthRepository.energyWindowKey, '{not json');
      final repo = HealthRepository(
        gateway: FakeGateway(throwOnRead: true),
        store: store,
      );

      expect((await repo.readEnergyWindow(now: now)).days, isEmpty);
    });
  });

  group('re-consent for the new data type', () {
    test('an already-connected user from before active energy is asked again',
        () async {
      final store = FakeStore();
      // What a version-1 install left behind: connected, with no version stamp.
      await store.write(HealthRepository.enabledKey, 'true');
      final repo = HealthRepository(gateway: FakeGateway(), store: store);

      expect(await repo.needsReauthorization(), isTrue);
    });

    test('is not asked again once the grant covers the current type set',
        () async {
      final store = FakeStore();
      final repo = HealthRepository(gateway: FakeGateway(), store: store);

      await repo.requestEnable();

      expect(await repo.needsReauthorization(), isFalse);
      expect(
        await store.read(HealthRepository.authorizedTypesVersionKey),
        HealthRepository.authorizedTypesVersion.toString(),
      );
    });

    test('disable() clears the window and the version stamp, so reconnecting '
        'starts clean', () async {
      final store = FakeStore();
      final repo = HealthRepository(
        gateway: FakeGateway(energyDays: [day(26)]),
        store: store,
      );
      await repo.requestEnable();
      await repo.readEnergyWindow(now: now);

      await repo.disable();

      expect(await store.read(HealthRepository.energyWindowKey), isNull);
      expect(
          await store.read(HealthRepository.authorizedTypesVersionKey), isNull);
    });
  });

  group('EnergyWindow averages', () {
    test('averages over measured days, not over the calendar', () async {
      // Eleven unmeasured days and three real ones — the shape of a user who
      // wore a watch for part of the window.
      final window = EnergyWindow(days: [
        for (var d = 13; d <= 23; d++)
          DailyEnergy(day: DateTime(2026, 8, d), steps: 0, activeKcal: 0),
        day(24, kcal: 300),
        day(25, kcal: 400),
        day(26, kcal: 500),
      ]);

      // 400, not 400 × 3 / 14 ≈ 86.
      expect(window.meanActiveKcal, 400);
      expect(window.measuredDayCount, 3);
      expect(window.isUsable, isTrue);
    });

    test('two measured days is not enough to set a mean from', () {
      final window = EnergyWindow(days: [day(25), day(26)]);

      expect(window.isUsable, isFalse);
    });

    test('a day with steps but no energy still counts as measured', () {
      // Phone-only users get no active-energy figure at all; their step count is
      // the evidence that the day was recorded.
      final window = EnergyWindow(days: [
        day(24, steps: 8000, kcal: 0),
        day(25, steps: 7000, kcal: 0),
        day(26, steps: 9000, kcal: 0),
      ]);

      expect(window.measuredDayCount, 3);
      expect(window.meanActiveKcal, 0);
      expect(window.meanSteps, 8000);
    });
  });

  group('EnergyWindow parsing', () {
    test('survives a round trip through the cache', () {
      final original = EnergyWindow(
        days: [day(25, kcal: 350.5), day(26, kcal: 410)],
        lastSynced: now,
      );

      final restored = EnergyWindow.fromJsonString(original.toJsonString())!;

      expect(restored.days.map((d) => d.activeKcal), [350.5, 410]);
      expect(restored.days.map((d) => d.day), original.days.map((d) => d.day));
      expect(restored.lastSynced, now);
    });

    test('reads a number that was cached as a string', () {
      // Defensive: a platform channel that hands back stringified numbers must
      // not empty the window.
      final restored = EnergyWindow.fromJsonString(
        '{"days":[{"day":"2026-08-26T00:00:00.000","steps":"7000",'
        '"workoutMinutes":"30","activeKcal":"420.5"}]}',
      )!;

      expect(restored.days.single.steps, 7000);
      expect(restored.days.single.activeKcal, 420.5);
    });

    test('skips a day that is not a map rather than dropping the window', () {
      final restored = EnergyWindow.fromJsonString(
        '{"days":[42,{"day":"2026-08-26T00:00:00.000","steps":7000}]}',
      )!;

      expect(restored.days, hasLength(1));
      expect(restored.days.single.steps, 7000);
    });

    test('an absent or unparseable blob is null, not an exception', () {
      expect(EnergyWindow.fromJsonString(null), isNull);
      expect(EnergyWindow.fromJsonString(''), isNull);
      expect(EnergyWindow.fromJsonString('{not json'), isNull);
      expect(EnergyWindow.fromJsonString('[]'), isNull);
    });
  });
}
