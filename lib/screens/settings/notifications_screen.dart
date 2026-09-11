import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/reminders/reminder_providers.dart';
import '../../features/reminders/reminder_settings.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_card.dart';

/// Settings → Notifications. One daily reminder to log what you ate.
///
/// One reminder rather than a schedule: a tracker's failure mode is people
/// forgetting to open it, and the smallest thing that fixes that is a single
/// nudge at an hour they choose. Anything more becomes a notification budget to
/// manage, which is a reason to turn all of them off.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  static const String toggleLabel = 'DAILY MEAL REMINDER';
  static const String timeLabel = 'REMIND ME AT';
  static const String offExplanation =
      'Turn this on to get one notification a day asking you to log your '
      'meals. Nothing else is ever sent.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminder = ref.watch(reminderProvider);

    return Scaffold(
      backgroundColor: MonolithTheme.background,
      appBar: AppBar(
        backgroundColor: MonolithTheme.background,
        elevation: 0,
        title: Text('NOTIFICATIONS', style: MonolithTheme.headlineMedium),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: switch (reminder) {
          AsyncData(:final value) => _body(context, ref, value),
          AsyncError() => Text(
              "COULDN'T READ YOUR REMINDER SETTING",
              style: MonolithTheme.bodyMedium,
            ),
          _ => const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: CircularProgressIndicator.adaptive(
                  valueColor:
                      AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                ),
              ),
            ),
        },
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, ReminderSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MonolithCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(toggleLabel, style: MonolithTheme.labelLarge),
                  ),
                  Switch.adaptive(
                    value: settings.enabled,
                    activeThumbColor: MonolithTheme.primary,
                    onChanged: (next) => _setEnabled(context, ref, next),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(offExplanation, style: MonolithTheme.bodyMedium),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Shown whether or not the reminder is on: picking a time first and
        // then switching it on is a reasonable order to do this in, and a
        // hidden control would make that impossible.
        MonolithCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(timeLabel, style: MonolithTheme.labelLarge),
                    const SizedBox(height: 4),
                    Text(
                      settings.label,
                      style: MonolithTheme.headlineLarge.copyWith(
                        color: settings.enabled
                            ? MonolithTheme.primary
                            : MonolithTheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => _pickTime(context, ref, settings),
                child: Text('CHANGE', style: MonolithTheme.labelMedium),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _setEnabled(
      BuildContext context, WidgetRef ref, bool enabled) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(reminderProvider.notifier).setEnabled(enabled);
    } on ReminderException catch (error) {
      // The switch is driven by the stored setting, which did not change, so it
      // springs back on its own — leaving only the reason to explain.
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _pickTime(
    BuildContext context,
    WidgetRef ref,
    ReminderSettings settings,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: settings.hour, minute: settings.minute),
    );
    if (picked == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(reminderProvider.notifier)
          .setTime(hour: picked.hour, minute: picked.minute);
    } on ReminderException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
