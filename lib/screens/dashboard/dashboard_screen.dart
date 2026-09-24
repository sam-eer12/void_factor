import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/calorie_dial.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_drawer.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/food_log/food_log_grouping.dart';
import '../../features/food_log/food_log_providers.dart';
import '../../features/health/health_providers.dart';
import '../../features/projection/calorie_budget.dart';
import '../../features/projection/projection_providers.dart';
import '../../models/health_metrics.dart';
import 'monolith_shell.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authStateProvider).value;
    final metrics = ref.watch(healthMetricsProvider);
    // Today's real intake. Until this existed the protein card read a hardcoded
    // '120g / Daily Target Met' on a screen whose whole job is to be true.
    final totals = ref.watch(todayTotalsProvider);
    // The same intake, paired with the target the dial measures it against.
    final budget = ref.watch(calorieBudgetProvider);
    // Only to tell "still loading" apart from "profile is missing metrics" when
    // the dial has no target to draw. The budget above carries the target itself.
    // Selected down to the one line of copy, so a projection that recomputes —
    // every logged meal and weigh-in — does not redraw the dashboard for it.
    final targetHint = ref.watch(projectionProvider
        .select((projection) => calorieTargetHintLabel(projection.value)));
    final healthStatus = ref.watch(healthStatusProvider);
    final connected = healthStatus == HealthConnectionStatus.enabled;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: MonolithTheme.background,
      drawer: MonolithDrawer(
        userName: (user?.displayName ?? 'USER').toUpperCase(),
        onProfileTap: () {
          Navigator.pop(context);
          MonolithShell.setActiveTab(context, 3, '/settings');
        },
        onDashboardTap: () => Navigator.pop(context),
        onAiModelsTap: () {
          Navigator.pop(context);
          MonolithShell.setActiveTab(context, 1, '/ai-vision');
        },
        onHistoryTap: () {
          Navigator.pop(context);
          Navigator.restorablePushNamed(context, '/food-log');
        },
        onLogoutTap: () => performLogout(context, ref),
      ),
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
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: () => _scaffoldKey.currentState?.openDrawer(),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: MonolithTheme.containerDecoration,
                      child: const Icon(Icons.menu,
                          color: MonolithTheme.primary, size: 22),
                    ),
                  ),
                  Text(
                    'Void_Factor',
                    style: MonolithTheme.headlineLarge,
                  ),
                  GestureDetector(
                    onTap: () => MonolithShell.setActiveTab(context, 3, '/settings'),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: MonolithTheme.containerDecoration,
                      child: user?.photoURL != null
                          ? Image.network(
                              user!.photoURL!,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => const Center(
                                child: Icon(Icons.person,
                                    color: MonolithTheme.primary, size: 22),
                              ),
                            )
                          : const Center(
                              child: Icon(Icons.person,
                                  color: MonolithTheme.primary, size: 22),
                            ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Content ──
            Expanded(
              child: SingleChildScrollView(
                restorationId: 'dashboard_scroll',
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Greeting
                    const SizedBox(height: 8),
                    Text(
                      'HELLO',
                      style: MonolithTheme.labelLarge.copyWith(
                        color: MonolithTheme.outline,
                      ),
                    ),
                    Text(
                      (user?.displayName ?? 'USER').toUpperCase(),
                      style: MonolithTheme.displayLarge,
                    ),
                    const SizedBox(height: 24),

                    // ── Today's intake ──
                    //
                    // Above the health grid, not inside it: calories are the
                    // number this app exists to show, and steps are context.
                    //
                    // A dial rather than a figure because the figure alone never
                    // answered the question the user opens the app with. 1,400
                    // is a good day or a bad one entirely depending on a target
                    // that used to live on a different screen.
                    CalorieDialCard(
                      budget: budget.value,
                      targetHint: targetHint,
                      onTap: () => Navigator.restorablePushNamed(context, '/food-log'),
                    ),
                    const SizedBox(height: 12),

                    // ── Stats Grid ──
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: connected
                                ? null
                                : () => MonolithShell.setActiveTab(
                                    context, 3, '/settings'),
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
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            onTap: connected
                                ? null
                                : () => MonolithShell.setActiveTab(
                                    context, 3, '/settings'),
                            child: MonolithStatCard(
                              title: 'Workout Mins',
                              value: connected
                                  ? metrics.workoutMinutes.toString()
                                  : '—',
                              subtitle: connected
                                  ? 'Minutes Today'
                                  : 'Connect in Settings',
                              icon: Icons.fitness_center,
                              inverted: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: connected
                                ? null
                                : () => MonolithShell.setActiveTab(
                                    context, 3, '/settings'),
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
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            onTap: () =>
                                Navigator.restorablePushNamed(context, '/food-log'),
                            child: MonolithStatCard(
                              title: 'Protein',
                              value: _macro(totals, (t) => t.proteinG),
                              subtitle: _intakeSubtitle(totals),
                              icon: Icons.restaurant,
                              inverted: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // ── Quick Actions ──
                    Text(
                      'QUICK ACTIONS',
                      style: MonolithTheme.labelLarge,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildQuickAction(
                            Icons.camera_alt,
                            'SCAN FOOD',
                            () => MonolithShell.setActiveTab(context, 1, '/ai-vision'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildQuickAction(
                            Icons.edit_note,
                            'LOG MEAL',
                            () => Navigator.restorablePushNamed(context, '/food-log'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildQuickAction(
                            Icons.insights,
                            'PROJECTIONS',
                            () => MonolithShell.setActiveTab(context, 2, '/projections'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildQuickAction(
                            Icons.favorite,
                            'DONATE',
                            () => Navigator.restorablePushNamed(context, '/donation'),
                          ),
                        ),
                      ],
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

  Widget _buildQuickAction(
      IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: MonolithTheme.cardDecoration,
        child: Column(
          children: [
            Icon(icon, color: MonolithTheme.primary, size: 28),
            const SizedBox(height: 10),
            Text(
              label,
              style: MonolithTheme.labelMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _macro(AsyncValue<DayTotals> totals, double Function(DayTotals) pick) {
    final value = totals.value;
    if (value == null) return '—';
    return '${foodLogAmountLabel(pick(value))}g';
  }

  /// Says whether the figures above are a real day or an empty one.
  ///
  /// A logged zero-calorie day and a day with nothing logged produce identical
  /// numbers, and only one of them means "you are on target".
  String _intakeSubtitle(AsyncValue<DayTotals> totals) {
    final value = totals.value;
    if (value == null) return 'Reading Your Log';
    if (value.isEmpty) return 'Nothing Logged Yet';
    final meals = value.entryCount == 1 ? 'Meal' : 'Meals';
    return 'From ${value.entryCount} $meals';
  }

  // Groups an integer with thousands separators, e.g. 8432 -> "8,432".
  String _formatInt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  // Water card subtitle: shows when the metrics were last read.
  String _syncedSubtitle(DateTime? ts) {
    if (ts == null) return 'Not Yet Synced';
    final h = ts.hour % 12 == 0 ? 12 : ts.hour % 12;
    final m = ts.minute.toString().padLeft(2, '0');
    final ap = ts.hour < 12 ? 'AM' : 'PM';
    return 'As of $h:$m $ap';
  }
}
