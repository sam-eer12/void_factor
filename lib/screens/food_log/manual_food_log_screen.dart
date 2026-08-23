import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/food_log/food_log_grouping.dart';
import '../../features/food_log/food_log_providers.dart';
import '../../models/food_entry.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/food_log_row.dart';
import '../../widgets/monolith_bottom_nav.dart';
import 'food_entry_form_screen.dart';

/// The full log window, grouped by day, plus the way in to a manual entry.
///
/// Reads the same provider as the vision tab and differs only in rendering: this
/// screen shows every entry in the window under a header per day, where the tab
/// shows the newest few.
class ManualFoodLogScreen extends ConsumerWidget {
  const ManualFoodLogScreen({super.key});

  static const String emptyLogLabel = 'NOTHING LOGGED YET';
  static const String logUnavailableLabel = "COULDN'T READ YOUR LOG";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: MonolithTheme.background,
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(context),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(context),
                    const SizedBox(height: 24),
                    _history(ref),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: MonolithBottomNav(
        currentIndex: 1,
        onTap: (i) {
          if (i == 0) {
            Navigator.pushReplacementNamed(context, '/dashboard');
          } else if (i == 1) {
            Navigator.pushReplacementNamed(context, '/ai-vision');
          } else if (i == 2) {
            Navigator.pushReplacementNamed(context, '/projections');
          } else if (i == 3) {
            Navigator.pushReplacementNamed(context, '/settings');
          }
        },
      ),
    );
  }

  Widget _topBar(BuildContext context) => Container(
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
            Text('MONOLITH FITNESS', style: MonolithTheme.headlineLarge),
          ],
        ),
      );

  Widget _header(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('HISTORY', style: MonolithTheme.displayMedium),
              Text(
                // Three calendar days, which is what `groupByDay` buckets — the
                // subtitle used to say 72 rolling hours, which it never was.
                'LAST $foodLogWindowDays DAYS',
                style: MonolithTheme.labelMedium
                    .copyWith(color: MonolithTheme.outline),
              ),
            ],
          ),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    const FoodEntryFormScreen(source: FoodSource.manual),
              ),
            ),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration:
                  MonolithTheme.invertedCardDecoration.copyWith(boxShadow: []),
              child: const Icon(Icons.add,
                  color: MonolithTheme.surface, size: 24),
            ),
          ),
        ],
      );

  Widget _history(WidgetRef ref) {
    return ref.watch(recentFoodLogProvider).when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: CircularProgressIndicator.adaptive(
                valueColor:
                    AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
              ),
            ),
          ),
          error: (_, _) => _notice(logUnavailableLabel),
          data: (entries) {
            final groups = groupByDay(entries, now: DateTime.now());
            if (groups.isEmpty) return _notice(emptyLogLabel);

            return Column(
              children: [
                for (final (index, group) in groups.indexed) ...[
                  if (index > 0) const SizedBox(height: 24),
                  _dayHeader(group.label),
                  const SizedBox(height: 12),
                  for (final (row, entry) in group.entries.indexed) ...[
                    if (row > 0) const SizedBox(height: 8),
                    _logRow(entry),
                  ],
                ],
              ],
            );
          },
        );
  }

  Widget _dayHeader(String day) => Container(
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

  Widget _notice(String message) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
        decoration: MonolithTheme.cardDecoration,
        child: Text(
          message,
          textAlign: TextAlign.center,
          style:
              MonolithTheme.labelMedium.copyWith(color: MonolithTheme.outline),
        ),
      );

  Widget _logRow(FoodEntry entry) => FoodLogRow(
        entry: entry,
        // The day is already the header above, so the row spends its second
        // line on protein instead of repeating it.
        subtitle: '${foodLogAmountLabel(entry.totalProteinG)}G PROTEIN · '
            '${foodLogTimeLabel(entry.loggedAt)}',
      );
}
