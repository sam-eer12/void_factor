import 'dart:convert';

/// Whether the user has connected a platform health store.
enum HealthConnectionStatus { disabled, enabled, unavailable }

/// Read-only snapshot of today's health metrics (local midnight → now).
///
/// Device-sourced and never written to Firestore; the only persistence is the
/// encrypted local cache blob (`health_metrics_json`) for instant launch
/// display. [fromMap] is defensive — it never throws on missing or
/// mixed-encoding data — so a malformed cache degrades to defaults.
class HealthMetrics {
  const HealthMetrics({
    required this.steps,
    required this.waterOz,
    required this.workoutMinutes,
    this.lastSynced,
  });

  final int steps;
  final double waterOz;
  final int workoutMinutes;
  final DateTime? lastSynced;

  factory HealthMetrics.empty() =>
      const HealthMetrics(steps: 0, waterOz: 0, workoutMinutes: 0);

  factory HealthMetrics.fromMap(Map<String, dynamic> map) {
    return HealthMetrics(
      steps: _asInt(map['steps']),
      waterOz: _asDouble(map['waterOz']),
      workoutMinutes: _asInt(map['workoutMinutes']),
      lastSynced: _asDate(map['lastSynced']),
    );
  }

  Map<String, dynamic> toMap() => {
        'steps': steps,
        'waterOz': waterOz,
        'workoutMinutes': workoutMinutes,
        'lastSynced': lastSynced?.toIso8601String(),
      };

  HealthMetrics copyWith({
    int? steps,
    double? waterOz,
    int? workoutMinutes,
    DateTime? lastSynced,
  }) {
    return HealthMetrics(
      steps: steps ?? this.steps,
      waterOz: waterOz ?? this.waterOz,
      workoutMinutes: workoutMinutes ?? this.workoutMinutes,
      lastSynced: lastSynced ?? this.lastSynced,
    );
  }

  String toJsonString() => jsonEncode(toMap());

  static HealthMetrics? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return HealthMetrics.fromMap(decoded);
      }
    } catch (_) {}
    return null;
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
