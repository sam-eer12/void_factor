import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_bottom_nav.dart';

class AiVisionScreen extends StatelessWidget {
  const AiVisionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MonolithTheme.background,
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
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: MonolithTheme.containerDecoration,
                      child: const Icon(Icons.arrow_back,
                          color: MonolithTheme.primary, size: 22),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    'MONOLITH',
                    style: MonolithTheme.headlineLarge,
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── AI Vision Camera ──
                    Container(
                      width: double.infinity,
                      height: 280,
                      decoration: BoxDecoration(
                        color: MonolithTheme.primary,
                        border: Border.all(
                          color: MonolithTheme.primary,
                          width: MonolithTheme.heroBorderWidth,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.center_focus_strong,
                            color: MonolithTheme.surface,
                            size: 64,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'AI VISION',
                            style: MonolithTheme.headlineLarge.copyWith(
                              color: MonolithTheme.surface,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'POINT CAMERA AT FOOD TO SCAN',
                            style: MonolithTheme.labelSmall.copyWith(
                              color: MonolithTheme.surfaceContainerHigh,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Scan Buttons ──
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {},
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              decoration: MonolithTheme.cardDecoration,
                              child: Column(
                                children: [
                                  const Icon(Icons.camera_alt,
                                      color: MonolithTheme.primary, size: 24),
                                  const SizedBox(height: 8),
                                  Text('CAPTURE',
                                      style: MonolithTheme.labelMedium),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            onTap: () {},
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              decoration:
                                  MonolithTheme.invertedCardDecoration,
                              child: Column(
                                children: [
                                  Icon(Icons.photo_library,
                                      color: MonolithTheme.surface, size: 24),
                                  const SizedBox(height: 8),
                                  Text(
                                    'GALLERY',
                                    style: MonolithTheme.labelMedium.copyWith(
                                      color: MonolithTheme.surface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),

                    // ── Recent Logs ──
                    Row(
                      children: [
                        const Icon(Icons.history,
                            color: MonolithTheme.primary, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'RECENT LOGS',
                          style: MonolithTheme.headlineMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'LAST 72 HOURS ACTIVITY',
                      style: MonolithTheme.labelSmall.copyWith(
                        color: MonolithTheme.outline,
                      ),
                    ),
                    const SizedBox(height: 16),

                    _buildLogEntry('Grilled Chicken Salad', '450 kcal',
                        '12:30 PM', 'TODAY'),
                    const SizedBox(height: 8),
                    _buildLogEntry(
                        'Protein Shake', '280 kcal', '08:15 AM', 'TODAY'),
                    const SizedBox(height: 8),
                    _buildLogEntry('Brown Rice Bowl', '520 kcal',
                        '07:45 PM', 'YESTERDAY'),
                    const SizedBox(height: 8),
                    _buildLogEntry('Oatmeal & Berries', '320 kcal',
                        '08:00 AM', 'YESTERDAY'),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

            // ── Bottom Nav ──
            MonolithBottomNav(
              currentIndex: 1,
              onTap: (i) {
                if (i == 0) {
                  Navigator.pushReplacementNamed(context, '/dashboard');
                } else if (i == 2) {
                  Navigator.pushReplacementNamed(context, '/projections');
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

  Widget _buildLogEntry(
      String food, String calories, String time, String day) {
    return MonolithCard(
      hasShadow: false,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: MonolithTheme.primary,
              border: Border.all(
                  color: MonolithTheme.primary,
                  width: MonolithTheme.borderWidth),
            ),
            child: const Icon(Icons.restaurant,
                color: MonolithTheme.surface, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(food.toUpperCase(),
                    style: MonolithTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  '$day · $time',
                  style: MonolithTheme.labelSmall.copyWith(
                    color: MonolithTheme.outline,
                  ),
                ),
              ],
            ),
          ),
          Text(calories, style: MonolithTheme.headlineMedium),
        ],
      ),
    );
  }
}
