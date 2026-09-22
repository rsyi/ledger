// Tests for the pure week-planner core (buildWeekPlannedEntries) against
// BOTH the live airledger-fitness program.yaml (pins the v4 `planned` +
// `weight_fill` + `warmup_protocol` contract) and synthetic programs
// (sets expansion, edge cases), plus the PlanStore-level regenerate
// (v1 → v2 upgrade) semantics.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/models/planned_entry.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/plan_store.dart';
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

ViewSchema _strengthView() => ViewSchema(
      name: 'strength',
      datasource: 'gsheets',
      table: 'strength',
      entities: const [],
      measures: const [],
      dateField: 'date',
      dimensions: [
        Dimension(name: 'id', type: DimensionType.string, expr: 'id'),
        Dimension(name: 'date', type: DimensionType.date, expr: 'Date'),
        Dimension(
            name: 'exercise', type: DimensionType.string, expr: 'Exercise'),
        Dimension(name: 'weight', type: DimensionType.number, expr: 'Weight'),
        Dimension(name: 'reps', type: DimensionType.number, expr: 'Reps'),
        Dimension(name: 'rpe', type: DimensionType.number, expr: 'RPE'),
      ],
    );

void main() {
  final program = _loadYamlMap('$_fitnessRepo/program.yaml');

  // Program anchor week: Monday 2026-09-21 = week 0 since anchor → parity a.
  final anchorMonday = DateTime.utc(2026, 9, 21);
  // One week later → parity b.
  final bMonday = DateTime.utc(2026, 9, 28);

  // References used across the weight-fill tests (per-lift 42-day e1rm).
  const refs = {
    'squat': 300.0,
    'bench': 250.0,
    'press': 150.0,
    'deadlift': 200.0,
  };

  List<Map<String, Object?>> onDay(
          List<Map<String, Object?>> entries, DateTime day) =>
      entries.where((e) => e['date'] == day).toList();

  List<String> rows(List<Map<String, Object?>> entries) => [
        for (final e in entries)
          '${e['exercise']} ${e['weight'] ?? '-'}x${e['reps']}',
      ];

  group('live program.yaml v4 — reps skeleton (no references)', () {
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

    test('v7 week_start saturday: the generation window runs Sat–Fri, '
        'so Monday + the FOLLOWING Friday plan as one week', () {
      // Passing the anchor Monday normalises to the Saturday before it
      // (Sep 19) — the accounting week containing that Monday.
      final entries = buildWeekPlannedEntries(program, anchorMonday);
      final dates = entries.map((e) => e['date'] as DateTime).toSet();
      final windowStart = DateTime.utc(2026, 9, 19); // Saturday
      for (final d in dates) {
        expect(d.isBefore(windowStart), isFalse);
        expect(d.isAfter(windowStart.add(const Duration(days: 6))), isFalse);
      }
      // Template lookup keys by ACTUAL weekday: Monday squats + the
      // Friday (Sep 25) deadlift both land inside this window, with the
      // same 'a' parity (alternation anchored to the contained Monday).
      final mon = onDay(entries, anchorMonday);
      expect(mon.map((e) => e['exercise']), everyElement('Barbell Squat'));
      final fri = onDay(entries, DateTime.utc(2026, 9, 25));
      expect(fri.map((e) => e['exercise']),
          everyElement('Barbell Deadlift'));
      expect(fri.map((e) => e['reps']).toList(), [3]); // a-week: light
    });

    test('without references: no weight keys, no warmup rows anywhere', () {
      for (final monday in [anchorMonday, bMonday]) {
        final entries = buildWeekPlannedEntries(program, monday);
        expect(entries, isNotEmpty);
        for (final e in entries) {
          expect(e.keys.toSet(), {'date', 'exercise', 'reps'});
        }
      }
    });

    test('non-lifting days (wed/thu/sat/sun) produce nothing', () {
      final entries =
          buildWeekPlannedEntries(program, anchorMonday, references: refs);
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
          program, anchorMonday.add(const Duration(days: 2)),
          references: refs);
      expect(fromWed,
          buildWeekPlannedEntries(program, anchorMonday, references: refs));
    });
  });

  group('live program.yaml v4 — weight fill + warmup ramp', () {
    test(
        'key lockdown: generated keys drawn from exactly '
        '{date, exercise, reps, weight} — never rpe/notes', () {
      for (final monday in [anchorMonday, bMonday]) {
        final entries =
            buildWeekPlannedEntries(program, monday, references: refs);
        expect(entries, isNotEmpty);
        for (final e in entries) {
          expect({'date', 'exercise', 'reps', 'weight'}.containsAll(e.keys),
              isTrue,
              reason: 'unexpected key in $e');
          expect(e.keys.toSet().containsAll({'date', 'exercise', 'reps'}),
              isTrue);
          expect(e.containsKey('rpe'), isFalse);
          expect(e.containsKey('notes'), isFalse);
        }
      }
    });

    test('A-week Monday: squat ramp to top single, then 96%/88% work', () {
      final mon = onDay(
          buildWeekPlannedEntries(program, anchorMonday, references: refs),
          anchorMonday);
      // ref 300: single = round5(288) = 290 (top), triple = round5(264) =
      // 265; ramp 45x10 → 40% 116→115 x5 → 60% 174→175 x3 → 80% 232→230 x1.
      expect(rows(mon), [
        'Barbell Squat 45x10',
        'Barbell Squat 115x5',
        'Barbell Squat 175x3',
        'Barbell Squat 230x1',
        'Barbell Squat 290x1',
        'Barbell Squat 265x3',
      ]);
    });

    test('Tuesday: per-exercise ramps for bench then press', () {
      final tue = onDay(
          buildWeekPlannedEntries(program, anchorMonday, references: refs),
          anchorMonday.add(const Duration(days: 1)));
      expect(rows(tue), [
        // bench ref 250: top single 240, triple 220; ramp 96→95, 144→145,
        // 192→190.
        'Flat Barbell Bench Press 45x10',
        'Flat Barbell Bench Press 95x5',
        'Flat Barbell Bench Press 145x3',
        'Flat Barbell Bench Press 190x1',
        'Flat Barbell Bench Press 240x1',
        'Flat Barbell Bench Press 220x3',
        // press ref 150: top single 145, triple 130; ramp 58→60, 87→85,
        // 116→115.
        'Overhead Press 45x10',
        'Overhead Press 60x5',
        'Overhead Press 85x3',
        'Overhead Press 115x1',
        'Overhead Press 145x1',
        'Overhead Press 130x3',
      ]);
    });

    test('deadlift rule: 135x5 start, only ramp steps above 135 survive',
        () {
      // A week, deadlift light (one triple): ref 200 → 175 top. 60% =
      // 105 (≤135, dropped), 80% = 140 (>135, kept).
      final friA = onDay(
          buildWeekPlannedEntries(program, anchorMonday, references: refs),
          anchorMonday.add(const Duration(days: 4)));
      expect(rows(friA), [
        'Barbell Deadlift 135x5',
        'Barbell Deadlift 140x1',
        'Barbell Deadlift 175x3',
      ]);
      // B week, deadlift heavy: top single 190. 60% = 114→115 (dropped),
      // 80% = 152→150 (kept). No 45-lb bar row ever.
      final friB = onDay(
          buildWeekPlannedEntries(program, bMonday, references: refs),
          bMonday.add(const Duration(days: 4)));
      expect(rows(friB), [
        'Barbell Deadlift 135x5',
        'Barbell Deadlift 150x1',
        'Barbell Deadlift 190x1',
        'Barbell Deadlift 175x3',
      ]);
      // Strong deadlift: both pct steps clear 135 and are kept.
      final friBig = onDay(
          buildWeekPlannedEntries(program, bMonday,
              references: const {'deadlift': 400.0}),
          bMonday.add(const Duration(days: 4)));
      expect(rows(friBig), [
        'Barbell Deadlift 135x5',
        'Barbell Deadlift 230x3', // 60% of 385
        'Barbell Deadlift 310x1', // 80% of 385
        'Barbell Deadlift 385x1',
        'Barbell Deadlift 350x3',
      ]);
    });

    test('rounding: every filled weight is a nearest-5 multiple', () {
      final entries = buildWeekPlannedEntries(program, anchorMonday,
          references: const {'squat': 299.0});
      final mon = onDay(entries, anchorMonday);
      // 299 × 0.96 = 287.04 → 285; 299 × 0.88 = 263.12 → 265.
      expect(rows(mon).sublist(4), [
        'Barbell Squat 285x1',
        'Barbell Squat 265x3',
      ]);
      for (final e in entries) {
        final w = e['weight'];
        if (w is num) expect(w % 5, 0, reason: '$e');
      }
    });

    test('absent reference: no weight AND no warmups for that lift only',
        () {
      // Only squat has a reference — bench/press/deadlift days fall back
      // to bare skeleton rows (never a guessed weight).
      final entries = buildWeekPlannedEntries(program, anchorMonday,
          references: const {'squat': 300.0});
      final mon = onDay(entries, anchorMonday);
      expect(mon, hasLength(6)); // 4 warmups + 2 working
      final tue = onDay(entries, anchorMonday.add(const Duration(days: 1)));
      expect(rows(tue), [
        'Flat Barbell Bench Press -x1',
        'Flat Barbell Bench Press -x3',
        'Overhead Press -x1',
        'Overhead Press -x3',
      ]);
      for (final e in tue) {
        expect(e.keys.toSet(), {'date', 'exercise', 'reps'});
      }
      final fri = onDay(entries, anchorMonday.add(const Duration(days: 4)));
      expect(rows(fri), ['Barbell Deadlift -x3']);
    });
  });

  group('v3 — working-max weights (wm × rpe_chart[policy target][reps])', () {
    // The §5 seed values; deadlift pain-capped at RPE 7.
    const wms = {
      'squat': 320.0,
      'bench': 240.0,
      'deadlift': 330.0,
      'press': 140.0,
    };

    test('A-week Monday squat: single at chart[8][1], triple at chart[8][3]',
        () {
      final mon = onDay(
          buildWeekPlannedEntries(program, anchorMonday,
              references: refs, workingMaxes: wms),
          anchorMonday);
      // wm 320, cut_early target 8: single 295.04→295, triple 276.16→275;
      // ramp toward 295: 118→120, 177→175, 236→235.
      expect(rows(mon), [
        'Barbell Squat 45x10',
        'Barbell Squat 120x5',
        'Barbell Squat 175x3',
        'Barbell Squat 235x1',
        'Barbell Squat 295x1',
        'Barbell Squat 275x3',
      ]);
    });

    test('Tuesday bench + press from their working maxes', () {
      final tue = onDay(
          buildWeekPlannedEntries(program, anchorMonday,
              references: refs, workingMaxes: wms),
          anchorMonday.add(const Duration(days: 1)));
      expect(rows(tue), [
        // bench wm 240: single 221.28→220, triple 207.12→205.
        'Flat Barbell Bench Press 45x10',
        'Flat Barbell Bench Press 90x5',
        'Flat Barbell Bench Press 130x3',
        'Flat Barbell Bench Press 175x1',
        'Flat Barbell Bench Press 220x1',
        'Flat Barbell Bench Press 205x3',
        // press wm 140: single 129.08→130, triple 120.82→120.
        'Overhead Press 45x10',
        'Overhead Press 50x5',
        'Overhead Press 80x3',
        'Overhead Press 105x1',
        'Overhead Press 130x1',
        'Overhead Press 120x3',
      ]);
    });

    test('an active RPE cap lowers the target (pain-capped deadlift)', () {
      final fri = onDay(
          buildWeekPlannedEntries(program, anchorMonday,
              references: refs,
              workingMaxes: wms,
              capRpeByLift: const {'deadlift': 7}),
          anchorMonday.add(const Duration(days: 4)));
      // A-week deadlift light 1x3 at chart[7][3]=0.837: 276.21→275.
      expect(rows(fri), [
        'Barbell Deadlift 135x5',
        'Barbell Deadlift 165x3',
        'Barbell Deadlift 220x1',
        'Barbell Deadlift 275x3',
      ]);
    });

    test('lifts without a working max fall back to the reference path', () {
      final entries = buildWeekPlannedEntries(program, anchorMonday,
          references: refs, workingMaxes: const {'squat': 320.0});
      final mon = onDay(entries, anchorMonday);
      expect(rows(mon).sublist(4),
          ['Barbell Squat 295x1', 'Barbell Squat 275x3']);
      final tue = onDay(entries, anchorMonday.add(const Duration(days: 1)));
      // bench ref 250 × 0.96 = 240 (v2 math).
      expect(rows(tue), contains('Flat Barbell Bench Press 240x1'));
    });

    test('no working maxes at all == v2 output exactly', () {
      expect(
          buildWeekPlannedEntries(program, anchorMonday, references: refs),
          buildWeekPlannedEntries(program, anchorMonday,
              references: refs, workingMaxes: const {}));
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

    test('reps without a pct_by_reps entry get no weight (never guess)', () {
      // Synthetic program plans 5s; live-style weight_fill only maps 1/3.
      final prog = synthetic();
      final version =
          (prog['versions'] as List).first as Map<Object?, Object?>;
      version['weight_fill'] = {
        'pct_by_reps': {1: 0.96, 3: 0.88},
        'rounding_lb': 5,
      };
      version['warmup_protocol'] = {
        'rounding_lb': 5,
        'default': [
          {'weight_lb': 45, 'reps': 10},
        ],
      };
      final entries = buildWeekPlannedEntries(
          prog, DateTime.utc(2026, 9, 21),
          references: const {'squat': 300.0});
      // No working weight → warmups skipped too.
      expect(entries, hasLength(1));
      expect(entries.single.keys.toSet(), {'date', 'exercise', 'reps'});
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

  group('regenerateWeek (v1 → v2 upgrade)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('replaces only this week\'s still-planned week-plan rows, '
        'today-forward', () async {
      final view = _strengthView();
      // v1-style leftovers for the target week (Mon + Fri), a user
      // template entry, and next week's plan — only the first two may go.
      final monEntry = PlannedEntry.create(
        view: view,
        date: DateTime(2026, 9, 21),
        values: {'exercise': 'Barbell Squat', 'reps': 1},
        templateName: WeekPlanner.templateLabel,
      );
      final friEntry = PlannedEntry.create(
        view: view,
        date: DateTime(2026, 9, 25),
        values: {'exercise': 'Barbell Deadlift', 'reps': 3},
        templateName: WeekPlanner.templateLabel,
      );
      final userEntry = PlannedEntry.create(
        view: view,
        date: DateTime(2026, 9, 21),
        values: {'exercise': 'Face Pull', 'reps': 15},
        templateName: 'my template',
      );
      final nextWeekEntry = PlannedEntry.create(
        view: view,
        date: DateTime(2026, 9, 28),
        values: {'exercise': 'Barbell Squat', 'reps': 3},
        templateName: WeekPlanner.templateLabel,
      );
      await PlanStore.addAll(
          view, [monEntry, friEntry, userEntry, nextWeekEntry]);
      // Simulate "Monday's single was already logged": Log-now removed it
      // from PlanStore before the upgrade ran.
      await PlanStore.remove(view, monEntry.localId);

      final added = await WeekPlanner.regenerateWeek(
        strengthView: view,
        program: program,
        references: refs,
        targetMonday: DateTime.utc(2026, 9, 21),
        today: DateTime(2026, 9, 23), // Wednesday
      );

      // Today-forward only: Mon/Tue are past — the logged Monday single is
      // NOT re-created. A-week Friday = deadlift light + its ramp.
      expect(
        [for (final e in added) '${e.values['exercise']} '
            '${e.values['weight'] ?? '-'}x${e.values['reps']}'],
        [
          'Barbell Deadlift 135x5',
          'Barbell Deadlift 140x1',
          'Barbell Deadlift 175x3',
        ],
      );
      for (final e in added) {
        expect(e.templateName, WeekPlanner.templateLabel);
        expect(e.values.containsKey('rpe'), isFalse);
        expect(e.values.containsKey('notes'), isFalse);
      }

      // Store state: old week-plan rows for THIS week gone; the user's
      // template entry and next week's plan untouched.
      final friday = await PlanStore.loadForDate(view, DateTime(2026, 9, 25));
      expect(friday.map((e) => e.localId), isNot(contains(friEntry.localId)));
      expect(friday, hasLength(3));
      final monday = await PlanStore.loadForDate(view, DateTime(2026, 9, 21));
      expect(monday.map((e) => e.localId), [userEntry.localId]);
      final nextMon =
          await PlanStore.loadForDate(view, DateTime(2026, 9, 28));
      expect(nextMon.map((e) => e.localId), [nextWeekEntry.localId]);
    });

    test('planned weights survive the PlanStore JSON round-trip', () async {
      final view = _strengthView();
      await WeekPlanner.regenerateWeek(
        strengthView: view,
        program: program,
        references: refs,
        targetMonday: DateTime.utc(2026, 9, 21),
        today: DateTime(2026, 9, 21),
      );
      final monday = await PlanStore.loadForDate(view, DateTime(2026, 9, 21));
      expect(
        [for (final e in monday) e.values['weight']],
        [45, 115, 175, 230, 290, 265],
      );
      expect(monday.first.values['weight'], isA<num>());
    });
  });
}
