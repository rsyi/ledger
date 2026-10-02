// muscle_volume.dart — the shared per-muscle weekly set counter.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

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

  test('hypertrophyTrackedGroups reads the version (absent → empty)', () {
    expect(
      hypertrophyTrackedGroups({
        'hypertrophy_targets': {
          'tracked_groups': ['lower_back', 'core'],
        },
      }),
      ['lower_back', 'core'],
    );
    expect(
      hypertrophyTrackedGroups({
        'hypertrophy_targets': {
          'muscle_groups': ['quads'],
        },
      }),
      isEmpty,
    );
  });

  test('real program.yaml v16: split groups + stimulus-tier credits; '
      'v15 history still resolves with back/shoulders', () {
    final file = File('../airledger-fitness/coach/program.yaml');
    if (!file.existsSync()) {
      markTestSkipped('no airledger-fitness checkout');
      return;
    }
    final doc = loadYaml(file.readAsStringSync()) as Map;
    final versions = doc['versions'] as List;
    Map<Object?, Object?> ver(int n) =>
        versions.firstWhere((v) => (v as Map)['version'] == n) as Map;
    final v16 = ver(16);
    expect(hypertrophyMuscleGroups(v16), [
      'quads', 'hamstrings_glutes', 'chest', 'lats', 'upper_back',
      'side_delts', 'rear_delts', 'biceps', 'triceps',
    ]);
    expect(hypertrophyTrackedGroups(v16),
        ['lower_back', 'front_delts', 'forearms', 'core']);
    final m = parseExerciseMuscleMap(v16)!;
    expect(m.creditsFor('Pull Up'), {'lats': 1.0, 'biceps': 0.25});
    expect(m.creditsFor('Chin Up'), {'lats': 1.0, 'biceps': 0.5});
    expect(m.creditsFor('Seated Cable Row'),
        {'upper_back': 1.0, 'lats': 0.5});
    expect(m.creditsFor('Cable Face Pull'),
        {'upper_back': 0.5, 'rear_delts': 0.5});
    expect(m.creditsFor('Barbell Deadlift'),
        {'hamstrings_glutes': 1.0, 'lower_back': 1.0});
    expect(m.creditsFor('Flat Barbell Bench Press'),
        {'chest': 1.0, 'triceps': 0.5});
    expect(m.creditsFor('Overhead Press'),
        {'front_delts': 1.0, 'side_delts': 0.25, 'triceps': 0.5});
    expect(m.creditsFor('Muscle Up Green Band'),
        {'lats': 0.75, 'triceps': 0.25});
    expect(m.creditsFor('Barbell Squat'),
        {'quads': 1.0, 'hamstrings_glutes': 0.5});
    expect(m.climbingSession,
        {'lats': 1.5, 'biceps': 0.5, 'forearms': 2.0, 'core': 0.5});
    // No credit names a group outside banded + tracked except calves.
    final known = {
      ...hypertrophyMuscleGroups(v16),
      ...hypertrophyTrackedGroups(v16),
      'calves',
    };
    for (final c in [...m.exercises.values, m.climbingSession]) {
      expect(known.containsAll(c.keys), isTrue, reason: '$c');
    }
    // Append-only: v15 keeps the old groups.
    final v15 = ver(15);
    expect(hypertrophyMuscleGroups(v15), contains('back'));
    expect(hypertrophyTrackedGroups(v15), isEmpty);
    expect(parseExerciseMuscleMap(v15)!.creditsFor('Pull Up')!['back'], 1.0);
  });
}
