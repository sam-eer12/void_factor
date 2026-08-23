import 'package:flutter/material.dart';

import '../features/food_log/food_log_grouping.dart';
import '../models/food_entry.dart';
import '../theme/monolith_theme.dart';
import 'monolith_card.dart';

/// One logged meal, as both food screens draw it.
///
/// Shared so the two lists cannot drift apart: the vision tab and the history
/// screen read the same log, and a row that looked different in each would
/// suggest they held different data.
class FoodLogRow extends StatelessWidget {
  final FoodEntry entry;

  /// The row's second line.
  ///
  /// The vision tab names the entry's day, having no day headers of its own; the
  /// history screen has one above already, so it spends the line on protein.
  final String subtitle;

  const FoodLogRow({
    super.key,
    required this.entry,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
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
                width: MonolithTheme.borderWidth,
              ),
            ),
            child: Icon(
              // How it got logged, which is the only thing about an entry the
              // model gives us to distinguish it by.
              entry.source == FoodSource.vision
                  ? Icons.center_focus_strong
                  : Icons.restaurant,
              color: MonolithTheme.surface,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.name.toUpperCase(), style: MonolithTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: MonolithTheme.labelSmall
                      .copyWith(color: MonolithTheme.outline),
                ),
              ],
            ),
          ),
          // The total, not the per-serving figure: what was eaten is the number
          // that belongs in a log.
          Text(
            '${foodLogAmountLabel(entry.totalCalories)} KCAL',
            style: MonolithTheme.headlineMedium,
          ),
        ],
      ),
    );
  }
}
