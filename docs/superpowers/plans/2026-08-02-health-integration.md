# Health Integration (Health Connect / HealthKit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display read-only daily Steps, Water, and Workout metrics from Health Connect (Android) / HealthKit (iOS) on the home screen, refreshed on open/resume/timer plus iOS background delivery and Android periodic background refresh, gated behind a user opt-in in Settings.

**Architecture:** The `health` package handles reads (permissions, type mapping, aggregation) on both platforms. A `HealthRepository` computes today's totals and caches them in secure storage. Riverpod providers (`healthRepositoryProvider`, `healthStatusProvider`, `healthMetricsProvider`) expose state; a `HealthMetricsController` orchestrates all refresh triggers with a monotonic-token guard. iOS background delivery is a thin Swift `HKObserverQuery` layer that signals Dart over an `EventChannel`; Android background refresh is a `workmanager` periodic task.

**Tech Stack:** Flutter 3.44, Dart, `flutter_riverpod` 3.x (Notifier API), `health` (carp-dk v13), `workmanager`, `flutter_secure_storage`, Swift (HealthKit), Android Health Connect manifest config.

## Global Constraints

- **Read-only:** never call any write/insert API on Health Connect / HealthKit.
- **Never persist health metrics to Firestore** — device-local secure storage only.
- **Disabled by default:** no health data is read until the user enables sync in Settings → Health Connect.
- **Secure-storage keys:** `health_enabled` (`"true"` when opted in), `health_metrics_json` (cached blob). Both cleared on logout in `SessionService.clearSession()`.
- **Units:** Steps = integer; Water = fl oz (`1 fl oz = 29.5735 ml`); Workout = whole minutes. All three are **today's totals**, local midnight → now.
- **Card copy:** Android subtitle `FROM HEALTH CONNECT`, iOS subtitle `FROM APPLE HEALTH`; dormant value `—`, dormant subtitle `CONNECT IN SETTINGS`; workout subtitle `MINUTES TODAY`; water subtitle `AS OF <lastSynced time>`.
- **Monotonic-token guard** on `refresh()` mirrors `AuthFlowNotifier._checkToken` (`session_provider.dart:207`) — a newer refresh always wins.
- **Store access discipline:** 15s timeout + try/catch, mirroring `ProfileRepository` (`profile_repository.dart:28`); on read failure fall back to the cached blob, else `HealthMetrics.empty()`.
- **Riverpod version:** use the `Notifier`/`NotifierProvider` API (project is on `flutter_riverpod` 3.x), matching `AuthFlowNotifier`.
- **Android background floor:** WorkManager minimum periodic interval is 15 min; the 4-min cadence is foreground-only. Do not attempt a sub-15-min periodic task.
- **Monolith styling:** new UI uses `MonolithCard`, `MonolithButton`, `MonolithTheme`, uppercase labels — match `edit_profile_screen.dart` / `settings_screen.dart`.

---

### Task 1: Add dependencies

**Files:**
- Modify: `pubspec.yaml:30-54` (dependencies block)

**Interfaces:**
- Consumes: nothing.
- Produces: `health` and `workmanager` importable in later tasks.

- [ ] **Step 1: Add the two dependencies**

In `pubspec.yaml`, under `dependencies:` (after `app_links: ^6.1.1`), add:

```yaml
  health: ^13.0.0
  workmanager: ^0.9.0+3
```

- [ ] **Step 2: Resolve**

Run: `flutter pub get`
Expected: resolves without version conflicts; `health` and `workmanager` appear in `pubspec.lock`.

- [ ] **Step 3: Verify import resolves**

Run: `dart -e "import 'package:health/health.dart';" 2>/dev/null || flutter pub deps | grep -E "health|workmanager"`
Expected: both packages listed.

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: add health and workmanager dependencies"
```

---

### Task 2: `HealthMetrics` model + `HealthConnectionStatus` enum

**Files:**
- Create: `lib/models/health_metrics.dart`
- Test: `test/health_metrics_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum HealthConnectionStatus { disabled, enabled, unavailable }`
  - `class HealthMetrics` with `final int steps; final double waterOz; final int workoutMinutes; final DateTime? lastSynced;`
  - `const HealthMetrics({required this.steps, required this.waterOz, required this.workoutMinutes, this.lastSynced});`
  - `factory HealthMetrics.empty()` → all zero, `lastSynced: null`.
  - `factory HealthMetrics.fromMap(Map<String, dynamic> map)` — defensive, never throws.
  - `Map<String, dynamic> toMap()` — `lastSynced` as ISO-8601 string or null.
  - `HealthMetrics copyWith({int? steps, double? waterOz, int? workoutMinutes, DateTime? lastSynced})`.
  - `String toJsonString()` / `static HealthMetrics? fromJsonString(String?)`.

- [ ] **Step 1: Write the failing tests**

Create `test/health_metrics_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/models/health_metrics.dart';

void main() {
  group('HealthMetrics', () {
    test('empty() is all zero with null lastSynced', () {
      final m = HealthMetrics.empty();
      expect(m.steps, 0);
      expect(m.waterOz, 0);
      expect(m.workoutMinutes, 0);
      expect(m.lastSynced, isNull);
    });

    test('toMap/fromMap round-trip with lastSynced set', () {
      final ts = DateTime.utc(2026, 8, 2, 14, 45);
      final m = HealthMetrics(
        steps: 8432, waterOz: 64.0, workoutMinutes: 45, lastSynced: ts);
      final back = HealthMetrics.fromMap(m.toMap());
      expect(back.steps, 8432);
      expect(back.waterOz, 64.0);
      expect(back.workoutMinutes, 45);
      expect(back.lastSynced, ts);
    });

    test('fromMap with missing keys defaults to zero/null', () {
      final m = HealthMetrics.fromMap({});
      expect(m.steps, 0);
      expect(m.waterOz, 0);
      expect(m.workoutMinutes, 0);
      expect(m.lastSynced, isNull);
    });

    test('fromMap tolerates mixed numeric encodings (String vs num)', () {
      final m = HealthMetrics.fromMap({
        'steps': '8432',
        'waterOz': '64.0',
        'workoutMinutes': 45,
      });
      expect(m.steps, 8432);
      expect(m.waterOz, 64.0);
      expect(m.workoutMinutes, 45);
    });

    test('fromJsonString(null) returns null', () {
      expect(HealthMetrics.fromJsonString(null), isNull);
    });

    test('toJsonString/fromJsonString round-trip', () {
      final m = HealthMetrics(
        steps: 100, waterOz: 8.0, workoutMinutes: 10,
        lastSynced: DateTime.utc(2026, 1, 1));
      final back = HealthMetrics.fromJsonString(m.toJsonString());
      expect(back!.steps, 100);
      expect(back.lastSynced, DateTime.utc(2026, 1, 1));
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/health_metrics_test.dart`
Expected: FAIL — `health_metrics.dart` does not exist / `HealthMetrics` undefined.

- [ ] **Step 3: Write the model**

Create `lib/models/health_metrics.dart`:

```dart
import 'dart:convert';

/// Whether the user has connected a platform health store.
enum HealthConnectionStatus { disabled, enabled, unavailable }

/// Read-only snapshot of today's health metrics (local midnight → now).
///
/// Device-sourced and never written to Firestore; the only persistence is the
/// encrypted local cache blob (`health_metrics_json`) for instant launch
/// display. [fromMap] is defensive — it never throws on missing or
/// mixed-encoding data — so a malformed cache degrades to defaults.
class HealthMetrics {
  const HealthMetrics({
    required this.steps,
    required this.waterOz,
    required this.workoutMinutes,
    this.lastSynced,
  });

  final int steps;
  final double waterOz;
  final int workoutMinutes;
  final DateTime? lastSynced;

  factory HealthMetrics.empty() =>
      const HealthMetrics(steps: 0, waterOz: 0, workoutMinutes: 0);

  factory HealthMetrics.fromMap(Map<String, dynamic> map) {
    return HealthMetrics(
      steps: _asInt(map['steps']),
      waterOz: _asDouble(map['waterOz']),
      workoutMinutes: _asInt(map['workoutMinutes']),
      lastSynced: _asDate(map['lastSynced']),
    );
  }

  Map<String, dynamic> toMap() => {
        'steps': steps,
        'waterOz': waterOz,
        'workoutMinutes': workoutMinutes,
        'lastSynced': lastSynced?.toIso8601String(),
      };

  HealthMetrics copyWith({
    int? steps,
    double? waterOz,
    int? workoutMinutes,
    DateTime? lastSynced,
  }) {
    return HealthMetrics(
      steps: steps ?? this.steps,
      waterOz: waterOz ?? this.waterOz,
      workoutMinutes: workoutMinutes ?? this.workoutMinutes,
      lastSynced: lastSynced ?? this.lastSynced,
    );
  }

  String toJsonString() => jsonEncode(toMap());

  static HealthMetrics? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return HealthMetrics.fromMap(decoded);
    } catch (_) {}
    return null;
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.round() ?? 0;
    return 0;
  }

  static double _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _asDate(Object? v) {
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/health_metrics_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/models/health_metrics.dart test/health_metrics_test.dart
git commit -m "feat: add HealthMetrics model and HealthConnectionStatus enum"
```

---

### Task 3: `HealthRepository`

**Files:**
- Create: `lib/app/health_repository.dart`
- Test: `test/health_repository_test.dart`

**Interfaces:**
- Consumes: `HealthMetrics`, `HealthConnectionStatus` (Task 2); `Health` from `package:health/health.dart`; `FlutterSecureStorage`.
- Produces:
  - `class HealthRepository` with constructor `HealthRepository({Health? health, FlutterSecureStorage? secureStorage})`.
  - `static const List<HealthDataType> readTypes` = `[STEPS, WATER, WORKOUT]`.
  - `static const String enabledKey = 'health_enabled';`
  - `static const String metricsKey = 'health_metrics_json';`
  - `Future<HealthConnectionStatus> requestEnable()`.
  - `Future<bool> isEnabled()`.
  - `Future<void> disable()`.
  - `Future<HealthMetrics> read({DateTime? now})` — `now` injectable for tests.
  - `Future<HealthMetrics> loadCached()`.
  - `final healthRepositoryProvider = Provider<HealthRepository>((ref) => HealthRepository());`

**Note on the `health` API surface (v13):** wrap only these calls so the class is mockable via a thin seam — `Health().configure()`, `Health().requestAuthorization(types)`, `Health().isHealthConnectAvailable()` (Android), `Health().getHealthDataFromTypes(types: ..., startTime: ..., endTime: ...)`, `Health().getTotalStepsInInterval(start, end)`. Because `Health` is a plugin singleton that is awkward to mock directly, introduce a minimal seam interface `HealthGateway` in this file that the repository depends on, with a `HealthGatewayImpl` wrapping the real `Health()`. Tests inject a fake `HealthGateway`.

- [ ] **Step 1: Write the failing tests**

Create `test/health_repository_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/app/health_repository.dart';
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
  });
  int steps;
  double waterMl;
  double workoutSeconds;
  bool available;
  bool authorized;
  bool throwOnRead;

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
}

void main() {
  group('HealthRepository', () {
    test('requestEnable() returns enabled and sets flag when authorized', () async {
      final store = FakeStore();
      final repo = HealthRepository(gateway: FakeGateway(authorized: true), store: store);
      final status = await repo.requestEnable();
      expect(status, HealthConnectionStatus.enabled);
      expect(await repo.isEnabled(), isTrue);
    });

    test('requestEnable() returns unavailable when store absent', () async {
      final repo = HealthRepository(
        gateway: FakeGateway(available: false), store: FakeStore());
      expect(await repo.requestEnable(), HealthConnectionStatus.unavailable);
    });

    test('read() aggregates today totals with ml->oz and sec->min conversions', () async {
      // 1183.0 ml / 29.5735 = 40.0 oz; 2700 s / 60 = 45 min.
      final repo = HealthRepository(
        gateway: FakeGateway(steps: 8432, waterMl: 1183.0, workoutSeconds: 2700),
        store: FakeStore());
      final m = await repo.read(now: DateTime(2026, 8, 2, 14, 45));
      expect(m.steps, 8432);
      expect(m.waterOz, closeTo(40.0, 0.1));
      expect(m.workoutMinutes, 45);
      expect(m.lastSynced, isNotNull);
    });

    test('read() writes the cache blob', () async {
      final store = FakeStore();
      final repo = HealthRepository(
        gateway: FakeGateway(steps: 100), store: store);
      await repo.read(now: DateTime(2026, 8, 2));
      expect(await store.read(HealthRepository.metricsKey), isNotNull);
    });

    test('read() failure falls back to cached blob', () async {
      final store = FakeStore();
      // Seed a cache.
      final good = HealthRepository(gateway: FakeGateway(steps: 500), store: store);
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/health_repository_test.dart`
Expected: FAIL — `health_repository.dart` / `HealthGateway` / `HealthKeyValueStore` undefined.

- [ ] **Step 3: Write the repository with its seams**

Create `lib/app/health_repository.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:health/health.dart';
import '../models/health_metrics.dart';

const double _mlPerFlOz = 29.5735;
const Duration _timeout = Duration(seconds: 15);

/// Minimal key-value seam so tests avoid the platform secure-storage channel.
abstract class HealthKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureHealthStore implements HealthKeyValueStore {
  SecureHealthStore([FlutterSecureStorage? s])
      : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// Seam over the `health` plugin singleton so the repository is unit-testable.
abstract class HealthGateway {
  Future<void> configure();
  Future<bool> isAvailable();
  Future<bool> requestAuthorization(List<Object> types);
  Future<int> totalSteps(DateTime start, DateTime end);
  Future<double> totalWaterMl(DateTime start, DateTime end);
  Future<double> totalWorkoutSeconds(DateTime start, DateTime end);
}

/// Real implementation backed by `package:health`.
class HealthGatewayImpl implements HealthGateway {
  final Health _health = Health();

  static const List<HealthDataType> types = [
    HealthDataType.STEPS,
    HealthDataType.WATER,
    HealthDataType.WORKOUT,
  ];

  @override
  Future<void> configure() => _health.configure();

  @override
  Future<bool> isAvailable() async {
    // HealthKit is always present on iOS 16+; Health Connect may be absent.
    try {
      return await _health.isHealthConnectAvailable();
    } catch (_) {
      return true; // iOS path: treat as available.
    }
  }

  @override
  Future<bool> requestAuthorization(List<Object> types) {
    return _health.requestAuthorization(
      types.cast<HealthDataType>(),
      permissions: List.filled(types.length, HealthDataAccess.READ),
    );
  }

  @override
  Future<int> totalSteps(DateTime start, DateTime end) async {
    final s = await _health.getTotalStepsInInterval(start, end);
    return s ?? 0;
  }

  @override
  Future<double> totalWaterMl(DateTime start, DateTime end) async {
    final points = await _health.getHealthDataFromTypes(
      types: [HealthDataType.WATER], startTime: start, endTime: end);
    double ml = 0;
    for (final p in points) {
      final v = p.value;
      if (v is NumericHealthValue) {
        // WATER is reported in litres by the plugin; convert to ml.
        ml += v.numericValue.toDouble() * 1000.0;
      }
    }
    return ml;
  }

  @override
  Future<double> totalWorkoutSeconds(DateTime start, DateTime end) async {
    final points = await _health.getHealthDataFromTypes(
      types: [HealthDataType.WORKOUT], startTime: start, endTime: end);
    double seconds = 0;
    for (final p in points) {
      seconds += p.dateTo.difference(p.dateFrom).inSeconds;
    }
    return seconds;
  }
}

/// Dart-facing single source of truth for read-only health metrics.
class HealthRepository {
  HealthRepository({HealthGateway? gateway, HealthKeyValueStore? store})
      : _gateway = gateway ?? HealthGatewayImpl(),
        _store = store ?? SecureHealthStore();

  final HealthGateway _gateway;
  final HealthKeyValueStore _store;

  static const String enabledKey = 'health_enabled';
  static const String metricsKey = 'health_metrics_json';

  Future<HealthConnectionStatus> requestEnable() async {
    try {
      await _gateway.configure();
      if (!await _gateway.isAvailable()) {
        return HealthConnectionStatus.unavailable;
      }
      final granted = await _gateway
          .requestAuthorization(HealthGatewayImpl.types)
          .timeout(_timeout);
      if (!granted) return HealthConnectionStatus.disabled;
      await _store.write(enabledKey, 'true');
      return HealthConnectionStatus.enabled;
    } catch (_) {
      return HealthConnectionStatus.disabled;
    }
  }

  Future<bool> isEnabled() async => (await _store.read(enabledKey)) == 'true';

  Future<void> disable() async {
    await _store.delete(enabledKey);
    await _store.delete(metricsKey);
  }

  Future<HealthMetrics> read({DateTime? now}) async {
    final end = now ?? DateTime.now();
    final start = DateTime(end.year, end.month, end.day);
    try {
      final steps = await _gateway.totalSteps(start, end).timeout(_timeout);
      final ml = await _gateway.totalWaterMl(start, end).timeout(_timeout);
      final secs = await _gateway.totalWorkoutSeconds(start, end).timeout(_timeout);
      final metrics = HealthMetrics(
        steps: steps,
        waterOz: ml / _mlPerFlOz,
        workoutMinutes: (secs / 60).round(),
        lastSynced: end,
      );
      await _store.write(metricsKey, metrics.toJsonString());
      return metrics;
    } catch (_) {
      return await loadCached();
    }
  }

  Future<HealthMetrics> loadCached() async {
    final raw = await _store.read(metricsKey);
    return HealthMetrics.fromJsonString(raw) ?? HealthMetrics.empty();
  }
}

final healthRepositoryProvider =
    Provider<HealthRepository>((ref) => HealthRepository());
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/health_repository_test.dart`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/app/health_repository.dart test/health_repository_test.dart
git commit -m "feat: add HealthRepository with mockable health/storage seams"
```

---

### Task 4: iOS observer Dart service (`EventChannel`)

**Files:**
- Create: `lib/app/health_observer_service.dart`

**Interfaces:**
- Consumes: nothing (pure platform-channel wrapper).
- Produces:
  - `class HealthObserverService` with `Stream<void> get changes`.
  - `Future<void> start()` — invokes the native `startObservers` method.
  - `Future<void> stop()` — invokes native `stopObservers`.
  - Channel names: `EventChannel('app/health_observer/events')`, `MethodChannel('app/health_observer')`.
  - `final healthObserverServiceProvider = Provider<HealthObserverService>((ref) => HealthObserverService());`

This task is the Dart half only; the Swift half is Task 8. Kept as one small unit so the controller (Task 5) can depend on a stable Dart interface regardless of native progress. No unit test — it is a thin channel wrapper with no logic (channels can't be exercised in `flutter test` without a native host). It will be verified end-to-end on device.

- [ ] **Step 1: Write the service**

Create `lib/app/health_observer_service.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dart side of the iOS HealthKit observer. The native layer registers
/// HKObserverQuery + background delivery and emits a data-changed ping (no
/// payload) on the event channel; this service surfaces those as a `Stream`.
///
/// No-op on Android — the method channel simply has no handler there, and
/// [start]/[stop] swallow the resulting MissingPluginException.
class HealthObserverService {
  static const EventChannel _events =
      EventChannel('app/health_observer/events');
  static const MethodChannel _methods = MethodChannel('app/health_observer');

  Stream<void>? _stream;

  Stream<void> get changes =>
      _stream ??= _events.receiveBroadcastStream().map((_) {});

  Future<void> start() async {
    try {
      await _methods.invokeMethod('startObservers');
    } on MissingPluginException {
      // Android / unsupported platform — nothing to start.
    } on PlatformException {
      // Permission not yet granted; ignored, retried on next enable.
    }
  }

  Future<void> stop() async {
    try {
      await _methods.invokeMethod('stopObservers');
    } on MissingPluginException {
      // Android / unsupported platform — nothing to stop.
    }
  }
}

final healthObserverServiceProvider =
    Provider<HealthObserverService>((ref) => HealthObserverService());
```

- [ ] **Step 2: Verify it analyzes clean**

Run: `flutter analyze lib/app/health_observer_service.dart`
Expected: No issues.

- [ ] **Step 3: Commit**

```bash
git add lib/app/health_observer_service.dart
git commit -m "feat: add Dart HealthObserverService channel wrapper"
```

---

### Task 5: Providers + `HealthMetricsController`

**Files:**
- Create: `lib/app/health_providers.dart`
- Test: `test/health_controller_test.dart`

**Interfaces:**
- Consumes: `healthRepositoryProvider`, `HealthRepository` (Task 3); `healthObserverServiceProvider`, `HealthObserverService` (Task 4); `HealthMetrics`, `HealthConnectionStatus` (Task 2).
- Produces:
  - `class HealthStatusNotifier extends Notifier<HealthConnectionStatus>` with `Future<void> refreshStatus()`, `Future<HealthConnectionStatus> enable()`, `Future<void> disable()`.
  - `final healthStatusProvider = NotifierProvider<HealthStatusNotifier, HealthConnectionStatus>(...)`.
  - `class HealthMetricsController extends Notifier<HealthMetrics>` with `Future<void> refresh()`, `void startAutoRefresh()`, `void stopAutoRefresh()`.
  - `final healthMetricsProvider = NotifierProvider<HealthMetricsController, HealthMetrics>(...)`.
  - Foreground timer interval constant: `const Duration healthRefreshInterval = Duration(minutes: 4);`

- [ ] **Step 1: Write the failing tests**

Create `test/health_controller_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:void_factor/app/health_providers.dart';
import 'package:void_factor/app/health_repository.dart';
import 'package:void_factor/app/health_observer_service.dart';
import 'package:void_factor/models/health_metrics.dart';

class StubRepo extends HealthRepository {
  StubRepo(this._cached, this._fresh) : super(gateway: _Never(), store: _NullStore());
  final HealthMetrics _cached;
  final HealthMetrics _fresh;
  int reads = 0;
  @override
  Future<HealthMetrics> loadCached() async => _cached;
  @override
  Future<HealthMetrics> read({DateTime? now}) async {
    reads++;
    return _fresh;
  }
  @override
  Future<bool> isEnabled() async => true;
}

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

class SilentObserver extends HealthObserverService {
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

void main() {
  test('controller seeds from cache then refreshes to fresh value', () async {
    final cached = HealthMetrics(steps: 100, waterOz: 8, workoutMinutes: 5);
    final fresh = HealthMetrics(steps: 8432, waterOz: 64, workoutMinutes: 45);
    final repo = StubRepo(cached, fresh);
    final container = ProviderContainer(overrides: [
      healthRepositoryProvider.overrideWithValue(repo),
      healthObserverServiceProvider.overrideWithValue(SilentObserver()),
    ]);
    addTearDown(container.dispose);

    // Initial read = cache seed.
    final first = container.read(healthMetricsProvider);
    expect(first.steps, 100);

    // Let the async refresh() kicked off in build() settle.
    await Future<void>.delayed(const Duration(milliseconds: 10));
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
    repo.nextDelayMs = 5;  // newer, fast -> steps 2
    final b = ctrl.refresh();
    await Future.wait([a, b]);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // Newer (steps 2) must win even though older resolved afterwards.
    expect(container.read(healthMetricsProvider).steps, 2);
  });
}

class _OrderedRepo extends HealthRepository {
  _OrderedRepo() : super(gateway: _Never(), store: _NullStore());
  int _counter = 0;
  int nextDelayMs = 0;
  @override
  Future<HealthMetrics> loadCached() async => HealthMetrics.empty();
  @override
  Future<bool> isEnabled() async => true;
  @override
  Future<HealthMetrics> read({DateTime? now}) async {
    final id = ++_counter;
    await Future<void>.delayed(Duration(milliseconds: nextDelayMs));
    return HealthMetrics(steps: id, waterOz: 0, workoutMinutes: 0);
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/health_controller_test.dart`
Expected: FAIL — `health_providers.dart` undefined.

- [ ] **Step 3: Write the providers + controller**

Create `lib/app/health_providers.dart`:

```dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/health_metrics.dart';
import 'health_repository.dart';
import 'health_observer_service.dart';

/// Foreground re-read cadence (matches the product "every 4 min" requirement).
const Duration healthRefreshInterval = Duration(minutes: 4);

/// Tracks whether health sync is connected. Read on build from the persisted
/// flag; mutated by the Settings screen.
class HealthStatusNotifier extends Notifier<HealthConnectionStatus> {
  @override
  HealthConnectionStatus build() {
    _load();
    return HealthConnectionStatus.disabled;
  }

  Future<void> _load() async {
    final repo = ref.read(healthRepositoryProvider);
    if (await repo.isEnabled()) {
      state = HealthConnectionStatus.enabled;
    }
  }

  Future<void> refreshStatus() => _load();

  Future<HealthConnectionStatus> enable() async {
    final repo = ref.read(healthRepositoryProvider);
    final status = await repo.requestEnable();
    state = status;
    if (status == HealthConnectionStatus.enabled) {
      final ctrl = ref.read(healthMetricsProvider.notifier);
      ctrl.startAutoRefresh();
      await ctrl.refresh();
    }
    return status;
  }

  Future<void> disable() async {
    final repo = ref.read(healthRepositoryProvider);
    await repo.disable();
    ref.read(healthMetricsProvider.notifier).stopAutoRefresh();
    state = HealthConnectionStatus.disabled;
  }
}

final healthStatusProvider =
    NotifierProvider<HealthStatusNotifier, HealthConnectionStatus>(
        HealthStatusNotifier.new);

/// Orchestrates every refresh trigger for the three home cards. State is the
/// current [HealthMetrics]; seeded from cache on build for an instant launch.
class HealthMetricsController extends Notifier<HealthMetrics> {
  Timer? _timer;
  StreamSubscription<void>? _observerSub;
  // Monotonic token: a newer refresh() always supersedes an older one, so an
  // out-of-order resolution can never overwrite fresher data.
  int _token = 0;

  @override
  HealthMetrics build() {
    ref.onDispose(() {
      _timer?.cancel();
      _observerSub?.cancel();
    });
    _init();
    return HealthMetrics.empty();
  }

  Future<void> _init() async {
    final repo = ref.read(healthRepositoryProvider);
    state = await repo.loadCached();
    if (await repo.isEnabled()) {
      startAutoRefresh();
      await refresh();
    }
  }

  Future<void> refresh() async {
    final repo = ref.read(healthRepositoryProvider);
    final token = ++_token;
    final metrics = await repo.read();
    if (token != _token) return; // A newer refresh() started; let it win.
    state = metrics;
  }

  void startAutoRefresh() {
    _timer?.cancel();
    _timer = Timer.periodic(healthRefreshInterval, (_) => refresh());
    _observerSub?.cancel();
    final observer = ref.read(healthObserverServiceProvider);
    observer.start();
    _observerSub = observer.changes.listen((_) => refresh());
  }

  void stopAutoRefresh() {
    _timer?.cancel();
    _timer = null;
    _observerSub?.cancel();
    _observerSub = null;
    ref.read(healthObserverServiceProvider).stop();
  }
}

final healthMetricsProvider =
    NotifierProvider<HealthMetricsController, HealthMetrics>(
        HealthMetricsController.new);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/health_controller_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/app/health_providers.dart test/health_controller_test.dart
git commit -m "feat: add health providers and refresh-orchestrating controller"
```

---

### Task 6: Wire dashboard cards + app-resume refresh + logout teardown

**Files:**
- Modify: `lib/screens/dashboard/dashboard_screen.dart:120-165` (three cards)
- Modify: `lib/app/app.dart:15-25` (add lifecycle listener)
- Modify: `lib/app/session_provider.dart:36-44` (`clearSession()` clears health keys)

**Interfaces:**
- Consumes: `healthMetricsProvider`, `healthStatusProvider` (Task 5); `HealthRepository.enabledKey` / `metricsKey` (Task 3).
- Produces: nothing consumed downstream.

- [ ] **Step 1: Wire the three dashboard cards**

In `lib/screens/dashboard/dashboard_screen.dart`, add imports at the top (after existing imports):

```dart
import 'dart:io' show Platform;
import '../../app/health_providers.dart';
import '../../models/health_metrics.dart';
```

In `build`, after `final user = ref.watch(authStateProvider).value;`, add:

```dart
    final metrics = ref.watch(healthMetricsProvider);
    final healthStatus = ref.watch(healthStatusProvider);
    final connected = healthStatus == HealthConnectionStatus.enabled;
```

Replace the Steps card (`dashboard_screen.dart:124-129`) with:

```dart
                          child: MonolithStatCard(
                            title: 'Steps',
                            value: connected ? _formatInt(metrics.steps) : '—',
                            subtitle: connected
                                ? (Platform.isIOS
                                    ? 'From Apple Health'
                                    : 'From Health Connect')
                                : 'Connect in Settings',
                            icon: Icons.directions_walk,
                          ),
```

Replace the Workout card (`dashboard_screen.dart:133-139`) with:

```dart
                          child: MonolithStatCard(
                            title: 'Workout Mins',
                            value: connected
                                ? metrics.workoutMinutes.toString()
                                : '—',
                            subtitle:
                                connected ? 'Minutes Today' : 'Connect in Settings',
                            icon: Icons.fitness_center,
                            inverted: true,
                          ),
```

Replace the Water card (`dashboard_screen.dart:147-152`) with:

```dart
                          child: MonolithStatCard(
                            title: 'Water',
                            value: connected
                                ? '${metrics.waterOz.round()} oz'
                                : '—',
                            subtitle: connected
                                ? _syncedSubtitle(metrics.lastSynced)
                                : 'Connect in Settings',
                            icon: Icons.water_drop,
                          ),
```

Add these helpers to `_DashboardScreenState` (after `_buildQuickAction`):

```dart
  String _formatInt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  String _syncedSubtitle(DateTime? ts) {
    if (ts == null) return 'Not Yet Synced';
    final h = ts.hour % 12 == 0 ? 12 : ts.hour % 12;
    final m = ts.minute.toString().padLeft(2, '0');
    final ap = ts.hour < 12 ? 'AM' : 'PM';
    return 'As of $h:$m $ap';
  }
```

- [ ] **Step 2: Add the app-resume refresh listener**

In `lib/app/app.dart`, change the class to observe lifecycle. Replace the `_MonolithAppState` declaration and `initState` (`app.dart:15-25`) with:

```dart
class _MonolithAppState extends ConsumerState<MonolithApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(linkVerificationServiceProvider).init(_navigatorKey);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(healthMetricsProvider.notifier).refresh();
    }
  }
```

Add the import at the top of `app.dart`:

```dart
import 'health_providers.dart';
```

- [ ] **Step 3: Clear health keys on logout**

In `lib/app/session_provider.dart`, inside `clearSession()` (`session_provider.dart:36-44`), add before `await _profileRepository.clearLocal();`:

```dart
    await _secureStorage.delete(key: 'health_enabled');
    await _secureStorage.delete(key: 'health_metrics_json');
```

- [ ] **Step 4: Analyze + run the full suite**

Run: `flutter analyze && flutter test`
Expected: No analyzer issues; all tests pass (existing smoke test + Tasks 2/3/5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/screens/dashboard/dashboard_screen.dart lib/app/app.dart lib/app/session_provider.dart
git commit -m "feat: wire dashboard cards to health metrics, refresh on resume, clear on logout"
```

---

### Task 7: Settings → Health Connect screen + route + tile

**Files:**
- Create: `lib/screens/settings/health_connect_screen.dart`
- Modify: `lib/app/routes.dart:11-49` (import + const + route entry)
- Modify: `lib/screens/settings/settings_screen.dart:204-209` (wire the tile)

**Interfaces:**
- Consumes: `healthStatusProvider`, `healthMetricsProvider` (Task 5); `HealthConnectionStatus` (Task 2); `MonolithCard`, `MonolithButton`, `MonolithTheme`.
- Produces: route `/health-connect`, `AppRoutes.healthConnect`.

- [ ] **Step 1: Create the screen**

Create `lib/screens/settings/health_connect_screen.dart`:

```dart
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_button.dart';
import '../../app/health_providers.dart';
import '../../models/health_metrics.dart';

class HealthConnectScreen extends ConsumerStatefulWidget {
  const HealthConnectScreen({super.key});

  @override
  ConsumerState<HealthConnectScreen> createState() =>
      _HealthConnectScreenState();
}

class _HealthConnectScreenState extends ConsumerState<HealthConnectScreen> {
  bool _busy = false;

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    final notifier = ref.read(healthStatusProvider.notifier);
    if (on) {
      final status = await notifier.enable();
      if (mounted && status == HealthConnectionStatus.unavailable) {
        _snack(Platform.isIOS
            ? 'Health data unavailable on this device'
            : 'Install Health Connect to enable sync');
      } else if (mounted && status == HealthConnectionStatus.disabled) {
        _snack('Permission denied');
      }
    } else {
      await notifier.disable();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _resync() async {
    setState(() => _busy = true);
    await ref.read(healthMetricsProvider.notifier).refresh();
    if (mounted) {
      setState(() => _busy = false);
      _snack('Re-synced');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(healthStatusProvider);
    final metrics = ref.watch(healthMetricsProvider);
    final connected = status == HealthConnectionStatus.enabled;
    final unavailable = status == HealthConnectionStatus.unavailable;

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Top Bar ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: const BoxDecoration(
                color: MonolithTheme.surface,
                border: Border(
                  bottom: BorderSide(
                    color: MonolithTheme.primary,
                    width: MonolithTheme.borderWidth,
                  ),
                ),
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: MonolithTheme.containerDecoration,
                      child: const Icon(Icons.arrow_back,
                          color: MonolithTheme.primary, size: 22),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text('HEALTH CONNECT', style: MonolithTheme.headlineLarge),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Enable toggle ──
                    MonolithCard(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('SYNC HEALTH DATA',
                                    style: MonolithTheme.labelLarge),
                                const SizedBox(height: 4),
                                Text(
                                  unavailable
                                      ? (Platform.isIOS
                                          ? 'HEALTH DATA UNAVAILABLE'
                                          : 'INSTALL HEALTH CONNECT')
                                      : 'STEPS · WATER · WORKOUT (READ-ONLY)',
                                  style: MonolithTheme.labelSmall.copyWith(
                                    color: MonolithTheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: connected,
                            onChanged: (_busy || unavailable) ? null : _toggle,
                            activeColor: MonolithTheme.primary,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Per-type status ──
                    Text('DATA TYPES', style: MonolithTheme.headlineMedium),
                    const SizedBox(height: 16),
                    _statusRow('STEPS', connected),
                    const SizedBox(height: 8),
                    _statusRow('WATER', connected),
                    const SizedBox(height: 8),
                    _statusRow('WORKOUT', connected),
                    const SizedBox(height: 24),

                    // ── Last synced ──
                    Text(
                      _lastSyncedLabel(metrics.lastSynced),
                      style: MonolithTheme.labelSmall.copyWith(
                        color: MonolithTheme.outline,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Re-sync ──
                    MonolithButton(
                      label: _busy ? 'WORKING…' : 'RE-SYNC NOW',
                      onPressed: (connected && !_busy) ? _resync : null,
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(String label, bool granted) {
    return MonolithCard(
      hasShadow: false,
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: MonolithTheme.labelLarge),
          Text(
            granted ? 'GRANTED' : 'NOT GRANTED',
            style: MonolithTheme.labelMedium.copyWith(
              color: granted ? MonolithTheme.primary : MonolithTheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  String _lastSyncedLabel(DateTime? ts) {
    if (ts == null) return 'NEVER SYNCED';
    final h = ts.hour % 12 == 0 ? 12 : ts.hour % 12;
    final m = ts.minute.toString().padLeft(2, '0');
    final ap = ts.hour < 12 ? 'AM' : 'PM';
    return 'LAST SYNCED: $h:$m $ap';
  }
}
```

- [ ] **Step 2: Add the route**

In `lib/app/routes.dart`, add the import (after line 12):

```dart
import '../screens/settings/health_connect_screen.dart';
```

Add the const (after `goalsDiet`, line 31):

```dart
  static const String healthConnect = '/health-connect';
```

Add the route entry (after `goalsDiet:` line, ~48):

```dart
        healthConnect: (_) => const HealthConnectScreen(),
```

- [ ] **Step 3: Wire the settings tile**

In `lib/screens/settings/settings_screen.dart`, replace the HEALTH CONNECT tile's no-op callback (`settings_screen.dart:204-209`):

```dart
                    _buildSettingsTile(
                      Icons.health_and_safety_outlined,
                      'HEALTH CONNECT',
                      'Sync with health services',
                      () => Navigator.pushNamed(context, '/health-connect'),
                    ),
```

- [ ] **Step 4: Analyze + full suite**

Run: `flutter analyze && flutter test`
Expected: No analyzer issues; all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/settings/health_connect_screen.dart lib/app/routes.dart lib/screens/settings/settings_screen.dart
git commit -m "feat: add Health Connect settings screen, route, and tile wiring"
```

---

### Task 8: iOS native — HealthKit entitlements, Info.plist, Swift observer

**Files:**
- Create: `ios/Runner/HealthObserver.swift`
- Modify: `ios/Runner/AppDelegate.swift` (register the channels)
- Modify: `ios/Runner/Info.plist` (usage description)
- Modify: `ios/Runner/Runner.entitlements` (HealthKit + background delivery)

**Interfaces:**
- Consumes: channel names from Task 4 — `app/health_observer` (method), `app/health_observer/events` (event).
- Produces: native observer that pings Dart on HealthKit changes.

- [ ] **Step 1: Add the usage description to Info.plist**

In `ios/Runner/Info.plist`, add inside the top-level `<dict>`:

```xml
	<key>NSHealthShareUsageDescription</key>
	<string>MONOLITH reads your steps, water, and workout data to show your daily activity.</string>
```

- [ ] **Step 2: Add HealthKit entitlements**

In `ios/Runner/Runner.entitlements`, add inside the `<dict>`:

```xml
	<key>com.apple.developer.healthkit</key>
	<true/>
	<key>com.apple.developer.healthkit.access</key>
	<array/>
	<key>com.apple.developer.healthkit.background-delivery</key>
	<true/>
```

- [ ] **Step 3: Write the Swift observer**

Create `ios/Runner/HealthObserver.swift`:

```swift
import Foundation
import HealthKit
import Flutter

/// Registers HKObserverQuery + background delivery for steps, water, and
/// workouts, and emits a (payload-free) "changed" event to Dart whenever
/// HealthKit reports new data. The Dart side responds by re-reading totals.
class HealthObserver: NSObject, FlutterStreamHandler {
  private let store = HKHealthStore()
  private var eventSink: FlutterEventSink?
  private var queries: [HKObserverQuery] = []

  private var sampleTypes: [HKSampleType] {
    var types: [HKSampleType] = []
    if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
      types.append(steps)
    }
    if let water = HKObjectType.quantityType(forIdentifier: .dietaryWater) {
      types.append(water)
    }
    types.append(HKObjectType.workoutType())
    return types
  }

  func start() {
    guard HKHealthStore.isHealthDataAvailable() else { return }
    stop()
    for type in sampleTypes {
      let query = HKObserverQuery(sampleType: type, predicate: nil) {
        [weak self] _, completionHandler, _ in
        DispatchQueue.main.async { self?.eventSink?(nil) }
        completionHandler()
      }
      store.execute(query)
      queries.append(query)
      store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }
  }

  func stop() {
    for q in queries { store.stop(q) }
    queries.removeAll()
    for type in sampleTypes {
      store.disableBackgroundDelivery(for: type) { _, _ in }
    }
  }

  // FlutterStreamHandler
  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
```

- [ ] **Step 4: Register the channels in AppDelegate**

In `ios/Runner/AppDelegate.swift`, inside `application(_:didFinishLaunchingWithOptions:)` before `return super....`, add:

```swift
    let controller = window?.rootViewController as! FlutterViewController
    let healthObserver = HealthObserver()
    self.healthObserver = healthObserver

    let eventChannel = FlutterEventChannel(
      name: "app/health_observer/events", binaryMessenger: controller.binaryMessenger)
    eventChannel.setStreamHandler(healthObserver)

    let methodChannel = FlutterMethodChannel(
      name: "app/health_observer", binaryMessenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "startObservers": healthObserver.start(); result(nil)
      case "stopObservers": healthObserver.stop(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
```

And add a stored property to the `AppDelegate` class body:

```swift
  private var healthObserver: HealthObserver?
```

- [ ] **Step 5: Verify the iOS build compiles**

Run: `flutter build ios --debug --no-codesign`
Expected: Build succeeds (Swift compiles, entitlements/plist valid). If no macOS/Xcode toolchain is available in this environment, instead run `flutter analyze` and note the iOS build must be verified on a Mac.

- [ ] **Step 6: Commit**

```bash
git add ios/Runner/HealthObserver.swift ios/Runner/AppDelegate.swift ios/Runner/Info.plist ios/Runner/Runner.entitlements
git commit -m "feat: add iOS HealthKit observer with background delivery"
```

---

### Task 9: Android native — Health Connect manifest + WorkManager background refresh

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/build.gradle.kts` (minSdk if needed)
- Modify: `lib/main.dart` (register the WorkManager callback dispatcher)
- Modify: `lib/app/health_providers.dart` (schedule/cancel the periodic task on enable/disable)

**Interfaces:**
- Consumes: `HealthRepository` (Task 3); `workmanager` (Task 1); `enable()`/`disable()` in `HealthStatusNotifier` (Task 5).
- Produces: background cache refresh on Android.

- [ ] **Step 1: Add Health Connect permissions + queries to the manifest**

In `android/app/src/main/AndroidManifest.xml`, add before `<application>`:

```xml
    <uses-permission android:name="android.permission.health.READ_STEPS" />
    <uses-permission android:name="android.permission.health.READ_HYDRATION" />
    <uses-permission android:name="android.permission.health.READ_EXERCISE" />
```

Inside `<application>`, add an activity-alias for the Health Connect permissions rationale (required by Health Connect):

```xml
        <activity-alias
            android:name="ViewPermissionUsageActivity"
            android:exported="true"
            android:targetActivity=".MainActivity"
            android:permission="android.permission.START_VIEW_PERMISSION_USAGE">
            <intent-filter>
                <action android:name="android.intent.action.VIEW_PERMISSION_USAGE" />
                <category android:name="android.intent.category.HEALTH_PERMISSIONS" />
            </intent-filter>
        </activity-alias>
```

Extend the existing `<queries>` block (`AndroidManifest.xml:48-53`) with the Health Connect package:

```xml
        <package android:name="com.google.android.apps.healthdata" />
        <intent>
            <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE" />
        </intent>
```

- [ ] **Step 2: Ensure minSdk meets Health Connect's floor**

In `android/app/build.gradle.kts`, in `defaultConfig`, pin `minSdk` to at least 26 (Health Connect requires 26+). Replace `minSdk = flutter.minSdkVersion` with:

```kotlin
        minSdk = maxOf(26, flutter.minSdkVersion)
```

- [ ] **Step 3: Register the WorkManager dispatcher in main.dart**

In `lib/main.dart`, add imports:

```dart
import 'package:workmanager/workmanager.dart';
import 'app/health_repository.dart';
```

Add the top-level callback (outside `main`):

```dart
/// Background entrypoint. Runs in its own isolate, so it builds a standalone
/// [HealthRepository] (no Riverpod) and only refreshes the secure-storage
/// cache; the in-memory provider updates on next open/resume.
@pragma('vm:entry-point')
void healthBackgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    try {
      final repo = HealthRepository();
      if (await repo.isEnabled()) {
        await repo.read();
      }
    } catch (_) {}
    return true;
  });
}
```

In `main()`, after `WidgetsFlutterBinding.ensureInitialized();`, add:

```dart
  Workmanager().initialize(healthBackgroundDispatcher);
```

- [ ] **Step 4: Schedule/cancel the task on enable/disable**

In `lib/app/health_providers.dart`, add the import:

```dart
import 'package:workmanager/workmanager.dart';
```

Add a constant near `healthRefreshInterval`:

```dart
const String healthBgTaskName = 'health_periodic_refresh';
```

In `HealthStatusNotifier.enable()`, after `ctrl.startAutoRefresh();`, add:

```dart
      Workmanager().registerPeriodicTask(
        healthBgTaskName,
        healthBgTaskName,
        // 15 min is Android's minimum periodic interval; the 4-min cadence is
        // foreground-only (see plan Global Constraints).
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.notRequired),
      );
```

In `HealthStatusNotifier.disable()`, after `stopAutoRefresh();`, add:

```dart
    Workmanager().cancelByUniqueName(healthBgTaskName);
```

- [ ] **Step 5: Analyze + full suite**

Run: `flutter analyze && flutter test`
Expected: No analyzer issues (the controller tests still pass — WorkManager calls are only hit in `enable()`, not exercised by the stubbed unit tests, which call `startAutoRefresh()` directly). All tests green.

- [ ] **Step 6: Verify the Android build compiles**

Run: `flutter build apk --debug`
Expected: Build succeeds; manifest merges without error.

- [ ] **Step 7: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml android/app/build.gradle.kts lib/main.dart lib/app/health_providers.dart
git commit -m "feat: add Android Health Connect permissions and WorkManager background refresh"
```

---

### Task 10: End-to-end verification pass

**Files:** none (verification only).

- [ ] **Step 1: Full static + test gate**

Run: `flutter analyze && flutter test`
Expected: zero analyzer issues; all unit tests pass.

- [ ] **Step 2: Manual device checklist (documented, run on hardware)**

Verify on at least one Android device with Health Connect installed and, if a Mac is available, one iOS device:

1. Fresh install → dashboard shows Steps/Water/Workout as `—` / `CONNECT IN SETTINGS`.
2. Tapping a dormant card navigates to Settings (tab 3).
3. Settings → Health Connect → toggle ON → OS permission prompt appears → grant.
4. Dashboard cards populate with today's totals; water subtitle shows `AS OF <time>`.
5. Background/foreground the app → values refresh on resume.
6. Wait 4 min in foreground → values re-read (confirm via a new step/water entry in the health app).
7. iOS only: log water in Apple Health while app is backgrounded → reopen → value already updated (observer path).
8. Android only: confirm the periodic task is registered (`adb shell dumpsys jobscheduler | grep health_periodic_refresh`).
9. Settings toggle OFF → cards go dormant, cache cleared.
10. Log out → log back in → health stays disabled (keys cleared).

- [ ] **Step 3: Final commit (if any doc/checklist notes added)**

```bash
git add -A
git commit -m "test: add health integration end-to-end verification checklist" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage:**
- Read-only Steps/Water/Workout on home → Task 6. ✓
- Refresh on every app open + resume → Task 5 (`build()`/`_init`) + Task 6 (lifecycle). ✓
- 4-min foreground timer → Task 5 (`healthRefreshInterval`). ✓
- iOS `HKObserverQuery` + background delivery → Tasks 4 + 8. ✓
- Android background refresh (~15 min) → Task 9. ✓
- Settings gate (toggle/status/resync/last-synced/unavailable) → Task 7. ✓
- Enable-from-config flow → Task 7 + `HealthStatusNotifier.enable()` (Task 5). ✓
- Cache last values for instant launch → Task 3 (`loadCached`) + Task 5 (`_init`). ✓
- Units (int / oz / min, today's totals) → Task 3. ✓
- Secure-storage keys + logout teardown → Tasks 3 + 6. ✓
- Native config (manifest, plist, entitlements) → Tasks 8 + 9. ✓
- Dependencies → Task 1. ✓
- Monotonic-token guard → Task 5. ✓
- Tests (model, repo, controller) → Tasks 2, 3, 5. ✓

**Placeholder scan:** No TBD/TODO; every code step carries full code. ✓

**Type consistency:** `HealthGateway` / `HealthKeyValueStore` seams defined in Task 3 and reused (as fakes) in Task 5 tests; `refresh()`, `startAutoRefresh()`, `stopAutoRefresh()`, `enable()`, `disable()` names consistent across Tasks 5/6/7/9; channel names `app/health_observer` + `app/health_observer/events` identical in Tasks 4 and 8; storage keys `health_enabled` / `health_metrics_json` identical in Tasks 3, 6, and the background dispatcher (Task 9). ✓

**Note for implementer:** the exact `health` v13 API names (`getTotalStepsInInterval`, `getHealthDataFromTypes`, `NumericHealthValue`, `HealthDataAccess.READ`) should be confirmed against the installed version after Task 1; if a signature differs, adjust only inside `HealthGatewayImpl` — the seam keeps the rest of the code and all tests unaffected.
