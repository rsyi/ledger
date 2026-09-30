import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/day_synthesis.dart';

void main() {
  DaySynthesisContext ctx({
    int hour = 15,
    String phase = 'cut',
    SynthProgramDay? program,
    SynthLogged? logged,
    SynthTargets? targets,
  }) =>
      DaySynthesisContext(
        hour: hour,
        phase: phase,
        program: program ?? const SynthProgramDay(),
        logged: logged ?? const SynthLogged(),
        targets: targets ?? const SynthTargets(),
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
}
