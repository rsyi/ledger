import 'package:airledger/services/set_recommendation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('recommendSet', () {
    test('no history → conservative start', () {
      final r = recommendSet(const []);
      expect(r.lastSessionSummary, isNull);
      expect(r.advice.toLowerCase(), contains('no prior'));
    });

    test('easy last session (RPE ≤ 8) → nudge up', () {
      final r = recommendSet(const [
        PriorSet(reps: 10, weight: 95, rpe: 7.5),
        PriorSet(reps: 10, weight: 95, rpe: 8),
      ]);
      expect(r.lastSessionSummary, contains('95'));
      expect(r.advice.toLowerCase(), contains('add'));
    });

    test('grind last session (RPE ≥ 9.5) → hold', () {
      final r = recommendSet(const [PriorSet(reps: 3, weight: 250, rpe: 9.5)]);
      expect(r.advice.toLowerCase(), contains('hold'));
    });

    test('on-target (RPE 9) → repeat, one more rep', () {
      final r = recommendSet(const [PriorSet(reps: 8, weight: 135, rpe: 9)]);
      expect(r.advice.toLowerCase(), contains('one more rep'));
    });

    test('bodyweight (no load) summarises reps/sets', () {
      final r = recommendSet(const [
        PriorSet(reps: 12),
        PriorSet(reps: 10),
      ]);
      expect(r.lastSessionSummary, contains('2 sets'));
      expect(r.lastSessionSummary, contains('10–12 reps'));
    });
  });
}
