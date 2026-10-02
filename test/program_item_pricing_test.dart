// program_item_pricing.dart — mapping the planner's priced lines onto the
// program day card's prose items (one line per item, Plan-tab format).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_item_pricing.dart';
import 'package:airledger/services/routine_display.dart';

PrescribedItem it(String name, [String scheme = '']) =>
    PrescribedItem(name: name, scheme: scheme, period: 'AM');

SessionLine ln(String ex, int sets, num reps,
        {num? hi, num? w, num? pct, bool top = false}) =>
    SessionLine(
        exercise: ex,
        sets: sets,
        reps: reps,
        repsHi: hi,
        weight: w,
        pct: pct,
        top: top);

List<String> names(List<SessionLine> ls) => [for (final l in ls) l.exercise];

void main() {
  group('matchItemLines', () {
    test('Fri: heavy → top, back-offs → non-top, RDL or leg curl → RDL', () {
      final items = [
        it('Deadlift heavy', 'top set'),
        it('Deadlift back-offs', '2x4-6 @ 75% TM'),
        it('RDL or leg curl', '2-3x8-12'),
        it('Bench volume', '3x8-10 @ 65% TM.'),
        it('Climb — LIGHT session', '(technique)'),
      ];
      final lines = [
        ln('Barbell Deadlift', 1, 5, w: 275, pct: 0.811, top: true),
        ln('Barbell Deadlift', 2, 4, w: 255, pct: 0.75),
        ln('Romanian Deadlift', 2, 8, hi: 12),
        ln('Flat Barbell Bench Press', 3, 8, w: 160, pct: 0.65),
      ];
      final m = matchItemLines(items, lines);
      expect(m[0].single.top, isTrue);
      expect(m[0].single.weight, 275);
      expect(m[1].single.weight, 255);
      expect(names(m[2]), ['Romanian Deadlift']);
      expect(names(m[3]), ['Flat Barbell Bench Press']);
      expect(m[4], isEmpty);
    });

    test('Mon: squat heavy never takes the BSS line', () {
      final items = [
        it('Squat heavy', 'top set'),
        it('Bulgarian split squat', '3x8-12/leg'),
        it('Bench volume', '4x8 @ 68% TM'),
        it('Lateral raise', '3x12-20'),
        it('Triceps extension', '2-3x10-15.'),
      ];
      final lines = [
        ln('Barbell Squat', 1, 5, w: 260, pct: 0.811, top: true),
        ln('Bulgarian Split Squat', 3, 8, hi: 12),
        ln('Flat Barbell Bench Press', 4, 8, w: 165, pct: 0.68),
        ln('Lateral Dumbbell Raise', 3, 12, hi: 20, w: 20),
        ln('Triceps Extension', 2, 10, hi: 15),
      ];
      final m = matchItemLines(items, lines);
      expect([for (final x in m) names(x)], [
        ['Barbell Squat'],
        ['Bulgarian Split Squat'],
        ['Flat Barbell Bench Press'],
        ['Lateral Dumbbell Raise'],
        ['Triceps Extension'],
      ]);
    });

    test('Thu: muscle-ups vs banded, handstand practice loosely', () {
      final items = [
        it('Muscle-ups', '6 sets of 1-2'),
        it('Banded muscle-ups', '2x3-5'),
        it('Handstand practice', '10 min'),
        it('Front-lever up-downs', '2x5'),
        it('Dips', '3x8-12'),
        it('EZ curls', '3x8-12'),
      ];
      final lines = [
        ln('Muscle Up', 6, 1, hi: 2),
        ln('Muscle Up Green Band', 2, 3, hi: 5),
        ln('Handstand Hold', 3, 1),
        ln('Front Lever', 2, 5),
        ln('Parallel Bar Triceps Dip', 3, 8, hi: 12),
        ln('EZ-Bar Preacher Curl', 3, 8, hi: 12),
      ];
      final m = matchItemLines(items, lines);
      expect([for (final x in m) names(x)], [
        ['Muscle Up'],
        ['Muscle Up Green Band'],
        ['Handstand Hold'],
        ['Front Lever'],
        ['Parallel Bar Triceps Dip'],
        ['EZ-Bar Preacher Curl'],
      ]);
    });

    test('Wed: bench heavy + back-offs + squat/OHP volume', () {
      final items = [
        it('Bench heavy', 'top set'),
        it('Bench back-offs', '3x6-8 @ 72% TM'),
        it('Squat volume', '3x8 @ 65% TM'),
        it('OHP volume', '3x8-10 @ 62% TM'),
        it('Pull-ups', '3x6-10.'),
      ];
      final lines = [
        ln('Flat Barbell Bench Press', 1, 5, w: 200, pct: 0.811, top: true),
        ln('Flat Barbell Bench Press', 3, 6, w: 175, pct: 0.72),
        ln('Barbell Squat', 3, 8, w: 210, pct: 0.65),
        ln('Overhead Press', 3, 8, w: 90, pct: 0.62),
        ln('Pull Up', 3, 6, hi: 10),
      ];
      final m = matchItemLines(items, lines);
      expect(m[0].single.weight, 200);
      expect(m[1].single.weight, 175);
      expect(names(m[2]), ['Barbell Squat']);
      expect(names(m[3]), ['Overhead Press']);
      expect(names(m[4]), ['Pull Up']);
    });

    test('a combined main-lift item takes top AND its back-offs', () {
      final m = matchItemLines([
        it('Squat', 'top set + 3x5 back-offs'),
        it('Leg press', '3x10'),
      ], [
        ln('Barbell Squat', 1, 5, w: 260, top: true),
        ln('Barbell Squat', 3, 5, w: 230),
        ln('Leg Press', 3, 10),
      ]);
      expect([for (final l in m[0]) l.weight], [260, 230]);
      expect(names(m[1]), ['Leg Press']);
    });

    test('no line for an item → empty (card falls back to prose)', () {
      final m = matchItemLines([it('Norwegian', '4x4 VO2')], const []);
      expect(m.single, isEmpty);
    });
  });

  group('itemLineText', () {
    test('drops the name when the item already names the lift', () {
      expect(
          itemLineText(
              ln('Barbell Deadlift', 1, 5, w: 275, pct: 0.811, top: true),
              it('Deadlift heavy')),
          '1×5 · 275 lb (81%)');
      expect(
          itemLineText(ln('Lateral Dumbbell Raise', 3, 12, hi: 20, w: 20),
              it('Lateral raise')),
          '3×12-20 · 20 lb');
    });

    test('keeps the exercise when the item is a choice or loose match', () {
      expect(
          itemLineText(ln('Romanian Deadlift', 2, 8, hi: 12, w: 135),
              it('RDL or leg curl')),
          'Romanian Deadlift 2×8-12 · 135 lb');
      expect(itemLineText(ln('Handstand Hold', 3, 1), it('Handstand practice')),
          'Handstand Hold 3×1');
    });
  });

  group('lineContext', () {
    test('cut-wave top → wave week + %TM', () {
      expect(
          lineContext(ln('Barbell Deadlift', 1, 5, w: 275, pct: 0.811, top: true),
              cutWaveWeek: 1),
          'wave wk1, 81% TM');
      expect(
          lineContext(ln('Barbell Deadlift', 1, 5, w: 240, pct: 0.7, top: true),
              cutWaveWeek: 4, cutDeload: true),
          'wave deload, 70% TM');
    });

    test('%TM volume slot / accessory / bare', () {
      expect(
          lineContext(ln('Barbell Deadlift', 2, 4, w: 255, pct: 0.75)),
          '75% TM');
      expect(lineContext(ln('Lateral Dumbbell Raise', 3, 12, hi: 20, w: 20)),
          'double progression');
      expect(lineContext(ln('Pull Up', 3, 6, hi: 10)), isNull);
    });
  });
}
