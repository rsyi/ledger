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
  List<DateTime> climbingDates = const [],
  List<DateTime> cardioDates = const [],
  Map<DateTime, double> proteinByDay = const {},
  double? bodyweightLb,
}) => WeekDriverInputs(
  graded: graded,
  climbingDates: climbingDates,
  cardioDates: cardioDates,
  proteinByDay: proteinByDay,
  bodyweightLb: bodyweightLb,
);

DriverEval evalOne(
  WeekDriverConfig config,
  WeekDriverInputs data,
) => evaluateWeekDrivers(
  configs: [config],
  inputs: data,
  today: today,
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

  group('top_single_per_lift', () {
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

  group('real dashboards.yaml (airledger-fitness checkout)', () {
    const path = '../airledger-fitness/app/dashboards.yaml';

    test('every phase parses with outcome-named drivers', () {
      final file = File(path);
      if (!file.existsSync()) {
        markTestSkipped('no airledger-fitness checkout');
        return;
      }
      final byPhase = parseWeeklyDrivers(file.readAsStringSync())!;
      expect(byPhase.keys.toSet(),
          {'cut', 'bulk', 'maintain', 'reverse'});
      final cut = byPhase['cut']!;
      expect(cut.map((d) => d.id).toList(), [
        'top_single_per_lift',
        'bench_frequency',
        'protein_floor',
        'climbing_cap',
        'bike_4x4',
      ]);
      expect(cut[3].cap, 2); // climbing CAP, program targets_block_0
      expect(cut[2].floorGPerLb, 0.8);
      final bulk = byPhase['bulk']!;
      expect(bulk.map((d) => d.id).toList(),
          ['lift_frequency', 'near_max_exposure', 'protein_floor']);
      expect(bulk[0].perLiftTargets['deadlift'], 1);
      expect(bulk[1].target, 6);
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
