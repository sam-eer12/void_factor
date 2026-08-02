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
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
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

/// Real implementation backed by `package:health` (v13).
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
    final typed = types.cast<HealthDataType>();
    return _health.requestAuthorization(
      typed,
      permissions: List.filled(typed.length, HealthDataAccess.READ),
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
      types: [HealthDataType.WATER],
      startTime: start,
      endTime: end,
    );
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
      types: [HealthDataType.WORKOUT],
      startTime: start,
      endTime: end,
    );
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
      final secs =
          await _gateway.totalWorkoutSeconds(start, end).timeout(_timeout);
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
