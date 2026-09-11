import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'reminder_settings.dart';

/// Scheduling and cancelling the daily meal reminder.
///
/// An interface so the settings screen and its tests never touch the plugin:
/// `flutter_local_notifications` has no in-memory implementation, and a screen
/// that could only be tested with a live notification channel would not be
/// tested.
abstract class ReminderScheduler {
  /// Asks the OS for permission. Returns false if the user refused, which is a
  /// decision the caller has to respect rather than retry.
  Future<bool> requestPermission();

  /// Replaces any existing reminder with one at [settings]' time.
  Future<void> schedule(ReminderSettings settings);

  Future<void> cancel();
}

class LocalNotificationReminderScheduler implements ReminderScheduler {
  LocalNotificationReminderScheduler([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  /// One fixed id, so scheduling twice replaces rather than stacks. A user who
  /// changed the time three times should not be reminded three times.
  static const int notificationId = 1001;

  static const String channelId = 'meal_reminder';
  static const String channelName = 'Meal reminders';
  static const String channelDescription =
      'A daily nudge to log what you ate.';

  static const String title = 'Log your meals';
  static const String body = "What did you eat today? It takes a few seconds.";

  Future<void> _ensureReady() async {
    if (_ready) return;
    // The timezone database has to be loaded before any TZDateTime exists, and
    // the local zone set, or `tz.local` is UTC and an 8pm reminder fires at
    // whatever 8pm UTC happens to be where the user lives.
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(await _deviceTimeZone()));

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          // Requested explicitly in requestPermission() instead, so the prompt
          // appears when the user turns the reminder on rather than at launch.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _ready = true;
  }

  /// The IANA name of the device's zone.
  ///
  /// `DateTime.now().timeZoneName` gives an abbreviation like "IST", which is
  /// ambiguous — India and Israel both use it — so the offset is matched against
  /// the database instead. A zone that cannot be identified falls back to UTC,
  /// which makes the reminder fire at the wrong hour rather than not at all.
  Future<String> _deviceTimeZone() async {
    final offset = DateTime.now().timeZoneOffset;
    for (final name in tz.timeZoneDatabase.locations.keys) {
      final location = tz.timeZoneDatabase.locations[name]!;
      if (tz.TZDateTime.now(location).timeZoneOffset == offset) return name;
    }
    return 'UTC';
  }

  @override
  Future<bool> requestPermission() async {
    await _ensureReady();

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }

    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    return true;
  }

  @override
  Future<void> schedule(ReminderSettings settings) async {
    await _ensureReady();
    await _plugin.zonedSchedule(
      id: notificationId,
      title: title,
      body: body,
      scheduledDate: nextOccurrence(settings, from: tz.TZDateTime.now(tz.local)),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      // Inexact deliberately: a meal reminder does not justify asking for
      // SCHEDULE_EXACT_ALARM, which Android 14 grants grudgingly and users
      // reasonably distrust. A few minutes' drift costs nothing here.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  /// The next time [settings]' clock time comes around, at or after [from].
  ///
  /// Pure and separated out because the only interesting case — asking for a
  /// time that has already passed today, which must land tomorrow rather than
  /// in the past — cannot be tested through the plugin.
  static tz.TZDateTime nextOccurrence(
    ReminderSettings settings, {
    required tz.TZDateTime from,
  }) {
    var next = tz.TZDateTime(
      from.location,
      from.year,
      from.month,
      from.day,
      settings.hour,
      settings.minute,
    );
    if (!next.isAfter(from)) {
      next = next.add(const Duration(days: 1));
    }
    return next;
  }

  @override
  Future<void> cancel() async {
    await _ensureReady();
    await _plugin.cancel(id: notificationId);
  }
}

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  return LocalNotificationReminderScheduler();
});
