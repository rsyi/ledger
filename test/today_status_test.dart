import 'package:airledger/services/today_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ------------------------------------------------------------------ food
  group('food line', () {
    test('protein + calories vs targets, on track partway through', () {
      final s = buildTodayStatus(
        meals: [
          const TodayMeal(calories: 600, proteinG: 50),
          const TodayMeal(calories: 640, proteinG: 45),
        ],
        loggedSets: const [],
        plannedSets: const [],
        targets: const TodayTargets(
          proteinGDay: [160, 175],
          carbsGDay: [225, 300],
          fatGDayMin: 55,
        ),
      );
      expect(s.foodText, 'Food: 95g protein of 160 · 1,240 kcal so far');
      // 95 of 160, day not over → on track (not behind on a partial day).
      expect(s.foodState, TodayState.onTrack);
    });

    test('behind on protein late in the day flags behind', () {
      final s = buildTodayStatus(
        meals: [const TodayMeal(calories: 1800, proteinG: 80)],
        loggedSets: const [],
        plannedSets: const [],
        targets: const TodayTargets(proteinGDay: [160, 175]),
        now: DateTime(2026, 9, 29, 21, 0), // 9pm — day nearly done
        today: DateTime(2026, 9, 29),
      );
      expect(s.foodText, contains('80g protein of 160'));
      expect(s.foodState, TodayState.behind);
    });

    test('protein target met reads done', () {
      final s = buildTodayStatus(
        meals: [const TodayMeal(calories: 2100, proteinG: 170)],
        loggedSets: const [],
        plannedSets: const [],
        targets: const TodayTargets(proteinGDay: [160, 175]),
      );
      expect(s.foodState, TodayState.done);
      expect(s.foodText, contains('170g protein of 160'));
    });

    test('no meals logged yet', () {
      final s = buildTodayStatus(
        meals: const [],
        loggedSets: const [],
        plannedSets: const [],
        targets: const TodayTargets(proteinGDay: [160, 175]),
      );
      expect(s.foodText, 'Food: nothing logged yet');
      expect(s.foodState, TodayState.none);
    });

    test('no protein target: still shows what was eaten', () {
      final s = buildTodayStatus(
        meals: [const TodayMeal(calories: 800, proteinG: 60)],
        loggedSets: const [],
        plannedSets: const [],
        targets: const TodayTargets(),
      );
      expect(s.foodText, 'Food: 60g protein · 800 kcal so far');
      expect(s.foodState, TodayState.onTrack);
    });

    test('thousands separator in kcal', () {
      final s = buildTodayStatus(
        meals: [const TodayMeal(calories: 12345, proteinG: 10)],
        loggedSets: const [],
        plannedSets: const [],
        targets: const TodayTargets(),
      );
      expect(s.foodText, contains('12,345 kcal'));
    });
  });

  // -------------------------------------------------------------- exercise
  group('exercise line', () {
    test('some planned sets done', () {
      final s = buildTodayStatus(
        meals: const [],
        loggedSets: [
          const TodaySet(exercise: 'Squat'),
          const TodaySet(exercise: 'Squat'),
        ],
        plannedSets: [
          const TodaySet(exercise: 'Squat'),
          const TodaySet(exercise: 'Squat'),
          const TodaySet(exercise: 'Squat'),
          const TodaySet(exercise: 'Leg Press'),
          const TodaySet(exercise: 'Leg Press'),
        ],
        targets: const TodayTargets(),
      );
      expect(s.exerciseText, 'Training: 2 of 5 planned sets done — squat');
      expect(s.exerciseState, TodayState.onTrack);
    });

    test('all planned sets done reads done', () {
      final s = buildTodayStatus(
        meals: const [],
        loggedSets: [
          const TodaySet(exercise: 'Bench Press'),
          const TodaySet(exercise: 'Bench Press'),
        ],
        plannedSets: [
          const TodaySet(exercise: 'Bench Press'),
          const TodaySet(exercise: 'Bench Press'),
        ],
        targets: const TodayTargets(),
      );
      expect(s.exerciseText, 'Training: 2 of 2 planned sets done — bench press');
      expect(s.exerciseState, TodayState.done);
    });

    test('planned but nothing logged yet', () {
      final s = buildTodayStatus(
        meals: const [],
        loggedSets: const [],
        plannedSets: [
          const TodaySet(exercise: 'Squat'),
          const TodaySet(exercise: 'Squat'),
        ],
        targets: const TodayTargets(),
      );
      expect(s.exerciseText, 'Training: nothing logged yet — 2 planned');
      expect(s.exerciseState, TodayState.none);
    });

    test('rest day (nothing planned, nothing logged)', () {
      final s = buildTodayStatus(
        meals: const [],
        loggedSets: const [],
        plannedSets: const [],
        targets: const TodayTargets(),
      );
      expect(s.exerciseText, 'Training: rest day');
      expect(s.exerciseState, TodayState.rest);
    });

    test('unplanned but logged: counts what was done', () {
      final s = buildTodayStatus(
        meals: const [],
        loggedSets: [
          const TodaySet(exercise: 'Deadlift'),
          const TodaySet(exercise: 'Deadlift'),
          const TodaySet(exercise: 'Row'),
        ],
        plannedSets: const [],
        targets: const TodayTargets(),
      );
      expect(s.exerciseText, 'Training: 3 sets logged — deadlift · row');
      expect(s.exerciseState, TodayState.done);
    });

    test('more logged than planned still reads done, exercises listed', () {
      final s = buildTodayStatus(
        meals: const [],
        loggedSets: [
          const TodaySet(exercise: 'Squat'),
          const TodaySet(exercise: 'Squat'),
          const TodaySet(exercise: 'Squat'),
        ],
        plannedSets: [const TodaySet(exercise: 'Squat')],
        targets: const TodayTargets(),
      );
      expect(s.exerciseText, 'Training: 3 of 1 planned sets done — squat');
      expect(s.exerciseState, TodayState.done);
    });

    test('exercise list caps at three names with an ellipsis', () {
      final s = buildTodayStatus(
        meals: const [],
        loggedSets: [
          const TodaySet(exercise: 'Squat'),
          const TodaySet(exercise: 'Bench'),
          const TodaySet(exercise: 'Deadlift'),
          const TodaySet(exercise: 'Row'),
        ],
        plannedSets: const [],
        targets: const TodayTargets(),
      );
      expect(s.exerciseText, 'Training: 4 sets logged — squat · bench · deadlift…');
    });
  });
}
