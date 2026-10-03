import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_metrics.dart'
    show GradedSet, SetTier;
import 'package:airledger/services/goals_service.dart';
import 'package:airledger/services/muscle_volume.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_item_pricing.dart'
    show itemLiftKey;
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/whoop_activity.dart';

// ---------------------------------------------------------------------------
// Fixtures — Saturday accounting weeks (program week_start: saturday). Today
// is Tue 2026-09-29, so the current week runs Sat 2026-09-26 .. Fri
// 2026-10-02. A date inside vs before the week separates "this week".
// ---------------------------------------------------------------------------

final today = DateTime(2026, 9, 29);
const satStart = DateTime.saturday;
// The program-progress + muscle groups below use a Mon–Sun fixture week:
// Monday-start weeks stay a valid configuration (week_start.dart).
const monStart = DateTime.monday;
final inWeek = DateTime(2026, 9, 28); // Mon, this accounting week
final lastWeek = DateTime(2026, 9, 24); // Thu, previous week

GradedSet hard(String lift, DateTime date, {double rpe = 8.5}) => GradedSet(
      date: date,
      lift: lift,
      weight: 200,
      reps: 5,
      e1rm: 233,
      reference: 240,
      effort: 0.9,
      pctMax: 0.83,
      tier: SetTier.hard,
      working: true,
      nearMax: false,
      longFailureSet: false,
      rpe: rpe,
    );

Map<DateTime, double> byDay(List<(DateTime, double)> xs) => {
      for (final x in xs) DateTime(x.$1.year, x.$1.month, x.$1.day): x.$2,
    };

void main() {
  group('parseGoals', () {
    test('returns null on missing / malformed yaml', () {
      expect(parseGoals(null), isNull);
      expect(parseGoals(''), isNull);
      expect(parseGoals('not: a phases map'), isNull);
    });

    test('parses a cut goal set with all fields', () {
      const yaml = '''
phases:
  cut:
    goals:
      - id: macros
        label: Fuel
        protein_g_per_lb: [0.8, 1.0]
        carbs_floor_g_day: 150
      - id: calorie_band
        calorie_mode: deficit
      - id: hard_sets
        lifts: [squat, bench, deadlift, press]
        hard_set_target: 10
        hard_rpe_min: 7
        accessories:
          squat: [Bulgarian Split Squat]
          bench: [Triceps Extension, Lateral Dumbbell Raise]
      - id: climbing
        target: 2
      - id: cardio_4x4
        target: 1
''';
      final byPhase = parseGoals(yaml)!;
      final cut = byPhase['cut']!;
      expect(cut.map((g) => g.id), [
        'macros',
        'calorie_band',
        'hard_sets',
        'climbing',
        'cardio_4x4',
      ]);
      expect(cut[0].label, 'Fuel');
      expect(cut[0].proteinGPerLb, [0.8, 1.0]);
      expect(cut[0].carbsFloorGDay, 150);
      expect(cut[1].calorieMode, 'deficit');
      expect(cut[2].hardSetTarget, 10);
      expect(cut[2].hardRpeMin, 7);
      expect(cut[2].accessories['squat'], ['Bulgarian Split Squat']);
      expect(cut[2].accessories['bench'],
          ['Triceps Extension', 'Lateral Dumbbell Raise']);
      expect(cut[3].target, 2);
    });

    test('skips entries with no id, never fatal', () {
      const yaml = '''
phases:
  cut:
    goals:
      - {}
      - id: climbing
        target: 2
''';
      final cut = parseGoals(yaml)!['cut']!;
      expect(cut.length, 1);
      expect(cut.single.id, 'climbing');
    });
  });

  group('macros', () {
    const cfg = GoalConfig(
      id: 'macros',
      proteinGPerLb: [0.8, 1.0],
      carbsFloorGDay: 150,
    );

    test('protein at/above floor + carbs enough → met', () {
      final r = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(
          bodyweightLb: 160,
          proteinByDay: byDay([(inWeek, 150)]), // 0.94 g/lb
          carbsByDay: byDay([(inWeek, 200)]),
        ),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.met);
      expect(r.value, contains('0.94'));
    });

    test('protein short → unmet', () {
      final r = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(
          bodyweightLb: 160,
          proteinByDay: byDay([(inWeek, 100)]), // 0.63 g/lb
          carbsByDay: byDay([(inWeek, 200)]),
        ),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.unmet);
    });

    test('protein ok but carbs short → partial', () {
      final r = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(
          bodyweightLb: 160,
          proteinByDay: byDay([(inWeek, 150)]),
          carbsByDay: byDay([(inWeek, 100)]), // < 150 floor
        ),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.partial);
      expect(r.detail, contains('aim'));
    });

    test('no meal data → unknown', () {
      final r = evaluateGoals(
        configs: [cfg],
        inputs: const GoalInputs(bodyweightLb: 160),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.unknown);
    });

    test('absolute protein band (recomp) uses grams not g/lb', () {
      const abs = GoalConfig(id: 'macros', proteinGDay: [160, 175]);
      final r = evaluateGoals(
        configs: [abs],
        inputs: GoalInputs(proteinByDay: byDay([(inWeek, 165)])),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.met);
      expect(r.value, contains('165 g'));
    });

    test('only this-week days count', () {
      final r = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(
          bodyweightLb: 160,
          proteinByDay: byDay([(lastWeek, 300)]), // outside the week
        ),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.unknown);
    });
  });

  group('calorie_band', () {
    const deficit = GoalConfig(id: 'calorie_band', calorieMode: 'deficit');
    const surplus =
        GoalConfig(id: 'calorie_band', calorieMode: 'surplus', bandKcal: 200);

    test('cut: below maintenance → met (in a deficit)', () {
      final r = evaluateGoals(
        configs: [deficit],
        inputs: const GoalInputs(intakeKcal7d: 1900, maintenanceKcal: 2200),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.met);
      expect(r.value, contains('deficit'));
    });

    test('cut: over maintenance → unmet', () {
      final r = evaluateGoals(
        configs: [deficit],
        inputs: const GoalInputs(intakeKcal7d: 2400, maintenanceKcal: 2200),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.unmet);
    });

    test('bulk: within maintenance..+band → met', () {
      final r = evaluateGoals(
        configs: [surplus],
        inputs: const GoalInputs(intakeKcal7d: 2350, maintenanceKcal: 2200),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.met);
    });

    test('bulk: under maintenance → partial', () {
      final r = evaluateGoals(
        configs: [surplus],
        inputs: const GoalInputs(intakeKcal7d: 2000, maintenanceKcal: 2200),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.partial);
    });

    test('bulk: over the band → unmet', () {
      final r = evaluateGoals(
        configs: [surplus],
        inputs: const GoalInputs(intakeKcal7d: 2600, maintenanceKcal: 2200),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.unmet);
    });

    test('no estimate → unknown', () {
      final r = evaluateGoals(
        configs: [deficit],
        inputs: const GoalInputs(intakeKcal7d: 1900),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.unknown);
    });
  });

  group('hard_sets', () {
    const cfg = GoalConfig(
      id: 'hard_sets',
      lifts: ['squat', 'bench', 'deadlift', 'press'],
      hardSetTarget: 10,
      hardRpeMin: 7,
      accessories: {
        'squat': ['Bulgarian Split Squat'],
      },
    );

    test('counts sets at RPE >= 7 this week per lift', () {
      final sets = <GradedSet>[
        // squat: 8 at RPE 7 (boundary counts) + 2 at RPE 9 = 10 hard sets.
        for (var i = 0; i < 8; i++) hard('squat', inWeek, rpe: 7),
        for (var i = 0; i < 2; i++) hard('squat', inWeek, rpe: 9),
        hard('squat', inWeek, rpe: 6.5), // below the floor — excluded
        for (var i = 0; i < 5; i++) hard('bench', inWeek, rpe: 8),
        hard('deadlift', lastWeek, rpe: 8.5), // last week
      ];
      final r = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(graded: sets),
        today: today,
        weekStartDay: satStart,
      ).single;
      final squat = r.ticks.firstWhere((t) => t.lift == 'squat');
      final bench = r.ticks.firstWhere((t) => t.lift == 'bench');
      final dead = r.ticks.firstWhere((t) => t.lift == 'deadlift');
      expect(squat.hardSets, 10);
      expect(bench.hardSets, 5);
      expect(dead.hardSets, 0);
      // 1 of 4 lifts at target → partial.
      expect(r.status, GoalStatus.partial);
      expect(r.value, contains('1/4'));
    });

    test('all lifts at target → met', () {
      final sets = <GradedSet>[
        for (final lift in ['squat', 'bench', 'deadlift', 'press'])
          for (var i = 0; i < 10; i++) hard(lift, inWeek),
      ];
      final r = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(graded: sets),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.met);
    });

    test('no hard sets → unmet', () {
      final r = evaluateGoals(
        configs: [cfg],
        inputs: const GoalInputs(graded: []),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.unmet);
    });

    test('accessory done when every declared accessory logged this week', () {
      final r = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(
          graded: [hard('squat', inWeek)],
          strengthRows: [(date: inWeek, exercise: 'Bulgarian Split Squat')],
        ),
        today: today,
        weekStartDay: satStart,
      ).single;
      final squat = r.ticks.firstWhere((t) => t.lift == 'squat');
      expect(squat.accessoriesDone, isTrue);
      final bench = r.ticks.firstWhere((t) => t.lift == 'bench');
      expect(bench.accessoriesDone, isNull); // none declared
    });

    test('accessory not done when the exercise is missing this week', () {
      final r = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(
          graded: [hard('squat', inWeek)],
          strengthRows: [(date: lastWeek, exercise: 'Bulgarian Split Squat')],
        ),
        today: today,
        weekStartDay: satStart,
      ).single;
      final squat = r.ticks.firstWhere((t) => t.lift == 'squat');
      expect(squat.accessoriesDone, isFalse);
    });
  });

  group('climbing + cardio', () {
    test('climbing 2/2 → met, 1/2 → partial, 0/2 → unmet', () {
      GoalEval eval(List<DateTime> dates) => evaluateGoals(
            configs: const [GoalConfig(id: 'climbing', target: 2)],
            inputs: GoalInputs(climbingDates: dates),
            today: today,
            weekStartDay: satStart,
          ).single;
      expect(eval([inWeek, DateTime(2026, 9, 27)]).status, GoalStatus.met);
      expect(eval([inWeek]).status, GoalStatus.partial);
      expect(eval([lastWeek]).status, GoalStatus.unmet);
    });

    test('two climbs on the same day collapse to one session', () {
      final r = evaluateGoals(
        configs: const [GoalConfig(id: 'climbing', target: 2)],
        inputs: GoalInputs(climbingDates: [inWeek, inWeek]),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.status, GoalStatus.partial);
    });

    test('I1: a Kaya export on D+1 folds into a Whoop climb on D — one '
        'session, not two', () {
      final whoopDay = inWeek; // Mon 2026-09-28
      final kayaDayPlus1 = inWeek.add(const Duration(days: 1)); // Tue 09-29
      final r = evaluateGoals(
        configs: const [GoalConfig(id: 'climbing', target: 2)],
        inputs: GoalInputs(
          climbingDates: [kayaDayPlus1],
          activities: [
            WhoopActivity(
              date: whoopDay,
              sport: 'rock-climbing',
              kind: ActivityKind.climb,
            ),
          ],
        ),
        today: today,
        weekStartDay: satStart,
      ).single;
      expect(r.value, '1/2 sessions');
      expect(r.status, GoalStatus.partial);
    });

    test('cardio 1/1 → met, 0/1 → unmet', () {
      GoalEval eval(List<DateTime> dates) => evaluateGoals(
            configs: const [GoalConfig(id: 'cardio_4x4', target: 1)],
            inputs: GoalInputs(cardioDates: dates),
            today: today,
            weekStartDay: satStart,
          ).single;
      expect(eval([inWeek]).status, GoalStatus.met);
      expect(eval([]).status, GoalStatus.unmet);
    });
  });

  test('unknown id is skipped, never throws', () {
    final r = evaluateGoals(
      configs: const [GoalConfig(id: 'made_up'), GoalConfig(id: 'climbing')],
      inputs: const GoalInputs(),
      today: today,
      weekStartDay: satStart,
    );
    expect(r.length, 1);
    expect(r.single.config.id, 'climbing');
  });

  group('whoop activity goals', () {
    // Tuesday 2026-09-29; Monday-start week = Sep 28 .. Oct 4.
    final today = DateTime(2026, 9, 29);
    WhoopActivity act(ActivityKind k, DateTime d,
            {double avg = 120, double dur = 40}) =>
        WhoopActivity(
            date: d, sport: k.name, kind: k, avgHr: avg, durationMin: dur);

    test('climbing counts Whoop ∪ Kaya days once', () {
      final evals = evaluateGoals(
        configs: [const GoalConfig(id: 'climbing', target: 2)],
        inputs: GoalInputs(
          climbingDates: [DateTime(2026, 9, 28)],
          activities: [
            act(ActivityKind.climb, DateTime(2026, 9, 28)), // same day
            act(ActivityKind.climb, DateTime(2026, 9, 29)),
          ],
        ),
        today: today,
      );
      expect(evals.single.value, '2/2 sessions');
      expect(evals.single.status, GoalStatus.met);
    });

    test('zone2_run met by an easy run', () {
      final evals = evaluateGoals(
        configs: [const GoalConfig(id: 'zone2_run', optional: true)],
        inputs: GoalInputs(
          maxHr: 200,
          activities: [act(ActivityKind.run, DateTime(2026, 9, 28))],
        ),
        today: today,
      );
      expect(evals.single.status, GoalStatus.met);
      expect(evals.single.value, '1/1 run');
    });

    test('optional unmet renders as optional, not unmet', () {
      final evals = evaluateGoals(
        configs: [const GoalConfig(id: 'zone2_run', optional: true)],
        inputs: GoalInputs(
          maxHr: 200,
          activities: [
            act(ActivityKind.run, DateTime(2026, 9, 28), avg: 170), // hard
          ],
        ),
        today: today,
      );
      expect(evals.single.status, GoalStatus.optional);
      expect(evals.single.detail, 'nice to have');
    });

    test('no max HR → unknown with a hint', () {
      final evals = evaluateGoals(
        configs: [const GoalConfig(id: 'zone2_run')],
        inputs: const GoalInputs(),
        today: today,
      );
      expect(evals.single.status, GoalStatus.unknown);
      expect(evals.single.value, 'set max HR');
    });

    test('parseGoals reads optional + zone-2 keys', () {
      final g = parseGoals('''
phases:
  cut:
    goals:
      - id: zone2_run
        optional: true
        target: 1
        min_minutes: 25
        max_avg_hr_pct: 0.7
''')!['cut']!.single;
      expect(g.optional, isTrue);
      expect(g.minMinutes, 25);
      expect(g.maxAvgHrPct, 0.7);
    });
  });

  group('hard_sets per-lift targets + routine schedule', () {
    test('parses hard_set_targets map alongside the scalar default', () {
      const yaml = '''
phases:
  cut:
    goals:
      - id: hard_sets
        hard_set_target: 10
        hard_set_targets: {deadlift: 3, bogus: x}
''';
      final g = parseGoals(yaml)!['cut']!.single;
      expect(g.hardSetTarget, 10);
      expect(g.hardSetTargetByLift, {'deadlift': 3});
    });

    test('per-lift target overrides the default; value says "at target"',
        () {
      const cfg = GoalConfig(
        id: 'hard_sets',
        lifts: ['bench', 'deadlift'],
        hardSetTarget: 10,
        hardSetTargetByLift: {'deadlift': 3},
      );
      final r = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(graded: [
          for (var i = 0; i < 3; i++) hard('deadlift', inWeek, rpe: 8),
        ]),
        today: today,
        weekStartDay: satStart,
      ).single;
      final dead = r.ticks.firstWhere((t) => t.lift == 'deadlift');
      final bench = r.ticks.firstWhere((t) => t.lift == 'bench');
      expect(dead.target, 3);
      expect(bench.target, 10);
      expect(r.value, '1/2 lifts at target');
    });

    test('mainLiftWeekdays reads planned main lifts per weekday', () {
      final week = <Object?, Object?>{
        'mon': {
          'planned': [
            {'exercise': 'Barbell Squat'},
            {'exercise': 'Flat Barbell Bench Press'},
            {'exercise': 'Bulgarian Split Squat'},
          ],
        },
        'tue': {'morning': 'climb', 'planned': null},
        'fri': {
          'planned': [
            {'exercise': 'Barbell Deadlift'},
            {'exercise': 'Romanian Deadlift'},
          ],
        },
        'sat': {
          'planned': {
            'A': [
              {'exercise': 'Overhead Press'},
            ],
          },
        },
      };
      expect(mainLiftWeekdays(week), {
        'squat': {DateTime.monday},
        'bench': {DateTime.monday},
        'deadlift': {DateTime.friday},
        'press': {DateTime.saturday},
      });
      expect(mainLiftWeekdays(null), isEmpty);
    });

    // The reported "greyed deadlift": deadlift is Friday-only and Friday
    // is the LAST day of the Sat–Fri accounting week, so on any earlier
    // day it has 0 hard sets — pending (due Fri), not missed.
    test('Friday-only deadlift is pending until Friday, then counted', () {
      const cfg = GoalConfig(
        id: 'hard_sets',
        lifts: ['squat', 'deadlift'],
        hardSetTarget: 10,
        hardSetTargetByLift: {'deadlift': 3},
      );
      const liftDays = {
        'squat': {DateTime.monday, DateTime.wednesday},
        'deadlift': {DateTime.friday},
      };
      // Tue 2026-09-29: squat Mon passed, Wed ahead; deadlift Fri ahead.
      final tue = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(
          graded: [hard('squat', inWeek)],
          liftDays: liftDays,
        ),
        today: today,
        weekStartDay: satStart,
      ).single;
      final squatTue = tue.ticks.firstWhere((t) => t.lift == 'squat');
      final deadTue = tue.ticks.firstWhere((t) => t.lift == 'deadlift');
      expect(squatTue.scheduledDays, [DateTime.monday, DateTime.wednesday]);
      expect(squatTue.remainingDays, [DateTime.wednesday]);
      expect(squatTue.pending, isFalse); // has sets
      expect(deadTue.hardSets, 0);
      expect(deadTue.remainingDays, [DateTime.friday]);
      expect(deadTue.pending, isTrue);

      // Fri 2026-10-02 after the session: 3 hard sets, target met.
      final fri = DateTime(2026, 10, 2);
      final friEval = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(
          graded: [for (var i = 0; i < 3; i++) hard('deadlift', fri)],
          liftDays: liftDays,
        ),
        today: fri,
        weekStartDay: satStart,
      ).single;
      final deadFri = friEval.ticks.firstWhere((t) => t.lift == 'deadlift');
      expect(deadFri.hardSets, 3);
      expect(deadFri.pending, isFalse);
      expect(deadFri.hardSets >= deadFri.target, isTrue);

      // Next Sat (new week): Fri is 6 days ahead again → pending.
      final sat = evaluateGoals(
        configs: [cfg],
        inputs: const GoalInputs(liftDays: liftDays),
        today: DateTime(2026, 10, 3),
        weekStartDay: satStart,
      ).single;
      expect(
          sat.ticks.firstWhere((t) => t.lift == 'deadlift').pending, isTrue);
    });

    test('no routine → no schedule, never pending', () {
      const cfg = GoalConfig(id: 'hard_sets', lifts: ['deadlift']);
      final t = evaluateGoals(
        configs: [cfg],
        inputs: const GoalInputs(),
        today: today,
        weekStartDay: satStart,
      ).single.ticks.single;
      expect(t.scheduledDays, isEmpty);
      expect(t.pending, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // ONE window (2026-10-03 week-start setting): with a Saturday start the
  // program sets, muscle stimulus and climbing all count Sat..Fri.
  // -------------------------------------------------------------------------
  group('configured Saturday week — every goal agrees on the window', () {
    // Week Sat 10/3 – Fri 10/9; today Tue 10/6.
    DateTime d(int i) => DateTime(2026, 10, 3 + i);
    final tue = d(3);
    PrescribedItem pi(String name, int sets) =>
        PrescribedItem(name: name, scheme: '', period: 'AM', targetSets: sets);
    final week = effectiveWeek({
      d(0): [pi('OHP heavy', 1)], // Sat
      d(1): const [], // Sun
      d(2): [pi('Squat heavy', 1)], // Mon
      d(3): const [],
      d(4): [pi('Bench heavy', 1)],
      d(5): const [],
      d(6): [pi('Deadlift heavy', 1)],
    }, const {});
    const map = MuscleMap(
      exercises: {'Overhead Press': {'shoulders': 1.0}},
      climbingSession: {'back': 3.0},
    );
    final rows = [
      (date: DateTime(2026, 10, 2), exercise: 'Overhead Press'), // Fri before
      (date: d(0), exercise: 'Overhead Press'), // Sat — this week
    ];
    final goals = evaluateGoals(
      configs: const [
        GoalConfig(id: 'hard_sets', lifts: ['press', 'squat']),
        GoalConfig(id: 'muscle_stimulus'),
        GoalConfig(id: 'climbing', target: 2),
      ],
      inputs: GoalInputs(
        programWeek: week,
        weekWorkingSets: rows,
        muscleMap: map,
        muscleGroups: const ['shoulders', 'back'],
        climbingDates: [DateTime(2026, 10, 2), d(0), d(1)],
      ),
      today: tue,
      weekStartDay: satStart,
    );
    GoalEval byId(String id) => goals.firstWhere((g) => g.config.id == id);

    test('Saturday\'s work counts for the week it STARTS (program sets)', () {
      final press = byId('hard_sets').ticks.firstWhere((t) => t.lift == 'press');
      expect(press.done, 1);
      expect(press.complete, isTrue);
      expect(byId('hard_sets').detail, contains('Sat–Fri program week'));
    });

    test('muscle stimulus + climbing count the same Sat..Fri window', () {
      final shoulders =
          byId('muscle_stimulus').muscles.firstWhere((m) => m.group == 'shoulders');
      expect(shoulders.sets, 1); // Fri 10/2 is LAST week
      final back =
          byId('muscle_stimulus').muscles.firstWhere((m) => m.group == 'back');
      expect(back.sets, 2 * 3.0); // Sat + Sun climbs; Fri 10/2 excluded
      expect(byId('climbing').value, startsWith('2/2'));
      expect(byId('muscle_stimulus').detail, contains('Sat–Fri'));
    });
  });

  // -------------------------------------------------------------------------
  // Program progress (hard_sets with a program week) — Mon–Sun week.
  // Week of Mon 2026-09-28; the cut routine's main-lift slots.
  // -------------------------------------------------------------------------
  group('hard_sets — program progress', () {
    DateTime d(int i) => DateTime(2026, 9, 28 + i);
    PrescribedItem pi(String name, int sets) =>
        PrescribedItem(name: name, scheme: '', period: 'AM', targetSets: sets);
    Map<DateTime, List<EffectiveItem>> week() => effectiveWeek({
          d(0): [
            pi('Squat heavy', 1),
            pi('Bulgarian split squat', 3),
            pi('Bench volume', 4),
          ],
          d(1): const [],
          d(2): [
            pi('Bench heavy', 1),
            pi('Bench back-offs', 3),
            pi('Squat volume', 3),
            pi('OHP volume', 3),
          ],
          d(3): const [],
          d(4): [
            pi('Deadlift heavy', 1),
            pi('Deadlift back-offs', 2),
            pi('Bench volume', 3),
          ],
          d(5): [pi('OHP heavy', 1), pi('OHP back-offs', 3)],
          d(6): const [],
        }, const {});
    List<({DateTime date, String exercise})> sets(
            DateTime day, String ex, int n) =>
        [for (var i = 0; i < n; i++) (date: day, exercise: ex)];
    const cfg = GoalConfig(
      id: 'hard_sets',
      lifts: ['squat', 'bench', 'deadlift', 'press'],
      hardSetTarget: 10,
    );
    GoalEval eval(
      DateTime today,
      List<({DateTime date, String exercise})> rows, {
      GoalConfig config = cfg,
      Set<String> skips = const {},
      List<GradedSet> graded = const [],
    }) =>
        evaluateGoals(
          configs: [config],
          inputs: GoalInputs(
            programWeek: week(),
            programSkips: skips,
            weekWorkingSets: rows,
            graded: graded,
          ),
          today: today,
          weekStartDay: monStart,
        ).single;
    GoalLiftTick tick(GoalEval e, String lift) =>
        e.ticks.firstWhere((t) => t.lift == lift);

    test('targets are derived from the program week, not the flat 10', () {
      final e = eval(d(0), const []);
      expect(tick(e, 'squat').target, 4);
      expect(tick(e, 'bench').target, 11);
      expect(tick(e, 'deadlift').target, 3);
      expect(tick(e, 'press').target, 7);
      expect(e.ticks.every((t) => t.fromProgram), isTrue);
      expect(e.value, '0 of 25 program sets · 0/4 lifts done');
      // Monday morning, nothing due yet → on schedule, never red.
      expect(e.status, GoalStatus.partial);
      expect(e.detail, contains('Mon–Sun'));
    });

    test('progress = allocated working sets, RPE-blind; Mon–Sun window', () {
      final rows = [
        // Saturday BEFORE this Mon–Sun week (same accounting week): ignored.
        ...sets(DateTime(2026, 9, 26), 'Barbell Squat', 5),
        ...sets(d(0), 'Barbell Squat', 1),
        ...sets(d(0), 'Flat Barbell Bench Press', 4),
        ...sets(d(0), 'Bulgarian Split Squat', 3), // accessory, not squat
      ];
      final e = eval(d(1), rows);
      expect(tick(e, 'squat').done, 1);
      expect(tick(e, 'bench').done, 4);
      expect(tick(e, 'squat').remainingDays, [DateTime.wednesday]);
      expect(tick(e, 'deadlift').remainingDays, [DateTime.friday]);
      expect(tick(e, 'deadlift').pending, isTrue);
      expect(tick(e, 'bench').dueAhead, isTrue);
      expect(e.status, GoalStatus.partial);
      expect(e.detail, startsWith('on schedule'));
    });

    test("a past-due shortfall (the card's missed work) → unmet", () {
      final rows = sets(d(0), 'Barbell Squat', 1); // Mon bench not done
      final e = eval(d(1), rows);
      expect(tick(e, 'bench').behind, isTrue);
      expect(tick(e, 'squat').behind, isFalse);
      expect(e.status, GoalStatus.unmet);
      expect(e.detail, startsWith('behind on bench'));
    });

    test('a skip removes the item from the target and from "behind"', () {
      final e = eval(d(1), sets(d(0), 'Barbell Squat', 1),
          skips: {skipKey(d(0), 'Bench volume')});
      expect(tick(e, 'bench').target, 7);
      expect(tick(e, 'bench').behind, isFalse);
      expect(e.status, GoalStatus.partial);
    });

    test('everything logged → met', () {
      final rows = [
        ...sets(d(0), 'Barbell Squat', 1),
        ...sets(d(0), 'Flat Barbell Bench Press', 4),
        ...sets(d(2), 'Flat Barbell Bench Press', 4),
        ...sets(d(2), 'Barbell Squat', 3),
        ...sets(d(2), 'Overhead Press', 3),
        ...sets(d(4), 'Barbell Deadlift', 3),
        ...sets(d(4), 'Flat Barbell Bench Press', 3),
        ...sets(d(5), 'Overhead Press', 4),
      ];
      final e = eval(d(6), rows);
      expect(e.status, GoalStatus.met);
      expect(e.value, '25 of 25 program sets · 4/4 lifts done');
    });

    test('hard-set (RPE ≥ 7) count rides along as secondary info', () {
      final e = eval(d(1), sets(d(0), 'Barbell Squat', 1), graded: [
        hard('squat', d(0), rpe: 8),
        hard('squat', d(0), rpe: 6),
      ]);
      expect(tick(e, 'squat').hardSets, 1);
      expect(tick(e, 'squat').done, 1);
    });

    test('hard_set_targets is an override: typed target, all lift sets', () {
      const over = GoalConfig(
        id: 'hard_sets',
        lifts: ['squat'],
        hardSetTargetByLift: {'squat': 6},
      );
      final e = eval(
        d(2),
        [
          ...sets(d(0), 'Barbell Squat', 2),
          ...sets(d(2), 'Barbell Squat', 3),
        ],
        config: over,
      );
      final t = tick(e, 'squat');
      expect(t.target, 6);
      expect(t.fromProgram, isFalse);
      expect(t.done, 5); // uncapped: 2 Mon + 3 Wed
    });

    test('itemLifts mapping wins over the name fallback', () {
      final e = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(
          programWeek: effectiveWeek({
            d(0): [pi('Heavy day lift', 2)],
          }, const {}),
          itemLifts: {itemLiftKey(d(0), 'Heavy day lift'): 'squat'},
          weekWorkingSets: sets(d(0), 'Heavy day lift', 2),
        ),
        today: d(0),
      ).single;
      expect(tick(e, 'squat').target, 2);
      expect(tick(e, 'squat').done, 2);
    });

    test('no program week → legacy hard-set mode unchanged', () {
      final e = evaluateGoals(
        configs: [cfg],
        inputs: GoalInputs(graded: [hard('squat', inWeek)]),
        today: today,
        weekStartDay: monStart,
      ).single;
      expect(tick(e, 'squat').target, 10);
      expect(tick(e, 'squat').done, 1);
    });
  });

  // -------------------------------------------------------------------------
  // muscle_stimulus
  // -------------------------------------------------------------------------
  group('muscle_stimulus', () {
    DateTime d(int i) => DateTime(2026, 9, 28 + i);
    const map = MuscleMap(
      exercises: {
        'Barbell Squat': {'quads': 1.0},
        'Pull Up': {'back': 1.0, 'biceps': 0.5},
        'Flat Barbell Bench Press': {'chest': 1.0},
      },
      climbingSession: {'back': 3.0, 'biceps': 1.5},
    );
    List<({DateTime date, String exercise})> sets(
            DateTime day, String ex, int n) =>
        [for (var i = 0; i < n; i++) (date: day, exercise: ex)];
    GoalEval eval(
      DateTime today,
      List<({DateTime date, String exercise})> rows, {
      GoalConfig config = const GoalConfig(id: 'muscle_stimulus'),
      List<DateTime> climbs = const [],
      MuscleMap? m = map,
    }) =>
        evaluateGoals(
          configs: [config],
          inputs: GoalInputs(
            muscleMap: m,
            muscleGroups: const ['quads', 'back', 'chest'],
            weekWorkingSets: rows,
            climbingDates: climbs,
          ),
          today: today,
          weekStartDay: monStart,
        ).single;

    test('parses band + muscle_groups', () {
      final g = parseGoals('phases:\n'
          '  cut:\n'
          '    goals:\n'
          '      - id: muscle_stimulus\n'
          '        band: [8, 12]\n'
          '        muscle_groups: [quads, back]\n')!['cut']!.single;
      expect(g.band, [8.0, 12.0]);
      expect(g.muscleGroups, ['quads', 'back']);
    });

    test('counts Mon–Sun working sets + climbing sessions per group', () {
      final e = eval(
        d(3),
        [
          ...sets(DateTime(2026, 9, 27), 'Barbell Squat', 9), // last Sun
          ...sets(d(0), 'Barbell Squat', 8),
          ...sets(d(2), 'Pull Up', 3),
        ],
        climbs: [d(1), d(1), d(3)],
      );
      final rows = {for (final r in e.muscles) r.group: r};
      expect(rows['quads']!.sets, 8);
      expect(rows['back']!.sets, 3 + 2 * 3.0);
      expect(rows['back']!.contributors.first.key, climbingLabel);
      expect(rows['chest']!.sets, 0);
      expect(e.value, '2 of 3 groups in 8–12');
      // Thu: pace = 8 × 4/7 ≈ 4.6 → chest (0) behind pace; under is
      // amber, never red.
      expect(rows['chest']!.behindPace, isTrue);
      expect(e.status, GoalStatus.partial);
      expect(e.detail, contains('1 behind pace'));
    });

    test('a group over the band is flagged, but the row is never red', () {
      final e = eval(d(4), [
        ...sets(d(0), 'Barbell Squat', 13),
        ...sets(d(0), 'Pull Up', 8),
        ...sets(d(0), 'Flat Barbell Bench Press', 8),
      ]);
      expect(e.muscles.first.state, 'over');
      expect(e.status, GoalStatus.partial);
      expect(e.detail, contains('1 over the range'));
    });

    test('all in band → met; configurable band', () {
      final e = eval(
        d(6),
        [
          ...sets(d(0), 'Barbell Squat', 6),
          ...sets(d(0), 'Pull Up', 6),
          ...sets(d(0), 'Flat Barbell Bench Press', 6),
        ],
        config: const GoalConfig(id: 'muscle_stimulus', band: [6, 10]),
      );
      expect(e.status, GoalStatus.met);
      expect(e.value, '3 of 3 groups in 6–10');
    });

    test('no muscle map → unknown, never throws', () {
      final e = eval(d(0), const [], m: null);
      expect(e.status, GoalStatus.unknown);
    });

    test('muscleDisplayName spells groups out, sentence case', () {
      expect(muscleDisplayName('hamstrings_glutes'), 'Hamstrings and glutes');
      expect(muscleDisplayName('lats'), 'Lats');
      expect(muscleDisplayName('upper_back'), 'Upper back');
      expect(muscleDisplayName('lower_back'), 'Lower back');
      expect(muscleDisplayName('side_delts'), 'Side delts');
      expect(muscleDisplayName('rear_delts'), 'Rear delts');
      expect(muscleDisplayName('front_delts'), 'Front delts');
    });

    test('v16 tracked_groups: counted + listed, never banded or judged', () {
      const m16 = MuscleMap(
        exercises: {
          'Barbell Deadlift': {'hamstrings_glutes': 1.0, 'lower_back': 1.0},
          'Pull Up': {'lats': 1.0, 'biceps': 0.25},
          'Calf Raise': {'calves': 1.0},
        },
        climbingSession: {'lats': 1.5, 'forearms': 2.0},
      );
      final e = evaluateGoals(
        configs: const [GoalConfig(id: 'muscle_stimulus')],
        inputs: GoalInputs(
          muscleMap: m16,
          muscleGroups: const ['hamstrings_glutes', 'lats'],
          trackedGroups: const ['lower_back', 'forearms', 'core'],
          weekWorkingSets: [
            ...sets(d(0), 'Barbell Deadlift', 14),
            ...sets(d(1), 'Pull Up', 8),
            ...sets(d(1), 'Calf Raise', 5),
          ],
          climbingDates: [d(2)],
        ),
        today: d(6),
        weekStartDay: monStart,
      ).single;
      // Banded rows only decide status: hams 14 (over), lats 9.5.
      expect(
        [for (final r in e.muscles) r.group],
        ['hamstrings_glutes', 'lats'],
      );
      expect(e.value, '1 of 2 groups in 8–12');
      final tracked = {for (final r in e.trackedMuscles) r.group: r};
      expect(tracked.keys, ['lower_back', 'forearms', 'core']);
      expect(tracked['lower_back']!.sets, 14);
      expect(tracked['forearms']!.sets, 2);
      expect(tracked['core']!.sets, 0);
      // 14 > 12 but tracked: never over / under / behind pace.
      expect(tracked['lower_back']!.over, isFalse);
      expect(tracked['core']!.under, isFalse);
      expect(tracked['core']!.behindPace, isFalse);
      expect(tracked['lower_back']!.state, 'tracked');
      expect(e.detail, contains('1 over the range')); // hams only
    });

    test('parses tracked_groups', () {
      final g = parseGoals('phases:\n'
          '  cut:\n'
          '    goals:\n'
          '      - id: muscle_stimulus\n'
          '        tracked_groups: [core]\n')!['cut']!.single;
      expect(g.trackedGroups, ['core']);
    });
  });

  test('real dashboards.yaml: cut + recomp declare program sets + muscles',
      () {
    final file = File('../airledger-fitness/app/dashboards.yaml');
    if (!file.existsSync()) {
      markTestSkipped('no airledger-fitness checkout');
      return;
    }
    final byPhase = parseGoals(file.readAsStringSync())!;
    for (final phase in ['cut', 'recomp']) {
      final goals = {for (final g in byPhase[phase]!) g.id: g};
      expect(goals['hard_sets']!.label, 'Program sets per lift');
      // Derived from the program now — no typed per-lift override.
      expect(goals['hard_sets']!.hardSetTargetByLift, isEmpty);
      expect(goals['muscle_stimulus']!.band, [8.0, 12.0]);
    }
  });
}
