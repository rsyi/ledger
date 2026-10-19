// Strength form "previous record" hint (2026-10-19): the best working
// set by RPE-adjusted e1RM for the same exercise + paused/belted state,
// plus the most recent comparable session's top set.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/previous_record.dart';

Map<String, Object?> _r(
  String id,
  String date,
  String exercise,
  num weight,
  int reps, {
  num? rpe,
  Object? paused,
  Object? belted,
  String? setType,
}) => {
  'id': id,
  'date': date,
  'exercise': exercise,
  'weight': weight,
  'reps': reps,
  'rpe': ?rpe,
  'paused': ?paused,
  'belted': ?belted,
  'set_type': ?setType,
};

void main() {
  group('PreviousRecordIndex', () {
    final rows = [
      // Paused bench day.
      _r('p1', '2026-10-01', 'Flat Barbell Bench Press', 225, 3,
          rpe: 8, paused: true),
      // Touch-and-go (explicit false) — heavier.
      _r('t1', '2026-10-05', 'Flat Barbell Bench Press', 245, 3,
          rpe: 8, paused: false),
      // Unrecorded (blank) — heaviest of all.
      _r('b1', '2026-09-20', 'Flat Barbell Bench Press', 250, 2, rpe: 9),
      // Tagged warm-up that would otherwise win everything.
      _r('w1', '2026-10-06', 'Flat Barbell Bench Press', 300, 5,
          setType: 'warmup'),
      // Other exercise.
      _r('s1', '2026-10-06', 'Barbell Squat', 320, 3, rpe: 8, belted: true),
      _r('s2', '2026-10-08', 'Barbell Squat', 275, 5, rpe: 8, belted: false),
    ];
    final index = PreviousRecordIndex(rows);

    test('null flag = any state (best overall by rpe-adjusted e1rm)', () {
      final res = index.lookup('Flat Barbell Bench Press');
      // b1 250x2@9 → 250*(1+3/30)=275; t1 245x3@8 → 245*1.1667=285.8.
      expect(res.best!.id, 't1');
      expect(res.best!.e1rm, closeTo(285.83, 0.01));
    });

    test('paused true / false filter strictly (blank never matches)', () {
      expect(index.lookup('Flat Barbell Bench Press', paused: true).best!.id,
          'p1');
      expect(index.lookup('Flat Barbell Bench Press', paused: false).best!.id,
          't1');
    });

    test('belted filter', () {
      expect(index.lookup('Barbell Squat', belted: true).best!.id, 's1');
      expect(index.lookup('Barbell Squat', belted: false).best!.id, 's2');
      expect(index.lookup('Barbell Squat').best!.id, 's1');
    });

    test('warm-ups excluded (tagged and untagged ramp sets)', () {
      final idx = PreviousRecordIndex([
        _r('top', '2026-10-01', 'Barbell Deadlift', 315, 3, rpe: 8),
        // Untagged + unrated + < 75% of the day's top → ramp.
        _r('ramp', '2026-10-01', 'Barbell Deadlift', 225, 12),
        _r('tag', '2026-10-02', 'Barbell Deadlift', 405, 5,
            setType: 'warmup'),
      ]);
      expect(idx.lookup('Barbell Deadlift').best!.id, 'top');
    });

    test('exercise match is case/whitespace-insensitive; unknown → null',
        () {
      expect(index.lookup('  barbell squat ').best!.id, 's1');
      final none = index.lookup('Muscle Up');
      expect(none.best, isNull);
      expect(none.last, isNull);
    });

    test('Sheets-shaped strings parse (TRUE/FALSE, numeric strings)', () {
      final idx = PreviousRecordIndex([
        {
          'id': 'x',
          'date': '2026-10-01',
          'exercise': 'Barbell Squat',
          'weight': '300',
          'reps': '3',
          'rpe': '8',
          'belted': 'TRUE',
        },
      ]);
      expect(idx.lookup('Barbell Squat', belted: true).best!.weight, 300);
      expect(idx.lookup('Barbell Squat', belted: false).best, isNull);
    });

    test('last = top set of the most recent session before the form date',
        () {
      final idx = PreviousRecordIndex([
        _r('a', '2026-10-01', 'Barbell Squat', 320, 3, rpe: 8),
        _r('b1', '2026-10-08', 'Barbell Squat', 260, 5, rpe: 8),
        _r('b2', '2026-10-08', 'Barbell Squat', 245, 6, rpe: 8),
        _r('today', '2026-10-12', 'Barbell Squat', 225, 5, rpe: 6),
      ]);
      final res = idx.lookup('Barbell Squat', before: DateTime(2026, 10, 12));
      expect(res.best!.id, 'a');
      expect(res.last!.id, 'b1');
      expect(res.last!.date, DateTime(2026, 10, 8));
    });

    test('memoized: same query returns the identical result object', () {
      final a = index.lookup('Barbell Squat', belted: true);
      final b = index.lookup('Barbell Squat', belted: true);
      expect(identical(a, b), isTrue);
    });

    test('formatting', () {
      final s = index.lookup('Flat Barbell Bench Press', paused: true).best!;
      expect(s.label, '225×3 @ 8');
      final idx = PreviousRecordIndex([
        _r('h', '2026-10-01', 'Barbell Squat', 272.5, 5),
      ]);
      expect(idx.lookup('Barbell Squat').best!.label, '272.5×5');
    });
  });
}
