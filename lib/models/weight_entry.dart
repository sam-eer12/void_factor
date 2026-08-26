import 'dart:math';

/// One recorded body weight.
///
/// Follows `FoodEntry`'s tolerant-parsing style, and for the same reason: the
/// on-device JSON file is the only copy, so one malformed entry must not cost
/// the user the rest of their history.
///
/// Where it deliberately differs is what counts as unrenderable. A food entry
/// with a missing macro still renders — it loses one number. A weight entry
/// *is* one number, so an absent or implausible weight has nothing left to
/// show, and a 0 kg point silently dragged into a regression would bend the
/// whole trend line. Those entries are dropped rather than defaulted.
class WeightEntry {
  /// Current on-disk schema version. Bump when the shape changes.
  static const int currentSchemaVersion = 1;

  /// Plausible human body weight, in kg.
  ///
  /// Wide on purpose. These are guards against a typo or a corrupt file — a
  /// fat-fingered `750` for `75.0` — not a judgement about any real body.
  static const double minKg = 20;
  static const double maxKg = 500;

  final String id;

  /// Always kilograms. The profile stores kg and the projection math is defined
  /// in kg, so there is no second unit to convert at rest; a lb-preferring UI
  /// converts at the edge on the way in and out.
  final double weightKg;

  /// Local wall-clock time, stored without an offset suffix — the same choice
  /// `FoodEntry.loggedAt` makes, so "Tuesday's weigh-in" stays on Tuesday
  /// across a timezone change.
  final DateTime recordedAt;

  final int schemaVersion;

  const WeightEntry({
    required this.id,
    required this.weightKg,
    required this.recordedAt,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Builds a new entry, generating an id and defaulting [recordedAt] to now.
  factory WeightEntry.create({
    required double weightKg,
    DateTime? recordedAt,
  }) {
    return WeightEntry(
      id: generateId(),
      weightKg: clampKg(weightKg),
      recordedAt: recordedAt ?? DateTime.now(),
    );
  }

  /// 16 random bytes as hex, generated the way `FoodEntry.generateId` and
  /// `session_provider.dart` generate theirs.
  static String generateId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static double clampKg(double value) => value.clamp(minKg, maxKg).toDouble();

  /// Whether [value] is a weight worth storing.
  ///
  /// Used by the entry sheet to refuse a value rather than silently clamp it:
  /// clamping `750` to `500` would record a weight the user never typed and
  /// never saw, and the projection would then be built on it.
  static bool isPlausible(double value) =>
      value.isFinite && value >= minKg && value <= maxKg;

  /// Local midnight of the day this weight belongs to.
  ///
  /// The projection plots one point per day, so this is the bucket key. Derived
  /// rather than stored: a stored copy could disagree with [recordedAt] after a
  /// schema change, and then two "days" would exist for one measurement.
  DateTime get day =>
      DateTime(recordedAt.year, recordedAt.month, recordedAt.day);

  /// Tolerant parse for a stored entry. Returns `null` when the entry cannot be
  /// plotted at all:
  ///
  /// - an unparseable or absent `recordedAt` — there is no day to plot it on;
  /// - a missing, non-numeric, or implausible `weightKg` — see the class note.
  static WeightEntry? tryFromMap(Map<String, dynamic> map) {
    final recordedAt = DateTime.tryParse(map['recordedAt']?.toString() ?? '');
    if (recordedAt == null) return null;

    final weightKg = _toDoubleOrNull(map['weightKg']);
    if (weightKg == null || !isPlausible(weightKg)) return null;

    return WeightEntry(
      // A stored entry with no id predates nothing, but synthesizing one is
      // cheaper than discarding a real measurement over a missing key.
      id: (map['id']?.toString().trim().isNotEmpty ?? false)
          ? map['id'].toString()
          : generateId(),
      weightKg: weightKg,
      recordedAt: recordedAt,
      schemaVersion: _toInt(map['schemaVersion'], fallback: 1),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'weightKg': weightKg,
        // A local DateTime writes as `2026-08-26T07:30:00.000` with no offset,
        // and DateTime.parse reads that back as local, so it round-trips.
        'recordedAt': recordedAt.toIso8601String(),
        'schemaVersion': currentSchemaVersion,
      };

  WeightEntry copyWith({double? weightKg, DateTime? recordedAt}) {
    return WeightEntry(
      id: id,
      weightKg: weightKg == null ? this.weightKg : clampKg(weightKg),
      recordedAt: recordedAt ?? this.recordedAt,
      schemaVersion: schemaVersion,
    );
  }

  // ── Parsing helpers (tolerant of String / num / null) ──

  /// Returns `null` rather than a fallback, because for this field there is no
  /// safe default — see the class note.
  static double? _toDoubleOrNull(Object? value) {
    if (value is num) {
      final asDouble = value.toDouble();
      return asDouble.isFinite ? asDouble : null;
    }
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static int _toInt(Object? value, {int fallback = 0}) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }
}
