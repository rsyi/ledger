// Tests for the pure week-planner core (buildWeekPlannedEntries) against
// BOTH the live airledger-fitness program.yaml (pins the v3 `planned`
// contract) and a synthetic program (sets expansion, edge cases).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/week_planner.dart';

const _fitnessRepo = '../airledger-fitness/coach';

Map<Object?, Object?> _loadYamlMap(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
        'Missing $path — is the airledger-fitness checkout present?');
  }
  final y = loadYaml(file.readAsStringSync());
  return y is Map ? Map<Object?, Object?>.from(y) : {};
}

void main() {
  final program = _loadYamlMap('$_fitnessRepo/program.yaml');

  // Program anchor week: Monday 2026-09-21 = week 0 since anchor → parity a.
  final anchorMonday = DateTime.utc(2026, 9, 21);
  // One week later → parity b.
  final bMonday = DateTime.utc(2026, 9, 28);

  List<Map<String, Object?>> onDay(
          List<Map<String, Object?>> entries, DateTime day) =>
      entries.where((e) => e['date'] == day).toList();

  group('live program.yaml v3', () {
    test('A week: squat heavy Monday (1x1 + 1x3), deadlift light Friday',
        () {
      final entries = buildWeekPlannedEntries(program, anchorMonday);
      final mon = onDay(entries, anchorMonday);
      expect(mon.map((e) => e['exercise']),
          everyElement('Barbell Squat'));
      expect(mon.map((e) => e['reps']).toList(), [1, 3]);
      final fri = onDay(entries, anchorMonday.add(const Duration(days: 4)));
      expect(fri.map((e) => e['exercise']),
          everyElement('Barbell Deadlift'));
      expect(fri.map((e) => e['reps']).toList(), [3]);
    });

    test('B week: squat light Monday (1x3), deadlift heavy Friday (1x1+1x3)',
        () {
      final entries = buildWeekPlannedEntries(program, bMonday);
      final mon = onDay(entries, bMonday);
      expect(mon.map((e) => e['exercise']),
          everyElement('Barbell Squat'));
      expect(mon.map((e) => e['reps']).toList(), [3]);
      final fri = onDay(entries, bMonday.add(const Duration(days: 4)));
      expect(fri.map((e) => e['exercise']),
          everyElement('Barbell Deadlift'));
      expect(fri.map((e) => e['reps']).toList(), [1, 3]);
    });

    test('Tuesday presses have no alternation: bench + OHP singles/triples',
        () {
      for (final monday in [anchorMonday, bMonday]) {
        final tue = onDay(buildWeekPlannedEntries(program, monday),
            monday.add(const Duration(days: 1)));
        expect(
            tue
                .map((e) => '${e['exercise']} x${e['reps']}')
                .toList(),
            [
              'Flat Barbell Bench Press x1',
              'Flat Barbell Bench Press x3',
              'Overhead Press x1',
              'Overhead Press x3',
            ],
            reason: 'week of $monday');
      }
    });

    test('entries carry ONLY date + exercise + reps — never rpe/notes/weight',
        () {
      for (final monday in [anchorMonday, bMonday]) {
        final entries = buildWeekPlannedEntries(program, monday);
        expect(entries, isNotEmpty);
        for (final e in entries) {
          expect(e.keys.toSet(), {'date', 'exercise', 'reps'});
        }
      }
    });

    test('non-lifting days (wed/thu/sat/sun) produce nothing', () {
      final entries = buildWeekPlannedEntries(program, anchorMonday);
      for (final offset in [2, 3, 5, 6]) {
        final day = anchorMonday.add(Duration(days: offset));
        expect(onDay(entries, day), isEmpty, reason: 'offset $offset');
      }
    });

    test('pre-program week produces nothing', () {
      expect(
          buildWeekPlannedEntries(program, DateTime.utc(2026, 9, 14)),
          isEmpty);
    });

    test('non-Monday input normalises to the same ISO week', () {
      final fromWed = buildWeekPlannedEntries(
          program, anchorMonday.add(const Duration(days: 2)));
      expect(fromWed, buildWeekPlannedEntries(program, anchorMonday));
    });
  });

  group('synthetic programs', () {
    Map<Object?, Object?> synthetic({int sets = 1}) => {
          'versions': [
            {
              'version': 1,
              'id': 'test',
              'blocks': [
                {
                  'n': 1,
                  'emphasis': 'lifting',
                  'dates': ['2020-01-06', '2030-12-31'],
                  'weight': [150, 160],
                },
              ],
              'planned_alternation': {'anchor_monday': '2020-01-06'},
              'weekly_template': {
                'mon': {
                  'morning': 'lift',
                  'planned': [
                    {'exercise': 'Barbell Squat', 'sets': sets, 'reps': 5},
                  ],
                },
                'tue': {'morning': 'rest'},
              },
            },
          ],
        };

    test('sets: N expands into N one-row entries', () {
      final entries = buildWeekPlannedEntries(
          synthetic(sets: 3), DateTime.utc(2026, 9, 21));
      expect(entries, hasLength(3));
      for (final e in entries) {
        expect(e['exercise'], 'Barbell Squat');
        expect(e['reps'], 5);
        expect(e['date'], DateTime.utc(2026, 9, 21));
      }
    });

    test('empty/malformed program produces nothing', () {
      expect(buildWeekPlannedEntries({}, anchorMonday), isEmpty);
      expect(
          buildWeekPlannedEntries({'versions': []}, anchorMonday), isEmpty);
      expect(
          buildWeekPlannedEntries({
            'versions': [
              {'version': 1, 'pending': true},
            ],
          }, anchorMonday),
          isEmpty);
    });
  });
}
