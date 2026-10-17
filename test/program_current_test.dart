// Tests for the program.current resolver against the SHARED fixtures in
// airledger-fitness (sibling checkout). The TS twin in ledger-mcp runs
// the same cases; drift between resolvers = a failure on either side.
// The lib under test stays pure — only the test does IO.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/program_current.dart';

const _fitnessRepo = '../airledger-fitness/coach';

dynamic _loadYamlFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
        'Missing $path — is the airledger-fitness checkout present?');
  }
  return loadYaml(file.readAsStringSync());
}

bool _deepEq(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEq(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a.toDouble() == b.toDouble();
  return a == b;
}

void main() {
  final program =
      _loadYamlFile('$_fitnessRepo/program.yaml') as Map<Object?, Object?>;
  final phase =
      _loadYamlFile('$_fitnessRepo/phase.yaml') as Map<Object?, Object?>;
  final fixtures =
      _loadYamlFile('$_fitnessRepo/fixtures/program_current_cases.yaml') as Map;
  final cases = fixtures['cases'] as List;

  test('fixtures file has at least 10 cases', () {
    expect(cases.length, greaterThanOrEqualTo(10));
  });

  test('currentVersion resolves last non-pending entry', () {
    final v = currentVersion(program);
    expect(v, isNotNull);
    expect(v!['id'], 'bulk-2026-27');
    expect(v['version'], 18);
    // A trailing pending entry must be skipped.
    final withPending = {
      'versions': [
        ...(program['versions'] as List),
        {'version': 99, 'pending': true, 'id': 'draft'},
      ],
    };
    expect(currentVersion(withPending)!['version'], 18);
  });

  for (final c in cases) {
    final caseMap = c as Map;
    final name = caseMap['name'].toString();
    final date = DateTime.parse(caseMap['date'].toString());
    final expected = caseMap['expect'];

    test('fixture: $name (${caseMap['date']})', () {
      final slice = programCurrent(program, phase, date);
      if (expected == null) {
        expect(slice, isNull, reason: 'expected null slice for $name');
        return;
      }
      expect(slice, isNotNull, reason: 'expected a slice for $name');
      final exp = expected as Map;
      expect(slice!.block['number'], exp['block'], reason: '$name block');
      expect(slice.block['emphasis'], exp['emphasis'],
          reason: '$name emphasis');
      expect(slice.weekInBlock, exp['week_in_block'],
          reason: '$name week_in_block');
      expect(slice.weekType, exp['week_type'], reason: '$name week_type');
      expect(slice.todayTemplate['weekday'], exp['weekday'],
          reason: '$name weekday');

      // Check today_template fields when the fixture specifies them.
      if (exp.containsKey('today_template')) {
        final expTmpl = exp['today_template'] as Map;
        for (final key in expTmpl.keys) {
          final actual = slice.todayTemplate[key.toString()];
          expect(_deepEq(actual, expTmpl[key]), isTrue,
              reason:
                  '$name today_template.$key: expected ${expTmpl[key]}, got $actual');
        }
      }

      // Check version when the fixture specifies it.
      if (exp.containsKey('version')) {
        expect(slice.version, exp['version'], reason: '$name version');
      }

      // v18: the cut-wave week when the fixture specifies it (null = no
      // cut wave for the date).
      if (exp.containsKey('cut_wave')) {
        final cw = strengthWaveCutFor(currentVersion(program),
            blockN: slice.block['number'] as int?, day: date);
        final want = exp['cut_wave'] as Map?;
        expect(
            cw == null
                ? null
                : {
                    'week': cw.week,
                    'reps': cw.reps,
                    'pct': cw.pct,
                    'deload': cw.deload,
                  },
            want == null ? isNull : Map<String, Object?>.from(want),
            reason: '$name cut_wave');
      }

      final expTargets = exp['targets'] as Map;
      for (final key in expTargets.keys) {
        final actual = slice.targetsInForce[key.toString()];
        expect(_deepEq(actual, expTargets[key]), isTrue,
            reason:
                '$name targets.$key: expected ${expTargets[key]}, got $actual');
      }

      // Slice invariants beyond the fixture subset.
      expect(slice.id, 'bulk-2026-27');
      expect(slice.rulesInForce, contains('NEAR_MAX_LOW'));
      expect(slice.rulesInForce.length, 15); // v8: WEIGHT_FLAT retired under recomp
      final wd = slice.todayTemplate['weekday'];
      expect(['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'], contains(wd));
    });
  }

  test('today_template carries the weekly_template text for Mondays (non-block-0)', () {
    final slice =
        programCurrent(program, phase, DateTime.parse('2027-03-01'))!;
    expect(slice.todayTemplate['morning'], contains('squat top work per the wave'));
    expect(slice.todayTemplate['afternoon'], isNull);
  });

  group('strength wave (program.yaml v10)', () {
    final version = currentVersion(program);

    test('wave week cycles 1..4 from the block start; cut excluded', () {
      expect(strengthWaveWeek(version, blockN: 3, weekInBlock: 1), 1);
      expect(strengthWaveWeek(version, blockN: 3, weekInBlock: 3), 3);
      expect(strengthWaveWeek(version, blockN: 3, weekInBlock: 4), 4);
      expect(strengthWaveWeek(version, blockN: 3, weekInBlock: 5), 1);
      expect(strengthWaveWeek(version, blockN: 3, weekInBlock: 8), 4);
      expect(strengthWaveWeek(version, blockN: 0, weekInBlock: 2), isNull);
      expect(strengthWaveWeek(version, blockN: null, weekInBlock: 2), isNull);
      expect(strengthWaveWeek({}, blockN: 3, weekInBlock: 2), isNull);
    });

    test('top reps: 5/3/1; light = wave-restart 5; test = the single', () {
      int? reps(int wk, [String type = 'normal']) => strengthWaveTopReps(
          version, blockN: 3, weekInBlock: wk, weekType: type);
      expect(reps(1), 5);
      expect(reps(2), 3);
      expect(reps(3), 1);
      expect(reps(4, 'light'), 5); // block light week IS the wave deload
      expect(reps(8, 'test'), 1); // deload carries the block-result single
      expect(reps(5), 5); // second wave restarts
      expect(reps(6), 3);
      expect(reps(7), 1);
      // Block 1 (3-week maintenance): 5/3/1, no deload.
      expect(strengthWaveTopReps(version, blockN: 1, weekInBlock: 3), 1);
      // No wave (cut) → null, never guessed.
      expect(strengthWaveTopReps(version, blockN: 0, weekInBlock: 1), isNull);
    });
  });

  test('block 0 slice reads the v12 routine base week and carries block_0_loads note', () {
    final slice =
        programCurrent(program, phase, DateTime.parse('2026-09-21'))!;
    // v11 cut-training revision: Monday = squat wave top + volume work.
    expect(slice.todayTemplate['morning'],
        contains('wave top per strength_wave_cut'));
    expect(slice.todayTemplate['block_note'],
        contains('Cut-training revision'));
  });

  group('cut wave (program.yaml v11 strength_wave_cut)', () {
    final version = currentVersion(program);

    CutWaveWeekSpec? at(String day) => strengthWaveCutFor(version,
        blockN: 0, day: DateTime.parse(day));

    test('calendar-anchored 4-week cycle from 2026-09-28', () {
      // Week of Sep 28 = wave week 1 (5 @ 0.811 = chart[8][5]).
      final w1 = at('2026-09-28')!;
      expect((w1.week, w1.reps, w1.pct, w1.deload), (1, 5, 0.811, false));
      // Any day of the week resolves via its Monday.
      expect(at('2026-10-02')!.week, 1); // the Friday
      final w2 = at('2026-10-05')!;
      expect((w2.reps, w2.pct), (4, 0.837)); // chart[8][4]
      final w3 = at('2026-10-12')!;
      expect((w3.reps, w3.pct), (3, 0.863)); // chart[8][3]
      // v18 restart (user travel Nov 9): Oct 19 restarts at wk1 instead
      // of the calendar deload; past weeks keep their interpretation.
      final r1 = at('2026-10-19')!;
      expect((r1.week, r1.reps, r1.pct, r1.deload), (1, 5, 0.811, false));
      expect(at('2026-10-26')!.week, 2);
      expect(at('2026-11-02')!.week, 3);
      final w4 = at('2026-11-09')!;
      expect((w4.week, w4.reps, w4.pct, w4.deload), (4, 5, 0.70, true));
      // Cycle repeats from the restart.
      expect(at('2026-11-16')!.week, 1);
      expect(at('2026-12-07')!.deload, isTrue);
      // Sat Oct 3 belongs to the week of Sep 28 (its Monday) → week 1,
      // even though the ACCOUNTING window starting Sat Oct 3 mostly
      // holds wave week 2 — the wave keys off each day's Monday.
      expect(at('2026-10-03')!.week, 1);
    });

    group('restarts (v18 strength_wave_cut.restarts)', () {
      Map<Object?, Object?> wave({Object? restarts}) => {
            'strength_wave_cut': {
              'applies_to_blocks': [0],
              'anchor_monday': '2026-09-28',
              'restarts': ?restarts,
              'weeks': {
                '1': {'reps': 5, 'pct': 0.811},
                '2': {'reps': 4, 'pct': 0.837},
                '3': {'reps': 3, 'pct': 0.863},
                '4': {'reps': 5, 'pct': 0.70, 'deload': true},
              },
            },
          };
      int? wk(Map<Object?, Object?> v, String d) =>
          strengthWaveCutFor(v, blockN: 0, day: DateTime.parse(d))?.week;

      test('weeks before the restart keep the anchor interpretation', () {
        final v = wave(restarts: ['2026-10-19']);
        expect(wk(v, '2026-09-28'), 1);
        expect(wk(v, '2026-10-05'), 2);
        expect(wk(v, '2026-10-12'), 3);
        expect(wk(v, '2026-10-18'), 3); // Sun before the restart
      });

      test('restart Monday = wk1; cycle counts from it', () {
        final v = wave(restarts: ['2026-10-19']);
        expect(wk(v, '2026-10-19'), 1);
        expect(wk(v, '2026-10-22'), 1);
        expect(wk(v, '2026-10-26'), 2);
        expect(wk(v, '2026-11-02'), 3);
        expect(wk(v, '2026-11-09'), 4);
        expect(
            strengthWaveCutFor(v, blockN: 0, day: DateTime.parse('2026-11-09'))!
                .deload,
            isTrue);
        expect(wk(v, '2026-11-16'), 1);
      });

      test('pre-anchor dates stay null; latest restart <= date wins', () {
        final v = wave(restarts: ['2026-11-16', '2026-10-19']); // unsorted
        expect(wk(v, '2026-09-21'), isNull);
        expect(wk(v, '2026-11-09'), 4);
        expect(wk(v, '2026-11-16'), 1);
        expect(wk(v, '2026-11-23'), 2);
      });

      test('no restarts / malformed entries → anchor-only behaviour', () {
        expect(wk(wave(), '2026-10-19'), 4);
        expect(wk(wave(restarts: 'nope'), '2026-10-19'), 4);
        expect(wk(wave(restarts: ['garbage', null]), '2026-10-19'), 4);
        // A restart that is not a Monday snaps to its week's Monday.
        expect(wk(wave(restarts: ['2026-10-21']), '2026-10-19'), 1);
        // A restart before the anchor never rescues pre-anchor dates.
        expect(wk(wave(restarts: ['2026-09-14']), '2026-09-21'), isNull);
      });
    });

    test('pre-anchor days, non-cut blocks and null block → null', () {
      expect(at('2026-09-21'), isNull); // the pre-revision cut week
      expect(at('2026-09-26'), isNull); // Sat before the anchor
      expect(
          strengthWaveCutFor(version,
              blockN: 1, day: DateTime.parse('2026-12-14')),
          isNull); // post-cut blocks use strength_wave instead
      expect(
          strengthWaveCutFor(version,
              blockN: null, day: DateTime.parse('2026-10-05')),
          isNull);
      expect(
          strengthWaveCutFor({}, blockN: 0, day: DateTime.parse('2026-10-05')),
          isNull);
    });
  });

  group('weekStartDayOf (v7 week_start)', () {
    test('parses saturday; defaults to monday when absent/garbage/null', () {
      expect(weekStartDayOf({'week_start': 'saturday'}), DateTime.saturday);
      expect(weekStartDayOf({'week_start': 'Saturday '}), DateTime.saturday);
      expect(weekStartDayOf({'week_start': 'sunday'}), DateTime.sunday);
      expect(weekStartDayOf({}), DateTime.monday);
      expect(weekStartDayOf({'week_start': 'caturday'}), DateTime.monday);
      expect(weekStartDayOf(null), DateTime.monday);
    });

    test('the LIVE program.yaml v7 declares saturday (user amendment '
        '2026-09-22)', () {
      expect(weekStartDayOf(currentVersion(program)), DateTime.saturday);
    });
  });
}
