import 'dart:convert';

/// One calendar day of activity, as the projection consumes it.
///
/// Device-sourced and never written to Firestore, following [HealthMetrics]:
/// the only persistence is the encrypted local cache blob.
class DailyEnergy {
  /// Local midnight of the day this covers.
  final DateTime day;

  final int steps;
  final int workoutMinutes;

  /// Active energy burned, kcal. Excludes basal metabolism — the projection adds
  /// BMR itself, and a figure that already contained it would be counted twice.
  final double activeKcal;

  const DailyEnergy({
    required this.day,
    this.steps = 0,
    this.workoutMinutes = 0,
    this.activeKcal = 0,
  });

  /// Whether this day carries any evidence the user was measured at all.
  ///
  /// The distinction that matters for the projection: a genuine rest day and a
  /// day the phone sat on a desk both report zero activity, but only the first
  /// is data. A living person carrying a phone accumulates *some* steps, so a
  /// day with no steps, no workout, and no energy is treated as unmeasured.
  ///
  /// This is the same rule the intake average uses for days with no logged
  /// meals, and for the same reason: averaging in a false zero drags the mean
  /// down and makes the projection confidently wrong.
  bool get hasSignal => steps > 0 || workoutMinutes > 0 || activeKcal > 0;

  factory DailyEnergy.fromMap(Map<String, dynamic> map) {
    return DailyEnergy(
      day: _asDate(map['day']) ?? DateTime(1970),
      steps: _asInt(map['steps']),
      workoutMinutes: _asInt(map['workoutMinutes']),
      activeKcal: _asDouble(map['activeKcal']),
    );
  }

  Map<String, dynamic> toMap() => {
        'day': day.toIso8601String(),
        'steps': steps,
        'workoutMinutes': workoutMinutes,
        'activeKcal': activeKcal,
      };

  DailyEnergy copyWith({int? steps, int? workoutMinutes, double? activeKcal}) {
    return DailyEnergy(
      day: day,
      steps: steps ?? this.steps,
      workoutMinutes: workoutMinutes ?? this.workoutMinutes,
      activeKcal: activeKcal ?? this.activeKcal,
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.round() ?? 0;
    return 0;
  }

  static double _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _asDate(Object? v) {
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }
}

/// A rolling window of daily activity, oldest day first.
///
/// [fromMap] is defensive in the style of [HealthMetrics] — it never throws on
/// missing or mixed-encoding data — so a malformed cache degrades to an empty
/// window rather than blocking the projections screen.
class EnergyWindow {
  const EnergyWindow({required this.days, this.lastSynced});

  /// Oldest first. Days the platform had nothing for are still present, with
  /// zeroes; [measuredDays] is what separates them from real rest days.
  final List<DailyEnergy> days;

  final DateTime? lastSynced;

  factory EnergyWindow.empty() => const EnergyWindow(days: []);

  /// Only the days that carry evidence of measurement.
  List<DailyEnergy> get measuredDays =>
      days.where((d) => d.hasSignal).toList(growable: false);

  int get measuredDayCount => measuredDays.length;

  /// Mean active kcal/day across measured days, or `0` when nothing was
  /// measured.
  ///
  /// Averaged over measured days rather than over the whole window: a 14-day
  /// window holding three days of watch data would otherwise report roughly a
  /// fifth of the user's real burn.
  double get meanActiveKcal {
    final measured = measuredDays;
    if (measured.isEmpty) return 0;
    final total = measured.fold<double>(0, (sum, d) => sum + d.activeKcal);
    return total / measured.length;
  }

  /// Mean workout minutes/day across measured days.
  double get meanWorkoutMinutes {
    final measured = measuredDays;
    if (measured.isEmpty) return 0;
    final total = measured.fold<int>(0, (sum, d) => sum + d.workoutMinutes);
    return total / measured.length;
  }

  /// Mean steps/day across measured days.
  double get meanSteps {
    final measured = measuredDays;
    if (measured.isEmpty) return 0;
    final total = measured.fold<int>(0, (sum, d) => sum + d.steps);
    return total / measured.length;
  }

  /// Whether there is enough measured activity to base a burn estimate on.
  ///
  /// Three days is the floor: fewer and one unusually active afternoon sets the
  /// mean for the whole projection.
  bool get isUsable => measuredDayCount >= 3;

  factory EnergyWindow.fromMap(Map<String, dynamic> map) {
    final rawDays = map['days'];
    final parsed = <DailyEnergy>[];
    if (rawDays is List) {
      for (final raw in rawDays) {
        if (raw is Map<String, dynamic>) parsed.add(DailyEnergy.fromMap(raw));
      }
    }
    parsed.sort((a, b) => a.day.compareTo(b.day));
    return EnergyWindow(
      days: parsed,
      lastSynced: DailyEnergy._asDate(map['lastSynced']),
    );
  }

  Map<String, dynamic> toMap() => {
        'days': days.map((d) => d.toMap()).toList(),
        'lastSynced': lastSynced?.toIso8601String(),
      };

  String toJsonString() => jsonEncode(toMap());

  static EnergyWindow? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return EnergyWindow.fromMap(decoded);
    } catch (_) {
      // Corrupt blob — treat as absent.
    }
    return null;
  }
}
