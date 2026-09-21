import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_metrics.dart';

DateTime d(String iso) => DateTime.parse(iso);

StrengthRow row(
  String date,
  String exercise,
  double weight,
  int reps, {
  double? rpe,
}) => StrengthRow(
  date: d(date),
  exercise: exercise,
  weight: weight,
  reps: reps,
  rpe: rpe,
);

void main() {
  group('gradeSets — Epley + reps cap', () {
    test('12 and 15 reps of the same weight grade identically', () {
      final sets = gradeSets([
        row('2025-01-06', 'Barbell Squat', 300, 3), // reference 330
        row('2025-01-08', 'Barbell Squat', 200, 12),
        row('2025-01-08', 'Barbell Squat', 200, 15),
      ]);
      final twelve = sets.firstWhere((s) => s.reps == 12);
      final fifteen = sets.firstWhere((s) => s.reps == 15);
      expect(twelve.e1rm, closeTo(200 * 1.4, 1e-9)); // cap at 12
      expect(fifteen.e1rm, twelve.e1rm);
      expect(fifteen.effort, twelve.effort);
    });

    test('e1rm is Epley below the cap', () {
      final sets = gradeSets([row('2025-01-06', 'Barbell Squat', 300, 5)]);
      expect(sets.single.e1rm, closeTo(300 * (1 + 5 / 30), 1e-9));
    });
  });

  group('gradeSets — main-lift mapping', () {
    test('exactly the five spec names map; variants are ignored', () {
      final sets = gradeSets([
        row('2025-01-06', 'Barbell Squat', 300, 3),
        row('2025-01-06', 'Flat Barbell Bench Press', 200, 3),
        row('2025-01-06', 'Barbell Deadlift', 400, 3),
        row('2025-01-06', 'Overhead Press', 120, 3),
        row('2025-01-06', 'Barbell Standing Military Press', 110, 3),
        // Variants — NOT main lifts.
        row('2025-01-06', 'Barbell Front Squat', 200, 3),
        row('2025-01-06', 'Barbell Close Grip Bench Press', 180, 3),
        row('2025-01-06', 'Barbell Sumo Barbell Deadlift', 350, 3),
        row('2025-01-06', 'Barbell Incline Bench Press', 150, 3),
        row('2025-01-06', 'Barbell Stiff-Legged Barbell Deadlift', 250, 3),
        row('2025-01-06', 'Pull Up', 0, 10),
      ]);
      expect(sets.length, 5);
      expect(sets.map((s) => s.lift).toSet(), {
        'squat',
        'bench',
        'deadlift',
        'press',
      });
      // Both press names land on the same lift and share a reference pool.
      final press = sets.where((s) => s.lift == 'press').toList();
      expect(press.length, 2);
      expect(press[0].reference, press[1].reference);
    });
  });

  group('gradeSets — reference window', () {
    test('42-day window ends on and includes the set date (day −41 in, '
        'older out)', () {
      final sets = gradeSets([
        row('2025-01-01', 'Barbell Squat', 290, 1), // e1rm ≈ 299.67
        row('2025-01-21', 'Barbell Squat', 240, 1), // e1rm 248
        // Day 41 after Jan 1 → Jan 1 still inside the 42-day window.
        row('2025-02-11', 'Barbell Squat', 200, 3),
        // Day 42 after Jan 1 → Jan 1 has dropped out; Jan 21 remains.
        row('2025-02-12', 'Barbell Squat', 200, 3),
      ]);
      final feb11 = sets.firstWhere((s) => s.date == d('2025-02-11'));
      final feb12 = sets.firstWhere((s) => s.date == d('2025-02-12'));
      expect(feb11.reference, closeTo(290 * (1 + 1 / 30), 1e-9));
      expect(feb12.reference, closeTo(240 * (1 + 1 / 30), 1e-9));
    });

    test('only reps <= 8 qualify as reference candidates', () {
      final sets = gradeSets([
        row('2025-01-01', 'Barbell Squat', 300, 9), // e1rm 390 — not a ref
        row('2025-01-02', 'Barbell Squat', 200, 8), // qualifies: e1rm ≈ 253.3
        row('2025-01-03', 'Barbell Squat', 100, 3),
      ]);
      final jan3 = sets.firstWhere((s) => s.date == d('2025-01-03'));
      expect(jan3.reference, closeTo(200 * (1 + 8 / 30), 1e-9));
    });

    test('reference carries forward when the window has none', () {
      final sets = gradeSets([
        row('2025-01-01', 'Barbell Squat', 300, 1),
        // 100 days later: window empty → carry the last known reference.
        row('2025-04-11', 'Barbell Squat', 200, 10),
      ]);
      final late = sets.firstWhere((s) => s.date == d('2025-04-11'));
      expect(late.reference, closeTo(300 * (1 + 1 / 30), 1e-9));
      expect(late.effort, isNotNull);
    });

    test('carry-forward carries the last windowed value, not the all-time '
        'max', () {
      // reps-10 sets don't qualify, so they never become their own ref.
      final sets = gradeSets([
        row('2025-01-01', 'Barbell Squat', 300, 1), // e1rm 310
        row('2025-02-01', 'Barbell Squat', 250, 1), // e1rm ≈ 258.3
        // Mar 10: Jan 1 out of window, Feb 1 in → ref from Feb 1.
        row('2025-03-10', 'Barbell Squat', 200, 10),
        // Jun 1: both out → carry forward the Mar 10 value (Feb 1 ref).
        row('2025-06-01', 'Barbell Squat', 200, 10),
      ]);
      final mar = sets.firstWhere((s) => s.date == d('2025-03-10'));
      final jun = sets.firstWhere((s) => s.date == d('2025-06-01'));
      expect(mar.reference, closeTo(250 * (1 + 1 / 30), 1e-9));
      expect(jun.reference, closeTo(250 * (1 + 1 / 30), 1e-9));
    });

    test('sets before any qualifying reference exist are ungraded and '
        'excluded from working/near-max', () {
      final sets = gradeSets([
        row('2025-01-01', 'Barbell Squat', 200, 10), // no qualifying ref yet
        row('2025-01-08', 'Barbell Squat', 250, 5), // first qualifying set
      ]);
      final ungraded = sets.firstWhere((s) => s.date == d('2025-01-01'));
      expect(ungraded.reference, isNull);
      expect(ungraded.effort, isNull);
      expect(ungraded.tier, isNull);
      expect(ungraded.working, isFalse);
      expect(ungraded.nearMax, isFalse);
      final graded = sets.firstWhere((s) => s.date == d('2025-01-08'));
      expect(graded.reference, isNotNull);
    });

    test('same-day qualifying sets count: a new PR is its own reference '
        '(effort 1.0)', () {
      final sets = gradeSets([
        row('2025-01-01', 'Barbell Squat', 300, 1), // e1rm 310
        row('2025-01-10', 'Barbell Squat', 330, 1), // PR: e1rm 341
      ]);
      final pr = sets.firstWhere((s) => s.weight == 330);
      expect(pr.reference, closeTo(330 * (1 + 1 / 30), 1e-9));
      expect(pr.effort, closeTo(1.0, 1e-9));
      expect(pr.nearMax, isTrue);
    });

    test('references are per lift', () {
      final sets = gradeSets([
        row('2025-01-01', 'Barbell Squat', 300, 1),
        row('2025-01-01', 'Flat Barbell Bench Press', 200, 1),
        row('2025-01-02', 'Flat Barbell Bench Press', 180, 3),
      ]);
      final bench = sets.firstWhere((s) => s.date == d('2025-01-02'));
      expect(bench.reference, closeTo(200 * (1 + 1 / 30), 1e-9));
    });
  });

  group('gradeSets — tiers and thresholds', () {
    // Fixtures chosen so effort lands EXACTLY on the boundary in IEEE
    // arithmetic (verified: e1rm(set)/e1rm(ref) == boundary as doubles).
    GradedSet withRef(double refW, double weight, int reps) => gradeSets([
      row('2025-01-01', 'Barbell Squat', refW, 1),
      row('2025-01-02', 'Barbell Squat', weight, reps),
    ]).last;

    test('tier boundaries on effort: <0.80 warm-up, 0.80 moderate, '
        '0.90 hard', () {
      expect(withRef(105, 83.9, 1).tier, SetTier.warmUp);
      final atPoint80 = withRef(105, 84, 1); // effort exactly 0.80
      expect(atPoint80.effort, 0.80);
      expect(atPoint80.tier, SetTier.moderate);
      expect(atPoint80.working, isTrue);
      expect(withRef(100, 89.9, 1).tier, SetTier.moderate);
      final atPoint90 = withRef(100, 90, 1); // effort exactly 0.90
      expect(atPoint90.effort, 0.90);
      expect(atPoint90.tier, SetTier.hard);
    });

    test('near_max at effort >= 0.95', () {
      expect(withRef(100, 94.9, 1).nearMax, isFalse);
      final atPoint95 = withRef(100, 95, 1); // effort exactly 0.95
      expect(atPoint95.effort, 0.95);
      expect(atPoint95.nearMax, isTrue);
    });

    test('near_max requires reps <= 8: 16-rep set at effort 1.0 is '
        'long_failure but not near_max; 3-rep set at effort 0.96 is near_max',
        () {
      // 16-rep set: effort >= 0.95 but reps > 8 → long_failure=true, near_max=false.
      // ref: 300x1 → e1rm = 310; 220x16 → e1rm = 220*(1+12/30)=308.0,
      //   effort = 308.0/310 ≈ 0.9935 >= 0.95. reps=16 >= 8 → long_failure.
      //   But reps > 8 → NOT near_max (amendment 2026-09-20).
      final amrap = gradeSets([
        row('2025-01-01', 'Barbell Squat', 300, 1), // e1rm 310 → reference
        row('2025-01-08', 'Barbell Squat', 220, 16), // 16-rep AMRAP
      ]).last;
      expect(amrap.reps, 16);
      expect(amrap.effort! >= 0.95, isTrue); // effort condition alone would fire
      expect(amrap.longFailureSet, isTrue); // reps>=8 and effort>=0.95
      expect(amrap.nearMax, isFalse); // reps > 8 → not near_max

      // 3-rep set at effort 0.96: both conditions met → near_max=true.
      // ref: 300x1 → e1rm 310; need weight s.t. weight*(1+3/30)/310 = 0.96.
      // weight = 0.96*310/(1+0.1) = 270.545…; use weight=270, e1rm=270*1.1=297,
      //   effort=297/310=0.9581 >= 0.95, reps=3 <= 8 → near_max.
      final heavy = gradeSets([
        row('2025-01-01', 'Barbell Squat', 300, 1),
        row('2025-01-08', 'Barbell Squat', 270, 3),
      ]).last;
      expect(heavy.reps, 3);
      expect(heavy.effort! >= 0.95, isTrue);
      expect(heavy.nearMax, isTrue);
      expect(heavy.longFailureSet, isFalse); // reps < 8
    });

    test('long_failure_set = reps >= 8 and effort >= 0.95', () {
      // ref 160x1 → e1rm ≈ 165.33; 124x8 → e1rm ≈ 157.07, effort == 0.95.
      final long = withRef(160, 124, 8);
      expect(long.effort, 0.95);
      expect(long.longFailureSet, isTrue);
      final sevenReps = withRef(160, 130, 7); // effort ≈ 0.97, reps < 8
      expect(sevenReps.nearMax, isTrue);
      expect(sevenReps.longFailureSet, isFalse);
    });

    test('pct_max = weight / reference', () {
      final s = withRef(300, 240, 5);
      expect(s.pctMax, closeTo(240 / 310, 1e-9));
    });
  });

  group('weeklyRollup — ISO weeks', () {
    test('weeks run Mon–Sun keyed by Monday; Sunday stays with the prior '
        'Monday', () {
      final sets = gradeSets([
        row('2025-01-06', 'Barbell Squat', 300, 1), // Monday
        row('2025-01-12', 'Barbell Squat', 280, 3), // Sunday, same ISO week
        row('2025-01-13', 'Barbell Squat', 280, 3), // Monday, next week
      ]);
      final weeks = weeklyRollup(sets);
      expect(weeks.length, 2);
      expect(weeks[0].weekStart, d('2025-01-06'));
      expect(weeks[0].sessions, 2);
      expect(weeks[0].setsTotal, 2);
      expect(weeks[1].weekStart, d('2025-01-13'));
      expect(weeks[1].sessions, 1);
    });

    test('counts: working/hard/near-max/long-failure + avg reps + per-lift',
        () {
      final sets = gradeSets([
        row('2025-01-06', 'Barbell Squat', 300, 1), // ref 310, effort 1.0
        row('2025-01-07', 'Barbell Squat', 240, 5), // effort 0.903 hard
        row('2025-01-07', 'Barbell Squat', 200, 3), // effort ~0.71 warm-up
        row('2025-01-08', 'Flat Barbell Bench Press', 200, 1), // 1.0
        // reps 9 → not a reference candidate; effort ≈ 0.94 vs 200x1 ref.
        row('2025-01-09', 'Flat Barbell Bench Press', 150, 9),
      ]);
      final w = weeklyRollup(sets).single;
      expect(w.sessions, 4);
      expect(w.setsTotal, 5);
      expect(w.workingSets, 4);
      expect(w.nearMaxSets, 2);
      expect(w.longFailureSets, 0);
      expect(w.avgRepsWorking, closeTo((1 + 5 + 1 + 9) / 4, 1e-9));
      expect(w.benchDays, 2);
      expect(w.perLift['squat']!.days, 2);
      expect(w.perLift['squat']!.workingSets, 2);
      expect(w.perLift['squat']!.nearMaxSets, 1);
      expect(
        w.perLift['squat']!.bestE1rmFromSetsLe5,
        closeTo(300 * (1 + 1 / 30), 1e-9),
      );
      expect(w.perLift['bench']!.days, 2);
      // reps-9 set excluded from best_e1rm_from_sets_le5.
      expect(
        w.perLift['bench']!.bestE1rmFromSetsLe5,
        closeTo(200 * (1 + 1 / 30), 1e-9),
      );
    });

    test('week keys stay on Mondays across a DST fall-back boundary', () {
      // US fall-back 2024-11-03: naive Duration arithmetic drifts week keys
      // to Sunday 23:00. Span it and check every key is a real Monday.
      final sets = gradeSets([
        row('2024-10-07', 'Barbell Squat', 300, 1), // Monday, pre-DST
        row('2024-12-02', 'Barbell Squat', 300, 1), // Monday, post-DST
      ]);
      final weeks = weeklyRollup(sets);
      for (final w in weeks) {
        expect(w.weekStart.weekday, DateTime.monday);
        expect(w.weekStart.hour, 0);
      }
      final dec = weeks.firstWhere((w) => w.weekStart == d('2024-12-02'));
      expect(dec.sessions, 1);
      expect(weeks.length, 9);
    });

    test('ungraded sets count toward sessions/sets_total only', () {
      final sets = gradeSets([
        row('2025-01-06', 'Barbell Squat', 200, 10), // ungraded (no ref yet)
      ]);
      final w = weeklyRollup(sets).single;
      expect(w.setsTotal, 1);
      expect(w.sessions, 1);
      expect(w.workingSets, 0);
      expect(w.nearMaxSets, 0);
    });
  });

  group('weeklyRollup — bodyweight', () {
    WeightRow bw(String date, double lbs) =>
        WeightRow(date: d(date), weightLbs: lbs);

    test('bw_7d_avg = mean of weigh-ins in [Sunday-6, Sunday]; missing days '
        'shrink the sample', () {
      // Week of Mon 2025-01-06 → Sunday 2025-01-12; window Jan 6–12.
      final weeks = weeklyRollup(
        gradeSets([row('2025-01-06', 'Barbell Squat', 300, 1)]),
        weights: [
          bw('2025-01-05', 150), // Sunday before — outside window
          bw('2025-01-06', 160), // Monday — inside (Sunday-6)
          bw('2025-01-12', 170), // Sunday — inside
        ],
      );
      // The Jan 5 weigh-in adds a prior week to the rollup; pick this one.
      final w = weeks.firstWhere((w) => w.weekStart == d('2025-01-06'));
      expect(w.bw7dAvg, closeTo(165, 1e-9));
    });

    test('bw_7d_avg null with no weigh-ins in window', () {
      final weeks = weeklyRollup(
        gradeSets([row('2025-01-06', 'Barbell Squat', 300, 1)]),
        weights: [WeightRow(date: d('2024-12-01'), weightLbs: 150)],
      );
      // Week list spans from the first input week; find the lifting week.
      final w = weeks.firstWhere((w) => w.weekStart == d('2025-01-06'));
      expect(w.bw7dAvg, isNull);
    });

    test('bw_rate_lb_wk and bw_3wk_change from consecutive Sundays', () {
      final weights = <WeightRow>[
        for (var i = 0; i < 28; i++)
          bw(
            '2025-01-${(6 + i).toString().padLeft(2, '0')}',
            160 + i * 0.1, // rises 0.1/day → 0.7/wk
          ),
      ];
      final weeks = weeklyRollup(
        gradeSets([
          row('2025-01-06', 'Barbell Squat', 300, 1),
          row('2025-01-27', 'Barbell Squat', 300, 1),
        ]),
        weights: weights,
      );
      expect(weeks.length, 4);
      expect(weeks[1].bwRateLbWk, closeTo(0.7, 1e-6));
      expect(weeks[3].bw3wkChange, closeTo(2.1, 1e-6));
      expect(weeks[0].bwRateLbWk, isNull); // no prior week
    });
  });

  group('evaluateFlags', () {
    // Builds a bare WeeklyMetrics for flag tests.
    WeeklyMetrics wk(
      String monday, {
      int sessions = 4,
      int setsTotal = 30,
      int workingSets = 25,
      int nearMaxSets = 6,
      int longFailureSets = 0,
      int benchDays = 2,
      double? bw7dAvg,
      double? bwRateLbWk,
      double? bw3wkChange,
      String? weekType,
      int tuesdayLowerSets = 0,
      int painNotes = 0,
    }) => WeeklyMetrics(
      weekStart: d(monday),
      sessions: sessions,
      setsTotal: setsTotal,
      workingSets: workingSets,
      hardSets: 0,
      nearMaxSets: nearMaxSets,
      longFailureSets: longFailureSets,
      avgRepsWorking: null,
      perLift: const {},
      benchDays: benchDays,
      climbingSessions: 0,
      bike4x4Sessions: const [],
      bw7dAvg: bw7dAvg,
      bwRateLbWk: bwRateLbWk,
      bw3wkChange: bw3wkChange,
      weekType: weekType,
      tuesdayLowerSets: tuesdayLowerSets,
      topSets: const {},
      painNotes: painNotes,
    );

    List<String> ids(Map<DateTime, List<FlagHit>> flags, String monday) =>
        (flags[d(monday)] ?? []).map((f) => f.id).toList();

    test('WEIGHT_FAST needs two consecutive weeks > 0.6', () {
      final flags = evaluateFlags([
        wk('2025-01-06', bwRateLbWk: 0.7),
        wk('2025-01-13', bwRateLbWk: 0.5),
        wk('2025-01-20', bwRateLbWk: 0.7),
        wk('2025-01-27', bwRateLbWk: 0.8),
      ]);
      expect(ids(flags, '2025-01-06'), isNot(contains('WEIGHT_FAST')));
      expect(ids(flags, '2025-01-20'), isNot(contains('WEIGHT_FAST')));
      expect(ids(flags, '2025-01-27'), contains('WEIGHT_FAST'));
    });

    test('WEIGHT_FAST: exactly 0.6 does not fire (> 0.6)', () {
      final flags = evaluateFlags([
        wk('2025-01-06', bwRateLbWk: 0.6),
        wk('2025-01-13', bwRateLbWk: 0.6),
      ]);
      expect(ids(flags, '2025-01-13'), isNot(contains('WEIGHT_FAST')));
    });

    test('WEIGHT_CAP fires when bw_7d_avg > 172', () {
      final flags = evaluateFlags([wk('2025-01-06', bw7dAvg: 172.5)]);
      expect(ids(flags, '2025-01-06'), contains('WEIGHT_CAP'));
    });

    test('PHASE_MISMATCH needs three consecutive weeks', () {
      String phase(DateTime _) => 'bulk';
      final flags = evaluateFlags([
        wk('2025-01-06', bwRateLbWk: -0.3),
        wk('2025-01-13', bwRateLbWk: -0.3),
        wk('2025-01-20', bwRateLbWk: -0.3),
      ], phaseOf: phase);
      expect(ids(flags, '2025-01-13'), isNot(contains('PHASE_MISMATCH')));
      expect(ids(flags, '2025-01-20'), contains('PHASE_MISMATCH'));
    });

    test('PHASE_MISMATCH silent without a phase', () {
      final flags = evaluateFlags([
        wk('2025-01-06', bwRateLbWk: -0.3),
        wk('2025-01-13', bwRateLbWk: -0.3),
        wk('2025-01-20', bwRateLbWk: -0.3),
      ]);
      expect(ids(flags, '2025-01-20'), isNot(contains('PHASE_MISMATCH')));
    });

    test('NEAR_MAX_LOW / WORKING_LOW / BENCH_ONCE fire on normal weeks and '
        'on unknown week_type (backtest), not on light weeks', () {
      final flags = evaluateFlags([
        wk('2025-01-06', nearMaxSets: 4, workingSets: 19, benchDays: 1),
        wk(
          '2025-01-13',
          nearMaxSets: 4,
          workingSets: 19,
          benchDays: 1,
          weekType: 'light',
        ),
        wk(
          '2025-01-20',
          nearMaxSets: 4,
          workingSets: 19,
          benchDays: 1,
          weekType: 'normal',
        ),
      ]);
      expect(
        ids(flags, '2025-01-06'),
        containsAll(['NEAR_MAX_LOW', 'WORKING_LOW', 'BENCH_ONCE']),
      );
      expect(ids(flags, '2025-01-13'), isNot(contains('NEAR_MAX_LOW')));
      expect(ids(flags, '2025-01-13'), isNot(contains('WORKING_LOW')));
      expect(ids(flags, '2025-01-13'), isNot(contains('BENCH_ONCE')));
      expect(
        ids(flags, '2025-01-20'),
        containsAll(['NEAR_MAX_LOW', 'WORKING_LOW', 'BENCH_ONCE']),
      );
    });

    test('NEAR_MAX_LOW boundary: 5 near-max sets do not fire; '
        'WORKING_LOW boundary: 20 working sets do not fire', () {
      final flags = evaluateFlags([wk('2025-01-06')]);
      final f2 = evaluateFlags([
        wk('2025-01-06', nearMaxSets: 5, workingSets: 20),
      ]);
      expect(ids(flags, '2025-01-06'), isEmpty);
      expect(ids(f2, '2025-01-06'), isNot(contains('NEAR_MAX_LOW')));
      expect(ids(f2, '2025-01-06'), isNot(contains('WORKING_LOW')));
    });

    test('LONG_SETS at >= 2 long failure sets, any week type', () {
      final flags = evaluateFlags([
        wk('2025-01-06', longFailureSets: 2, weekType: 'light'),
        wk('2025-01-13', longFailureSets: 1),
      ]);
      expect(ids(flags, '2025-01-06'), contains('LONG_SETS'));
      expect(ids(flags, '2025-01-13'), isNot(contains('LONG_SETS')));
    });

    test('TUESDAY_LOWER fires when a squat/deadlift set hits effort >= 0.85 '
        'on a Tuesday', () {
      final flags = evaluateFlags([wk('2025-01-06', tuesdayLowerSets: 1)]);
      expect(ids(flags, '2025-01-06'), contains('TUESDAY_LOWER'));
    });

    test('PAIN_NOTE fires on a cause=pain note', () {
      final flags = evaluateFlags([wk('2025-01-06', painNotes: 1)]);
      expect(ids(flags, '2025-01-06'), contains('PAIN_NOTE'));
    });

    test('TWO_SIGNALS counts other flags (>= 2) and not itself', () {
      final two = evaluateFlags([
        wk('2025-01-06', nearMaxSets: 3, benchDays: 1),
      ]);
      expect(
        ids(two, '2025-01-06'),
        containsAll(['NEAR_MAX_LOW', 'BENCH_ONCE', 'TWO_SIGNALS']),
      );
      final one = evaluateFlags([wk('2025-01-06', nearMaxSets: 3)]);
      expect(ids(one, '2025-01-06'), ['NEAR_MAX_LOW']);
    });

    test('TOP_SET_HEAVY: two consecutive top sets on one lift at '
        'RPE >= 9.5, across weeks', () {
      WeeklyMetrics withTop(String monday, String liftDate, double? rpe) {
        final base = wk(monday);
        return WeeklyMetrics(
          weekStart: base.weekStart,
          sessions: base.sessions,
          setsTotal: base.setsTotal,
          workingSets: base.workingSets,
          hardSets: base.hardSets,
          nearMaxSets: base.nearMaxSets,
          longFailureSets: base.longFailureSets,
          avgRepsWorking: base.avgRepsWorking,
          perLift: base.perLift,
          benchDays: base.benchDays,
          climbingSessions: base.climbingSessions,
          bike4x4Sessions: base.bike4x4Sessions,
          bw7dAvg: base.bw7dAvg,
          bwRateLbWk: base.bwRateLbWk,
          bw3wkChange: base.bw3wkChange,
          weekType: base.weekType,
          tuesdayLowerSets: base.tuesdayLowerSets,
          topSets: {
            'squat': [TopSetInfo(date: d(liftDate), e1rm: 400, rpe: rpe)],
          },
          painNotes: base.painNotes,
        );
      }

      final flags = evaluateFlags([
        withTop('2025-01-06', '2025-01-06', 9.5),
        withTop('2025-01-13', '2025-01-13', 9.5),
      ]);
      expect(ids(flags, '2025-01-06'), isNot(contains('TOP_SET_HEAVY')));
      expect(ids(flags, '2025-01-13'), contains('TOP_SET_HEAVY'));

      // A no-RPE session breaks the chain.
      final broken = evaluateFlags([
        withTop('2025-01-06', '2025-01-06', 9.5),
        withTop('2025-01-13', '2025-01-13', null),
        withTop('2025-01-20', '2025-01-20', 9.5),
      ]);
      expect(ids(broken, '2025-01-20'), isNot(contains('TOP_SET_HEAVY')));
    });

    test('flags carry firedOn = the Sunday of the week', () {
      final flags = evaluateFlags([wk('2025-01-06', bw7dAvg: 180)]);
      final hit = flags[d('2025-01-06')]!.single;
      expect(hit.id, 'WEIGHT_CAP');
      expect(hit.firedOn, d('2025-01-12'));
      expect(hit.evidence['bw_7d_avg'], 180);
    });
  });
}
