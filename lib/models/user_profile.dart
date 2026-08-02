import 'dart:convert';

/// The user's weight objective. Drives the projections screen and the
/// goals/diet editing flow.
enum WeightGoal {
  lose,
  maintain,
  gain;

  /// Stable wire value stored in Firestore and the local JSON blob.
  String get wireValue => name;

  /// Parses defensively: any unknown or null value falls back to [maintain]
  /// so a malformed document never throws or blocks the user.
  static WeightGoal fromWire(Object? value) {
    switch (value?.toString().trim().toLowerCase()) {
      case 'lose':
        return WeightGoal.lose;
      case 'gain':
        return WeightGoal.gain;
      case 'maintain':
      default:
        return WeightGoal.maintain;
    }
  }
}

/// Immutable user profile. Single typed representation shared by the session
/// layer, the settings screens, and persistence.
///
/// Reads tolerate both the current (v2) schema and legacy (v1) documents that
/// only had the four physical metrics — every field defaults rather than
/// throwing on missing/mismatched data, which is what makes the per-user
/// backfill safe.
class UserProfile {
  /// Current on-disk / Firestore schema version. Bump when the shape changes.
  static const int currentSchemaVersion = 2;

  /// The fixed set of allergies offered as multi-select chips.
  static const List<String> allergyOptions = [
    'Peanuts',
    'Tree nuts',
    'Dairy',
    'Eggs',
    'Gluten',
    'Soy',
    'Shellfish',
    'Fish',
  ];

  /// Weekly rate choices in kg/week.
  static const List<double> weeklyRateOptions = [0.25, 0.5, 0.75];

  // ── Existing physical metrics ──
  final double height; // cm
  final double weight; // kg (current weight)
  final int age;
  final String gender; // MALE / FEMALE / OTHER

  // ── New goal & diet fields ──
  final WeightGoal goal;
  final double targetWeight; // kg
  final double weeklyRate; // kg/week
  final List<String> allergies;

  const UserProfile({
    required this.height,
    required this.weight,
    required this.age,
    required this.gender,
    required this.goal,
    required this.targetWeight,
    required this.weeklyRate,
    required this.allergies,
  });

  /// A blank profile used as a starting point before any data is collected.
  factory UserProfile.empty() => const UserProfile(
        height: 0,
        weight: 0,
        age: 0,
        gender: 'MALE',
        goal: WeightGoal.maintain,
        targetWeight: 0,
        weeklyRate: 0.5,
        allergies: [],
      );

  /// Builds a profile from a Firestore document map or a decoded local JSON
  /// blob. Handles missing keys and mixed numeric encodings (Firestore returns
  /// `num`; the legacy local store wrote everything as `String`).
  factory UserProfile.fromMap(Map<String, dynamic> map) {
    final weight = _toDouble(map['weight']);
    return UserProfile(
      height: _toDouble(map['height']),
      weight: weight,
      age: _toInt(map['age']),
      gender: (map['gender']?.toString().trim().isNotEmpty ?? false)
          ? map['gender'].toString()
          : 'MALE',
      goal: WeightGoal.fromWire(map['goal']),
      // Missing target defaults to the current weight so an un-migrated user
      // starts "on maintain" rather than targeting 0 kg.
      targetWeight: map.containsKey('targetWeight')
          ? _toDouble(map['targetWeight'])
          : weight,
      weeklyRate: map.containsKey('weeklyRate')
          ? _toDouble(map['weeklyRate'], fallback: 0.5)
          : 0.5,
      allergies: _toStringList(map['allergies']),
    );
  }

  /// Decodes the local JSON blob. Returns `null` when the blob is absent or
  /// unparseable so callers can fall back to a fresh/remote profile.
  static UserProfile? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return UserProfile.fromMap(decoded);
      }
    } catch (_) {
      // Corrupt blob — treat as absent.
    }
    return null;
  }

  /// Serializes for Firestore / local storage. Includes [currentSchemaVersion]
  /// so a future migration can distinguish document versions.
  ///
  /// Note: this intentionally omits `sessionId` / `createdAt` / API credentials.
  /// Persistence writes with merge semantics so those fields are preserved.
  Map<String, dynamic> toMap() => {
        'height': height,
        'weight': weight,
        'age': age,
        'gender': gender,
        'goal': goal.wireValue,
        'targetWeight': targetWeight,
        'weeklyRate': weeklyRate,
        'allergies': allergies,
        'schemaVersion': currentSchemaVersion,
      };

  String toJsonString() => jsonEncode(toMap());

  UserProfile copyWith({
    double? height,
    double? weight,
    int? age,
    String? gender,
    WeightGoal? goal,
    double? targetWeight,
    double? weeklyRate,
    List<String>? allergies,
  }) {
    return UserProfile(
      height: height ?? this.height,
      weight: weight ?? this.weight,
      age: age ?? this.age,
      gender: gender ?? this.gender,
      goal: goal ?? this.goal,
      targetWeight: targetWeight ?? this.targetWeight,
      weeklyRate: weeklyRate ?? this.weeklyRate,
      allergies: allergies ?? this.allergies,
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
    if (value is String) {
      return int.tryParse(value.trim()) ??
          double.tryParse(value.trim())?.toInt() ??
          fallback;
    }
    return fallback;
  }

  static List<String> _toStringList(Object? value) {
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return const [];
  }
}
