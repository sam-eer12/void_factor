/// When, if ever, to nudge the user to log a meal.
///
/// A value type so the preference can be read, compared and stored without any
/// of that depending on the notification plugin.
class ReminderSettings {
  /// Both halves of the stored preference. `enabled` is kept separately from the
  /// time rather than encoded as a null time, so switching the reminder off and
  /// on again returns it to the hour the user chose rather than to a default.
  final bool enabled;
  final int hour;
  final int minute;

  const ReminderSettings({
    required this.enabled,
    required this.hour,
    required this.minute,
  });

  /// Off, at a time most people have finished eating and can still remember
  /// what they ate.
  static const ReminderSettings initial =
      ReminderSettings(enabled: false, hour: 20, minute: 0);

  ReminderSettings copyWith({bool? enabled, int? hour, int? minute}) =>
      ReminderSettings(
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
      );

  /// `'20:00'`. Stored as text rather than two keys so the pair can never be
  /// read half-updated.
  String get wireValue =>
      '${enabled ? 1 : 0}|${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}';

  /// Parses defensively: anything unrecognised falls back to [initial] rather
  /// than throwing, so a corrupt preference costs the setting and not the
  /// screen.
  static ReminderSettings fromWire(String? raw) {
    if (raw == null) return initial;
    final parts = raw.split('|');
    if (parts.length != 2) return initial;
    final clock = parts[1].split(':');
    if (clock.length != 2) return initial;

    final hour = int.tryParse(clock[0]);
    final minute = int.tryParse(clock[1]);
    if (hour == null || minute == null) return initial;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return initial;

    return ReminderSettings(
      enabled: parts[0] == '1',
      hour: hour,
      minute: minute,
    );
  }

  /// `'08:00 PM'`, matching the 12-hour clock the rest of the app's copy uses.
  String get label {
    final h = hour % 12 == 0 ? 12 : hour % 12;
    final suffix = hour < 12 ? 'AM' : 'PM';
    return '${h.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')} $suffix';
  }

  @override
  bool operator ==(Object other) =>
      other is ReminderSettings &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(enabled, hour, minute);
}
