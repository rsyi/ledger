import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_metrics.dart'
    show GradedSet, SetTier;
import 'package:airledger/services/goals_service.dart';
import 'package:airledger/services/whoop_activity.dart';

// ---------------------------------------------------------------------------
// Fixtures — Saturday accounting weeks (program week_start: saturday). Today
// is Tue 2026-09-29, so the current week runs Sat 2026-09-26 .. Fri
// 2026-10-02. A date inside vs before the week separates "this week".
// ---------------------------------------------------------------------------

final today = DateTime(2026, 9, 29);
const satStart = DateTime.saturday;
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
}
