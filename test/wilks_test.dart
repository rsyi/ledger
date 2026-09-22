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

  group('monthlyWilksSeries', () {
    // August / September 2026 (October only via `through`).
    final rows = [
      // August: all three lifts.
      _set('2026-08-03', 'Barbell Squat', 300, 1), // e1RM 310
      _set('2026-08-05', 'Flat Barbell Bench Press', 200, 3), // e1RM 220
      _set('2026-08-10', 'Barbell Deadlift', 400, 1), // e1RM 413.33
      // Aug 31 is a Monday whose ISO week runs into September — the
      // set belongs to AUGUST by calendar month, and beats the 08-05
      // bench (224 > 220).
      _set('2026-08-31', 'Flat Barbell Bench Press', 210, 2), // e1RM 224
      // September: squat improves early, then a weaker deload set —
      // best-of-month must win, so the deload can't drag the point.
      _set('2026-09-01', 'Barbell Squat', 305, 1), // e1RM 315.17
      _set('2026-09-21', 'Barbell Squat', 250, 5), // deload, e1RM 291.67
      // Bench untrained in September (carried); deadlift only has a
      // reps-6 set → does not qualify, carried too.
      _set('2026-09-15', 'Barbell Deadlift', 350, 6), // reps > 5 → ignored
      // Press is never part of the total; non-mains ignored.
      _set('2026-09-14', 'Overhead Press', 500, 1),
      _set('2026-09-14', 'Leg Press', 600, 5),
    ];
    final weights = [
      _bw('2026-08-04', 164),
      _bw('2026-08-20', 166), // Aug mean 165; September has NO weigh-in
    ];

    double e(double w, int reps) => w * (1 + reps / 30);

    test('groups by calendar month, bw = mean of the month\'s weigh-ins',
        () {
      final s = monthlyWilksSeries(rows, weights);
      expect(s, hasLength(2));

      final aug = s[0];
      expect(aug.monthStart, DateTime(2026, 8, 1));
      final totalAug = e(300, 1) + e(210, 2) + e(400, 1);
      expect(aug.totalLbs, closeTo(totalAug, 1e-9));
      expect(aug.bodyweightLbs, closeTo(165, 1e-9));
      expect(
        aug.wilks,
        closeTo(totalAug * kgPerLb * wilks2020MaleCoeff(165 * kgPerLb), 1e-9),
      );
      expect(aug.carried, isEmpty);
      expect(aug.bwCarried, isFalse);
    });

    test('deload sets do not drag the month — best-of wins', () {
      final s = monthlyWilksSeries(rows, weights);
      final sep = s[1];
      expect(sep.monthStart, DateTime(2026, 9, 1));
      // Squat = the 09-01 top single, NOT the 09-21 deload 5x250.
      final totalSep = e(305, 1) + e(210, 2) + e(400, 1);
      expect(sep.totalLbs, closeTo(totalSep, 1e-9));
    });

    test('carries untrained lifts forward and reports them', () {
      final s = monthlyWilksSeries(rows, weights);
      final sep = s[1];
      expect(sep.carried, ['bench', 'deadlift']);
    });

    test('bodyweight carries into months with no weigh-ins, flagged', () {
      final s = monthlyWilksSeries(rows, weights);
      expect(s[1].bodyweightLbs, closeTo(165, 1e-9));
      expect(s[1].bwCarried, isTrue);
    });

    test('no point until all three lifts AND a bodyweight are known', () {
      final s = monthlyWilksSeries(
        [
          _set('2026-08-03', 'Barbell Squat', 300, 1),
          _set('2026-08-05', 'Flat Barbell Bench Press', 200, 3),
          // deadlift first appears in September
          _set('2026-09-05', 'Barbell Deadlift', 400, 1),
        ],
        weights,
      );
      expect(s, hasLength(1));
      expect(s.single.monthStart, DateTime(2026, 9, 1));
    });

    test('through extends the series with fully carried months', () {
      final s = monthlyWilksSeries(
        rows,
        weights,
        through: DateTime(2026, 11, 15), // Oct + Nov: no data at all
      );
      expect(s, hasLength(4));
      expect(s[2].monthStart, DateTime(2026, 10, 1));
      expect(s.last.monthStart, DateTime(2026, 11, 1));
      expect(s.last.carried, ['squat', 'bench', 'deadlift']);
      expect(s.last.bwCarried, isTrue);
      expect(s.last.totalLbs, closeTo(s[1].totalLbs, 1e-9));
      expect(s.last.wilks, closeTo(s[1].wilks, 1e-9));
    });

    test('empty inputs yield an empty series', () {
      expect(monthlyWilksSeries([], []), isEmpty);
      expect(
        monthlyWilksSeries([], [], through: DateTime(2026, 9, 21)),
        isEmpty,
      );
      // Weigh-ins but no lifts → still empty (never guess a total).
      expect(monthlyWilksSeries([], weights), isEmpty);
    });
  });

  group('weeklyWilksSeries — saturday-start weeks (v7 week_start)', () {
    test('weeks key by Saturday and a Saturday PR counts toward the '
        'current week', () {
      StrengthRow s(String date, String ex, double w, int reps) =>
          StrengthRow(
              date: DateTime.parse(date), exercise: ex, weight: w, reps: reps);
      final rows = [
        s('2026-09-14', 'Barbell Squat', 300, 1),
        s('2026-09-14', 'Flat Barbell Bench Press', 200, 1),
        s('2026-09-14', 'Barbell Deadlift', 350, 1),
        // Saturday Sep 19: squat PR — must move the Sep 19 week's point.
        s('2026-09-19', 'Barbell Squat', 320, 1),
      ];
      final w = [
        WeightRow(date: DateTime.parse('2026-09-14'), weightLbs: 160),
      ];
      final weeks = weeklyWilksSeries(
        rows,
        w,
        through: DateTime(2026, 9, 22),
        weekStartDay: DateTime.saturday,
      );
      for (final wk in weeks) {
        expect(wk.weekStart.weekday, DateTime.saturday);
      }
      final byStart = {for (final wk in weeks) wk.weekStart: wk};
      final prior = byStart[DateTime(2026, 9, 12)]!; // Sep 12–18
      final current = byStart[DateTime(2026, 9, 19)]!; // Sep 19–25
      // Epley singles: 300→310, 200→206.67, 350→361.67, 320→330.67.
      expect(prior.totalLbs, closeTo(878.3333333, 1e-6));
      expect(current.totalLbs, closeTo(899.0, 1e-6)); // Saturday PR in
      expect(current.carried, ['bench', 'deadlift']);
    });
  });
}
