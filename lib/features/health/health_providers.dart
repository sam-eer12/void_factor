import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/health_metrics.dart';
import 'health_repository.dart';
import 'health_observer_service.dart';
import 'health_background_service.dart';

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
      await scheduleHealthRefresh(); // Android background tier (15 min floor)
    }
    return status;
  }

  Future<void> disable() async {
    final repo = ref.read(healthRepositoryProvider);
    await repo.disable();
    ref.read(healthMetricsProvider.notifier).stopAutoRefresh();
    await cancelHealthRefresh();
    state = HealthConnectionStatus.disabled;
  }
}

final healthStatusProvider =
    NotifierProvider<HealthStatusNotifier, HealthConnectionStatus>(() {
  return HealthStatusNotifier();
});

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
    NotifierProvider<HealthMetricsController, HealthMetrics>(() {
  return HealthMetricsController();
});
