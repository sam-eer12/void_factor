import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/health_providers.dart';
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
            const SizedBox(height: 20),
            Text(
              'Void Factor reads Steps, Water, and Workout minutes in '
              'read-only mode. It never writes to your health data.',
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
