import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/health/health_repository.dart';
import 'package:void_factor/models/energy_window.dart';
import 'package:void_factor/models/health_metrics.dart';

/// In-memory fake for the secure-storage seam.
class FakeStore implements HealthKeyValueStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

/// Fake gateway returning canned aggregates.
class FakeGateway implements HealthGateway {
  FakeGateway({
    this.steps = 0,
    this.waterMl = 0,
    this.workoutSeconds = 0,
    this.available = true,
    this.authorized = true,
    this.throwOnRead = false,
    this.energyDays = const [],
  });
  int steps;
  double waterMl;
  double workoutSeconds;
  bool available;
  bool authorized;
  bool throwOnRead;

  /// What [dailyEnergy] hands back, verbatim.
  List<DailyEnergy> energyDays;

  /// Ranges [dailyEnergy] was asked for, so a test can assert the window bounds.
  final List<({DateTime start, DateTime end})> energyRequests = [];

  @override
  Future<void> configure() async {}
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> requestAuthorization(List<Object> types) async => authorized;
  @override
  Future<int> totalSteps(DateTime start, DateTime end) async {
    if (throwOnRead) throw Exception('read failed');
    return steps;
  }

  @override
  Future<double> totalWaterMl(DateTime start, DateTime end) async {
    if (throwOnRead) throw Exception('read failed');
    return waterMl;
  }

  @override
  Future<double> totalWorkoutSeconds(DateTime start, DateTime end) async {
    if (throwOnRead) throw Exception('read failed');
    return workoutSeconds;
  }

  @override
  Future<List<DailyEnergy>> dailyEnergy(DateTime start, DateTime end) async {
    energyRequests.add((start: start, end: end));
    if (throwOnRead) throw Exception('read failed');
    return energyDays;
  }
}

void main() {
  group('HealthRepository', () {
    test('requestEnable() returns enabled and sets flag when authorized',
        () async {
      final store = FakeStore();
      final repo =
          HealthRepository(gateway: FakeGateway(authorized: true), store: store);
      final status = await repo.requestEnable();
      expect(status, HealthConnectionStatus.enabled);
      expect(await repo.isEnabled(), isTrue);
    });

    test('requestEnable() returns unavailable when store absent', () async {
      final repo = HealthRepository(
          gateway: FakeGateway(available: false), store: FakeStore());
      expect(await repo.requestEnable(), HealthConnectionStatus.unavailable);
    });

    test('read() aggregates today totals with ml->oz and sec->min conversions',
        () async {
      // 1183.0 ml / 29.5735 = 40.0 oz; 2700 s / 60 = 45 min.
      final repo = HealthRepository(
          gateway:
              FakeGateway(steps: 8432, waterMl: 1183.0, workoutSeconds: 2700),
          store: FakeStore());
      final m = await repo.read(now: DateTime(2026, 8, 2, 14, 45));
      expect(m.steps, 8432);
      expect(m.waterOz, closeTo(40.0, 0.1));
      expect(m.workoutMinutes, 45);
      expect(m.lastSynced, isNotNull);
    });

    test('read() writes the cache blob', () async {
      final store = FakeStore();
      final repo =
          HealthRepository(gateway: FakeGateway(steps: 100), store: store);
      await repo.read(now: DateTime(2026, 8, 2));
      expect(await store.read(HealthRepository.metricsKey), isNotNull);
    });

    test('read() failure falls back to cached blob', () async {
      final store = FakeStore();
      // Seed a cache.
      final good =
          HealthRepository(gateway: FakeGateway(steps: 500), store: store);
      await good.read(now: DateTime(2026, 8, 2));
      // Now a failing gateway must return the cached 500, not empty.
      final bad = HealthRepository(
          gateway: FakeGateway(throwOnRead: true), store: store);
      final m = await bad.read(now: DateTime(2026, 8, 2));
      expect(m.steps, 500);
    });

    test('read() failure with no cache returns empty', () async {
      final repo = HealthRepository(
          gateway: FakeGateway(throwOnRead: true), store: FakeStore());
      final m = await repo.read(now: DateTime(2026, 8, 2));
      expect(m.steps, 0);
      expect(m.waterOz, 0);
    });

    test('disable() clears both keys', () async {
      final store = FakeStore();
      final repo = HealthRepository(gateway: FakeGateway(), store: store);
      await repo.requestEnable();
      await repo.read(now: DateTime(2026, 8, 2));
      await repo.disable();
      expect(await store.read(HealthRepository.enabledKey), isNull);
      expect(await store.read(HealthRepository.metricsKey), isNull);
    });

    test('loadCached() returns empty when nothing cached', () async {
      final repo = HealthRepository(gateway: FakeGateway(), store: FakeStore());
      final m = await repo.loadCached();
      expect(m.steps, 0);
    });
  });
}
