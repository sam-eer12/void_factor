import 'package:workmanager/workmanager.dart';
import 'health_repository.dart';

/// Android background refresh for health metrics.
///
/// WorkManager's periodic floor is 15 minutes, so this is the coarse
/// background tier; the fine-grained "every 4 min" cadence is handled in the
/// foreground by [HealthMetricsController]'s timer. The task runs in a
/// separate isolate with no access to Riverpod, so it reads through a fresh
/// [HealthRepository] and writes to the same secure-storage cache the
/// providers hydrate from on next resume.
const String healthRefreshTask = 'com.voidfactor.app.healthRefresh';
const String _healthRefreshUnique = 'health-refresh-periodic';

/// Registered as the WorkManager entry point. Must be a top-level function
/// annotated for the background isolate's VM entry point.
@pragma('vm:entry-point')
void healthCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != healthRefreshTask) return true;
    try {
      final repo = HealthRepository();
      if (!await repo.isEnabled()) return true; // Nothing to refresh.
      await repo.read(); // Reads + caches; providers pick it up on resume.
      return true;
    } catch (_) {
      // Never crash the isolate — WorkManager will retry on its own schedule.
      return false;
    }
  });
}

/// Initializes WorkManager. Safe to call on every platform: the plugin is a
/// no-op where unsupported. Call once from `main()`.
Future<void> initHealthBackground() async {
  await Workmanager().initialize(healthCallbackDispatcher);
}

/// Schedules the periodic Android refresh (idempotent — same unique name just
/// updates the pending request). Called when health sync is enabled.
Future<void> scheduleHealthRefresh() async {
  await Workmanager().registerPeriodicTask(
    _healthRefreshUnique,
    healthRefreshTask,
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.notRequired),
  );
}

/// Cancels the periodic refresh. Called on disable / logout.
Future<void> cancelHealthRefresh() async {
  await Workmanager().cancelByUniqueName(_healthRefreshUnique);
}
