import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:void_factor/app/health_providers.dart';
import 'package:void_factor/app/health_repository.dart';
import 'package:void_factor/app/health_observer_service.dart';
import 'package:void_factor/models/health_metrics.dart';

class _Never implements HealthGateway {
  @override
  dynamic noSuchMethod(Invocation i) async => throw UnimplementedError();
}

class _NullStore implements HealthKeyValueStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}

class StubRepo extends HealthRepository {
  StubRepo(this._cached, this._fresh, {this.readDelayMs = 0})
      : super(gateway: _Never(), store: _NullStore());
  final HealthMetrics _cached;
  final HealthMetrics _fresh;
  final int readDelayMs;
  int reads = 0;
  @override
  Future<HealthMetrics> loadCached() async => _cached;
  @override
  Future<HealthMetrics> read({DateTime? now}) async {
    reads++;
    if (readDelayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: readDelayMs));
    }
    return _fresh;
  }

  @override
  Future<bool> isEnabled() async => true;
}

class SilentObserver extends HealthObserverService {
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class _OrderedRepo extends HealthRepository {
  _OrderedRepo() : super(gateway: _Never(), store: _NullStore());
  int _counter = 0;
  int nextDelayMs = 0;
  @override
  Future<HealthMetrics> loadCached() async => HealthMetrics.empty();
  // Reported disabled so build()/_init() does NOT inject its own refresh() —
  // this test drives refresh() explicitly to isolate the token guard.
  @override
  Future<bool> isEnabled() async => false;
  @override
  Future<HealthMetrics> read({DateTime? now}) async {
    final id = ++_counter;
    await Future<void>.delayed(Duration(milliseconds: nextDelayMs));
    return HealthMetrics(steps: id, waterOz: 0, workoutMinutes: 0);
  }
}

void main() {
  test('controller seeds from cache then refreshes to fresh value', () async {
    final cached = HealthMetrics(steps: 100, waterOz: 8, workoutMinutes: 5);
    final fresh = HealthMetrics(steps: 8432, waterOz: 64, workoutMinutes: 45);
    // Delay the fresh read so the cache seed is observable in between.
    final repo = StubRepo(cached, fresh, readDelayMs: 30);
    final container = ProviderContainer(overrides: [
      healthRepositoryProvider.overrideWithValue(repo),
      healthObserverServiceProvider.overrideWithValue(SilentObserver()),
    ]);
    addTearDown(container.dispose);

    // Synchronous build() seed is empty (secure-storage load is async).
    expect(container.read(healthMetricsProvider).steps, 0);

    // After the async cache load but before the delayed fresh read.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(container.read(healthMetricsProvider).steps, 100);

    // After the fresh read resolves.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(container.read(healthMetricsProvider).steps, 8432);
    expect(repo.reads, greaterThanOrEqualTo(1));
  });

  test('refresh() monotonic guard: latest wins', () async {
    final repo = _OrderedRepo();
    final container = ProviderContainer(overrides: [
      healthRepositoryProvider.overrideWithValue(repo),
      healthObserverServiceProvider.overrideWithValue(SilentObserver()),
    ]);
    addTearDown(container.dispose);
    final ctrl = container.read(healthMetricsProvider.notifier);

    // Fire two refreshes; the slower-but-older one resolves last.
    repo.nextDelayMs = 40; // older, slow -> steps 1
    final a = ctrl.refresh();
    repo.nextDelayMs = 5; // newer, fast -> steps 2
    final b = ctrl.refresh();
    await Future.wait([a, b]);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // Newer (steps 2) must win even though older resolved afterwards.
    expect(container.read(healthMetricsProvider).steps, 2);
  });
}
