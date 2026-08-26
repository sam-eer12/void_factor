import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:health/health.dart';
import '../../models/energy_window.dart';
import '../../models/health_metrics.dart';

const double _mlPerFlOz = 29.5735;
const Duration _timeout = Duration(seconds: 15);

/// A window read makes one aggregated call per day plus two range reads, so it
/// gets a longer budget than the three single-day reads [_timeout] covers.
const Duration _windowTimeout = Duration(seconds: 45);

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

  /// Per-day activity from [start] to [end], one entry per calendar day
  /// inclusive, oldest first. Days the platform had nothing for come back with
  /// zeroes rather than being omitted, so the caller can tell a gap in the
  /// window from a gap in the calendar.
  Future<List<DailyEnergy>> dailyEnergy(DateTime start, DateTime end);
}

/// Real implementation backed by `package:health` (v13).
class HealthGatewayImpl implements HealthGateway {
  final Health _health = Health();

  static const List<HealthDataType> types = [
    HealthDataType.STEPS,
    HealthDataType.WATER,
    HealthDataType.WORKOUT,
    // Added for the projection's burn side. Appending to this list is what makes
    // an existing user's grant incomplete — see
    // [HealthRepository.authorizedTypesVersion].
    HealthDataType.ACTIVE_ENERGY_BURNED,
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

  /// Local midnight of the day after [day].
  ///
  /// Built through the constructor rather than by adding a 24-hour Duration,
  /// which is wrong across a DST change: midnight plus 24h lands at 01:00 or
  /// 23:00, and the day's samples then fall in the neighbouring bucket.
  static DateTime nextDay(DateTime day) =>
      DateTime(day.year, day.month, day.day + 1);

  static DateTime _dayOf(DateTime at) => DateTime(at.year, at.month, at.day);

  /// Known limitation: active-energy samples are summed, so a user whose watch
  /// and phone both report the same session can read high. HealthKit's own
  /// statistics queries reconcile sources; `getHealthDataFromTypes` returns raw
  /// samples and this plugin exposes no aggregated equivalent for energy.
  ///
  /// The projection is built to survive it — an overstated burn only affects the
  /// energy-balance basis, and the measured weigh-in slope supersedes that basis
  /// as soon as the user has a real series. See `ProjectionBasis`.
  @override
  Future<List<DailyEnergy>> dailyEnergy(DateTime start, DateTime end) async {
    final firstDay = _dayOf(start);
    final lastDay = _dayOf(end);

    // Pre-seeded so an unmeasured day is present with zeroes. The window's shape
    // is then the calendar, and the caller can tell a gap in the data from a gap
    // in the range it asked for.
    final steps = <DateTime, int>{};
    final workoutSeconds = <DateTime, double>{};
    final activeKcal = <DateTime, double>{};
    for (var day = firstDay; !day.isAfter(lastDay); day = nextDay(day)) {
      steps[day] = 0;
      workoutSeconds[day] = 0;
      activeKcal[day] = 0;
    }

    // Steps come from the plugin's interval aggregation, one call per day.
    // Summing raw step samples would double count a phone and a watch that both
    // recorded the same walk — the same reason `totalSteps` uses this call.
    for (final day in steps.keys.toList(growable: false)) {
      final boundary = nextDay(day);
      // The final day is partial: it ends at `end`, not at midnight.
      final dayEnd = boundary.isAfter(end) ? end : boundary;
      if (!dayEnd.isAfter(day)) continue;
      steps[day] = await _health.getTotalStepsInInterval(day, dayEnd) ?? 0;
    }

    // One request per type, matching totalWaterMl and totalWorkoutSeconds above,
    // so no sample ever has to be re-identified by its type after the fact.
    final workouts = await _health.getHealthDataFromTypes(
      types: [HealthDataType.WORKOUT],
      startTime: firstDay,
      endTime: end,
    );
    for (final p in workouts) {
      final day = _dayOf(p.dateFrom);
      final current = workoutSeconds[day];
      if (current == null) continue;
      workoutSeconds[day] =
          current + p.dateTo.difference(p.dateFrom).inSeconds;
    }

    final energy = await _health.getHealthDataFromTypes(
      types: [HealthDataType.ACTIVE_ENERGY_BURNED],
      startTime: firstDay,
      endTime: end,
    );
    for (final p in energy) {
      final day = _dayOf(p.dateFrom);
      final current = activeKcal[day];
      if (current == null) continue;
      final v = p.value;
      if (v is NumericHealthValue) {
        activeKcal[day] = current + v.numericValue.toDouble();
      }
    }

    return [
      for (var day = firstDay; !day.isAfter(lastDay); day = nextDay(day))
        DailyEnergy(
          day: day,
          steps: steps[day] ?? 0,
          workoutMinutes: ((workoutSeconds[day] ?? 0) / 60).round(),
          activeKcal: activeKcal[day] ?? 0,
        ),
    ];
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

  /// Cached [EnergyWindow] blob, so the projections screen renders instantly and
  /// offline — the same role [metricsKey] plays for the home cards.
  static const String energyWindowKey = 'health_energy_window_json';

  /// Which revision of [HealthGatewayImpl.types] the user's grant covers.
  static const String authorizedTypesVersionKey =
      'health_authorized_types_version';

  /// Bumped whenever [HealthGatewayImpl.types] gains a type.
  ///
  /// `1` was steps + water + workouts. `2` adds active energy. Without this, an
  /// already-connected user keeps `health_enabled = true`, is never re-prompted,
  /// and silently reads `activeKcal: 0` — which the projection would take at
  /// face value as "burns nothing" and report a wrong date with full confidence.
  static const int authorizedTypesVersion = 2;

  /// How many days of activity the projection reads.
  ///
  /// Two weeks: long enough that one unusual day cannot set the mean, short
  /// enough to still describe current behaviour rather than last month's.
  static const int energyWindowDays = 14;

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
      // Recorded only on a granted request, so a refused re-prompt leaves the
      // stale version in place and the user is asked again next time.
      await _store.write(
        authorizedTypesVersionKey,
        authorizedTypesVersion.toString(),
      );
      return HealthConnectionStatus.enabled;
    } catch (_) {
      return HealthConnectionStatus.disabled;
    }
  }

  Future<bool> isEnabled() async => (await _store.read(enabledKey)) == 'true';

  /// Whether a connected user's grant predates the current type list.
  ///
  /// False when health was never enabled — there is nothing to re-grant, and the
  /// ordinary connect flow already requests every type.
  Future<bool> needsReauthorization() async {
    if (!await isEnabled()) return false;
    final raw = await _store.read(authorizedTypesVersionKey);
    final version = int.tryParse(raw ?? '') ?? 1;
    return version < authorizedTypesVersion;
  }

  Future<void> disable() async {
    await _store.delete(enabledKey);
    await _store.delete(metricsKey);
    await _store.delete(energyWindowKey);
    await _store.delete(authorizedTypesVersionKey);
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

  /// The last [energyWindowDays] days of activity, ending at [now].
  ///
  /// Falls back to the cached window on any failure, matching [read]: a
  /// projection drawn from slightly stale activity is far more useful than an
  /// error where the chart should be.
  Future<EnergyWindow> readEnergyWindow({DateTime? now}) async {
    final end = now ?? DateTime.now();
    // Inclusive of today, so 14 days means today plus the 13 before it.
    final start = DateTime(end.year, end.month, end.day - (energyWindowDays - 1));
    try {
      final days =
          await _gateway.dailyEnergy(start, end).timeout(_windowTimeout);
      final window = EnergyWindow(
        days: List<DailyEnergy>.from(days)
          ..sort((a, b) => a.day.compareTo(b.day)),
        lastSynced: end,
      );
      await _store.write(energyWindowKey, window.toJsonString());
      return window;
    } catch (_) {
      return await loadCachedEnergyWindow();
    }
  }

  Future<EnergyWindow> loadCachedEnergyWindow() async {
    final raw = await _store.read(energyWindowKey);
    return EnergyWindow.fromJsonString(raw) ?? EnergyWindow.empty();
  }
}

final healthRepositoryProvider =
    Provider<HealthRepository>((ref) => HealthRepository());
