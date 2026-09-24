import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/food_log/food_log_grouping.dart';
import '../../features/food_log/food_log_providers.dart';
import '../../models/food_entry.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/food_log_row.dart';
import '../../widgets/monolith_bottom_nav.dart';
import 'food_entry_form_screen.dart';
import 'food_log_actions.dart';

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
              child: CustomScrollView(
                // Where the list was scrolled comes back with the screen when
                // Android restores an app it killed in the background.
                restorationId: 'food_log_history',
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.all(20),
                    sliver: _history(context, ref),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: MonolithBottomNav(
        currentIndex: 1,
        onTap: (i) {
          if (i == 0) {
            Navigator.restorablePushReplacementNamed(context, '/dashboard');
          } else if (i == 1) {
            Navigator.restorablePushReplacementNamed(context, '/ai-vision');
          } else if (i == 2) {
            Navigator.restorablePushReplacementNamed(context, '/projections');
          } else if (i == 3) {
            Navigator.restorablePushReplacementNamed(context, '/settings');
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
            Text('Void_Factor', style: MonolithTheme.headlineLarge),
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
            onTap: () => Navigator.restorablePush(
              context,
              FoodEntryFormScreen.restorableRoute,
              arguments: FoodEntryFormScreen.manualArguments,
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

  /// The header, then the log: one lazily built list, so only the rows on
  /// screen are ever laid out however long the window's log grows.
  ///
  /// Flattened to plain items first — a gap, a day heading, an entry — so the
  /// builder can make each widget only when it scrolls into view.
  Widget _history(BuildContext context, WidgetRef ref) {
    final items = <Object>[
      const _HistoryHeader(),
      const _Gap(24),
      ...ref.watch(recentFoodLogProvider).when(
            loading: () => const [_HistoryLoading()],
            error: (_, _) => const [_Notice(logUnavailableLabel)],
            data: (entries) {
              final groups = groupByDay(entries, now: DateTime.now());
              if (groups.isEmpty) return const [_Notice(emptyLogLabel)];
              return [
                for (final (index, group) in groups.indexed) ...[
                  if (index > 0) const _Gap(24),
                  _DayLabel(group.label),
                  const _Gap(12),
                  for (final (row, entry) in group.entries.indexed) ...[
                    if (row > 0) const _Gap(8),
                    entry,
                  ],
                ],
              ];
            },
          ),
      const _Gap(20),
    ];

    return SliverList.builder(
      itemCount: items.length,
      itemBuilder: (context, index) => switch (items[index]) {
        _HistoryHeader() => _header(context),
        _Gap(:final height) => SizedBox(height: height),
        _HistoryLoading() => const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: CircularProgressIndicator.adaptive(
                valueColor:
                    AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
              ),
            ),
          ),
        _Notice(:final message) => _notice(message),
        _DayLabel(:final label) => _dayHeader(label),
        final FoodEntry entry => _logRow(context, ref, entry),
        _ => const SizedBox.shrink(),
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

  Widget _logRow(BuildContext context, WidgetRef ref, FoodEntry entry) =>
      FoodLogRow(
        entry: entry,
        // The day is already the header above, so the row spends its second
        // line on protein instead of repeating it.
        subtitle: '${foodLogAmountLabel(entry.totalProteinG)}G PROTEIN · '
            '${foodLogTimeLabel(entry.loggedAt)}',
        onEdit: () => editFoodEntry(context, entry),
        onDelete: () => deleteFoodEntry(context, ref, entry),
      );
}

// The kinds of item the history list is flattened into.

class _HistoryHeader {
  const _HistoryHeader();
}

class _HistoryLoading {
  const _HistoryLoading();
}

class _Gap {
  const _Gap(this.height);
  final double height;
}

class _Notice {
  const _Notice(this.message);
  final String message;
}

class _DayLabel {
  const _DayLabel(this.label);
  final String label;
}
