import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/models/health_metrics.dart';

void main() {
  group('HealthMetrics', () {
    test('empty() is all zero with null lastSynced', () {
      final m = HealthMetrics.empty();
      expect(m.steps, 0);
      expect(m.waterOz, 0);
      expect(m.workoutMinutes, 0);
      expect(m.lastSynced, isNull);
    });

    test('toMap/fromMap round-trip with lastSynced set', () {
      final ts = DateTime.utc(2026, 8, 2, 14, 45);
      final m = HealthMetrics(
          steps: 8432, waterOz: 64.0, workoutMinutes: 45, lastSynced: ts);
      final back = HealthMetrics.fromMap(m.toMap());
      expect(back.steps, 8432);
      expect(back.waterOz, 64.0);
      expect(back.workoutMinutes, 45);
      expect(back.lastSynced, ts);
    });

    test('fromMap with missing keys defaults to zero/null', () {
      final m = HealthMetrics.fromMap({});
      expect(m.steps, 0);
      expect(m.waterOz, 0);
      expect(m.workoutMinutes, 0);
      expect(m.lastSynced, isNull);
    });

    test('fromMap tolerates mixed numeric encodings (String vs num)', () {
      final m = HealthMetrics.fromMap({
        'steps': '8432',
        'waterOz': '64.0',
        'workoutMinutes': 45,
      });
      expect(m.steps, 8432);
      expect(m.waterOz, 64.0);
      expect(m.workoutMinutes, 45);
    });

    test('fromJsonString(null) returns null', () {
      expect(HealthMetrics.fromJsonString(null), isNull);
    });

    test('toJsonString/fromJsonString round-trip', () {
      final m = HealthMetrics(
          steps: 100,
          waterOz: 8.0,
          workoutMinutes: 10,
          lastSynced: DateTime.utc(2026, 1, 1));
      final back = HealthMetrics.fromJsonString(m.toJsonString());
      expect(back!.steps, 100);
      expect(back.lastSynced, DateTime.utc(2026, 1, 1));
    });
  });
}
