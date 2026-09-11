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
  static const String deleteTooltip = 'Delete entry';

  final FoodEntry entry;

  /// The row's second line.
  ///
  /// The vision tab names the entry's day, having no day headers of its own; the
  /// history screen has one above already, so it spends the line on protein.
  final String subtitle;

  /// Opens the entry for correction. Null leaves the row inert, which is what
  /// any future read-only listing of the log would want.
  final VoidCallback? onEdit;

  /// Removes the entry. Undo is the caller's business, not the row's.
  final VoidCallback? onDelete;

  const FoodLogRow({
    super.key,
    required this.entry,
    required this.subtitle,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final card = _card(context);
    // Not wrapped when there is nothing to open: an InkWell with a null callback
    // still swallows the tap, so the row would look interactive and do nothing.
    if (onEdit == null) return card;
    return GestureDetector(onTap: onEdit, child: card);
  }

  Widget _card(BuildContext context) {
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
          if (onDelete != null) ...[
            const SizedBox(width: 4),
            // A visible control rather than a swipe or a long-press: both are
            // invisible affordances, and a log you cannot see how to correct is
            // one people stop trusting.
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.close, size: 18),
              color: MonolithTheme.outline,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: deleteTooltip,
            ),
          ],
        ],
      ),
    );
  }
}
