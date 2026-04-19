import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_bottom_nav.dart';

class ManualFoodLogScreen extends StatelessWidget {
  const ManualFoodLogScreen({super.key});

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
                  Text('MONOLITH FITNESS',
                      style: MonolithTheme.headlineLarge),
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('HISTORY',
                                style: MonolithTheme.displayMedium),
                            Text(
                              'LAST 72H',
                              style: MonolithTheme.labelMedium.copyWith(
                                color: MonolithTheme.outline,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: MonolithTheme.invertedCardDecoration
                              .copyWith(boxShadow: []),
                          child: const Icon(Icons.add,
                              color: MonolithTheme.surface, size: 24),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // ── Today ──
                    _buildDayHeader('TODAY'),
                    const SizedBox(height: 12),
                    _buildFoodItem(
                      'Grilled Chicken Breast',
                      '330 kcal',
                      '42g protein',
                      '12:45 PM',
                      Icons.restaurant,
                    ),
                    const SizedBox(height: 8),
                    _buildFoodItem(
                      'Whey Protein Shake',
                      '280 kcal',
                      '35g protein',
                      '08:30 AM',
                      Icons.local_drink,
                    ),
                    const SizedBox(height: 8),
                    _buildFoodItem(
                      'Oatmeal & Banana',
                      '380 kcal',
                      '12g protein',
                      '07:15 AM',
                      Icons.breakfast_dining,
                    ),
                    const SizedBox(height: 24),

                    // ── Yesterday ──
                    _buildDayHeader('YESTERDAY'),
                    const SizedBox(height: 12),
                    _buildFoodItem(
                      'Salmon & Brown Rice',
                      '520 kcal',
                      '38g protein',
                      '07:30 PM',
                      Icons.set_meal,
                    ),
                    const SizedBox(height: 8),
                    _buildFoodItem(
                      'Caesar Salad',
                      '290 kcal',
                      '18g protein',
                      '12:00 PM',
                      Icons.eco,
                    ),
                    const SizedBox(height: 8),
                    _buildFoodItem(
                      'Eggs & Toast',
                      '340 kcal',
                      '22g protein',
                      '08:00 AM',
                      Icons.egg,
                    ),
                    const SizedBox(height: 24),

                    // ── 2 Days Ago ──
                    _buildDayHeader('2 DAYS AGO'),
                    const SizedBox(height: 12),
                    _buildFoodItem(
                      'Chicken Stir Fry',
                      '480 kcal',
                      '35g protein',
                      '08:00 PM',
                      Icons.rice_bowl,
                    ),
                    const SizedBox(height: 8),
                    _buildFoodItem(
                      'Greek Yogurt',
                      '180 kcal',
                      '15g protein',
                      '03:30 PM',
                      Icons.icecream,
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),

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

  Widget _buildDayHeader(String day) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: MonolithTheme.primary,
      child: Text(
        day,
        style: MonolithTheme.labelLarge.copyWith(
          color: MonolithTheme.surface,
        ),
      ),
    );
  }

  Widget _buildFoodItem(
    String name,
    String calories,
    String macro,
    String time,
    IconData icon,
  ) {
    return MonolithCard(
      hasShadow: false,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              border: Border.all(
                color: MonolithTheme.primary,
                width: MonolithTheme.borderWidth,
              ),
            ),
            child: Icon(icon, color: MonolithTheme.primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name.toUpperCase(),
                    style: MonolithTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  '$macro · $time',
                  style: MonolithTheme.labelSmall.copyWith(
                    color: MonolithTheme.outline,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(
                color: MonolithTheme.primary,
                width: MonolithTheme.borderWidth,
              ),
            ),
            child: Text(calories, style: MonolithTheme.labelMedium),
          ),
        ],
      ),
    );
  }
}
