import 'dart:math';

/// How an entry got into the log.
enum FoodSource {
  vision,
  manual;

  /// Stable wire value written to the on-device JSON file.
  String get wireValue => name;

  /// Parses defensively: any unknown or null value falls back to [manual] so a
  /// malformed entry never throws or costs the user the rest of their log.
  static FoodSource fromWire(Object? value) {
    switch (value?.toString().trim().toLowerCase()) {
      case 'vision':
        return FoodSource.vision;
      case 'manual':
      default:
        return FoodSource.manual;
    }
  }
}

/// Macro figures for **one serving** of a food.
///
/// Two read constructors, deliberately separate: [Nutrients.fromApi] speaks the
/// microservice's snake_case wire format, [Nutrients.fromMap] speaks the stored
/// camelCase format. Keeping them apart means a provider prompt change cannot
/// silently reshape stored entries.
class Nutrients {
  final double calories;
  final double proteinG;
  final double carbsG;
  final double fatsG;

  const Nutrients({
    this.calories = 0,
    this.proteinG = 0,
    this.carbsG = 0,
    this.fatsG = 0,
  });

  /// Reads the microservice's snake_case response.
  ///
  /// `parsing.py:normalize()` builds its nutrients map with `nutrients.get(...)`,
  /// which emits `null` for anything the model omitted, so every field coerces
  /// `null` to `0`. The user sees the zero in the editable form and can correct
  /// it before saving.
  factory Nutrients.fromApi(Map<String, dynamic> map) => Nutrients(
        calories: _toDouble(map['calories']),
        proteinG: _toDouble(map['protein_g']),
        carbsG: _toDouble(map['carbs_g']),
        fatsG: _toDouble(map['fats_g']),
      );

  /// Reads the stored camelCase shape, matching `UserProfile`'s convention.
  factory Nutrients.fromMap(Map<String, dynamic> map) => Nutrients(
        calories: _toDouble(map['calories']),
        proteinG: _toDouble(map['proteinG']),
        carbsG: _toDouble(map['carbsG']),
        fatsG: _toDouble(map['fatsG']),
      );

  Map<String, dynamic> toMap() => {
        'calories': calories,
        'proteinG': proteinG,
        'carbsG': carbsG,
        'fatsG': fatsG,
      };

  static double _toDouble(Object? value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? fallback;
    return fallback;
  }
}

/// One logged food item.
///
/// Follows `UserProfile`'s tolerant-parsing style, which matters more here: the
/// JSON file is the only copy of the data, so a single malformed entry must not
/// make the whole log unreadable.
class FoodEntry {
  /// Current on-disk schema version. Bump when the shape changes.
  static const int currentSchemaVersion = 1;

  /// Stepper bounds. Quantity is a serving multiplier, not a gram weight.
  static const double minQuantity = 0.5;
  static const double quantityStep = 0.5;
  static const double maxQuantity = 20;

  final String id;
  final String name;

  /// Always per **one** serving. Never pre-multiplied by [quantity].
  final Nutrients nutrients;

  /// Serving multiplier, clamped to [minQuantity]..[maxQuantity].
  final double quantity;

  final FoodSource source;

  /// Local wall-clock time, stored without an offset suffix so the reading the
  /// user remembers ("lunch at 12:30") stays 12:30 across a timezone change.
  final DateTime loggedAt;

  final int schemaVersion;

  const FoodEntry({
    required this.id,
    required this.name,
    required this.nutrients,
    required this.quantity,
    required this.source,
    required this.loggedAt,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Builds a new entry, generating an id and defaulting [loggedAt] to now.
  factory FoodEntry.create({
    required String name,
    required Nutrients nutrients,
    required double quantity,
    required FoodSource source,
    DateTime? loggedAt,
  }) {
    return FoodEntry(
      id: generateId(),
      name: name.trim(),
      nutrients: nutrients,
      quantity: clampQuantity(quantity),
      source: source,
      loggedAt: loggedAt ?? DateTime.now(),
    );
  }

  /// 16 random bytes as hex, generated the same way `session_provider.dart`
  /// generates session ids. Entries need stable identity for `ListView` keys
  /// now, and for edit/delete later; a timestamp would collide on a double-tap
  /// and a list index is not stable across a delete.
  static String generateId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static double clampQuantity(double value) =>
      value.clamp(minQuantity, maxQuantity).toDouble();

  // ── Totals: per-serving nutrients scaled by quantity ──
  double get totalCalories => nutrients.calories * quantity;
  double get totalProteinG => nutrients.proteinG * quantity;
  double get totalCarbsG => nutrients.carbsG * quantity;
  double get totalFatsG => nutrients.fatsG * quantity;

  /// Tolerant parse for a stored entry. Returns `null` only when the entry
  /// cannot be rendered at all:
  ///
  /// - an unparseable or absent `loggedAt` — there is no day bucket for it to
  ///   live in, so it would be invisible anyway;
  /// - an empty `name` — it would render as a blank row.
  ///
  /// Everything else defaults, so a missing macro costs one number rather than
  /// the whole entry.
  static FoodEntry? tryFromMap(Map<String, dynamic> map) {
    final loggedAt = DateTime.tryParse(map['loggedAt']?.toString() ?? '');
    if (loggedAt == null) return null;

    final name = map['name']?.toString().trim() ?? '';
    if (name.isEmpty) return null;

    final rawNutrients = map['nutrients'];

    return FoodEntry(
      // A stored entry with no id predates nothing, but synthesizing one is
      // cheaper than discarding a real meal over a missing key.
      id: (map['id']?.toString().trim().isNotEmpty ?? false)
          ? map['id'].toString()
          : generateId(),
      name: name,
      nutrients: rawNutrients is Map<String, dynamic>
          ? Nutrients.fromMap(rawNutrients)
          : const Nutrients(),
      quantity: clampQuantity(_toDouble(map['quantity'], fallback: 1.0)),
      source: FoodSource.fromWire(map['source']),
      loggedAt: loggedAt,
      schemaVersion: _toInt(map['schemaVersion'], fallback: 1),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'nutrients': nutrients.toMap(),
        'quantity': quantity,
        'source': source.wireValue,
        // A local DateTime writes as `2026-08-22T12:30:00.000` with no offset,
        // and DateTime.parse reads that back as local, so it round-trips.
        'loggedAt': loggedAt.toIso8601String(),
        'schemaVersion': currentSchemaVersion,
      };

  FoodEntry copyWith({
    String? name,
    Nutrients? nutrients,
    double? quantity,
    FoodSource? source,
    DateTime? loggedAt,
  }) {
    return FoodEntry(
      id: id,
      name: name ?? this.name,
      nutrients: nutrients ?? this.nutrients,
      quantity: quantity == null ? this.quantity : clampQuantity(quantity),
      source: source ?? this.source,
      loggedAt: loggedAt ?? this.loggedAt,
      schemaVersion: schemaVersion,
    );
  }

  // ── Parsing helpers (tolerant of String / num / null) ──

  static double _toDouble(Object? value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  static int _toInt(Object? value, {int fallback = 0}) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }
}
