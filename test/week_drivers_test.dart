import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_metrics.dart'
    show GradedSet, SetTier;
import 'package:airledger/services/week_drivers.dart';

// ---------------------------------------------------------------------------
// Fixtures — Saturday accounting weeks (program v7): today is Tue
// 2026-09-22, so the current week runs Sat 2026-09-19 .. Fri 2026-09-25.
// ---------------------------------------------------------------------------

final today = DateTime(2026, 9, 22);
const satStart = DateTime.saturday;

GradedSet g(
  String lift,
  DateTime date, {
  bool nearMax = false,
  bool working = true,
}) => GradedSet(
  date: date,
  lift: lift,
  weight: 200,
  reps: 1,
  e1rm: 206.7,
  reference: 210,
  effort: nearMax ? 0.98 : 0.85,
  pctMax: 0.95,
  tier: SetTier.hard,
  working: working,
  nearMax: nearMax,
  longFailureSet: false,
);

WeekDriverInputs inputs({
  List<GradedSet> graded = const [],
  List<TopSetReading>? readings,
  DateTime? alternationAnchorMonday,
  List<DateTime> climbingDates = const [],
  List<DateTime> cardioDates = const [],
  Map<DateTime, double> proteinByDay = const {},
  double? bodyweightLb,
  List<LoggedSet> strengthSets = const [],
  MuscleMap? muscleMap,
}) => WeekDriverInputs(
  graded: graded,
  readings: readings,
  alternationAnchorMonday: alternationAnchorMonday,
  climbingDates: climbingDates,
  cardioDates: cardioDates,
  proteinByDay: proteinByDay,
  bodyweightLb: bodyweightLb,
  strengthSets: strengthSets,
  muscleMap: muscleMap,
);

LoggedSet ls(String exercise, DateTime date, {int reps = 5}) =>
    LoggedSet(date: date, exercise: exercise, reps: reps);

/// A small v9-shaped muscle map for the counting tests.
final testMap = MuscleMap(
  exercises: {
    'Barbell Squat': {'quads': 1.0, 'hamstrings_glutes': 0.5},
    'Flat Barbell Bench Press': {'chest': 1.0, 'triceps': 0.5},
    'Weighted Pull Up': {'back': 1.0, 'biceps': 0.5},
    'Muscle Up': {'back': 0.75, 'triceps': 0.5},
  },
  climbingSession: {'back': 3.0, 'biceps': 1.5},
);

TopSetReading reading(
  String lift,
  DateTime date, {
  String kind = 'heavy_top',
  int reps = 1,
  double rpe = 8,
}) => TopSetReading(date: date, lift: lift, kind: kind, reps: reps, rpe: rpe);

DriverEval evalOne(
  WeekDriverConfig config,
  WeekDriverInputs data, {
  DateTime? at,
}) => evaluateWeekDrivers(
  configs: [config],
  inputs: data,
  today: at ?? today,
  weekStartDay: satStart,
).single;

const cutYaml = '''
phases:
  cut:
    eigenvectors:
      - id: weight_loss
        rate_band: [-1.0, -0.5]
    weekly_drivers:
      - id: top_single_per_lift
        label: singles
        lifts: [squat, bench, deadlift, press]
        heavy_single_max_days: 14
        outcome: "Wilks preserved"
        why: "One heavy single per lift holds neural strength."
      - id: bench_frequency
        label: bench 2x
        target: 2
        outcome: "bench holds"
        why: "Bench detrains fastest."
      - id: protein_floor
        label: protein
        floor_g_per_lb: 0.8
        outcome: "muscle retention"
        why: "Deficit weight loss stays mostly fat."
      - id: climbing_cap
        label: climb
        cap: 2
        outcome: "recovery budget"
        why: "A third session taxes lift recovery."
      - id: bike_4x4
        label: 4x4
        target: 1
        outcome: "VO2 held"
        why: "One weekly 4x4 keeps the top end."
  bulk:
    weekly_drivers:
      - id: lift_frequency
        per_lift_targets: { squat: 2, bench: 2, press: 2, deadlift: 1 }
        outcome: "e1RM growth"
        why: "Muscle-group 2x/wk, specialized to the program."
      - id: near_max_exposure
        target: 6
        outcome: "e1RM growth"
        why: "Backtest-validated productive stretch."
  maintain:
    eigenvectors:
      - id: weight_hold
        rate_band: [-0.25, 0.25]
''';

void main() {
  group('parseWeeklyDrivers', () {
    test('parses per-phase driver lists with all field kinds', () {
      final byPhase = parseWeeklyDrivers(cutYaml)!;
      final cut = byPhase['cut']!;
      expect(cut, hasLength(5));
      expect(cut[0].id, 'top_single_per_lift');
      expect(cut[0].lifts, ['squat', 'bench', 'deadlift', 'press']);
      expect(cut[0].heavySingleMaxDays, 14);
      expect(cut[0].outcome, 'Wilks preserved');
      expect(cut[0].why, contains('neural'));
      expect(cut[1].target, 2);
      expect(cut[2].floorGPerLb, 0.8);
      expect(cut[3].cap, 2);
      expect(cut[4].label, '4x4');
      final bulk = byPhase['bulk']!;
      expect(bulk[0].perLiftTargets, {
        'squat': 2,
        'bench': 2,
        'press': 2,
        'deadlift': 1,
      });
      expect(bulk[1].target, 6);
    });

    test('phase without weekly_drivers is absent from the map', () {
      expect(parseWeeklyDrivers(cutYaml)!.containsKey('maintain'), isFalse);
    });

    test('back-compat: no weekly_drivers anywhere → null (strip unchanged)',
        () {
      const legacy = '''
phases:
  cut:
    eigenvectors:
      - id: weight_loss
''';
      expect(parseWeeklyDrivers(legacy), isNull);
      expect(parseWeeklyDrivers(null), isNull);
      expect(parseWeeklyDrivers(''), isNull);
      expect(parseWeeklyDrivers('domains: []'), isNull);
      expect(parseWeeklyDrivers('not: [valid'), isNull);
    });

    test('driver entries without an id are skipped, never fatal', () {
      const raw = '''
phases:
  cut:
    weekly_drivers:
      - label: no id here
      - id: bench_frequency
        target: 2
''';
      final cut = parseWeeklyDrivers(raw)!['cut']!;
      expect(cut, hasLength(1));
      expect(cut.single.id, 'bench_frequency');
    });
  });

  group('top_single_per_lift — readings-based (2026-09-25)', () {
    final config = WeekDriverConfig(
      id: 'top_single_per_lift',
      lifts: const ['squat', 'bench', 'deadlift', 'press'],
    );

    test('any top-set reading ticks its lift — the Monday 275x2@8 squat '
        '(not near-max by §2.5 grading) passes the week', () {
      final e = evalOne(
        config,
        inputs(
          // §2.5 grading says NOT near-max — must be irrelevant now.
          graded: [g('squat', DateTime(2026, 9, 21))],
          readings: [reading('squat', DateTime(2026, 9, 21), reps: 2)],
        ),
      );
      expect(e.value, '1/4');
      expect(e.ticks.firstWhere((t) => t.lift == 'squat').done, isTrue);
    });

    test('heavy_top, saturday_single, capped and test readings all tick; '
        'light_week never does', () {
      DriverTick tickOf(String kind, String lift) => evalOne(
        config,
        inputs(readings: [
          reading(lift, DateTime(2026, 9, 21), kind: kind, reps: 3),
        ]),
      ).ticks.firstWhere((t) => t.lift == lift);
      expect(tickOf('heavy_top', 'squat').done, isTrue);
      expect(tickOf('saturday_single', 'bench').done, isTrue);
      expect(tickOf('capped', 'deadlift').done, isTrue);
      expect(tickOf('test', 'press').done, isTrue);
      expect(tickOf('light_week', 'squat').done, isFalse);
    });

    test('readings outside the accounting week (or in the future) never '
        'tick', () {
      final e = evalOne(
        config,
        inputs(readings: [
          reading('deadlift', DateTime(2026, 9, 17)), // prior week (Thu)
          reading('squat', DateTime(2026, 9, 24)), // future (planned)
        ]),
      );
      expect(e.value, '0/4');
    });

    test('all four lifts covered by readings → met', () {
      final e = evalOne(
        config,
        inputs(readings: [
          reading('squat', DateTime(2026, 9, 21), reps: 2),
          reading('bench', DateTime(2026, 9, 21)),
          reading('deadlift', DateTime(2026, 9, 22), kind: 'capped'),
          reading('press', DateTime(2026, 9, 19), reps: 5, rpe: 9),
        ]),
      );
      expect(e.status, DriverStatus.met);
      expect(e.value, '4/4');
    });

    test('parity labels from the alternation anchor: A week = squat '
        'heavy + deadlift light; B week swaps; bench/press unlabeled', () {
      // Week of Sat 2026-09-19: its Monday is the anchor itself → A.
      final a = evalOne(
        config,
        inputs(
          readings: const [],
          alternationAnchorMonday: DateTime(2026, 9, 21),
        ),
      );
      final aByLift = {for (final t in a.ticks) t.lift: t.parity};
      expect(aByLift, {
        'squat': 'heavy',
        'bench': null,
        'deadlift': 'light',
        'press': null,
      });
      // One accounting week later (Tue 2026-09-29 → Monday 09-28) → B.
      final b = evalOne(
        config,
        inputs(
          readings: const [],
          alternationAnchorMonday: DateTime(2026, 9, 21),
        ),
        at: DateTime(2026, 9, 29),
      );
      final bByLift = {for (final t in b.ticks) t.lift: t.parity};
      expect(bByLift['squat'], 'light');
      expect(bByLift['deadlift'], 'heavy');
    });

    test('no anchor → no parity labels', () {
      final e = evalOne(config, inputs(readings: const []));
      expect(e.ticks.every((t) => t.parity == null), isTrue);
    });

    group('heavy-single recency (every-two-weeks rule)', () {
      final heavyConfig = WeekDriverConfig(
        id: 'top_single_per_lift',
        lifts: const ['squat', 'bench', 'deadlift', 'press'],
        heavySingleMaxDays: 14,
      );

      test('newest ≤2-rep RPE ≥ 7.5 reading dates the exposure; bands: '
          'fresh ≤ 14d, amber past 14d, red past 21d', () {
        final e = evalOne(
          heavyConfig,
          inputs(readings: [
            // Squat: heavy 3d ago (later 3-rep day must not count).
            reading('squat', DateTime(2026, 9, 19), reps: 2, rpe: 8),
            reading('squat', DateTime(2026, 9, 21), reps: 3, rpe: 8),
            // Deadlift: heavy 16 days ago → amber.
            reading('deadlift', DateTime(2026, 9, 6), reps: 1, rpe: 7.5),
          ]),
        );
        final byLift = {for (final h in e.heavyRecency) h.lift: h};
        expect(byLift.keys.toSet(), {'squat', 'deadlift'});
        expect(byLift['squat']!.daysAgo, 3);
        expect(byLift['squat']!.band, HeavySingleBand.fresh);
        expect(byLift['deadlift']!.daysAgo, 16);
        expect(byLift['deadlift']!.band, HeavySingleBand.overdue);
      });

      test('past 21 days → stale (red); light_week / high-rep / easy '
          'readings never qualify', () {
        final e = evalOne(
          heavyConfig,
          inputs(readings: [
            reading('squat', DateTime(2026, 8, 30), reps: 1, rpe: 9),
            // None of these refresh the squat exposure:
            reading('squat', DateTime(2026, 9, 21), reps: 3, rpe: 9),
            reading('squat', DateTime(2026, 9, 21), reps: 2, rpe: 7),
            reading('squat', DateTime(2026, 9, 20),
                reps: 1, rpe: 8, kind: 'light_week'),
          ]),
        );
        final squat = e.heavyRecency.firstWhere((h) => h.lift == 'squat');
        expect(squat.daysAgo, 23);
        expect(squat.band, HeavySingleBand.stale);
      });

      test('no qualifying reading yet → null daysAgo, amber (unknown is '
          'not violated)', () {
        final e = evalOne(heavyConfig, inputs(readings: const []));
        final squat = e.heavyRecency.firstWhere((h) => h.lift == 'squat');
        expect(squat.daysAgo, isNull);
        expect(squat.band, HeavySingleBand.overdue);
      });

      test('recency only tracks the alternating lifts (squat/deadlift), '
          'and only when heavy_single_max_days is configured', () {
        final e = evalOne(heavyConfig, inputs(readings: const []));
        expect(e.heavyRecency.map((h) => h.lift).toSet(),
            {'squat', 'deadlift'});
        final noConfig = evalOne(config, inputs(readings: const []));
        expect(noConfig.heavyRecency, isEmpty);
        // Legacy mode (no readings source) has no recency data either.
        final legacy = evalOne(heavyConfig, inputs());
        expect(legacy.heavyRecency, isEmpty);
      });
    });
  });

  group('top_single_per_lift — legacy near-max fallback (no readings '
      'source plumbed)', () {
    final config = WeekDriverConfig(
      id: 'top_single_per_lift',
      lifts: const ['squat', 'bench', 'deadlift', 'press'],
    );

    test('per-lift ticks: 3 of 4 done → pending, deadlift tick open', () {
      final e = evalOne(
        config,
        inputs(graded: [
          g('squat', DateTime(2026, 9, 21), nearMax: true),
          g('bench', DateTime(2026, 9, 21), nearMax: true),
          g('press', DateTime(2026, 9, 19), nearMax: true),
          // Deadlift single happened LAST accounting week (Thu 9/17).
          g('deadlift', DateTime(2026, 9, 17), nearMax: true),
        ]),
      );
      expect(e.status, DriverStatus.pending);
      expect(e.value, '3/4');
      expect(e.ticks.map((t) => t.lift).toList(),
          ['squat', 'bench', 'deadlift', 'press']);
      expect(e.ticks.map((t) => t.done).toList(),
          [true, true, false, true]);
    });

    test('all four lifts near-max this week → met', () {
      final e = evalOne(
        config,
        inputs(graded: [
          for (final lift in ['squat', 'bench', 'deadlift', 'press'])
            g(lift, DateTime(2026, 9, 21), nearMax: true),
        ]),
      );
      expect(e.status, DriverStatus.met);
      expect(e.value, '4/4');
    });

    test('Saturday keying: Fri 9/18 is last week, Sat 9/19 is this week',
        () {
      final e = evalOne(
        config,
        inputs(graded: [
          g('squat', DateTime(2026, 9, 18), nearMax: true), // prior week
          g('bench', DateTime(2026, 9, 19), nearMax: true), // this week
        ]),
      );
      expect(
        e.ticks.firstWhere((t) => t.lift == 'squat').done,
        isFalse,
      );
      expect(
        e.ticks.firstWhere((t) => t.lift == 'bench').done,
        isTrue,
      );
    });

    test('future planned rows never count', () {
      final e = evalOne(
        config,
        inputs(graded: [
          g('squat', DateTime(2026, 9, 24), nearMax: true), // Thu, planned
        ]),
      );
      expect(e.value, '0/4');
    });

    test('working-but-not-near-max sets do not tick a lift', () {
      final e = evalOne(
        config,
        inputs(graded: [g('squat', DateTime(2026, 9, 21))]),
      );
      expect(e.value, '0/4');
    });
  });

  group('bench_frequency', () {
    final config = WeekDriverConfig(id: 'bench_frequency', target: 2);

    test('two distinct bench days → met', () {
      final e = evalOne(
        config,
        inputs(graded: [
          g('bench', DateTime(2026, 9, 19)),
          g('bench', DateTime(2026, 9, 19), nearMax: true), // same day
          g('bench', DateTime(2026, 9, 21)),
        ]),
      );
      expect(e.status, DriverStatus.met);
      expect(e.value, '2/2');
    });

    test('one day → pending', () {
      final e = evalOne(
        config,
        inputs(graded: [g('bench', DateTime(2026, 9, 21))]),
      );
      expect(e.status, DriverStatus.pending);
      expect(e.value, '1/2');
    });
  });

  group('lift_frequency (bulk)', () {
    final config = WeekDriverConfig(
      id: 'lift_frequency',
      perLiftTargets: const {'squat': 2, 'bench': 2, 'press': 2, 'deadlift': 1},
    );

    test('per-lift day counts vs targets', () {
      final e = evalOne(
        config,
        inputs(graded: [
          g('squat', DateTime(2026, 9, 19)),
          g('bench', DateTime(2026, 9, 19)),
          g('bench', DateTime(2026, 9, 21)),
          g('deadlift', DateTime(2026, 9, 21)),
        ]),
      );
      expect(e.status, DriverStatus.pending);
      final byLift = {for (final t in e.ticks) t.lift: t};
      expect(byLift['squat']!.count, 1);
      expect(byLift['squat']!.target, 2);
      expect(byLift['squat']!.done, isFalse);
      expect(byLift['bench']!.done, isTrue);
      expect(byLift['press']!.count, 0);
      expect(byLift['deadlift']!.done, isTrue);
    });

    test('every lift at target → met', () {
      final e = evalOne(
        config,
        inputs(graded: [
          for (final d in [DateTime(2026, 9, 19), DateTime(2026, 9, 21)]) ...[
            g('squat', d),
            g('bench', d),
            g('press', d),
          ],
          g('deadlift', DateTime(2026, 9, 21)),
        ]),
      );
      expect(e.status, DriverStatus.met);
    });
  });

  group('near_max_exposure', () {
    final config = WeekDriverConfig(id: 'near_max_exposure', target: 6);

    test('counts near-max SETS (not days) this week', () {
      final e = evalOne(
        config,
        inputs(graded: [
          for (var i = 0; i < 4; i++)
            g('squat', DateTime(2026, 9, 21), nearMax: true),
          g('bench', DateTime(2026, 9, 17), nearMax: true), // last week
          g('bench', DateTime(2026, 9, 21)), // not near-max
        ]),
      );
      expect(e.status, DriverStatus.pending);
      expect(e.value, '4/6');
    });

    test('six or more → met', () {
      final e = evalOne(
        config,
        inputs(graded: [
          for (var i = 0; i < 6; i++)
            g('bench', DateTime(2026, 9, 20), nearMax: true),
        ]),
      );
      expect(e.status, DriverStatus.met);
    });
  });

  group('protein_floor', () {
    final config = WeekDriverConfig(id: 'protein_floor', floorGPerLb: 0.8);

    test('daily average over days WITH data, pro-rated by nature', () {
      final e = evalOne(
        config,
        inputs(
          proteinByDay: {
            DateTime(2026, 9, 19): 190,
            DateTime(2026, 9, 20): 150,
            DateTime(2026, 9, 21): 160,
            DateTime(2026, 9, 22): 170,
          },
          bodyweightLb: 160,
        ),
      );
      // avg 167.5 g / 160 lb = 1.05 g/lb ≥ 0.8 → met.
      expect(e.status, DriverStatus.met);
      expect(e.value, '1.05 g/lb');
    });

    test('under the floor → violated (a floor breach is red, not pending)',
        () {
      final e = evalOne(
        config,
        inputs(
          proteinByDay: {DateTime(2026, 9, 21): 96},
          bodyweightLb: 160,
        ),
      );
      expect(e.status, DriverStatus.violated);
      expect(e.value, '0.60 g/lb');
    });

    test('days outside the accounting week are ignored', () {
      final e = evalOne(
        config,
        inputs(
          proteinByDay: {
            DateTime(2026, 9, 18): 10, // Fri — last week
            DateTime(2026, 9, 21): 160,
          },
          bodyweightLb: 160,
        ),
      );
      expect(e.value, '1.00 g/lb');
    });

    test('no meal data or no bodyweight → pending', () {
      expect(
        evalOne(config, inputs(bodyweightLb: 160)).status,
        DriverStatus.pending,
      );
      expect(
        evalOne(
          config,
          inputs(proteinByDay: {DateTime(2026, 9, 21): 160}),
        ).status,
        DriverStatus.pending,
      );
    });
  });

  group('climbing_cap', () {
    final config = WeekDriverConfig(id: 'climbing_cap', cap: 2);

    test('at the cap is FINE (a cap is not a target) → met', () {
      final e = evalOne(
        config,
        inputs(climbingDates: [
          DateTime(2026, 9, 21),
          DateTime(2026, 9, 22),
          DateTime(2026, 9, 22), // second ascent same day — one session
        ]),
      );
      expect(e.status, DriverStatus.met);
      expect(e.value, '2/≤2');
      expect(e.staleAsOf, isNull);
    });

    test('over the cap → violated', () {
      final e = evalOne(
        config,
        inputs(climbingDates: [
          DateTime(2026, 9, 19),
          DateTime(2026, 9, 21),
          DateTime(2026, 9, 22),
        ]),
      );
      expect(e.status, DriverStatus.violated);
      expect(e.value, '3/≤2');
    });

    test('under the cap with a current snapshot → met', () {
      final e = evalOne(
        config,
        inputs(climbingDates: [
          DateTime(2026, 9, 15), // last week
          DateTime(2026, 9, 21), // this week — snapshot is current
        ]),
      );
      expect(e.status, DriverStatus.met);
      expect(e.value, '1/≤2');
    });

    test('snapshot honesty: latest ascent predates the accounting week → '
        'pending with the as-of date (cannot know this week)', () {
      final e = evalOne(
        config,
        inputs(climbingDates: [
          DateTime(2026, 9, 12),
          DateTime(2026, 9, 15),
        ]),
      );
      expect(e.status, DriverStatus.pending);
      expect(e.staleAsOf, DateTime(2026, 9, 15));
      expect(e.value, '0/≤2');
    });

    test('empty snapshot → pending, no as-of', () {
      final e = evalOne(config, inputs());
      expect(e.status, DriverStatus.pending);
      expect(e.staleAsOf, isNull);
    });
  });

  group('bike_4x4', () {
    final config = WeekDriverConfig(id: 'bike_4x4', target: 1);

    test('one session day this week → met', () {
      final e = evalOne(
        config,
        inputs(cardioDates: [
          DateTime(2026, 9, 17), // last week
          DateTime(2026, 9, 22),
          DateTime(2026, 9, 22), // interval rows collapse to one session
        ]),
      );
      expect(e.status, DriverStatus.met);
      expect(e.value, '1/1');
    });

    test('none yet → pending', () {
      final e = evalOne(config, inputs());
      expect(e.status, DriverStatus.pending);
      expect(e.value, '0/1');
    });
  });

  // v9 (post-cut-recomp-spec 2026-09-27): hypertrophy is first-class —
  // 8-12 productive sets per muscle group per week, overlap-counted
  // from strength rows + climbing sessions + calisthenics via the
  // program's declared exercise_muscle_map.
  group('hypertrophy_volume (v9)', () {
    final config = WeekDriverConfig(
      id: 'hypertrophy_volume',
      band: const [8, 12],
      muscleGroups: const ['quads', 'chest', 'back'],
    );

    test('counts per-group set credits from strength rows via the map', () {
      final d = DateTime(2026, 9, 21);
      final e = evalOne(
        config,
        inputs(
          muscleMap: testMap,
          strengthSets: [
            for (var i = 0; i < 8; i++) ls('Barbell Squat', d),
            for (var i = 0; i < 8; i++) ls('Flat Barbell Bench Press', d),
          ],
        ),
      );
      // quads 8 (in band), chest 8 (in band), back 0 → pending.
      expect(e.status, DriverStatus.pending);
      final byGroup = {for (final t in e.ticks) t.lift: t};
      expect(byGroup['quads']!.count, 8);
      expect(byGroup['chest']!.count, 8);
      expect(byGroup['back']!.count, 0);
      expect(byGroup['quads']!.target, 8); // band low edge
      expect(e.value, '2/3');
    });

    test('climbing sessions credit via climbing_session; all groups in '
        'band → met', () {
      final d = DateTime(2026, 9, 21);
      final e = evalOne(
        config,
        inputs(
          muscleMap: testMap,
          climbingDates: [DateTime(2026, 9, 20), DateTime(2026, 9, 22)],
          strengthSets: [
            for (var i = 0; i < 8; i++) ls('Barbell Squat', d),
            for (var i = 0; i < 8; i++) ls('Flat Barbell Bench Press', d),
            // back: 2 pull-up sets (2.0) + 2 climbing sessions (6.0) = 8
            ls('Weighted Pull Up', d),
            ls('Weighted Pull Up', d),
          ],
        ),
      );
      expect(e.status, DriverStatus.met);
      final byGroup = {for (final t in e.ticks) t.lift: t};
      expect(byGroup['back']!.count, 8);
    });

    test('over the top of the band → violated (excess volume, the '
        'pulling caution)', () {
      final d = DateTime(2026, 9, 21);
      final e = evalOne(
        config,
        inputs(
          muscleMap: testMap,
          climbingDates: [DateTime(2026, 9, 20), DateTime(2026, 9, 22)],
          strengthSets: [
            for (var i = 0; i < 8; i++) ls('Barbell Squat', d),
            for (var i = 0; i < 8; i++) ls('Flat Barbell Bench Press', d),
            // back: 8 pull-up sets + 6.0 climbing credit = 14 > 12
            for (var i = 0; i < 8; i++) ls('Weighted Pull Up', d),
          ],
        ),
      );
      expect(e.status, DriverStatus.violated);
    });

    test('prefix match: banded muscle-up rows count under "Muscle Up"', () {
      final d = DateTime(2026, 9, 21);
      final e = evalOne(
        config,
        inputs(
          muscleMap: testMap,
          strengthSets: [
            ls('Muscle Up Purple Band', d),
            ls('Muscle Up', d),
          ],
        ),
      );
      final byGroup = {for (final t in e.ticks) t.lift: t};
      expect(byGroup['back']!.count, 2); // 2 × 0.75 = 1.5 → rounds to 2
    });

    test('rows outside the accounting week never count; no map → pending '
        'with no ticks', () {
      final e = evalOne(
        config,
        inputs(
          muscleMap: testMap,
          strengthSets: [
            for (var i = 0; i < 8; i++)
              ls('Barbell Squat', DateTime(2026, 9, 18)), // last week
          ],
        ),
      );
      expect({for (final t in e.ticks) t.lift: t.count}['quads'], 0);
      final noMap = evalOne(config, inputs(strengthSets: [
        ls('Barbell Squat', DateTime(2026, 9, 21)),
      ]));
      expect(noMap.status, DriverStatus.pending);
      expect(noMap.ticks, isEmpty);
    });
  });

  // v9: each main lift gets BOTH a heavy exposure (top-set reading)
  // and a hypertrophy exposure (3-8-rep sets) every week.
  group('dual_exposure (v9)', () {
    final config = WeekDriverConfig(
      id: 'dual_exposure',
      lifts: const ['squat', 'bench', 'deadlift', 'press'],
      hypSetsMin: 3,
      hypReps: const [3, 8],
    );

    test('heavy reading + 3 hypertrophy sets = both halves tick', () {
      final d = DateTime(2026, 9, 21);
      final e = evalOne(
        config,
        inputs(
          readings: [reading('squat', d)],
          strengthSets: [
            ls('Barbell Squat', d, reps: 5),
            ls('Barbell Squat', d, reps: 5),
            ls('Barbell Squat', d, reps: 5),
          ],
        ),
      );
      final byLift = {for (final t in e.ticks) t.lift: t};
      expect(byLift['squat']!.count, 2);
      expect(byLift['squat']!.target, 2);
      expect(byLift['bench']!.count, 0);
      expect(e.status, DriverStatus.pending);
      expect(e.value, '2/8');
    });

    test('reps outside 3-8 (singles, warmup 10s) never count toward the '
        'hypertrophy half', () {
      final d = DateTime(2026, 9, 21);
      final e = evalOne(
        config,
        inputs(
          readings: const [],
          strengthSets: [
            ls('Barbell Squat', d, reps: 1),
            ls('Barbell Squat', d, reps: 10),
            ls('Barbell Squat', d, reps: 2),
          ],
        ),
      );
      expect({for (final t in e.ticks) t.lift: t.count}['squat'], 0);
    });

    test('all four lifts with both exposures → met', () {
      final d = DateTime(2026, 9, 21);
      final e = evalOne(
        config,
        inputs(
          readings: [
            reading('squat', d),
            reading('bench', d),
            reading('deadlift', d),
            reading('press', d),
          ],
          strengthSets: [
            for (final ex in [
              'Barbell Squat',
              'Flat Barbell Bench Press',
              'Barbell Deadlift',
              'Overhead Press',
            ])
              for (var i = 0; i < 3; i++) ls(ex, d, reps: 5),
          ],
        ),
      );
      expect(e.status, DriverStatus.met);
      expect(e.value, '8/8');
    });

    test('light_week readings do not tick the heavy half', () {
      final d = DateTime(2026, 9, 21);
      final e = evalOne(
        config,
        inputs(readings: [reading('squat', d, kind: 'light_week')]),
      );
      expect({for (final t in e.ticks) t.lift: t.count}['squat'], 0);
    });
  });

  // v9: the recomp protein target is ABSOLUTE (160-175 g/day), not
  // per-lb — floor_g wins over floor_g_per_lb when declared.
  group('protein_floor — absolute floor_g (v9)', () {
    final config = WeekDriverConfig(
      id: 'protein_floor',
      floorG: 160,
      bandG: const [160, 175],
    );

    test('daily average at/over the absolute floor → met, grams shown', () {
      final e = evalOne(
        config,
        inputs(proteinByDay: {
          DateTime(2026, 9, 21): 170,
          DateTime(2026, 9, 22): 160,
        }),
      );
      expect(e.status, DriverStatus.met);
      expect(e.value, '165 g');
    });

    test('under the absolute floor → violated', () {
      final e = evalOne(
        config,
        inputs(proteinByDay: {DateTime(2026, 9, 21): 120}),
      );
      expect(e.status, DriverStatus.violated);
      expect(e.value, '120 g');
    });

    test('absolute floor needs no bodyweight; no data → pending', () {
      final e = evalOne(config, inputs());
      expect(e.status, DriverStatus.pending);
      expect(e.value, '— g');
    });
  });

  group('real dashboards.yaml (airledger-fitness checkout)', () {
    const path = '../airledger-fitness/app/dashboards.yaml';

    test('every phase parses with outcome-named drivers', () {
      final file = File(path);
      if (!file.existsSync()) {
        markTestSkipped('no airledger-fitness checkout');
        return;
      }
      final byPhase = parseWeeklyDrivers(file.readAsStringSync())!;
      // 2026-09-26: + recomp — the recomposition-variant driver set,
      // selected over bulk while program.yaml v8 carries
      // `variant: recomposition` (effectivePhaseKey).
      expect(byPhase.keys.toSet(),
          {'cut', 'bulk', 'recomp', 'maintain', 'reverse'});
      final cut = byPhase['cut']!;
      // v11 cut-training revision (2026-09-28): dual_exposure +
      // hypertrophy_volume go ACTIVE for the cut; bench moves to 3
      // days; the heavy-single recency rule + alternation tags are
      // retired (the wave tops weekly at 3-5 reps).
      expect(cut.map((d) => d.id).toList(), [
        'top_single_per_lift',
        'dual_exposure',
        'hypertrophy_volume',
        'bench_frequency',
        'protein_floor',
        'climbing_cap',
        'bike_4x4',
      ]);
      expect(cut[5].cap, 2); // climbing CAP, program targets_block_0
      // Protein floor stays the CUT-ERA relative 0.8 g/lb until Dec 14.
      expect(cut[4].floorGPerLb, 0.8);
      expect(cut[4].floorG, isNull);
      expect(cut[0].heavySingleMaxDays, isNull); // retired with the wave
      expect(cut[1].hypSetsMin, 2); // deadlift's planned 2x4-6
      expect(cut[1].hypReps, [4, 12]);
      expect(cut[2].band, [8, 12]);
      expect(cut[3].target, 3); // bench 3 days (Mon/Wed/Fri exposures)
      final bulk = byPhase['bulk']!;
      expect(bulk.map((d) => d.id).toList(),
          ['lift_frequency', 'near_max_exposure', 'protein_floor']);
      expect(bulk[0].perLiftTargets['deadlift'], 1);
      expect(bulk[1].target, 6);
      final recomp = byPhase['recomp']!;
      // v9 (post-cut-recomp-spec): dual exposure per lift + the 8-12
      // hypertrophy band + the ABSOLUTE protein floor replace the
      // bulk-shaped frequency/near-max/per-lb drivers.
      expect(recomp.map((d) => d.id).toList(), [
        'dual_exposure',
        'hypertrophy_volume',
        'protein_floor',
        'bike_4x4',
      ]);
      expect(recomp[0].lifts, ['squat', 'bench', 'deadlift', 'press']);
      expect(recomp[0].hypSetsMin, 3);
      expect(recomp[0].hypReps, [3, 8]);
      expect(recomp[1].band, [8, 12]);
      expect(recomp[1].muscleGroups, contains('back'));
      expect(recomp[2].floorG, 160);
      expect(recomp[2].bandG, [160, 175]);
      // The ship gate: every driver names the outcome it drives and
      // carries its causal story.
      for (final drivers in byPhase.values) {
        for (final d in drivers) {
          expect(d.outcome, isNotNull, reason: '${d.id} needs outcome');
          expect(d.why, isNotNull, reason: '${d.id} needs why');
        }
      }
    });
  });

  test('unknown driver ids are skipped (config forward-compat)', () {
    final evals = evaluateWeekDrivers(
      configs: [
        WeekDriverConfig(id: 'sleep_score'),
        WeekDriverConfig(id: 'bench_frequency', target: 2),
      ],
      inputs: inputs(),
      today: today,
      weekStartDay: satStart,
    );
    expect(evals, hasLength(1));
    expect(evals.single.config.id, 'bench_frequency');
  });
}
