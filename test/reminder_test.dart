import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:void_factor/features/reminders/reminder_providers.dart';
import 'package:void_factor/features/reminders/reminder_service.dart';
import 'package:void_factor/features/reminders/reminder_settings.dart';

class FakeScheduler implements ReminderScheduler {
  bool granted = true;
  Object? scheduleThrows;
  ReminderSettings? scheduled;
  int cancelCount = 0;
  int permissionRequests = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return granted;
  }

  @override
  Future<void> schedule(ReminderSettings settings) async {
    if (scheduleThrows != null) throw scheduleThrows!;
    scheduled = settings;
  }

  @override
  Future<void> cancel() async => cancelCount++;
}

class InMemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  group('ReminderSettings wire format', () {
    test('survives a round trip', () {
      const settings = ReminderSettings(enabled: true, hour: 7, minute: 5);
      expect(ReminderSettings.fromWire(settings.wireValue), settings);
    });

    test('keeps the chosen time when switched off', () {
      // Encoding "off" as a null time would lose the hour, and switching back
      // on would silently jump to a default the user never picked.
      const settings = ReminderSettings(enabled: false, hour: 7, minute: 5);
      final parsed = ReminderSettings.fromWire(settings.wireValue);
      expect(parsed.hour, 7);
      expect(parsed.enabled, isFalse);
    });

    test('falls back to the default rather than throwing on junk', () {
      for (final junk in ['', 'nonsense', '1|', '1|99:99', '1|aa:bb', '1|7']) {
        expect(ReminderSettings.fromWire(junk), ReminderSettings.initial,
            reason: 'for "$junk"');
      }
    });

    test('an absent preference is the default', () {
      expect(ReminderSettings.fromWire(null), ReminderSettings.initial);
    });

    test('reads as a 12-hour clock, like the rest of the copy', () {
      expect(const ReminderSettings(enabled: true, hour: 20, minute: 0).label,
          '08:00 PM');
      expect(const ReminderSettings(enabled: true, hour: 0, minute: 5).label,
          '12:05 AM');
      expect(const ReminderSettings(enabled: true, hour: 12, minute: 0).label,
          '12:00 PM');
    });
  });

  group('nextOccurrence', () {
    setUpAll(() {
      tz_data.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('UTC'));
    });

    tz.TZDateTime at(int hour, int minute) =>
        tz.TZDateTime(tz.local, 2026, 9, 11, hour, minute);

    test('later today when the time has not passed', () {
      final next = LocalNotificationReminderScheduler.nextOccurrence(
        const ReminderSettings(enabled: true, hour: 20, minute: 0),
        from: at(9, 0),
      );
      expect(next.day, 11);
      expect(next.hour, 20);
    });

    test('tomorrow when the time has already passed', () {
      // The case worth testing: scheduling into the past fires immediately or
      // not at all, depending on the platform.
      final next = LocalNotificationReminderScheduler.nextOccurrence(
        const ReminderSettings(enabled: true, hour: 8, minute: 0),
        from: at(9, 0),
      );
      expect(next.day, 12);
      expect(next.hour, 8);
    });

    test('tomorrow when the time is exactly now', () {
      final next = LocalNotificationReminderScheduler.nextOccurrence(
        const ReminderSettings(enabled: true, hour: 9, minute: 0),
        from: at(9, 0),
      );
      expect(next.day, 12);
    });
  });

  group('ReminderController', () {
    late FakeScheduler scheduler;
    late InMemoryStore store;

    setUp(() {
      scheduler = FakeScheduler();
      store = InMemoryStore();
    });

    ProviderContainer containerWith() {
      final container = ProviderContainer(overrides: [
        reminderSchedulerProvider.overrideWithValue(scheduler),
        reminderStorageProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    test('starts from the stored preference', () async {
      store.values[reminderSettingsKey] =
          const ReminderSettings(enabled: true, hour: 7, minute: 30).wireValue;

      final settings = await containerWith().read(reminderProvider.future);

      expect(settings.hour, 7);
      expect(settings.enabled, isTrue);
    });

    test('enabling asks permission, schedules, then persists', () async {
      final container = containerWith();
      await container.read(reminderProvider.future);

      await container.read(reminderProvider.notifier).setEnabled(true);

      expect(scheduler.permissionRequests, 1);
      expect(scheduler.scheduled!.enabled, isTrue);
      expect(store.values[reminderSettingsKey], isNotNull);
    });

    test('a refused permission leaves the setting off', () async {
      // A switch that stays on while the OS drops every notification is the
      // worst available outcome.
      scheduler.granted = false;
      final container = containerWith();
      await container.read(reminderProvider.future);

      await expectLater(
        container.read(reminderProvider.notifier).setEnabled(true),
        throwsA(isA<ReminderException>().having((e) => e.message, 'message',
            ReminderController.errorPermissionDenied)),
      );
      expect(scheduler.scheduled, isNull);
      expect(store.values[reminderSettingsKey], isNull);
      expect((await container.read(reminderProvider.future)).enabled, isFalse);
    });

    test('disabling cancels rather than scheduling', () async {
      final container = containerWith();
      await container.read(reminderProvider.future);
      await container.read(reminderProvider.notifier).setEnabled(true);

      await container.read(reminderProvider.notifier).setEnabled(false);

      expect(scheduler.cancelCount, 1);
      expect((await container.read(reminderProvider.future)).enabled, isFalse);
    });

    test('disabling does not ask for permission', () async {
      final container = containerWith();
      await container.read(reminderProvider.future);

      await container.read(reminderProvider.notifier).setEnabled(false);

      expect(scheduler.permissionRequests, 0);
    });

    test('changing the time while on reschedules', () async {
      final container = containerWith();
      await container.read(reminderProvider.future);
      await container.read(reminderProvider.notifier).setEnabled(true);

      await container
          .read(reminderProvider.notifier)
          .setTime(hour: 6, minute: 45);

      expect(scheduler.scheduled!.hour, 6);
      expect(scheduler.scheduled!.minute, 45);
    });

    test('changing the time while off stores it without scheduling', () async {
      // Picking a time first and switching on afterwards is a reasonable order.
      final container = containerWith();
      await container.read(reminderProvider.future);

      await container
          .read(reminderProvider.notifier)
          .setTime(hour: 6, minute: 45);

      expect(scheduler.scheduled, isNull);
      expect((await container.read(reminderProvider.future)).hour, 6);
    });

    test('nothing is persisted when scheduling fails', () async {
      // A stored 'on' with nothing scheduled behind it is a reminder the user
      // believes in and never receives.
      scheduler.scheduleThrows = Exception('channel unavailable');
      final container = containerWith();
      await container.read(reminderProvider.future);

      await expectLater(
        container.read(reminderProvider.notifier).setEnabled(true),
        throwsA(isA<ReminderException>().having((e) => e.message, 'message',
            ReminderController.errorScheduleFailed)),
      );
      expect(store.values[reminderSettingsKey], isNull);
    });
  });
}
