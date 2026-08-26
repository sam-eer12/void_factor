import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/health/health_providers.dart';
import '../../models/health_metrics.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';

/// Settings → Health Connect. The one place the user grants or revokes access
/// to the three read-only metrics shown on the dashboard.
class HealthConnectScreen extends ConsumerStatefulWidget {
  const HealthConnectScreen({super.key});

  @override
  ConsumerState<HealthConnectScreen> createState() =>
      _HealthConnectScreenState();
}

class _HealthConnectScreenState extends ConsumerState<HealthConnectScreen> {
  bool _busy = false;

  Future<void> _connect() async {
    setState(() => _busy = true);
    final status = await ref.read(healthStatusProvider.notifier).enable();
    if (!mounted) return;
    setState(() => _busy = false);
    // `enable()` leaves the status enum unchanged when the user was already
    // connected, so a re-grant would not move any state the derived providers
    // watch. Invalidated by hand, or a completed re-grant keeps showing the
    // prompt that asked for it.
    ref.invalidate(healthNeedsReauthorizationProvider);
    ref.invalidate(energyWindowProvider);
    if (status == HealthConnectionStatus.unavailable) {
      _toast('Health services are not available on this device.');
    } else if (status == HealthConnectionStatus.disabled) {
      _toast('Permission denied. Enable access to see your metrics.');
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    await ref.read(healthStatusProvider.notifier).disable();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(healthStatusProvider);
    final metrics = ref.watch(healthMetricsProvider);
    final connected = status == HealthConnectionStatus.enabled;
    // Absent while the check is in flight — treated as "nothing to ask for", so
    // the prompt appears once the answer is known rather than flickering.
    final needsReauth =
        ref.watch(healthNeedsReauthorizationProvider).value ?? false;

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      appBar: AppBar(
        backgroundColor: MonolithTheme.background,
        elevation: 0,
        title: Text('HEALTH CONNECT', style: MonolithTheme.headlineMedium),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusBanner(status),
            if (connected && needsReauth) ...[
              const SizedBox(height: 16),
              _reauthorizeBanner(),
            ],
            const SizedBox(height: 20),
            Text(
              'Void Factor reads Steps, Water, Workout minutes, and Energy '
              'Burned in read-only mode. It never writes to your health data.',
              style: MonolithTheme.labelMedium.copyWith(
                color: MonolithTheme.outline,
              ),
            ),
            const SizedBox(height: 24),
            if (connected) ...[
              _metricRow('Steps', '${metrics.steps}'),
              _metricRow('Water', '${metrics.waterOz.round()} oz'),
              _metricRow('Workout', '${metrics.workoutMinutes} min'),
              const SizedBox(height: 24),
              MonolithButton(
                label: 'Re-Sync Now',
                icon: Icons.refresh,
                style: MonolithButtonStyle.secondary,
                onPressed: _busy
                    ? null
                    : () => ref.read(healthMetricsProvider.notifier).refresh(),
              ),
              const SizedBox(height: 12),
              MonolithButton(
                label: 'Disconnect',
                style: MonolithButtonStyle.tertiary,
                onPressed: _busy ? null : _disconnect,
              ),
            ] else
              MonolithButton(
                label: status == HealthConnectionStatus.unavailable
                    ? 'Not Available'
                    : 'Connect Health',
                icon: Icons.favorite_border,
                onPressed: _busy || status == HealthConnectionStatus.unavailable
                    ? null
                    : _connect,
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusBanner(HealthConnectionStatus status) {
    final (label, color) = switch (status) {
      HealthConnectionStatus.enabled => ('CONNECTED', MonolithTheme.primary),
      HealthConnectionStatus.unavailable => ('UNAVAILABLE', MonolithTheme.outline),
      HealthConnectionStatus.disabled => ('NOT CONNECTED', MonolithTheme.outline),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: MonolithTheme.containerDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('STATUS', style: MonolithTheme.labelSmall.copyWith(
            color: MonolithTheme.outline,
          )),
          const SizedBox(height: 4),
          Text(label, style: MonolithTheme.headlineLarge.copyWith(color: color)),
        ],
      ),
    );
  }

  /// Shown when the user connected before Energy Burned was requested.
  ///
  /// Inverted rather than a snackbar: the projection is quietly wrong until this
  /// is acted on, and a message that disappears on its own would not carry that.
  Widget _reauthorizeBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: MonolithTheme.invertedCardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ENERGY BURNED NOT GRANTED',
            style: MonolithTheme.labelMedium
                .copyWith(color: MonolithTheme.surface),
          ),
          const SizedBox(height: 8),
          Text(
            'You connected before Void Factor started reading Energy Burned. '
            'Until you grant it, projections estimate your burn from steps and '
            'workouts alone.',
            style: MonolithTheme.bodyMedium.copyWith(
              color: MonolithTheme.surfaceContainerHigh,
            ),
          ),
          const SizedBox(height: 16),
          MonolithButton(
            label: 'Grant Energy Access',
            icon: Icons.local_fire_department_outlined,
            style: MonolithButtonStyle.secondary,
            onPressed: _busy ? null : _connect,
          ),
        ],
      ),
    );
  }

  Widget _metricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label.toUpperCase(), style: MonolithTheme.labelMedium),
          Text(value, style: MonolithTheme.headlineMedium),
        ],
      ),
    );
  }
}
