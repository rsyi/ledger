import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/day_synthesis.dart';
import 'package:airledger/services/whoop_activity.dart';

void main() {
  DaySynthesisContext ctx({
    int hour = 15,
    String phase = 'cut',
    SynthProgramDay? program,
    SynthLogged? logged,
    SynthTargets? targets,
    SynthRecovery? recovery,
  }) =>
      DaySynthesisContext(
        hour: hour,
        phase: phase,
        program: program ?? const SynthProgramDay(),
        logged: logged ?? const SynthLogged(),
        targets: targets ?? const SynthTargets(),
        recovery: recovery ?? const SynthRecovery(),
      );

  group('derived tallies', () {
    test('macro sums skip nulls', () {
      final c = ctx(
        logged: const SynthLogged(meals: [
          SynthMeal(calories: 600, proteinG: 40, carbsG: 50),
          SynthMeal(calories: 400, proteinG: 30, carbsG: 20, fatG: 15),
        ]),
      );
      expect(c.proteinSoFar, 70);
      expect(c.carbsSoFar, 70);
      expect(c.fatSoFar, 15);
      expect(c.kcalSoFar, 1000);
    });

    test('lifts done/planned/remaining are distinct and lower-cased', () {
      final c = ctx(
        program: const SynthProgramDay(plannedLifts: ['Squat', 'Bench', 'Row']),
        logged: const SynthLogged(sets: [
          SynthSet(exercise: 'Squat'),
          SynthSet(exercise: 'squat'),
        ]),
      );
      expect(c.liftsDone, ['squat']);
      expect(c.liftsPlanned, ['squat', 'bench', 'row']);
      expect(c.liftsRemaining, ['bench', 'row']);
    });

    test('climbToCome true when scheduled and none logged', () {
      final c = ctx(
        program: const SynthProgramDay(climbCall: 'hard session'),
        logged: const SynthLogged(climbCount: 0),
      );
      expect(c.climbToCome, isTrue);
    });

    test('climbToCome false once climbing is logged', () {
      final c = ctx(
        program: const SynthProgramDay(climbCall: 'hard session'),
        logged: const SynthLogged(climbCount: 3),
      );
      expect(c.climbToCome, isFalse);
    });

    test('cardioToCome tracks the 4x4', () {
      expect(
        ctx(program: const SynthProgramDay(wants4x4: true)).cardioToCome,
        isTrue,
      );
      expect(
        ctx(
          program: const SynthProgramDay(wants4x4: true),
          logged: const SynthLogged(did4x4: true),
        ).cardioToCome,
        isFalse,
      );
    });
  });

  group('buildDaySynthesisPrompt', () {
    test('the climb-still-to-come case never reads as a rest day', () {
      // User's example: 3pm, 4x4 done this morning, hard climb still to
      // come. The prompt must carry the climb as outstanding.
      final c = ctx(
        hour: 15,
        program: const SynthProgramDay(
          morning: 'AM 4x4 intervals',
          afternoon: 'PM hard climbing session',
          wants4x4: true,
          climbCall: 'hard session',
        ),
        logged: const SynthLogged(
          did4x4: true,
          meals: [SynthMeal(calories: 600, proteinG: 40, carbsG: 45)],
        ),
        targets: const SynthTargets(
          proteinGDay: [140, 160],
          carbsGDay: [225, 300],
        ),
      );
      final p = buildDaySynthesisPrompt(c);
      expect(p, contains('climbing (hard session)'));
      expect(p, contains('STILL TO COME'));
      expect(p, contains('4x4: done'));
      expect(p, isNot(contains('rest day')));
      // Protein floor is 140, ate 40 → 100 remaining surfaced.
      expect(p, contains('100g more protein to the floor'));
    });

    test('true rest day is labelled a rest day', () {
      final p = buildDaySynthesisPrompt(ctx(program: const SynthProgramDay()));
      expect(p, contains('rest day'));
    });

    test('protein target absent → no target, no floor nudge', () {
      final c = ctx(
        logged: const SynthLogged(meals: [SynthMeal(proteinG: 20)]),
        targets: const SynthTargets(),
      );
      final p = buildDaySynthesisPrompt(c);
      expect(p, contains('protein floor: no target'));
      expect(p, isNot(contains('more protein to the floor')));
    });

    test('no meals logged reads honestly', () {
      final p = buildDaySynthesisPrompt(ctx());
      expect(p, contains('food: nothing logged yet'));
    });

    test('time renders 12-hour with am/pm', () {
      expect(buildDaySynthesisPrompt(ctx(hour: 15)), contains('3pm'));
      expect(buildDaySynthesisPrompt(ctx(hour: 9)), contains('9am'));
      expect(buildDaySynthesisPrompt(ctx(hour: 0)), contains('12am'));
    });
  });

  // The cut-phase bug: the slice exposes protein_g_per_lb (relative) + no
  // absolute carb target, so the old absolute-only read fell through to
  // "no macro targets set". These pin the resolution + honest fallbacks.
  group('cut per-lb protein resolution', () {
    test('per-lb band × bodyweight → absolute g/day band', () {
      // 0.8–1.0 g/lb at 162 lb → 130–162 g.
      const t = SynthTargets(
        proteinGPerLb: [0.8, 1.0],
        bodyweightLb: 162,
      );
      expect(t.resolvedProteinBand, [162 * 0.8, 162 * 1.0]);
      expect(t.resolvedProteinBand![0].round(), 130);
      expect(t.resolvedProteinBand![1].round(), 162);
    });

    test('absolute band wins over the per-lb band when both present', () {
      const t = SynthTargets(
        proteinGDay: [160, 175],
        proteinGPerLb: [0.8, 1.0],
        bodyweightLb: 162,
      );
      expect(t.resolvedProteinBand, [160, 175]);
    });

    test('missing bodyweight → no resolved band, but per-lb text stands in',
        () {
      const t = SynthTargets(proteinGPerLb: [0.8, 1.0]);
      expect(t.resolvedProteinBand, isNull);
      expect(t.proteinPerLbText, '0.8–1.0 g/lb');
    });

    test('prompt shows the resolved cut protein band, not "no target"', () {
      final c = ctx(
        targets: const SynthTargets(
          proteinGPerLb: [0.8, 1.0],
          bodyweightLb: 162,
        ),
        logged: const SynthLogged(meals: [SynthMeal(proteinG: 40)]),
      );
      final p = buildDaySynthesisPrompt(c);
      expect(p, contains('protein floor: 130–162g'));
      expect(p, isNot(contains('protein floor: no target')));
      // Floor is 130 (0.8×162), ate 40 → 90 remaining surfaced.
      expect(p, contains('90g more protein to the floor'));
    });

    test('prompt falls back to per-lb text when bodyweight is unavailable',
        () {
      final c = ctx(
        targets: const SynthTargets(proteinGPerLb: [0.8, 1.0]),
        logged: const SynthLogged(meals: [SynthMeal(proteinG: 40)]),
      );
      final p = buildDaySynthesisPrompt(c);
      expect(p, contains('protein floor: 0.8–1.0 g/lb'));
      expect(p, isNot(contains('protein floor: no target')));
      // No absolute floor to compute a remaining gram count against.
      expect(p, isNot(contains('more protein to the floor')));
    });

    test('cut carbs read as a floor, not "no target"', () {
      final p = buildDaySynthesisPrompt(ctx(
        targets: const SynthTargets(
          proteinGPerLb: [0.8, 1.0],
          bodyweightLb: 162,
        ),
      ));
      expect(p, contains('carbs: no hard target on the cut'));
      expect(p, isNot(contains('carbs: no target')));
    });

    test('recomp absolute carb band still renders as an absolute band', () {
      final p = buildDaySynthesisPrompt(ctx(
        phase: 'recomp',
        targets: const SynthTargets(
          proteinGDay: [160, 175],
          carbsGDay: [225, 300],
        ),
      ));
      expect(p, contains('carbs: 225–300g'));
    });

    test('agrees with the GOALS surface on the cut target (162 lb, 0.8 g/lb)',
        () {
      // goals_service prices protein/lb × bw the same way (protein g/lb
      // band low = 0.8, bw = 162 → 130 g floor). The synthesis card must
      // cite the same floor so the two surfaces never disagree.
      const t = SynthTargets(proteinGPerLb: [0.8, 1.0], bodyweightLb: 162);
      final goalsFloor = (0.8 * 162).round(); // 130
      expect(t.resolvedProteinBand![0].round(), goalsFloor);
    });
  });

  group('recovery/sleep in the prompt', () {
    test('a good night renders sleep + recovery (green) + HRV + 7d avg', () {
      final p = buildDaySynthesisPrompt(ctx(
        recovery: const SynthRecovery(
          day: '2026-09-30',
          sleepHours: 7.4,
          recoveryScore: 80,
          hrvMs: 65,
          recoveryScore7dAvg: 74,
        ),
      ));
      expect(p, contains('RECOVERY (last night, from Whoop)'));
      expect(p, contains('slept 7.4h'));
      expect(p, contains('recovery 80 (green)'));
      expect(p, contains('HRV 65ms'));
      expect(p, contains('7d avg recovery 74'));
      // Advice framing is present so the model factors readiness.
      expect(p, contains('Factor readiness'));
    });

    test('low recovery is banded red/yellow', () {
      expect(
        buildDaySynthesisPrompt(
            ctx(recovery: const SynthRecovery(recoveryScore: 28))),
        contains('recovery 28 (red)'),
      );
      expect(
        buildDaySynthesisPrompt(
            ctx(recovery: const SynthRecovery(recoveryScore: 50))),
        contains('recovery 50 (yellow)'),
      );
    });

    test('no recovery data → the line is omitted entirely', () {
      final p = buildDaySynthesisPrompt(ctx());
      expect(p, isNot(contains('RECOVERY')));
      expect(p, isNot(contains('recovery ')));
    });

    test('partial recovery (sleep only) still renders what it has', () {
      final p = buildDaySynthesisPrompt(
          ctx(recovery: const SynthRecovery(sleepHours: 6)));
      expect(p, contains('RECOVERY'));
      expect(p, contains('slept 6h'));
      expect(p, isNot(contains('(green)')));
    });
  });

  group('Whoop activity in the prompt', () {
    test('prompt lists Whoop activity and counts a Whoop climb', () {
      final c = DaySynthesisContext(
        hour: 20,
        phase: 'cut',
        program: const SynthProgramDay(climbCall: 'LIGHT'),
        logged: const SynthLogged(),
        targets: const SynthTargets(),
        activities: [
          WhoopActivity(
            date: DateTime(2026, 10, 1),
            start: DateTime(2026, 10, 1, 14, 58),
            sport: 'rock-climbing',
            kind: ActivityKind.climb,
            strain: 14.8,
            durationMin: 86,
          ),
        ],
      );
      expect(c.climbToCome, isFalse);
      final p = buildDaySynthesisPrompt(c);
      expect(p, contains('ACTIVITY (Whoop'));
      expect(p, contains('rock-climbing 14:58 · strain 14.8 · 86 min'));
    });
  });
}
