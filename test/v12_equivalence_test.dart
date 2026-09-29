// v11 → v12 REGENERATION EQUIVALENCE PROOF (routine unification).
//
// program.yaml v12 replaced weekly_template / weekly_template_block_0
// with ONE `routine:` base week + phase_overrides. The approved v11
// plan must regenerate byte-comparably: same days, same exercises, same
// sets/reps/pcts, same working-max-priced weights ("minus TM drift" —
// both sides here read the SAME working maxes, so outputs must be
// EXACTLY equal; the only sanctioned additive delta is the new
// accessory double-progression weights, which need history and are OFF
// in this comparison). Also proves the sim reads an unchanged block
// calendar (routine unification cannot alter counted W).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/sim2_harness.dart'
    show sim2BlocksFromProgramDocs;
import 'package:airledger/services/week_planner.dart';

const _fitnessRepo = '../airledger-fitness/coach';

void main() {
  final file = File('$_fitnessRepo/program.yaml');
  final program = loadYaml(file.readAsStringSync()) as Map;
  final versions = program['versions'] as List;

  Map<Object?, Object?> docThrough(int maxVersion) => {
        'versions': [
          for (final v in versions)
            if (v is Map && (v['version'] as num) <= maxVersion) v,
        ],
      };

  final docV11 = docThrough(11);
  final docV12 = docThrough(12);

  test('sanity: the two docs resolve v11 and v12', () {
    expect(currentVersion(docV11)!['version'], 11);
    expect(currentVersion(docV12)!['version'], 12);
  });

  const maxes = {
    'squat': 320.0,
    'bench': 240.0,
    'deadlift': 330.0,
    'press': 140.0,
  };
  const refs = {
    'squat': 340.0,
    'bench': 255.0,
    'deadlift': 355.0,
    'press': 150.0,
  };

  // One representative week per phase shape:
  //   cut normal (wave wk1), cut deload (wave wk4), reverse ramp,
  //   climbing-emphasis, lifting-emphasis, light week, test week.
  final weeks = <String, DateTime>{
    'cut wave week 1': DateTime.utc(2026, 9, 28),
    'cut wave week 2': DateTime.utc(2026, 10, 5),
    'cut deload (wave week 4)': DateTime.utc(2026, 10, 19),
    'cut_late window': DateTime.utc(2026, 11, 23),
    'reverse / volume-ramp week 1': DateTime.utc(2026, 12, 14),
    'climbing-emphasis normal': DateTime.utc(2027, 1, 11),
    'climbing-emphasis light (block wk 4)': DateTime.utc(2027, 1, 25),
    'lifting-emphasis normal': DateTime.utc(2027, 3, 8),
    'lifting-emphasis test (block wk 8)': DateTime.utc(2027, 4, 19),
  };

  for (final e in weeks.entries) {
    test('planner output identical for ${e.key}', () {
      final a = buildWeekPlannedEntries(docV11, e.value,
          references: refs, workingMaxes: maxes);
      final b = buildWeekPlannedEntries(docV12, e.value,
          references: refs, workingMaxes: maxes);
      expect(b, equals(a));
      expect(a, isNotEmpty, reason: 'representative week must plan rows');
    });

    test('planner output identical for ${e.key} (reference fallback)', () {
      final a = buildWeekPlannedEntries(docV11, e.value, references: refs);
      final b = buildWeekPlannedEntries(docV12, e.value, references: refs);
      expect(b, equals(a));
    });
  }

  test('today_template strings identical across a cut and a post-cut week',
      () {
    for (final start in [DateTime.utc(2026, 10, 5), DateTime.utc(2027, 3, 8)]) {
      for (var i = 0; i < 7; i++) {
        final day = start.add(Duration(days: i));
        final a = programCurrent(docV11, null, day)!;
        final b = programCurrent(docV12, null, day)!;
        expect(b.todayTemplate['morning'], a.todayTemplate['morning'],
            reason: '$day morning');
        expect(b.todayTemplate['afternoon'], a.todayTemplate['afternoon'],
            reason: '$day afternoon');
        expect(b.weekType, a.weekType);
        expect(b.weekInBlock, a.weekInBlock);
      }
    }
  });

  test('sim block calendar unchanged (counted W cannot move)', () {
    final a = sim2BlocksFromProgramDocs(docV11)!;
    final b = sim2BlocksFromProgramDocs(docV12)!;
    expect(b.length, a.length);
    for (var i = 0; i < a.length; i++) {
      expect(b[i].n, a[i].n);
      expect(b[i].start, a[i].start);
      expect(b[i].end, a[i].end);
      expect(b[i].emphasis, a[i].emphasis);
      expect(b[i].r, a[i].r);
    }
  });
}
