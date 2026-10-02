// muscle_volume.dart — the shared per-muscle weekly set counter.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/muscle_volume.dart';

const map = MuscleMap(
  exercises: {
    'Barbell Squat': {'quads': 1.0, 'hamstrings_glutes': 0.5, 'core': 0.25},
    'Flat Barbell Bench Press': {'chest': 1.0, 'triceps': 0.5},
    'Muscle Up': {'back': 0.75, 'biceps': 0.5},
    'Handstand Hold': {'shoulders': 0.25},
    'Handstand Push Up': {'shoulders': 1.0, 'triceps': 0.5},
    'Front Lever': {'back': 0.75},
  },
  climbingSession: {'back': 3.0, 'biceps': 1.5, 'forearms': 3.0},
);

void main() {
  group('MuscleMap.creditsFor', () {
    test('exact, then longest prefix', () {
      expect(map.creditsFor('Barbell Squat')!['quads'], 1.0);
      expect(map.creditsFor('Muscle Up Green Band')!['back'], 0.75);
      expect(map.creditsFor('Leg Curl'), isNull);
    });

    test('calisthenics skill names: case/hyphen-blind + aliases', () {
      expect(map.creditsFor('muscle-up green band')!['back'], 0.75);
      expect(map.creditsFor('front lever tuck')!['back'], 0.75);
      expect(map.creditsFor('handstand wall')!['shoulders'], 0.25);
      expect(map.creditsFor('hspu')!['shoulders'], 1.0);
      expect(map.creditsFor('core'), isNull);
    });
  });

  group('weeklyMuscleVolume', () {
    test('fractional per-set credits + per-session climbing, groups only',
        () {
      final v = weeklyMuscleVolume(
        map: map,
        groups: ['quads', 'chest', 'back', 'biceps', 'triceps'],
        setNames: [
          'Barbell Squat',
          'Barbell Squat',
          'Flat Barbell Bench Press',
          'Muscle Up',
          'Unmapped Thing',
        ],
        climbSessions: 2,
      );
      expect(v.keys, ['quads', 'chest', 'back', 'biceps', 'triceps']);
      expect(v['quads']!.sets, 2.0);
      expect(v['chest']!.sets, 1.0);
      expect(v['triceps']!.sets, 0.5);
      expect(v['back']!.sets, 6.75);
      expect(v['back']!.byExercise,
          {'Muscle Up': 0.75, climbingLabel: 6.0});
      expect(v['biceps']!.sets, 3.5);
      // forearms/core are credited by the map but not in [groups].
      expect(v.containsKey('forearms'), isFalse);
    });

    test('every group present even with no work', () {
      final v = weeklyMuscleVolume(
          map: map, groups: ['quads', 'calves'], setNames: const []);
      expect(v['quads']!.sets, 0);
      expect(v['calves']!.sets, 0);
      expect(v['calves']!.byExercise, isEmpty);
    });
  });

  test('hypertrophyMuscleGroups reads the version', () {
    expect(
      hypertrophyMuscleGroups({
        'hypertrophy_targets': {
          'muscle_groups': ['quads', 'back'],
        },
      }),
      ['quads', 'back'],
    );
    expect(hypertrophyMuscleGroups(null), isEmpty);
  });
}
