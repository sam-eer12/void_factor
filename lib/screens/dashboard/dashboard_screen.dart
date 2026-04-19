import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_bottom_nav.dart';
import '../../widgets/monolith_drawer.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final int _currentNavIndex = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  void _onNavTap(int index) {
    switch (index) {
      case 0:
        break; // Already on dashboard
      case 1:
        Navigator.pushNamed(context, '/ai-vision');
        break;
      case 2:
        Navigator.pushNamed(context, '/projections');
        break;
      case 3:
        Navigator.pushNamed(context, '/settings');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: MonolithTheme.background,
      drawer: MonolithDrawer(
        onProfileTap: () {
          Navigator.pop(context);
          Navigator.pushNamed(context, '/settings');
        },
        onDashboardTap: () => Navigator.pop(context),
        onAiModelsTap: () {
          Navigator.pop(context);
          Navigator.pushNamed(context, '/ai-vision');
        },
        onHistoryTap: () {
          Navigator.pop(context);
          Navigator.pushNamed(context, '/food-log');
        },
        onLogoutTap: () {
          Navigator.pushReplacementNamed(context, '/login');
        },
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
                    'MONOLITH',
                    style: MonolithTheme.headlineLarge,
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pushNamed(context, '/settings'),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: MonolithTheme.containerDecoration,
                      child: const Icon(Icons.person,
                          color: MonolithTheme.primary, size: 22),
                    ),
                  ),
                ],
              ),
            ),

            // ── Content ──
            Expanded(
              child: SingleChildScrollView(
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
                      'USER',
                      style: MonolithTheme.displayLarge,
                    ),
                    const SizedBox(height: 24),

                    // ── Stats Grid ──
                    Row(
                      children: [
                        Expanded(
                          child: MonolithStatCard(
                            title: 'Steps',
                            value: '8,432',
                            subtitle: 'From Health Connect',
                            icon: Icons.directions_walk,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: MonolithStatCard(
                            title: 'Workout Mins',
                            value: '45',
                            subtitle: 'Goal: 60 Mins',
                            icon: Icons.fitness_center,
                            inverted: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: MonolithStatCard(
                            title: 'Water',
                            value: '64oz',
                            subtitle: 'Remaining: 32 oz',
                            icon: Icons.water_drop,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: MonolithStatCard(
                            title: 'Protein',
                            value: '120g',
                            subtitle: 'Daily Target Met',
                            icon: Icons.restaurant,
                            inverted: true,
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
                            () => Navigator.pushNamed(context, '/ai-vision'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildQuickAction(
                            Icons.edit_note,
                            'LOG MEAL',
                            () => Navigator.pushNamed(context, '/food-log'),
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
                            () =>
                                Navigator.pushNamed(context, '/projections'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildQuickAction(
                            Icons.favorite,
                            'DONATE',
                            () => Navigator.pushNamed(context, '/donation'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

            // ── Bottom Nav ──
            MonolithBottomNav(
              currentIndex: _currentNavIndex,
              onTap: _onNavTap,
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
}
