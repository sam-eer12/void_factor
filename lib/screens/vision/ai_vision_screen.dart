import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../features/food_log/food_analysis_client.dart';
import '../../features/food_log/food_log_grouping.dart';
import '../../features/food_log/food_log_providers.dart';
import '../../models/food_entry.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';
import '../dashboard/monolith_shell.dart';
import '../food_log/food_entry_form_screen.dart';

/// Photograph a meal, have it read, confirm what was logged.
///
/// The panel is a framing placeholder rather than a live preview: capture goes
/// through `image_picker`, which hands off to the OS camera. That avoids owning a
/// `CameraController` inside `MonolithShell`'s always-alive `PageView`, and
/// covers the gallery with the same call.
class AiVisionScreen extends ConsumerWidget {
  const AiVisionScreen({super.key});

  static const String analysingLabel = 'READING THE PLATE…';
  static const String emptyLogLabel = 'NOTHING LOGGED YET';
  static const String logUnavailableLabel = "COULDN'T READ YOUR LOG";

  /// This tab shows the last few entries as reassurance that a scan landed. The
  /// full three-day window, grouped by day, is the history screen's job.
  static const int recentLogLimit = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final analysis = ref.watch(visionAnalysisProvider);

    return Scaffold(
      backgroundColor: MonolithTheme.background,
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
                    _panel(analysis),
                    const SizedBox(height: 16),
                    _scanButtons(context, ref),
                    const SizedBox(height: 32),
                    _recentLogsHeader(),
                    const SizedBox(height: 16),
                    _recentLogs(ref),
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

  /// Picks an image, has it analysed, and opens the form on what came back.
  Future<void> _scan(
    BuildContext context,
    WidgetRef ref,
    ImageSource source,
  ) async {
    // Every scan costs one of the ten requests a minute nginx allows, and two in
    // flight would race to push a form on top of each other.
    if (ref.read(visionAnalysisProvider).isLoading) return;

    final (String, Nutrients)? draft;
    try {
      draft =
          await ref.read(visionAnalysisProvider.notifier).capture(source);
    } on FoodAnalysisException {
      // Already in the controller's error state, which the panel renders. Caught
      // only so the rethrow does not surface as an unhandled async error.
      return;
    }

    // Null means the picker was dismissed: a deliberate choice, so nothing
    // happens and nothing is said.
    if (draft == null || !context.mounted) return;
    final (name, nutrients) = draft;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FoodEntryFormScreen(
          initialName: name,
          initialNutrients: nutrients,
          source: FoodSource.vision,
        ),
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
              onTap: () =>
                  MonolithShell.setActiveTab(context, 0, '/dashboard'),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: MonolithTheme.containerDecoration,
                child: const Icon(Icons.arrow_back,
                    color: MonolithTheme.primary, size: 22),
              ),
            ),
            const SizedBox(width: 16),
            Text('MONOLITH', style: MonolithTheme.headlineLarge),
          ],
        ),
      );

  /// Framing placeholder, progress, or the reason the last scan failed.
  ///
  /// A result is not shown here — it goes straight to the form, which is where
  /// the user can act on it.
  Widget _panel(AsyncValue<(String, Nutrients)?> analysis) {
    return Container(
      width: double.infinity,
      height: 280,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MonolithTheme.primary,
        border: Border.all(
          color: MonolithTheme.primary,
          width: MonolithTheme.heroBorderWidth,
        ),
      ),
      child: Center(
        child: switch (analysis) {
          AsyncLoading() => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(
                  valueColor:
                      AlwaysStoppedAnimation<Color>(MonolithTheme.surface),
                ),
                const SizedBox(height: 24),
                Text(
                  analysingLabel,
                  style: MonolithTheme.labelMedium
                      .copyWith(color: MonolithTheme.surface),
                ),
              ],
            ),
          AsyncError(:final error) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline,
                    color: MonolithTheme.surface, size: 48),
                const SizedBox(height: 16),
                Text(
                  error is FoodAnalysisException
                      ? error.message
                      // Every failure path in the client throws a
                      // FoodAnalysisException, so this is a bug's last resort
                      // rather than a state the user should be able to reach.
                      : FoodAnalysisClient.errorProviderFailed,
                  textAlign: TextAlign.center,
                  style: MonolithTheme.labelMedium
                      .copyWith(color: MonolithTheme.surface),
                ),
                const SizedBox(height: 8),
                Text(
                  'TRY AGAIN BELOW',
                  style: MonolithTheme.labelSmall
                      .copyWith(color: MonolithTheme.surfaceContainerHigh),
                ),
              ],
            ),
          _ => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.center_focus_strong,
                    color: MonolithTheme.surface, size: 64),
                const SizedBox(height: 16),
                Text(
                  'AI VISION',
                  style: MonolithTheme.headlineLarge
                      .copyWith(color: MonolithTheme.surface),
                ),
                const SizedBox(height: 8),
                Text(
                  'PHOTOGRAPH A MEAL TO LOG IT',
                  style: MonolithTheme.labelSmall
                      .copyWith(color: MonolithTheme.surfaceContainerHigh),
                ),
              ],
            ),
        },
      ),
    );
  }

  Widget _scanButtons(BuildContext context, WidgetRef ref) => Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => _scan(context, ref, ImageSource.camera),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: MonolithTheme.cardDecoration,
                child: Column(
                  children: [
                    const Icon(Icons.camera_alt,
                        color: MonolithTheme.primary, size: 24),
                    const SizedBox(height: 8),
                    Text('CAPTURE', style: MonolithTheme.labelMedium),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () => _scan(context, ref, ImageSource.gallery),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: MonolithTheme.invertedCardDecoration,
                child: Column(
                  children: [
                    const Icon(Icons.photo_library,
                        color: MonolithTheme.surface, size: 24),
                    const SizedBox(height: 8),
                    Text(
                      'GALLERY',
                      style: MonolithTheme.labelMedium
                          .copyWith(color: MonolithTheme.surface),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );

  Widget _recentLogsHeader() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history,
                  color: MonolithTheme.primary, size: 20),
              const SizedBox(width: 8),
              Text('RECENT LOGS', style: MonolithTheme.headlineMedium),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'YOUR LATEST ENTRIES',
            style:
                MonolithTheme.labelSmall.copyWith(color: MonolithTheme.outline),
          ),
        ],
      );

  Widget _recentLogs(WidgetRef ref) {
    return ref.watch(recentFoodLogProvider).when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: CircularProgressIndicator.adaptive(
                valueColor:
                    AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
              ),
            ),
          ),
          error: (_, _) => _notice(logUnavailableLabel),
          data: (entries) {
            final rows = _recentRows(entries);
            if (rows.isEmpty) return _notice(emptyLogLabel);
            return Column(
              children: [
                for (final (index, row) in rows.indexed) ...[
                  if (index > 0) const SizedBox(height: 8),
                  _logRow(row.$1, row.$2),
                ],
              ],
            );
          },
        );
  }

  /// The newest few entries, each paired with the day label of its group, so the
  /// wording matches the history screen's headers.
  List<(String, FoodEntry)> _recentRows(List<FoodEntry> entries) {
    final rows = <(String, FoodEntry)>[];
    for (final group in groupByDay(entries, now: DateTime.now())) {
      for (final entry in group.entries) {
        rows.add((group.label, entry));
        if (rows.length == recentLogLimit) return rows;
      }
    }
    return rows;
  }

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

  Widget _logRow(String dayLabel, FoodEntry entry) {
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
            child: Icon(
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
                Text(entry.name.toUpperCase(),
                    style: MonolithTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  '$dayLabel · ${foodLogTimeLabel(entry.loggedAt)}',
                  style: MonolithTheme.labelSmall
                      .copyWith(color: MonolithTheme.outline),
                ),
              ],
            ),
          ),
          // The total, not the per-serving figure: what was eaten is the number
          // that belongs in a log.
          Text('${_kcal(entry.totalCalories)} KCAL',
              style: MonolithTheme.headlineMedium),
        ],
      ),
    );
  }

  static String _kcal(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}
