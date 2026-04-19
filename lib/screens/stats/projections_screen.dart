import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_bottom_nav.dart';
import '../../widgets/monolith_drawer.dart';

class ProjectionsScreen extends StatelessWidget {
  const ProjectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scaffoldKey = GlobalKey<ScaffoldState>();

    return Scaffold(
      key: scaffoldKey,
      backgroundColor: MonolithTheme.background,
      drawer: MonolithDrawer(
        onProfileTap: () {
          Navigator.pop(context);
          Navigator.pushNamed(context, '/settings');
        },
        onDashboardTap: () {
          Navigator.pushReplacementNamed(context, '/dashboard');
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
                    onTap: () => scaffoldKey.currentState?.openDrawer(),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: MonolithTheme.containerDecoration,
                      child: const Icon(Icons.menu,
                          color: MonolithTheme.primary, size: 22),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text('MONOLITH', style: MonolithTheme.headlineLarge),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Header ──
                    Text('PROJECTIONS', style: MonolithTheme.displayLarge),
                    const SizedBox(height: 4),
                    Text(
                      'ANALYSIS REPORT & TRAJECTORY',
                      style: MonolithTheme.labelMedium.copyWith(
                        color: MonolithTheme.outline,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Weight Trajectory ──
                    MonolithCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text('WEIGHT TRAJECTORY',
                                  style: MonolithTheme.headlineMedium),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                color: MonolithTheme.primary,
                                child: Text(
                                  'ON TRACK',
                                  style:
                                      MonolithTheme.labelSmall.copyWith(
                                    color: MonolithTheme.surface,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'PROJECTION STATUS',
                            style: MonolithTheme.labelSmall.copyWith(
                              color: MonolithTheme.outline,
                            ),
                          ),
                          const SizedBox(height: 20),

                          // ── Chart Placeholder ──
                          Container(
                            height: 180,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: MonolithTheme.primary,
                                width: 1,
                              ),
                            ),
                            child: CustomPaint(
                              painter: _ChartPainter(),
                              size: const Size(double.infinity, 180),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text('WEEK 1',
                                  style: MonolithTheme.labelSmall),
                              Text('WEEK 4',
                                  style: MonolithTheme.labelSmall),
                              Text('WEEK 8',
                                  style: MonolithTheme.labelSmall),
                              Text('WEEK 12',
                                  style: MonolithTheme.labelSmall),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Goal Reached ──
                    MonolithCard(
                      inverted: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'GOAL REACHED IN:',
                            style: MonolithTheme.labelMedium.copyWith(
                              color: MonolithTheme.surfaceContainerHigh,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '47 DAYS',
                            style: MonolithTheme.displayLarge.copyWith(
                              color: MonolithTheme.surface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'AT CURRENT TRAJECTORY',
                            style: MonolithTheme.labelSmall.copyWith(
                              color: MonolithTheme.surfaceContainerHigh,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Mandatory Protocols ──
                    MonolithCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('MANDATORY PROTOCOLS',
                              style: MonolithTheme.headlineMedium),
                          const SizedBox(height: 20),
                          _buildProtocol(
                            Icons.directions_run,
                            'HIIT CARDIO',
                            '45 MINS',
                            'High intensity interval training daily.',
                          ),
                          const SizedBox(height: 16),
                          Container(
                            height: MonolithTheme.borderWidth,
                            color: MonolithTheme.primary,
                          ),
                          const SizedBox(height: 16),
                          _buildProtocol(
                            Icons.restaurant,
                            'CALORIC DEFICIT',
                            '500 KCAL',
                            'Maintain strict logging of all intake.',
                          ),
                          const SizedBox(height: 16),
                          Container(
                            height: MonolithTheme.borderWidth,
                            color: MonolithTheme.primary,
                          ),
                          const SizedBox(height: 16),
                          _buildProtocol(
                            Icons.water_drop,
                            'HYDRATION',
                            '4 LITERS',
                            'Minimum daily water consumption.',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

            MonolithBottomNav(
              currentIndex: 2,
              onTap: (i) {
                if (i == 0) {
                  Navigator.pushReplacementNamed(context, '/dashboard');
                } else if (i == 1) {
                  Navigator.pushReplacementNamed(context, '/ai-vision');
                } else if (i == 3) {
                  Navigator.pushReplacementNamed(context, '/settings');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProtocol(
      IconData icon, String title, String value, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          color: MonolithTheme.primary,
          child: Icon(icon, color: MonolithTheme.surface, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title, style: MonolithTheme.labelLarge),
                  Text(value, style: MonolithTheme.headlineMedium),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                desc,
                style: MonolithTheme.bodyMedium.copyWith(
                  color: MonolithTheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = MonolithTheme.primary
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    path.moveTo(0, size.height * 0.8);
    path.lineTo(size.width * 0.15, size.height * 0.7);
    path.lineTo(size.width * 0.3, size.height * 0.55);
    path.lineTo(size.width * 0.45, size.height * 0.5);
    path.lineTo(size.width * 0.6, size.height * 0.38);
    path.lineTo(size.width * 0.75, size.height * 0.3);
    path.lineTo(size.width * 0.9, size.height * 0.22);
    path.lineTo(size.width, size.height * 0.18);

    canvas.drawPath(path, paint);

    // Draw data points
    final dotPaint = Paint()
      ..color = MonolithTheme.primary
      ..style = PaintingStyle.fill;

    final points = [
      Offset(0, size.height * 0.8),
      Offset(size.width * 0.15, size.height * 0.7),
      Offset(size.width * 0.3, size.height * 0.55),
      Offset(size.width * 0.45, size.height * 0.5),
      Offset(size.width * 0.6, size.height * 0.38),
      Offset(size.width * 0.75, size.height * 0.3),
      Offset(size.width * 0.9, size.height * 0.22),
      Offset(size.width, size.height * 0.18),
    ];

    for (final p in points) {
      canvas.drawRect(
        Rect.fromCenter(center: p, width: 8, height: 8),
        dotPaint,
      );
    }

    // Grid lines
    final gridPaint = Paint()
      ..color = MonolithTheme.primary.withValues(alpha: 0.1)
      ..strokeWidth = 1;

    for (var i = 0; i < 4; i++) {
      final y = size.height * (i + 1) / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
