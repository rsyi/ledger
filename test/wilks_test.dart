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
      final s = weeklyWilksSeries(rows, weights, basis: WilksBasis.e1rm);
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
      final s = weeklyWilksSeries(rows, weights, basis: WilksBasis.e1rm);
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
        basis: WilksBasis.e1rm,
      );
      expect(s, hasLength(1));
      expect(s.single.weekStart, DateTime(2026, 9, 14));
    });

    test('bodyweight carries across weeks with no weigh-ins', () {
      final s = weeklyWilksSeries(rows, [_bw('2026-09-07', 164)],
          basis: WilksBasis.e1rm);
      expect(s, hasLength(2));
      expect(s[1].bodyweightLbs, 164);
    });

    test('through extends the series with a fully carried point', () {
      final s = weeklyWilksSeries(
        rows,
        weights,
        through: DateTime(2026, 9, 30), // week of Mon 09-28: no data
        basis: WilksBasis.e1rm,
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
      final s = monthlyWilksSeries(rows, weights, basis: WilksBasis.e1rm);
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
      final s = monthlyWilksSeries(rows, weights, basis: WilksBasis.e1rm);
      final sep = s[1];
      expect(sep.monthStart, DateTime(2026, 9, 1));
      // Squat = the 09-01 top single, NOT the 09-21 deload 5x250.
      final totalSep = e(305, 1) + e(210, 2) + e(400, 1);
      expect(sep.totalLbs, closeTo(totalSep, 1e-9));
    });

    test('carries untrained lifts forward and reports them', () {
      final s = monthlyWilksSeries(rows, weights, basis: WilksBasis.e1rm);
      final sep = s[1];
      expect(sep.carried, ['bench', 'deadlift']);
    });

    test('bodyweight carries into months with no weigh-ins, flagged', () {
      final s = monthlyWilksSeries(rows, weights, basis: WilksBasis.e1rm);
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
        basis: WilksBasis.e1rm,
      );
      expect(s, hasLength(1));
      expect(s.single.monthStart, DateTime(2026, 9, 1));
    });

    test('through extends the series with fully carried months', () {
      final s = monthlyWilksSeries(
        rows,
        weights,
        through: DateTime(2026, 11, 15), // Oct + Nov: no data at all
        basis: WilksBasis.e1rm,
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

  group('actual-max basis (the display standard, 2026-09-22)', () {
    // User, verbatim: "my wilks should be tracked against my absolute
    // max score for wilks ever. That should be the benchmark, but done
    // against actually max lift numbers, not e1RM."
    final weights = [_bw('2026-08-04', 164), _bw('2026-08-20', 166)];

    test('month picks the heaviest weight ACTUALLY lifted — 405×2 '
        'counts as 405, not its e1RM', () {
      final s = monthlyWilksSeries(
        [
          _set('2026-08-03', 'Barbell Squat', 405, 2), // → 405, not 432
          _set('2026-08-05', 'Flat Barbell Bench Press', 225, 3),
          _set('2026-08-10', 'Barbell Deadlift', 455, 1),
        ],
        weights,
        basis: WilksBasis.actualMax,
      );
      expect(s, hasLength(1));
      expect(s.single.totalLbs, closeTo(405 + 225 + 455, 1e-9));
    });

    test('any reps >= 1 qualifies — a heavy high-rep set is still a '
        'lifted number', () {
      final s = monthlyWilksSeries(
        [
          // reps 8 would NOT qualify on the e1RM basis (reps <= 5).
          _set('2026-08-03', 'Barbell Squat', 315, 8),
          _set('2026-08-05', 'Flat Barbell Bench Press', 185, 10),
          _set('2026-08-10', 'Barbell Deadlift', 365, 6),
        ],
        weights,
        basis: WilksBasis.actualMax,
      );
      expect(s, hasLength(1));
      expect(s.single.totalLbs, closeTo(315 + 185 + 365, 1e-9));
    });

    test('carries untrained lifts and bodyweight across months', () {
      final s = monthlyWilksSeries(
        [
          _set('2026-08-03', 'Barbell Squat', 405, 2),
          _set('2026-08-05', 'Flat Barbell Bench Press', 225, 3),
          _set('2026-08-10', 'Barbell Deadlift', 455, 1),
          // September: only squat trained, LIGHTER — best-of-month is
          // 385, but bench + deadlift carry at their August values.
          _set('2026-09-14', 'Barbell Squat', 385, 5),
        ],
        weights, // no September weigh-in → bw carries at Aug mean 165
        basis: WilksBasis.actualMax,
      );
      expect(s, hasLength(2));
      expect(s[1].totalLbs, closeTo(385 + 225 + 455, 1e-9));
      expect(s[1].carried, ['bench', 'deadlift']);
      expect(s[1].bodyweightLbs, closeTo(165, 1e-9));
      expect(s[1].bwCarried, isTrue);
    });

    test('weekly series takes the same basis (weekly-current stat)', () {
      final s = weeklyWilksSeries(
        [
          _set('2026-09-07', 'Barbell Squat', 405, 2),
          _set('2026-09-08', 'Flat Barbell Bench Press', 225, 8),
          _set('2026-09-10', 'Barbell Deadlift', 455, 1),
        ],
        [_bw('2026-09-07', 164)],
        basis: WilksBasis.actualMax,
      );
      expect(s, hasLength(1));
      expect(s.single.totalLbs, closeTo(405 + 225 + 455, 1e-9));
    });

    test('actual-max wilks <= e1RM wilks for the same data (an actual '
        'lift is never more than its estimate)', () {
      final rows = [
        _set('2026-08-03', 'Barbell Squat', 300, 1),
        _set('2026-08-05', 'Flat Barbell Bench Press', 200, 3),
        _set('2026-08-10', 'Barbell Deadlift', 400, 2),
        _set('2026-09-01', 'Barbell Squat', 305, 5),
        _set('2026-09-15', 'Barbell Deadlift', 410, 1),
      ];
      final actual = monthlyWilksSeries(
        rows,
        weights,
        basis: WilksBasis.actualMax,
      );
      final e1rm = monthlyWilksSeries(rows, weights, basis: WilksBasis.e1rm);
      expect(actual, hasLength(e1rm.length));
      for (var i = 0; i < actual.length; i++) {
        expect(
          actual[i].wilks,
          lessThanOrEqualTo(e1rm[i].wilks),
          reason: 'month ${actual[i].monthStart}',
        );
      }
    });

    test('actualMax is the default basis', () {
      final rows = [
        _set('2026-08-03', 'Barbell Squat', 405, 2),
        _set('2026-08-05', 'Flat Barbell Bench Press', 225, 3),
        _set('2026-08-10', 'Barbell Deadlift', 455, 1),
      ];
      expect(
        monthlyWilksSeries(rows, weights).single.totalLbs,
        closeTo(405 + 225 + 455, 1e-9),
      );
      expect(
        weeklyWilksSeries(rows, weights).first.totalLbs,
        closeTo(405 + 225 + 455, 1e-9),
      );
    });
  });

  group('wilksBenchmark', () {
    WilksMonth m(int year, int month, double wilks) => WilksMonth(
          monthStart: DateTime(year, month),
          wilks: wilks,
          totalLbs: 1000,
          bodyweightLbs: 164,
        );

    test('returns the all-time max point with its month', () {
      final best = wilksBenchmark([
        m(2024, 1, 310.0),
        m(2024, 2, 342.1), // the peak
        m(2024, 3, 320.0),
        m(2026, 9, 335.0),
      ]);
      expect(best!.wilks, 342.1);
      expect(best.monthStart, DateTime(2024, 2));
    });

    test('ties keep the earliest month', () {
      final best = wilksBenchmark([m(2024, 1, 330.0), m(2024, 5, 330.0)]);
      expect(best!.monthStart, DateTime(2024, 1));
    });

    test('empty series → null', () {
      expect(wilksBenchmark(const []), isNull);
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
        basis: WilksBasis.e1rm,
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

  group('wilksWeekDecomposition (hero sheet, 2026-09-25)', () {
    // Week of Mon 2026-09-14: deadlift trained; week of Mon 2026-09-21:
    // squat + bench trained, deadlift CARRIED from the 14th's week.
    final rows = [
      _set('2026-09-14', 'Barbell Deadlift', 315, 1),
      _set('2026-09-15', 'Barbell Squat', 285, 3),
      _set('2026-09-15', 'Flat Barbell Bench Press', 215, 2),
      _set('2026-09-21', 'Barbell Squat', 295, 1),
      _set('2026-09-22', 'Flat Barbell Bench Press', 225, 1),
    ];
    final weighIns = [
      _bw('2026-09-14', 160),
      _bw('2026-09-21', 159),
    ];

    test('weeks expose per-lift lbs and the week each value was trained',
        () {
      final weeks = weeklyWilksSeries(rows, weighIns);
      expect(weeks, hasLength(2));
      final w2 = weeks.last;
      expect(
        w2.liftLbs,
        {'squat': 295.0, 'bench': 225.0, 'deadlift': 315.0},
      );
      // Trained-this-week lifts point at this week; the carry points at
      // the week its weight was actually lifted.
      expect(w2.liftTrainedWeek['squat'], DateTime(2026, 9, 21));
      expect(w2.liftTrainedWeek['bench'], DateTime(2026, 9, 21));
      expect(w2.liftTrainedWeek['deadlift'], DateTime(2026, 9, 14));
      expect(w2.carried, ['deadlift']);
    });

    test('parts are exact kg×coeff shares that sum to the stat', () {
      final w2 = weeklyWilksSeries(rows, weighIns).last;
      final parts = wilksWeekDecomposition(w2);
      expect([for (final p in parts) p.lift], wilksLifts);
      final coeff = wilks2020MaleCoeff(159 * kgPerLb);
      expect(parts[0].points, closeTo(295 * kgPerLb * coeff, 1e-9));
      expect(parts[1].points, closeTo(225 * kgPerLb * coeff, 1e-9));
      expect(parts[2].points, closeTo(315 * kgPerLb * coeff, 1e-9));
      expect(
        parts.fold<double>(0, (s, p) => s + p.points),
        closeTo(w2.wilks, 1e-9),
      );
      // Carry tagging: only the untrained lift carries a source week.
      expect(parts[0].carriedFrom, isNull);
      expect(parts[1].carriedFrom, isNull);
      expect(parts[2].carriedFrom, DateTime(2026, 9, 14));
    });

    test('displayed 1dp parts always sum to the displayed 1dp total', () {
      // Property check across a spread of totals and bodyweights: the
      // largest-remainder display rounding keeps the sheet's sum line
      // exact — three independently rounded parts would drift by up to
      // ±0.15.
      for (var s = 200.0; s <= 360; s += 7) {
        for (var bw = 140.0; bw <= 205; bw += 11) {
          final lifts = {
            'squat': s,
            'bench': s * 0.63,
            'deadlift': s * 1.117,
          };
          final total = lifts.values.fold<double>(0, (a, b) => a + b);
          final coeff = wilks2020MaleCoeff(bw * kgPerLb);
          final week = WilksWeek(
            weekStart: DateTime(2026, 9, 21),
            wilks: total * kgPerLb * coeff,
            totalLbs: total,
            bodyweightLbs: bw,
            liftLbs: lifts,
          );
          final parts = wilksWeekDecomposition(week);
          final displayed =
              parts.fold<double>(0, (a, p) => a + p.displayPoints);
          expect(
            displayed,
            closeTo((week.wilks * 10).round() / 10, 1e-9),
            reason: 'total $total lb at $bw lb bw',
          );
          for (final p in parts) {
            expect(p.displayPoints, closeTo(p.points, 0.11),
                reason: 'display value must stay within one tenth-step '
                    'of the exact share');
          }
        }
      }
    });

    test('empty on weeks without per-lift values (back-compat)', () {
      // Weeks built without liftLbs (older call sites / hand-rolled
      // fixtures) decompose to nothing rather than guessing.
      final week = WilksWeek(
        weekStart: DateTime(2026, 9, 21),
        wilks: 320.5,
        totalLbs: 835,
        bodyweightLbs: 159,
      );
      expect(wilksWeekDecomposition(week), isEmpty);
    });
  });

  group('wilksPointsLb', () {
    // Independently computed (python3, direct power form, 2026-09-22):
    //   315 lb at 165 lb bw → 121.97756160079403
    //   377 lb at 192 lb bw → 133.4584122788316
    //   310 lb at 165 lb bw → 120.04140982935286
    //   320 lb at 175 lb bw → 119.45633051406521
    //     (the home_dashboard_test STRENGTH fixture: the all-time top
    //     actual weight at its contemporaneous bodyweight — a detail-
    //     sheet line since the last-bulk column took the card slot)
    //   315 lb at 185 lb bw → 113.82642366705377
    //     (same fixture: the last-bulk top at its contemporaneous
    //     Jun-'25 bulk bodyweight)
    test('matches independently computed known values', () {
      expect(wilksPointsLb(315, 165), closeTo(121.97756160079403, 1e-9));
      expect(wilksPointsLb(377, 192), closeTo(133.4584122788316, 1e-9));
      expect(wilksPointsLb(310, 165), closeTo(120.04140982935286, 1e-9));
      expect(wilksPointsLb(320, 175), closeTo(119.45633051406521, 1e-9));
      expect(wilksPointsLb(315, 185), closeTo(113.82642366705377, 1e-9));
    });

    test('agrees with the coefficient identity (lb → kg round trip)', () {
      // 500 kg at 74 kg bw is the canonical score example; feed the
      // same masses in lb and the points must match exactly.
      expect(
        wilksPointsLb(500 / kgPerLb, 74 / kgPerLb),
        closeTo(429.97430360707364, 1e-9),
      );
    });

    test('heavier bodyweight → fewer points for the same lift', () {
      expect(wilksPointsLb(315, 192), lessThan(wilksPointsLb(315, 165)));
    });
  });

  group('contemporaneousBodyweightLbs', () {
    final weighIns = [
      _bw('2024-12-03', 190),
      _bw('2024-12-20', 194), // Dec '24 mean 192
      _bw('2026-09-18', 164),
      _bw('2026-09-21', 166), // Sep '26 mean 165
    ];

    test("uses the date's own calendar-month mean when present", () {
      expect(
        contemporaneousBodyweightLbs(weighIns, DateTime(2024, 12, 15)),
        closeTo(192, 1e-9),
      );
      expect(
        contemporaneousBodyweightLbs(weighIns, DateTime(2026, 9, 22)),
        closeTo(165, 1e-9),
      );
    });

    test('whole-month mean: weigh-ins later in the month still count', () {
      // Same monthly-mean semantics as monthlyWilksSeries — Dec 1 sees
      // the full December mean, not just weigh-ins up to Dec 1.
      expect(
        contemporaneousBodyweightLbs(weighIns, DateTime(2024, 12, 1)),
        closeTo(192, 1e-9),
      );
    });

    test('carries the nearest earlier month across a gap', () {
      // Mar '25 has no weigh-ins; Dec '24 is the newest earlier month.
      expect(
        contemporaneousBodyweightLbs(weighIns, DateTime(2025, 3, 10)),
        closeTo(192, 1e-9),
      );
    });

    test('null before the first weigh-in month (never guesses)', () {
      expect(
        contemporaneousBodyweightLbs(weighIns, DateTime(2024, 6, 1)),
        isNull,
      );
      expect(
        contemporaneousBodyweightLbs(const [], DateTime(2026, 1, 1)),
        isNull,
      );
    });
  });
}
