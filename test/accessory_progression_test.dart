// Accessory double progression (program.yaml v12 accessory_progression)
// — RPE-nudged load suggestions for planned accessory rows.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/accessory_progression.dart';
import 'package:airledger/services/program_metrics.dart' show StrengthRow;

StrengthRow row(String date, String ex, double w, int reps, {double? rpe}) =>
    StrengthRow(
      date: DateTime.parse(date),
      exercise: ex,
      weight: w,
      reps: reps,
      rpe: rpe,
    );

void main() {
  final asOf = DateTime.utc(2026, 10, 5);

  group('suggestAccessoryLoad', () {
    test('no history → null (never guess)', () {
      expect(
        suggestAccessoryLoad(
            exercise: 'Seated Cable Row', history: const [], asOf: asOf),
        isNull,
      );
    });

    test('bodyweight-only history (weight 0) → null', () {
      final h = [row('2026-10-01', 'Pull Up', 0, 8, rpe: 8)];
      expect(
        suggestAccessoryLoad(exercise: 'Pull Up', history: h, asOf: asOf),
        isNull,
      );
    });

    test('same-day and future rows are excluded', () {
      final h = [row('2026-10-05', 'Seated Cable Row', 100, 8, rpe: 8)];
      expect(
        suggestAccessoryLoad(
            exercise: 'Seated Cable Row', history: h, asOf: asOf),
        isNull,
      );
    });

    test('all sets at top of range at <=2 RIR → +5', () {
      final h = [
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 8),
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 8.5),
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 9),
      ];
      final s = suggestAccessoryLoad(
        exercise: 'Seated Cable Row',
        history: h,
        asOf: asOf,
        repRangeHigh: 10,
      )!;
      expect(s.action, 'overload');
      expect(s.weightLb, 105);
      expect(s.lastWeightLb, 100);
    });

    test('isolation exercises get +2.5', () {
      const rule = AccessoryRule(isolation: {'Lateral Dumbbell Raise'});
      final h = [
        row('2026-09-30', 'Lateral Dumbbell Raise', 20, 20, rpe: 8),
        row('2026-09-30', 'Lateral Dumbbell Raise', 20, 20, rpe: 8),
      ];
      final s = suggestAccessoryLoad(
        exercise: 'Lateral Dumbbell Raise',
        history: h,
        asOf: asOf,
        repRangeHigh: 20,
        rule: rule,
      )!;
      expect(s.action, 'overload');
      expect(s.weightLb, 22.5);
    });

    test('one set below top of range → hold', () {
      final h = [
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 8),
        row('2026-09-30', 'Seated Cable Row', 100, 8, rpe: 8.5),
      ];
      final s = suggestAccessoryLoad(
        exercise: 'Seated Cable Row',
        history: h,
        asOf: asOf,
        repRangeHigh: 10,
      )!;
      expect(s.action, 'hold');
      expect(s.weightLb, 100);
    });

    test('a set at <=2 RIR but missing RPE elsewhere → hold '
        '(unknown effort never proves overload)', () {
      final h = [
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 8),
        row('2026-09-30', 'Seated Cable Row', 100, 10), // no RPE
      ];
      final s = suggestAccessoryLoad(
        exercise: 'Seated Cable Row',
        history: h,
        asOf: asOf,
        repRangeHigh: 10,
      )!;
      expect(s.action, 'hold');
      expect(s.weightLb, 100);
    });

    test('top-of-range reps at 3+ RIR (RPE < 8) → hold', () {
      final h = [
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 7),
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 7.5),
      ];
      final s = suggestAccessoryLoad(
        exercise: 'Seated Cable Row',
        history: h,
        asOf: asOf,
        repRangeHigh: 10,
      )!;
      expect(s.action, 'hold');
    });

    test('no rep range known → overload impossible, hold', () {
      final h = [row('2026-09-30', 'Seated Cable Row', 100, 12, rpe: 9)];
      final s = suggestAccessoryLoad(
          exercise: 'Seated Cable Row', history: h, asOf: asOf)!;
      expect(s.action, 'hold');
      expect(s.weightLb, 100);
    });

    test('avg RPE > 9 → −5% rounded DOWN to the step', () {
      final h = [
        row('2026-09-30', 'Triceps Extension', 60, 8, rpe: 9.5),
        row('2026-09-30', 'Triceps Extension', 60, 6, rpe: 9),
      ];
      final s = suggestAccessoryLoad(
        exercise: 'Triceps Extension',
        history: h,
        asOf: asOf,
        repRangeHigh: 15,
      )!;
      expect(s.action, 'backoff');
      // 60 × 0.95 = 57 → floor to 5 → 55.
      expect(s.weightLb, 55);
    });

    test('backoff on a small isolation load actually decreases', () {
      const rule = AccessoryRule(isolation: {'Lateral Dumbbell Raise'});
      final h = [
        row('2026-09-30', 'Lateral Dumbbell Raise', 20, 12, rpe: 9.5),
      ];
      final s = suggestAccessoryLoad(
        exercise: 'Lateral Dumbbell Raise',
        history: h,
        asOf: asOf,
        repRangeHigh: 20,
        rule: rule,
      )!;
      expect(s.action, 'backoff');
      // 20 × 0.95 = 19 → floor to 2.5 → 17.5.
      expect(s.weightLb, 17.5);
    });

    test('backoff beats overload when both would fire', () {
      // All sets top-of-range at RIR 0-ish AND avg > 9 → too hard: back
      // off, don't add load.
      final h = [
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 9.5),
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 9.5),
      ];
      final s = suggestAccessoryLoad(
        exercise: 'Seated Cable Row',
        history: h,
        asOf: asOf,
        repRangeHigh: 10,
      )!;
      expect(s.action, 'backoff');
      expect(s.weightLb, 95);
    });

    test('uses the LAST session only, heaviest set as reference', () {
      final h = [
        row('2026-09-20', 'Seated Cable Row', 90, 10, rpe: 8),
        row('2026-09-30', 'Seated Cable Row', 100, 10, rpe: 8),
        row('2026-09-30', 'Seated Cable Row', 95, 10, rpe: 8),
      ];
      final s = suggestAccessoryLoad(
        exercise: 'Seated Cable Row',
        history: h,
        asOf: asOf,
        repRangeHigh: 10,
      )!;
      expect(s.lastDate, DateTime.utc(2026, 9, 30));
      expect(s.action, 'overload');
      expect(s.weightLb, 105);
    });
  });

  group('AccessoryRule.fromVersion', () {
    test('missing key → defaults', () {
      final r = AccessoryRule.fromVersion({});
      expect(r.stepLb, 5);
      expect(r.isolationStepLb, 2.5);
      expect(r.backoffPct, 5);
      expect(r.backoffAvgRpeGt, 9);
      expect(r.overloadMinRpe, 8);
      expect(r.isolation, isEmpty);
    });

    test('parses declared values + isolation list', () {
      final r = AccessoryRule.fromVersion({
        'accessory_progression': {
          'step_lb': 10,
          'isolation_step_lb': 2.5,
          'backoff_pct': 7.5,
          'backoff_avg_rpe_gt': 8.5,
          'target_rir_max': 1,
          'isolation': ['Lateral Dumbbell Raise', 'Triceps Extension'],
        },
      });
      expect(r.stepLb, 10);
      expect(r.backoffPct, 7.5);
      expect(r.backoffAvgRpeGt, 8.5);
      expect(r.overloadMinRpe, 9);
      expect(r.stepFor('Triceps Extension'), 2.5);
      expect(r.stepFor('Seated Cable Row'), 10);
    });

    test('malformed value → defaults, never throws', () {
      final r = AccessoryRule.fromVersion({'accessory_progression': 'nope'});
      expect(r.stepLb, 5);
    });
  });
}
