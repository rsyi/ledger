import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, WeightRow;
import 'package:airledger/services/wilks.dart';
import 'package:flutter_test/flutter_test.dart';

StrengthRow _set(
  String date,
  String exercise,
  double weight,
  int reps,
) =>
    StrengthRow(
      date: DateTime.parse(date),
      exercise: exercise,
      weight: weight,
      reps: reps,
    );

WeightRow _bw(String date, double lbs) =>
    WeightRow(date: DateTime.parse(date), weightLbs: lbs);

void main() {
  group('wilks2020MaleCoeff', () {
    // Known values: WILKS-2020 male constants from
    // https://en.wikipedia.org/wiki/Wilks_coefficient (March 2020
    // revision, numerator 600), polynomial evaluated independently
    // (python3, direct power form) on 2026-09-21:
    //   x=60  → 0.9968368614195446
    //   x=74  → 0.8599486072141472
    //   x=100 → 0.7293619854505856
    test('matches independently computed known values', () {
      expect(wilks2020MaleCoeff(60), closeTo(0.9968368614195446, 1e-12));
      expect(wilks2020MaleCoeff(74), closeTo(0.8599486072141472, 1e-12));
      expect(wilks2020MaleCoeff(100), closeTo(0.7293619854505856, 1e-12));
    });

    test('score example: 500 kg SBD total at 74 kg bw', () {
      expect(500 * wilks2020MaleCoeff(74), closeTo(429.97430360707364, 1e-9));
    });

    test('is monotonically decreasing over the human range', () {
      var prev = wilks2020MaleCoeff(40);
      for (var x = 45.0; x <= 200; x += 5) {
        final c = wilks2020MaleCoeff(x);
        expect(c, lessThan(prev), reason: 'coeff must fall at $x kg');
        prev = c;
      }
    });
  });

  group('weeklyWilksSeries', () {
    // Week of Mon 2026-09-07 and Mon 2026-09-14.
    final rows = [
      _set('2026-09-07', 'Barbell Squat', 300, 1), // e1RM 310
      _set('2026-09-08', 'Flat Barbell Bench Press', 200, 3), // e1RM 220
      _set('2026-09-10', 'Barbell Deadlift', 400, 1), // e1RM 413.33
      // Week 2: squat improves, bench NOT trained (carried), deadlift
      // only has a reps-6 set → does not qualify, carried too.
      _set('2026-09-14', 'Barbell Squat', 305, 1), // e1RM 315.17
      _set('2026-09-15', 'Barbell Deadlift', 350, 6), // reps > 5 → ignored
      // Press is never part of the total (classic 3-lift).
      _set('2026-09-14', 'Overhead Press', 500, 1),
      // Non-main exercise ignored.
      _set('2026-09-14', 'Leg Press', 600, 5),
    ];
    final weights = [
      _bw('2026-09-07', 164),
      _bw('2026-09-09', 166), // wk1 mean 165
      _bw('2026-09-14', 163), // wk2 mean 163
    ];

    test('computes per-week bests, bw mean, and the WILKS-2020 score', () {
      final s = weeklyWilksSeries(rows, weights);
      expect(s, hasLength(2));

      final w1 = s[0];
      expect(w1.weekStart, DateTime(2026, 9, 7));
      final total1 = 300 * (1 + 1 / 30) +
          200 * (1 + 3 / 30) +
          400 * (1 + 1 / 30);
      expect(w1.totalLbs, closeTo(total1, 1e-9));
      expect(w1.bodyweightLbs, closeTo(165, 1e-9));
      expect(
        w1.wilks,
        closeTo(
          total1 * kgPerLb * wilks2020MaleCoeff(165 * kgPerLb),
          1e-9,
        ),
      );
      expect(w1.carried, isEmpty);
    });

    test('carries untrained lifts forward and reports them', () {
      final s = weeklyWilksSeries(rows, weights);
      final w2 = s[1];
      expect(w2.weekStart, DateTime(2026, 9, 14));
      final total2 = 305 * (1 + 1 / 30) + // new squat best
          200 * (1 + 3 / 30) + // bench carried
          400 * (1 + 1 / 30); // deadlift carried (reps-6 set ignored)
      expect(w2.totalLbs, closeTo(total2, 1e-9));
      expect(w2.bodyweightLbs, closeTo(163, 1e-9));
      expect(w2.carried, ['bench', 'deadlift']);
    });

    test('no point until all three lifts have a value', () {
      final s = weeklyWilksSeries(
        [
          _set('2026-09-07', 'Barbell Squat', 300, 1),
          _set('2026-09-08', 'Flat Barbell Bench Press', 200, 3),
          // deadlift first appears in week 2
          _set('2026-09-14', 'Barbell Deadlift', 400, 1),
        ],
        weights,
      );
      expect(s, hasLength(1));
      expect(s.single.weekStart, DateTime(2026, 9, 14));
    });

    test('bodyweight carries across weeks with no weigh-ins', () {
      final s = weeklyWilksSeries(rows, [_bw('2026-09-07', 164)]);
      expect(s, hasLength(2));
      expect(s[1].bodyweightLbs, 164);
    });

    test('through extends the series with a fully carried point', () {
      final s = weeklyWilksSeries(
        rows,
        weights,
        through: DateTime(2026, 9, 30), // week of Mon 09-28: no data
      );
      expect(s, hasLength(4));
      expect(s.last.weekStart, DateTime(2026, 9, 28));
      expect(s.last.carried, ['squat', 'bench', 'deadlift']);
      expect(s.last.totalLbs, closeTo(s[1].totalLbs, 1e-9));
    });

    test('empty inputs yield an empty series', () {
      expect(weeklyWilksSeries([], []), isEmpty);
      expect(
        weeklyWilksSeries([], [], through: DateTime(2026, 9, 21)),
        isEmpty,
      );
      // Weigh-ins but no lifts → still empty (never guess a total).
      expect(weeklyWilksSeries([], weights), isEmpty);
    });
  });
}
