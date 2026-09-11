import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'reminder_service.dart';
import 'reminder_settings.dart';

/// Where the preference is kept.
///
/// Secure storage is not chosen for secrecy — a reminder time is not a secret —
/// but because the app already depends on it and every other small preference
/// lives there. Adding `shared_preferences` for one string would buy nothing.
const String reminderSettingsKey = 'meal_reminder';

final reminderStorageProvider = Provider<KeyValueStore>((ref) {
  return const SecureKeyValueStore();
});

/// The stored reminder preference, and the only thing that changes it.
///
/// Writing the preference and telling the OS about it happen together, because
/// a saved setting the scheduler never heard about is a reminder the user
/// believes is on and which never fires.
class ReminderController extends AsyncNotifier<ReminderSettings> {
  static const String errorPermissionDenied =
      'NOTIFICATIONS ARE OFF FOR THIS APP — ENABLE THEM IN SYSTEM SETTINGS';
  static const String errorScheduleFailed = "COULDN'T SET THE REMINDER";

  @override
  Future<ReminderSettings> build() async {
    final raw = await ref.read(reminderStorageProvider).read(
          reminderSettingsKey,
        );
    return ReminderSettings.fromWire(raw);
  }

  /// Turns the reminder on or off.
  ///
  /// Turning it on asks for permission first and gives up if refused, leaving
  /// the switch off. A switch that stays on while the OS silently drops every
  /// notification is the worst available outcome.
  Future<void> setEnabled(bool enabled) async {
    final current = state.value ?? ReminderSettings.initial;

    if (enabled) {
      final granted =
          await ref.read(reminderSchedulerProvider).requestPermission();
      if (!granted) {
        throw const ReminderException(errorPermissionDenied);
      }
    }
    await _apply(current.copyWith(enabled: enabled));
  }

  /// Changes the time. A change while the reminder is off is stored and not
  /// scheduled, so switching it on later uses the time the user picked.
  Future<void> setTime({required int hour, required int minute}) async {
    final current = state.value ?? ReminderSettings.initial;
    await _apply(current.copyWith(hour: hour, minute: minute));
  }

  Future<void> _apply(ReminderSettings next) async {
    final scheduler = ref.read(reminderSchedulerProvider);
    try {
      if (next.enabled) {
        await scheduler.schedule(next);
      } else {
        await scheduler.cancel();
      }
    } catch (_) {
      throw const ReminderException(errorScheduleFailed);
    }

    // Persisted only after the OS agreed. The reverse order would leave a
    // stored 'on' that nothing is scheduled behind.
    await ref
        .read(reminderStorageProvider)
        .write(reminderSettingsKey, next.wireValue);
    state = AsyncData(next);
  }
}

class ReminderException implements Exception {
  final String message;

  const ReminderException(this.message);

  @override
  String toString() => message;
}

final reminderProvider =
    AsyncNotifierProvider<ReminderController, ReminderSettings>(() {
  return ReminderController();
});

/// Minimal key-value seam, mirroring `ApiCredentialStore`'s.
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureKeyValueStore implements KeyValueStore {
  const SecureKeyValueStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}
