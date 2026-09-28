// Tests for the pure week-planner core (buildWeekPlannedEntries) against
// BOTH the live airledger-fitness program.yaml (v11: the block-0 CUT
// WAVE + %TM volume slots, plan_v5; v10: the post-cut wave template)
// and synthetic programs (sets expansion, edge cases), plus the
// PlanStore-level regenerate semantics.
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

  // Cut-wave anchor week (strength_wave_cut.anchor_monday): Monday
  // 2026-09-28 = wave week 1 (top 5 @ 0.811). The program-start week
  // (Sep 21) PRECEDES the anchor — wave tops are skipped there.
  final w1Monday = DateTime.utc(2026, 9, 28);
  final preMonday = DateTime.utc(2026, 9, 21);

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

  group('live program.yaml v11 — block-0 cut skeleton (no wm/refs)', () {
    test('wave week 1: tops resolve to 5s; volume slots + accessories at '
        'low-end reps; Tue/Sun plan nothing', () {
      final entries = buildWeekPlannedEntries(program, w1Monday);
      final mon = onDay(entries, w1Monday);
      expect(rows(mon), [
        'Barbell Squat -x5', // wave wk1 top
        'Bulgarian Split Squat -x8',
        'Bulgarian Split Squat -x8',
        'Bulgarian Split Squat -x8',
        'Flat Barbell Bench Press -x8', // 4x8 @ 68% TM (weightless w/o wm)
        'Flat Barbell Bench Press -x8',
        'Flat Barbell Bench Press -x8',
        'Flat Barbell Bench Press -x8',
        'Lateral Dumbbell Raise -x12',
        'Lateral Dumbbell Raise -x12',
        'Lateral Dumbbell Raise -x12',
        'Triceps Extension -x10',
        'Triceps Extension -x10',
      ]);
      expect(mon.first['top'], isTrue);
      final wed = onDay(entries, w1Monday.add(const Duration(days: 2)));
      expect(rows(wed), [
        'Flat Barbell Bench Press -x5', // wave top
        'Flat Barbell Bench Press -x6', // back-offs 3x6-8 @ 72%
        'Flat Barbell Bench Press -x6',
        'Flat Barbell Bench Press -x6',
        'Barbell Squat -x8', // squat volume 3x8 @ 65%
        'Barbell Squat -x8',
        'Barbell Squat -x8',
        'Overhead Press -x8', // OHP volume 3x8-10 @ 62%
        'Overhead Press -x8',
        'Overhead Press -x8',
        'Pull Up -x6',
        'Pull Up -x6',
        'Pull Up -x6',
      ]);
      final thu = onDay(entries, w1Monday.add(const Duration(days: 3)));
      expect(rows(thu), [
        'Muscle Up -x1', // skill FIRST — planner keeps template order
        'Muscle Up -x1',
        'Muscle Up -x1',
        'Parallel Bar Triceps Dip -x8',
        'Parallel Bar Triceps Dip -x8',
        'Parallel Bar Triceps Dip -x8',
        'EZ-Bar Preacher Curl -x8',
        'EZ-Bar Preacher Curl -x8',
        'EZ-Bar Preacher Curl -x8',
      ]);
      final fri = onDay(entries, w1Monday.add(const Duration(days: 4)));
      expect(rows(fri), [
        'Barbell Deadlift -x5', // wave top
        'Barbell Deadlift -x4', // back-offs 2x4-6 @ 75%
        'Barbell Deadlift -x4',
        'Romanian Deadlift -x8',
        'Romanian Deadlift -x8',
        'Flat Barbell Bench Press -x8', // third bench exposure @ 65%
        'Flat Barbell Bench Press -x8',
        'Flat Barbell Bench Press -x8',
      ]);
      // Tue (4x4 + hard climb, no lifting) and Sun plan nothing.
      for (final offset in [1, 6]) {
        expect(onDay(entries, w1Monday.add(Duration(days: offset))), isEmpty,
            reason: 'offset $offset');
      }
    });

    test('the Saturday OHP day (Sat Oct 3 sits in the Oct 5 window and is '
        'wave week 1 via ITS Monday)', () {
      final entries =
          buildWeekPlannedEntries(program, DateTime.utc(2026, 10, 5));
      final sat = onDay(entries, DateTime.utc(2026, 10, 3));
      expect(rows(sat), [
        'Overhead Press -x5', // wave wk1 top (Sat's Monday is Sep 28)
        'Overhead Press -x6', // back-offs 3x6-8 @ 72%
        'Overhead Press -x6',
        'Overhead Press -x6',
        'Seated Cable Row -x8',
        'Seated Cable Row -x8',
        'Seated Cable Row -x8',
        'Pull Up -x6',
        'Pull Up -x6',
        'Pull Up -x6',
        'Lateral Dumbbell Raise -x12',
        'Lateral Dumbbell Raise -x12',
        'Lateral Dumbbell Raise -x12',
        'Cable Face Pull -x12',
        'Cable Face Pull -x12',
        'Cable External Rotation -x12',
        'Cable External Rotation -x12',
      ]);
      // Mon Oct 5 = wave week 2: top goes to 4 reps.
      final mon = onDay(entries, DateTime.utc(2026, 10, 5));
      expect(rows(mon).first, 'Barbell Squat -x4');
    });

    test('wave weeks cycle 5/4/3 then deload (top 5, non-top halved)', () {
      // Week 3 (Oct 12): tops are triples.
      final w3 = onDay(
          buildWeekPlannedEntries(program, DateTime.utc(2026, 10, 12)),
          DateTime.utc(2026, 10, 12));
      expect(rows(w3).first, 'Barbell Squat -x3');
      // Week 4 (Oct 19): deload — top 5 stays, every non-top set count
      // is halved (min 1): BSS 3→2, bench 4→2, laterals 3→2,
      // triceps 2→1.
      final w4 = onDay(
          buildWeekPlannedEntries(program, DateTime.utc(2026, 10, 19)),
          DateTime.utc(2026, 10, 19));
      expect(rows(w4), [
        'Barbell Squat -x5',
        'Bulgarian Split Squat -x8',
        'Bulgarian Split Squat -x8',
        'Flat Barbell Bench Press -x8',
        'Flat Barbell Bench Press -x8',
        'Lateral Dumbbell Raise -x12',
        'Lateral Dumbbell Raise -x12',
        'Triceps Extension -x10',
      ]);
      expect(w4.first['top'], isTrue);
    });

    test('pre-anchor cut days: wave tops are SKIPPED (never guessed), '
        'volume slots still plan', () {
      final entries = buildWeekPlannedEntries(program, preMonday);
      final mon = onDay(entries, preMonday);
      // No squat top — the wave starts Sep 28; the rest of Monday plans.
      expect(rows(mon).where((r) => r.startsWith('Barbell Squat')), isEmpty);
      expect(mon.where((e) => e['top'] == true), isEmpty);
      expect(rows(mon), contains('Flat Barbell Bench Press -x8'));
    });

    test('without wm or references: no weight keys anywhere', () {
      for (final monday in [preMonday, w1Monday]) {
        final entries = buildWeekPlannedEntries(program, monday);
        expect(entries, isNotEmpty);
        for (final e in entries) {
          expect(e.containsKey('weight'), isFalse, reason: '$e');
        }
      }
    });

    test('pre-program week produces nothing', () {
      expect(
          buildWeekPlannedEntries(program, DateTime.utc(2026, 9, 14)),
          isEmpty);
    });

    test('non-Monday input normalises to the same ISO week', () {
      final fromWed = buildWeekPlannedEntries(
          program, w1Monday.add(const Duration(days: 2)),
          references: refs);
      expect(fromWed,
          buildWeekPlannedEntries(program, w1Monday, references: refs));
    });
  });

  // v10 (post-cut-final-spec 2026-09-27): from Dec 14 the post-cut
  // weekly_template plans the WAVE top set (reps 5/3/1 by week), the
  // back-offs (3x5; deadlift 2x4) AND the concrete accessories. The
  // volume_ramp scales accessory sets in maintenance weeks 1-2
  // (×0.65 / ×0.85); climbing-emphasis blocks scale ALL non-top sets
  // ×0.65; light/test weeks halve non-top volume (wave deload). Cut
  // weeks (block 0, through Dec 13) keep the block-0 skeleton —
  // covered by the groups above.
  group('live program.yaml v10 — post-cut template (Dec 14+)', () {
    // Block 1 starts Mon 2026-12-14; the Sat-anchored window for that
    // week runs Sat Dec 12 (still block 0) .. Fri Dec 18. Maintenance
    // week 1: wave week 1 (top 5s), accessory ramp ×0.65.
    final dec14 = DateTime.utc(2026, 12, 14);

    test('week 1 skeleton: wave top 5s + back-offs + ramped accessories',
        () {
      final entries = buildWeekPlannedEntries(program, dec14);
      expect(rows(onDay(entries, dec14)), [
        'Muscle Up -x1', // 3 sets ×0.65 → 2
        'Muscle Up -x1',
        'Barbell Squat -x5', // wave wk1 top
        'Barbell Squat -x5', // back-offs 3x5 (main lift: not ramped)
        'Barbell Squat -x5',
        'Barbell Squat -x5',
        'Romanian Deadlift -x6', // 3 ×0.65 → 2
        'Romanian Deadlift -x6',
        'Bulgarian Split Squat -x8', // 2 ×0.65 → 1
        'Hanging Leg Raise -x8', // 3 ×0.65 → 2
        'Hanging Leg Raise -x8',
      ]);
      final tue = onDay(entries, dec14.add(const Duration(days: 1)));
      expect(rows(tue), [
        'Flat Barbell Bench Press -x5', // wave top
        'Flat Barbell Bench Press -x5', // back-offs
        'Flat Barbell Bench Press -x5',
        'Flat Barbell Bench Press -x5',
        'Seated Cable Row -x6',
        'Seated Cable Row -x6',
        'Lateral Dumbbell Raise -x10',
        'Lateral Dumbbell Raise -x10',
        'Triceps Extension -x8',
        'Cable Face Pull -x12',
        'Cable External Rotation -x12',
      ]);
      // Wed now plans the pistol-squat progression (ramped 3 → 2).
      final wed = onDay(entries, dec14.add(const Duration(days: 2)));
      expect(rows(wed), ['Pistol Squat -x3', 'Pistol Squat -x3']);
      final fri = onDay(entries, dec14.add(const Duration(days: 4)));
      expect(rows(fri), [
        'Barbell Deadlift -x5', // wave wk1 top
        'Barbell Deadlift -x4', // back-offs 2x4-6 low end
        'Barbell Deadlift -x4',
        'Leg Press -x8',
        'Leg Press -x8',
        'Leg Curl -x8',
        'Leg Curl -x8',
        'Calf Raise -x8',
        'Calf Raise -x8',
      ]);
      // Sat Dec 12 still belongs to block 0 — since v11 the CUT
      // template's Saturday (OHP day) plans there, on the cut wave's
      // clock (Dec 12's Monday is Dec 7 → cut wave week 3, top x3).
      final sat0 = onDay(entries, DateTime.utc(2026, 12, 12));
      expect(rows(sat0).first, 'Overhead Press -x3');
      expect(sat0.first['top'], isTrue);
      // Thu (4x4) / Sun (rest) plan nothing.
      for (final offset in [3, 6]) {
        expect(onDay(entries, dec14.add(Duration(days: offset))), isEmpty,
            reason: 'offset $offset');
      }
      // The wave top rows carry the marker; everything else does not.
      // Block-1 tops (squat, bench, deadlift) are the post-cut wave's
      // week-1 fives; the block-0 Saturday OHP is the cut wave's x3.
      final tops = entries.where((e) => e['top'] == true).toList();
      expect(tops, hasLength(4));
      expect(
          tops.where((e) => e['date'] != DateTime.utc(2026, 12, 12))
              .map((e) => e['reps']),
          everyElement(5));
    });

    test('the Saturday OHP day: wave top + back-offs, un-ramped second '
        'bench exposure, ramped accessories', () {
      final dec21 = DateTime.utc(2026, 12, 21);
      final entries = buildWeekPlannedEntries(program, dec21);
      // Window Sat Dec 19 .. Fri Dec 25; Sat Dec 19 is still block-1
      // week 1 (wave 5s, ramp ×0.65 on accessories).
      final sat = onDay(entries, DateTime.utc(2026, 12, 19));
      expect(rows(sat), [
        'Overhead Press -x5', // wave wk1 top
        'Overhead Press -x5', // back-offs 3x5
        'Overhead Press -x5',
        'Overhead Press -x5',
        'Flat Barbell Bench Press -x6', // main lift: never ramped
        'Flat Barbell Bench Press -x6',
        'Flat Barbell Bench Press -x6',
        'Seated Cable Row -x8', // 3 ×0.65 → 2
        'Seated Cable Row -x8',
        'Lateral Dumbbell Raise -x12', // 3 ×0.65 → 2
        'Lateral Dumbbell Raise -x12',
        'EZ-Bar Preacher Curl -x8', // 2 ×0.65 → 1
        'Triceps Extension -x8',
        'Cable Face Pull -x12',
        'Cable External Rotation -x12',
      ]);
      // Mon Dec 21 = maintenance week 2: wave week 2 (top 3s), ramp
      // ×0.85 (rounds accessory sets back to full here).
      final mon = onDay(entries, dec21);
      final squat =
          mon.where((e) => e['exercise'] == 'Barbell Squat').toList();
      expect(squat.map((e) => e['reps']).toList(), [3, 5, 5, 5]);
      expect(squat.first['top'], isTrue);
    });

    test('wave week 3 tops are singles; week 3+ accessories at full '
        'volume', () {
      final dec28 = DateTime.utc(2026, 12, 28);
      final entries = buildWeekPlannedEntries(program, dec28);
      final mon = onDay(entries, dec28);
      final squat =
          mon.where((e) => e['exercise'] == 'Barbell Squat').toList();
      expect(squat.map((e) => e['reps']).toList(), [1, 5, 5, 5]);
      // Ramp over (week 3): full accessory volume.
      expect(
          mon.where((e) => e['exercise'] == 'Romanian Deadlift'),
          hasLength(3));
    });

    test('climbing-emphasis block: non-top sets ×0.65, tops preserved',
        () {
      // Block 2 (climbing) week 1: Mon 2027-01-04, wave restarts at 5s.
      final jan4 = DateTime.utc(2027, 1, 4);
      final mon = onDay(buildWeekPlannedEntries(program, jan4), jan4);
      final squat =
          mon.where((e) => e['exercise'] == 'Barbell Squat').toList();
      // Top preserved; back-offs 3 → 2 (×0.65).
      expect(squat.map((e) => e['reps']).toList(), [5, 5, 5]);
      expect(squat.first['top'], isTrue);
      expect(mon.where((e) => e['exercise'] == 'Romanian Deadlift'),
          hasLength(2)); // accessories ×0.65 too
    });

    test('light week = wave deload: top 5s at the RPE-6 cap, non-top '
        'volume halved on top of the emphasis cut', () {
      // Block 2 week 4 (light): Mon 2027-01-25.
      final jan25 = DateTime.utc(2027, 1, 25);
      final mon = onDay(
          buildWeekPlannedEntries(program, jan25,
              workingMaxes: const {'squat': 300.0}),
          jan25);
      final squat =
          mon.where((e) => e['exercise'] == 'Barbell Squat').toList();
      // Working fives only (a warm-up step is also 5 reps — exclude by
      // weight). Wave-restart top 5 + ONE back-off (3 ×0.5×0.65 → 1),
      // all at the light policy's RPE-6 pricing: 300 × 0.762 → 230.
      final working = squat
          .where((e) => e['reps'] == 5 && (e['weight'] as num) > 200)
          .toList();
      expect(working, hasLength(2));
      for (final e in working) {
        expect(e['weight'], 230);
      }
      // Accessories collapse to min 1 set (×0.5 ×0.65).
      expect(mon.where((e) => e['exercise'] == 'Hanging Leg Raise'),
          hasLength(1));
    });

    test('test week: the top is the block-result single', () {
      // Block 2 week 8 (test): Mon 2027-02-22.
      final feb22 = DateTime.utc(2027, 2, 22);
      final mon = onDay(
          buildWeekPlannedEntries(program, feb22,
              workingMaxes: const {'squat': 300.0}),
          feb22);
      final squat =
          mon.where((e) => e['exercise'] == 'Barbell Squat').toList();
      final single =
          squat.where((e) => e['reps'] == 1 && e['top'] == true).toList();
      // Test policy target 8: 300 × 0.922 = 276.6 → 275.
      expect(single, hasLength(1));
      expect(single.single['weight'], 275);
    });

    test('working-max fill: block-1 reverse policy caps at RPE 7 — '
        'wave top 5 and back-off fives at chart[7][5]', () {
      final entries = buildWeekPlannedEntries(
        program,
        dec14,
        workingMaxes: const {'squat': 300.0},
      );
      final squat = onDay(entries, dec14)
          .where((e) => e['exercise'] == 'Barbell Squat')
          .toList();
      // 300 × 0.786 = 235.8 → 235 for top + back-offs; warm-ups ramp
      // toward 235 (45x10, 95x5, 140x3, 190x1 — the 95x5 step is why
      // working fives are filtered by weight).
      final working = squat
          .where((e) => e['reps'] == 5 && (e['weight'] as num) > 200)
          .toList();
      expect(working, hasLength(4));
      for (final e in working) {
        expect(e['weight'], 235);
      }
      expect(squat.length, working.length + 4); // + the warm-up ramp
    });

    test('reference fallback prices fives at pct_by_reps[5] = 0.80', () {
      final entries = buildWeekPlannedEntries(
        program,
        dec14,
        references: const {'squat': 300.0},
      );
      // Working fives only (the 0.4×top warm-up step is also 5 reps —
      // exclude it by weight).
      final fives = onDay(entries, dec14)
          .where((e) => e['reps'] == 5 && (e['weight'] as num) > 200)
          .toList();
      expect(fives, hasLength(4)); // wave top + 3 back-offs
      for (final e in fives) {
        expect(e['weight'], 240); // 300 × 0.80
      }
    });

    test('accessories never get weights (no main-lift reference)', () {
      final entries = buildWeekPlannedEntries(
        program,
        dec14,
        references: const {
          'squat': 300.0,
          'bench': 250.0,
          'press': 150.0,
          'deadlift': 400.0,
        },
      );
      for (final e in entries) {
        final lift = e['exercise'] as String;
        const mains = {
          'Barbell Squat',
          'Barbell Deadlift',
          'Flat Barbell Bench Press',
          'Overhead Press',
        };
        if (!mains.contains(lift)) {
          expect(e.containsKey('weight'), isFalse, reason: '$e');
        }
      }
    });
  });

  group('live program.yaml v11 — cut weights (wm × wave pct / %TM)', () {
    // The §5 seed values; deadlift pain-capped at RPE 7 in one test.
    const wms = {
      'squat': 320.0,
      'bench': 240.0,
      'deadlift': 330.0,
      'press': 140.0,
    };

    test(
        'key lockdown: generated keys drawn from exactly '
        '{date, exercise, reps, weight, top} — never rpe/notes/pct', () {
      // Block-0 cut weeks + a post-cut (v10) week with wave-top markers.
      for (final monday in [preMonday, w1Monday,
          DateTime.utc(2026, 12, 14)]) {
        final entries = buildWeekPlannedEntries(program, monday,
            references: refs, workingMaxes: wms);
        expect(entries, isNotEmpty);
        for (final e in entries) {
          expect(
              {'date', 'exercise', 'reps', 'weight', 'top'}
                  .containsAll(e.keys),
              isTrue,
              reason: 'unexpected key in $e');
          expect(e.keys.toSet().containsAll({'date', 'exercise', 'reps'}),
              isTrue);
          expect(e.containsKey('rpe'), isFalse);
          expect(e.containsKey('notes'), isFalse);
          expect(e.containsKey('pct'), isFalse);
        }
      }
    });

    test('Monday wk1: squat top at wm × 0.811 (chart[8][5]) with its '
        'ramp; bench volume 4x8 at wm × 0.68; accessories weightless', () {
      final mon = onDay(
          buildWeekPlannedEntries(program, w1Monday,
              references: refs, workingMaxes: wms),
          w1Monday);
      // squat 320 × 0.811 = 259.5 → 260; ramp 45x10, 104→105 x5,
      // 156→155 x3, 208→210 x1. bench 240 × 0.68 = 163.2 → 165; ramp
      // toward 165: 66→65, 99→100, 132→130.
      expect(rows(mon), [
        'Barbell Squat 45x10',
        'Barbell Squat 105x5',
        'Barbell Squat 155x3',
        'Barbell Squat 210x1',
        'Barbell Squat 260x5',
        'Bulgarian Split Squat -x8',
        'Bulgarian Split Squat -x8',
        'Bulgarian Split Squat -x8',
        'Flat Barbell Bench Press 45x10',
        'Flat Barbell Bench Press 65x5',
        'Flat Barbell Bench Press 100x3',
        'Flat Barbell Bench Press 130x1',
        'Flat Barbell Bench Press 165x8',
        'Flat Barbell Bench Press 165x8',
        'Flat Barbell Bench Press 165x8',
        'Flat Barbell Bench Press 165x8',
        'Lateral Dumbbell Raise -x12',
        'Lateral Dumbbell Raise -x12',
        'Lateral Dumbbell Raise -x12',
        'Triceps Extension -x10',
        'Triceps Extension -x10',
      ]);
    });

    test('Wednesday wk1: bench top + 72% back-offs, squat 65%, OHP 62%',
        () {
      final wed = onDay(
          buildWeekPlannedEntries(program, w1Monday,
              references: refs, workingMaxes: wms),
          w1Monday.add(const Duration(days: 2)));
      // bench top 240 × 0.811 = 194.6 → 195 (ramp 80/115/155);
      // back-offs 240 × 0.72 = 172.8 → 175; squat 320 × 0.65 = 208 →
      // 210 (ramp 85/125/170); OHP 140 × 0.62 = 86.8 → 85 (ramp
      // 35/50/70). Pull-ups are weightless accessories.
      expect(rows(wed), [
        'Flat Barbell Bench Press 45x10',
        'Flat Barbell Bench Press 80x5',
        'Flat Barbell Bench Press 115x3',
        'Flat Barbell Bench Press 155x1',
        'Flat Barbell Bench Press 195x5',
        'Flat Barbell Bench Press 175x6',
        'Flat Barbell Bench Press 175x6',
        'Flat Barbell Bench Press 175x6',
        'Barbell Squat 45x10',
        'Barbell Squat 85x5',
        'Barbell Squat 125x3',
        'Barbell Squat 170x1',
        'Barbell Squat 210x8',
        'Barbell Squat 210x8',
        'Barbell Squat 210x8',
        'Overhead Press 45x10',
        'Overhead Press 35x5',
        'Overhead Press 50x3',
        'Overhead Press 70x1',
        'Overhead Press 85x8',
        'Overhead Press 85x8',
        'Overhead Press 85x8',
        'Pull Up -x6',
        'Pull Up -x6',
        'Pull Up -x6',
      ]);
    });

    test('Friday wk1: deadlift top + 75% back-offs (135-rule ramp), '
        'bench 65%', () {
      final fri = onDay(
          buildWeekPlannedEntries(program, w1Monday,
              references: refs, workingMaxes: wms),
          w1Monday.add(const Duration(days: 4)));
      // dl top 330 × 0.811 = 267.6 → 270 (ramp 135x5, 160x3, 215x1);
      // back-offs 330 × 0.75 = 247.5 → 250; bench 240 × 0.65 = 156 →
      // 155 (ramp toward 155: 60/95/125).
      expect(rows(fri), [
        'Barbell Deadlift 135x5',
        'Barbell Deadlift 160x3',
        'Barbell Deadlift 215x1',
        'Barbell Deadlift 270x5',
        'Barbell Deadlift 250x4',
        'Barbell Deadlift 250x4',
        'Romanian Deadlift -x8',
        'Romanian Deadlift -x8',
        'Flat Barbell Bench Press 45x10',
        'Flat Barbell Bench Press 60x5',
        'Flat Barbell Bench Press 95x3',
        'Flat Barbell Bench Press 125x1',
        'Flat Barbell Bench Press 155x8',
        'Flat Barbell Bench Press 155x8',
        'Flat Barbell Bench Press 155x8',
      ]);
    });

    test('wave week 2/3 pcts: 0.837 then 0.863; deload top at 0.70', () {
      num topWeight(DateTime monday) {
        final mon = onDay(
            buildWeekPlannedEntries(program, monday,
                references: refs, workingMaxes: wms),
            monday);
        return mon.firstWhere((e) => e['top'] == true)['weight'] as num;
      }

      // wk2 (Oct 5): 320 × 0.837 = 267.8 → 270 (x4).
      expect(topWeight(DateTime.utc(2026, 10, 5)), 270);
      // wk3 (Oct 12): 320 × 0.863 = 276.2 → 275 (x3).
      expect(topWeight(DateTime.utc(2026, 10, 12)), 275);
      // deload (Oct 19): 320 × 0.70 = 224 → 225 (x5).
      expect(topWeight(DateTime.utc(2026, 10, 19)), 225);
    });

    test('an active RPE cap undercuts the wave pct (pain-capped '
        'deadlift → chart[7][5])', () {
      final fri = onDay(
          buildWeekPlannedEntries(program, w1Monday,
              references: refs,
              workingMaxes: wms,
              capRpeByLift: const {'deadlift': 7}),
          w1Monday.add(const Duration(days: 4)));
      // min(0.811, chart[7][5] = 0.786) → 330 × 0.786 = 259.4 → 260.
      expect(rows(fri), contains('Barbell Deadlift 260x5'));
      // The 75% back-offs sit under chart[7][4] = 0.811 — unchanged.
      expect(rows(fri), contains('Barbell Deadlift 250x4'));
    });

    test('cut_late (Nov 16+) RPE-7 cap softens the wave top the same '
        'way', () {
      // Nov 23 is wave week 1 again (8 whole weeks since the anchor);
      // cut_late's target/cap 7 → min(0.811, 0.786) → 320 × 0.786 =
      // 251.5 → 250.
      final mon = onDay(
          buildWeekPlannedEntries(program, DateTime.utc(2026, 11, 23),
              references: refs, workingMaxes: wms),
          DateTime.utc(2026, 11, 23));
      expect(
          mon.firstWhere((e) => e['top'] == true)['weight'], 250);
    });

    test('%TM rows NEVER price off the reference e1rm — without a '
        'working max the whole cut week is weightless', () {
      final entries = buildWeekPlannedEntries(program, w1Monday,
          references: refs); // references only, no wms
      expect(entries, isNotEmpty);
      for (final e in entries) {
        expect(e.containsKey('weight'), isFalse, reason: '$e');
      }
    });

    test('rounding: every filled weight is a nearest-5 multiple', () {
      final entries = buildWeekPlannedEntries(program, w1Monday,
          references: refs, workingMaxes: wms);
      for (final e in entries) {
        final w = e['weight'];
        if (w is num) expect(w % 5, 0, reason: '$e');
      }
    });

    test('lifts without a working max stay weightless; others fill', () {
      final entries = buildWeekPlannedEntries(program, w1Monday,
          references: refs, workingMaxes: const {'squat': 320.0});
      final mon = onDay(entries, w1Monday);
      expect(rows(mon), contains('Barbell Squat 260x5'));
      // Bench volume has no wm → weightless (never the reference).
      expect(
          mon
              .where((e) =>
                  e['exercise'] == 'Flat Barbell Bench Press' &&
                  e.containsKey('weight'))
              .toList(),
          isEmpty);
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
      expect(buildWeekPlannedEntries({}, w1Monday), isEmpty);
      expect(
          buildWeekPlannedEntries({'versions': []}, w1Monday), isEmpty);
      expect(
          buildWeekPlannedEntries({
            'versions': [
              {'version': 1, 'pending': true},
            ],
          }, w1Monday),
          isEmpty);
    });
  });

  group('regenerateWeek (plan upgrade semantics)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('replaces only this week\'s still-planned week-plan rows, '
        'today-forward', () async {
      final view = _strengthView();
      // Stale leftovers for the target week (Mon + Fri), a user
      // template entry, and next week's plan — only the first two may go.
      final monEntry = PlannedEntry.create(
        view: view,
        date: DateTime(2026, 9, 28),
        values: {'exercise': 'Barbell Squat', 'reps': 5},
        templateName: WeekPlanner.templateLabel,
      );
      final friEntry = PlannedEntry.create(
        view: view,
        date: DateTime(2026, 10, 2),
        values: {'exercise': 'Barbell Deadlift', 'reps': 5},
        templateName: WeekPlanner.templateLabel,
      );
      final userEntry = PlannedEntry.create(
        view: view,
        date: DateTime(2026, 9, 28),
        values: {'exercise': 'Face Pull', 'reps': 15},
        templateName: 'my template',
      );
      final nextWeekEntry = PlannedEntry.create(
        view: view,
        date: DateTime(2026, 10, 5),
        values: {'exercise': 'Barbell Squat', 'reps': 4},
        templateName: WeekPlanner.templateLabel,
      );
      await PlanStore.addAll(
          view, [monEntry, friEntry, userEntry, nextWeekEntry]);
      // Simulate "Monday's top was already logged": Log-now removed it
      // from PlanStore before the upgrade ran.
      await PlanStore.remove(view, monEntry.localId);

      final added = await WeekPlanner.regenerateWeek(
        strengthView: view,
        program: program,
        references: refs,
        targetMonday: DateTime.utc(2026, 9, 28),
        today: DateTime(2026, 9, 30), // Wednesday
      );

      // Today-forward only: Sat/Sun/Mon/Tue are past — the logged
      // Monday squat is NOT re-created. Wed 13 + Thu 9 + Fri 8 rows
      // (skeleton — references only, %TM rows never price off e1rm).
      expect(added, hasLength(30));
      final wed = added
          .where((e) => e.date == DateTime(2026, 9, 30))
          .toList();
      expect(
        [for (final e in wed) '${e.values['exercise']} '
            '${e.values['weight'] ?? '-'}x${e.values['reps']}'],
        containsAll([
          'Flat Barbell Bench Press -x5', // wave wk1 top
          'Barbell Squat -x8', // 65% volume slot (weightless w/o wm)
          'Overhead Press -x8',
          'Pull Up -x6',
        ]),
      );
      for (final e in added) {
        expect(e.templateName, WeekPlanner.templateLabel);
        expect(e.values.containsKey('rpe'), isFalse);
        expect(e.values.containsKey('notes'), isFalse);
      }

      // Store state: old week-plan rows for THIS week gone; the user's
      // template entry and next week's plan untouched.
      final friday = await PlanStore.loadForDate(view, DateTime(2026, 10, 2));
      expect(friday.map((e) => e.localId), isNot(contains(friEntry.localId)));
      expect(friday, hasLength(8));
      final monday = await PlanStore.loadForDate(view, DateTime(2026, 9, 28));
      expect(monday.map((e) => e.localId), [userEntry.localId]);
      final nextMon =
          await PlanStore.loadForDate(view, DateTime(2026, 10, 5));
      expect(nextMon.map((e) => e.localId), [nextWeekEntry.localId]);
    });

    test('planned weights survive the PlanStore JSON round-trip', () async {
      final view = _strengthView();
      await WeekPlanner.regenerateWeek(
        strengthView: view,
        program: program,
        references: refs,
        targetMonday: DateTime.utc(2026, 9, 28),
        today: DateTime(2026, 9, 28),
        workingMaxes: const {'squat': 320.0},
      );
      final monday = await PlanStore.loadForDate(view, DateTime(2026, 9, 28));
      // Squat ramp + wave top: 45x10, 105x5, 155x3, 210x1, 260x5.
      expect(
        [for (final e in monday.take(5)) e.values['weight']],
        [45, 105, 155, 210, 260],
      );
      expect(monday.first.values['weight'], isA<num>());
    });
  });
}
