import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/day_achievement.dart';
import 'package:airledger/services/day_status.dart';
import 'package:airledger/services/day_synthesis.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/whoop_activity.dart';

void main() {
  DaySynthesisContext ctx({
    int hour = 15,
    String phase = 'cut',
    DayStatus? status,
    SynthLogged? logged,
    SynthTargets? targets,
    SynthRecovery? recovery,
    List<WhoopActivity> activities = const [],
  }) =>
      DaySynthesisContext(
        hour: hour,
        phase: phase,
        status: status,
        logged: logged ?? const SynthLogged(),
        targets: targets ?? const SynthTargets(),
        recovery: recovery ?? const SynthRecovery(),
        activities: activities,
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

  });

  group('buildDaySynthesisPrompt', () {
    test('protein floor shortfall surfaces under the targets', () {
      final p = buildDaySynthesisPrompt(ctx(
        logged: const SynthLogged(
            meals: [SynthMeal(calories: 600, proteinG: 40, carbsG: 45)]),
        targets: const SynthTargets(
          proteinGDay: [140, 160],
          carbsGDay: [225, 300],
        ),
      ));
      expect(p, contains('100g more protein to the floor'));
    });

    test('no program → status unavailable, no training commentary', () {
      final p = buildDaySynthesisPrompt(ctx());
      expect(p, contains('PROGRAM STATUS: unavailable'));
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

  group('PROGRAM STATUS drives training (2026-10-02 morning-climb bug)', () {
    // Live Fri 10/2: AM deadlift session + PM "Climb — LIGHT session";
    // the user climbed in the MORNING (Whoop rock-climbing 10:25). The
    // old prompt carried "TODAY'S PROGRAM: climbing (light session)",
    // the routine prose "PM: Climb — LIGHT session" and "climbing: not
    // logged" — the read told him to make sure the PM climb happens.
    final fri = DateTime(2026, 10, 2);
    PrescribedItem it(String n, String sc, String p, int sets) =>
        PrescribedItem(name: n, scheme: sc, period: p, targetSets: sets);
    final entries = [
      EffectiveItem(item: it('Deadlift heavy', 'top set', 'AM', 1), home: fri),
      EffectiveItem(
          item: it('Bench volume', '3x8-10 @ 65% TM.', 'AM', 3), home: fri),
      EffectiveItem(
          item: it('Climb — LIGHT session',
              '(technique/volume, movement quality; low fatigue).', 'PM', 1),
          home: fri),
    ];
    final climb = WhoopActivity(
      date: fri,
      start: DateTime(2026, 10, 2, 10, 25),
      sport: 'rock-climbing',
      kind: ActivityKind.climb,
      strain: 8.0,
      durationMin: 25,
    );
    AchievedSet set(String ex, double w, int r) =>
        AchievedSet(exercise: ex, weight: w, reps: r);
    DayStatus status({bool whoop = true, bool bench = false}) =>
        buildDayStatus(
          date: fri,
          entries: entries,
          logged: [
            set('Barbell Deadlift', 275, 6),
            if (bench)
              for (var i = 0; i < 3; i++) set('Flat Barbell Bench Press', 155, 8),
          ],
          whoop: whoop ? [climb] : const [],
        );

    test('Whoop morning climb → DONE; no pending-climb instruction anywhere',
        () {
      final c = ctx(hour: 15, status: status(), activities: [climb]);
      expect(c.climbToCome, isFalse);
      expect(c.climbPrescribed, isTrue);
      final p = buildDaySynthesisPrompt(c);
      expect(p, contains('- DONE Climb — LIGHT session — Whoop rock-climbing '
          '10:25, strain 8.0, 25 min (planned PM, done earlier — complete)'));
      expect(p, isNot(contains('PENDING Climb')));
      expect(p, isNot(contains('PM: Climb')));
      expect(p, isNot(contains('climbing (light')));
      expect(p, isNot(contains('climbing: not logged')));
      expect(p, isNot(contains('STILL TO COME')));
      expect(p, contains('TRAINING LEFT TODAY: Bench volume'));
      expect(p, contains('Only nudge items marked PENDING'));
      expect(p, contains('Never suggest repeating, or "making sure" of, an '
          'item marked DONE'));
      // Whoop sessions are context only, flagged as already reflected.
      expect(p, contains('already reflected in PROGRAM STATUS'));
    });

    test('everything done → the training day is complete', () {
      final p = buildDaySynthesisPrompt(
          ctx(status: status(bench: true), activities: [climb]));
      expect(p, contains("TRAINING LEFT TODAY: none — today's training is "
          'complete'));
      expect(p, isNot(contains('- PENDING')));
    });

    test('no Whoop climb → the climb is PENDING (still to come)', () {
      final c = ctx(status: status(whoop: false));
      expect(c.climbToCome, isTrue);
      final p = buildDaySynthesisPrompt(c);
      expect(p, contains('- PENDING Climb — LIGHT session — not done yet'));
    });

    test('tally: lifts hit / planned from the status', () {
      final c = ctx(status: status());
      expect(c.liftsPlanned, 2);
      expect(c.liftsHit, 1);
    });

    test('fingerprint changes when a Whoop climb appears', () {
      final before = ctx(status: status(whoop: false)).fingerprint;
      final after =
          ctx(status: status(), activities: [climb]).fingerprint;
      expect(after, isNot(before));
    });

    test('fingerprint changes on a logged set, a meal bucket and recovery; '
        'stable otherwise', () {
      final base = ctx(status: status());
      expect(ctx(status: status()).fingerprint, base.fingerprint);
      expect(ctx(status: status(bench: true)).fingerprint,
          isNot(base.fingerprint));
      expect(
          ctx(
            status: status(),
            logged: const SynthLogged(meals: [SynthMeal(proteinG: 40)]),
          ).fingerprint,
          isNot(base.fingerprint));
      expect(
          ctx(
            status: status(),
            recovery: const SynthRecovery(recoveryScore: 64),
          ).fingerprint,
          isNot(base.fingerprint));
      // Same hour bucket → same fingerprint; evening → new read.
      expect(ctx(hour: 16, status: status()).fingerprint, base.fingerprint);
      expect(ctx(hour: 19, status: status()).fingerprint,
          isNot(base.fingerprint));
    });
  });
}
