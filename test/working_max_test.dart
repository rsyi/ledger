// Working-max controller tests — every §7 acceptance item of
// docs/superpowers/specs/2026-09-21-working-max-controller-spec.md
// (airledger repo) plus unit tests for the chart / variants / policies.
//
// §7.1 runs as a REPLAY: the four real bench readings from the spec are
// encoded as fixtures and fed through cut_early with seed 240; the test
// asserts the exact decision sequence (hold, drop→235 cap 8.5, hold,
// drop→230). Policies are parsed from the REAL program.yaml v5 in the
// sibling airledger-fitness checkout so the YAML encoding and the Dart
// parser are pinned together. The lib under test stays pure — only the
// test does IO.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_metrics.dart' show StrengthRow;
import 'package:airledger/services/working_max.dart';

const _fitnessRepo = '../airledger-fitness/coach';

dynamic _loadYamlFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
        'Missing $path — is the airledger-fitness checkout present?');
  }
  return loadYaml(file.readAsStringSync());
}

DateTime _d(String s) => DateTime.parse(s);

void main() {
  final program =
      _loadYamlFile('$_fitnessRepo/program.yaml') as Map<Object?, Object?>;
  final version = currentVersion(program)!;
  final policies = loadPolicies(version);
  LoadPolicy byName(String n) => policies.firstWhere((p) => p.name == n);

  // v12: the live program moved TM movement to `tm_rule`
  // (guarded_implied_max — see guarded_implied_max_test.dart and the
  // shared fixtures); the LEGACY band mechanics below stay pinned
  // against the v11 entry still in the versions history, so the
  // pre-v12 evaluate() path never silently rots.
  final legacyVersion = Map<Object?, Object?>.from(
      (program['versions'] as List).firstWhere(
          (v) => v is Map && v['version'] == 11) as Map);
  final legacyPolicies = loadPolicies(legacyVersion);
  LoadPolicy byLegacyName(String n) =>
      legacyPolicies.firstWhere((p) => p.name == n);

  final cutEarly = byLegacyName('cut_early');
  final cutLate = byLegacyName('cut_late');
  final liftingBlock = byLegacyName('lifting_block');
  final lightWeek = byLegacyName('light_week');
  final testWeek = byLegacyName('test_week');

  Reading heavy({
    required String date,
    String lift = 'bench',
    required double weight,
    int reps = 1,
    required double rpe,
    String kind = 'heavy_top',
    bool grinder = false,
    bool missed = false,
    bool variantMismatch = false,
  }) =>
      Reading(
        date: _d(date),
        lift: lift,
        variant: 'paused',
        weightLb: weight,
        rawWeightLb: weight,
        reps: reps,
        rpe: rpe,
        kind: kind,
        grinder: grinder || rpe >= 9.5,
        missed: missed,
        variantMismatch: variantMismatch,
      );

  // -------------------------------------------------------------------------
  // program.yaml v5 parsing
  // -------------------------------------------------------------------------
  group('load_policies (program.yaml v12 — caps only, bands retired)', () {
    test('all seven policies parse; tm_rule owns TM movement', () {
      expect(policies.map((p) => p.name).toList(), [
        'cut_early',
        'cut_late',
        'reverse',
        'lifting_block',
        'climbing_block',
        'light_week',
        'test_week',
      ]);
      final v12CutEarly = byName('cut_early');
      final v12CutLate = byName('cut_late');
      final v12LightWeek = byName('light_week');
      final v12TestWeek = byName('test_week');
      expect(v12CutEarly.targetRpeHigh, 8);
      expect(v12CutEarly.capRpe, 8.5);
      expect(v12CutEarly.capAfterDropRpe, 8.5);
      expect(v12CutEarly.consecutiveDropsAction, 'no_top_sets_next_week');
      // The band keys are GONE (tm_rule replaces them).
      expect(v12CutEarly.raiseIfRpeLte, isNull);
      expect(v12CutEarly.holdBand, isNull);
      expect(v12CutEarly.dropIfRpeGte, isNull);
      expect(v12CutEarly.readingsThatRaise, isEmpty);
      expect(v12CutEarly.readingsThatLower, isEmpty);
      expect(v12CutEarly.resetOnTest, isFalse);
      expect(v12CutEarly.saturdaySingle, isFalse);
      // Frozen semantics survive ONLY on light weeks; cut_late/reverse/
      // test are unfrozen (the TM tracks implied maxes everywhere,
      // guarded) but keep their RPE caps.
      expect(v12CutLate.frozen, isFalse);
      expect(v12CutLate.capRpe, 7);
      expect(v12LightWeek.frozen, isTrue);
      expect(v12LightWeek.readingsIgnored, isTrue);
      expect(v12TestWeek.frozen, isFalse);
      expect(v12TestWeek.capRpe, 8);
    });

    test('tm_rule parses from the live program (guarded_implied_max)', () {
      final rule = tmRuleOf(version)!;
      expect(rule.raiseCapLb, 5);
      expect(rule.roundingLb, 5);
      expect(rule.minTopFraction, 0.78);
      expect(rule.minDropLbOnGrinder, 5);
      expect(rule.cleanRpeLt, 9);
    });

    test('legacy v11 policies keep their band fields (history pin)', () {
      expect(cutEarly.raiseIfRpeLte, 7);
      expect(cutEarly.raiseRequiresConsecutive, 2);
      expect(cutEarly.holdBand, [7.5, 8.5]);
      expect(cutEarly.dropIfRpeGte, 9);
      expect(cutEarly.readingsThatRaise, ['heavy_top']);
      expect(cutEarly.resetOnTest, isTrue);
      expect(cutEarly.saturdaySingle, isTrue);
      expect(cutLate.frozen, isTrue);
      expect(testWeek.frozen, isTrue);
    });

    test('policyForDate: block-0 date split + week-type overrides', () {
      expect(
          policyForDate(policies, date: _d('2026-11-15'), block: 0)!.name,
          'cut_early');
      expect(
          policyForDate(policies, date: _d('2026-11-16'), block: 0)!.name,
          'cut_late');
      expect(policyForDate(policies, date: _d('2026-12-20'), block: 1)!.name,
          'reverse');
      expect(policyForDate(policies, date: _d('2027-03-02'), block: 3)!.name,
          'lifting_block');
      expect(policyForDate(policies, date: _d('2027-01-10'), block: 2)!.name,
          'climbing_block');
      expect(
          policyForDate(policies,
                  date: _d('2027-03-22'), block: 3, weekType: 'light')!
              .name,
          'light_week');
      expect(
          policyForDate(policies,
                  date: _d('2027-04-20'), block: 3, weekType: 'test')!
              .name,
          'test_week');
    });
  });

  // -------------------------------------------------------------------------
  // §1.3 RPE chart
  // -------------------------------------------------------------------------
  group('rpe chart', () {
    test('chart edge: RPE 7 x 8 reps = 0.707', () {
      expect(rpePct(7, 8), closeTo(0.707, 1e-9));
    });

    test('inside table: RPE 8 x 1 = 0.922, RPE 8.5 x 1 = 0.939', () {
      expect(rpePct(8, 1), closeTo(0.922, 1e-9));
      expect(rpePct(8.5, 1), closeTo(0.939, 1e-9));
    });

    test('outside table falls back to inverted Epley (rpe 8, reps 10)', () {
      // pct = 1 / (1 + (10 + (10 - 8)) / 30) = 1 / 1.4
      expect(rpePct(8, 10), closeTo(1 / 1.4, 1e-12));
      // reps 7 is not a chart column either
      expect(rpePct(9, 7), closeTo(1 / (1 + (7 + 1) / 30), 1e-12));
    });

    test('Dart chart matches program.yaml v5 rpe_chart verbatim', () {
      final chart = version['rpe_chart'] as Map;
      final byRpe = chart['pct_by_rpe_reps'] as Map;
      byRpe.forEach((rpeKey, repsMap) {
        final rpe = double.parse(rpeKey.toString());
        (repsMap as Map).forEach((repsKey, pct) {
          final reps = int.parse(repsKey.toString());
          expect(rpePct(rpe, reps), closeTo((pct as num) / 100, 1e-9),
              reason: 'chart[$rpe][$reps]');
        });
      });
    });

    test('impliedMax = weight / chart pct', () {
      // 230x1@9 -> 230 / 0.955 = 240.8...
      expect(impliedMax(230, 1, 9), closeTo(230 / 0.955, 1e-9));
    });
  });

  // -------------------------------------------------------------------------
  // §1.4 variants
  // -------------------------------------------------------------------------
  group('variants', () {
    test('unknown / empty notes -> lift default, factor 1', () {
      final v = parseVariant('bench', null);
      expect(v.variant, 'paused');
      expect(v.factor, 1.0);
      expect(v.mismatch, isFalse);
      expect(parseVariant('squat', 'felt heavy').variant, 'belted');
      expect(parseVariant('press', '').variant, 'standard');
    });

    test('§7.4 touch-and-go bench divides by 1.03 before comparison', () {
      final v = parseVariant('bench', 'touch and go');
      expect(v.factor, closeTo(1.03, 1e-12));
      expect(v.mismatch, isFalse);
      final rows = [
        StrengthRow(
            date: _d('2026-08-17'),
            exercise: 'Flat Barbell Bench Press',
            weight: 247.2,
            reps: 1,
            rpe: 8,
            notes: 'touch and go'),
      ];
      final r = extractReadings(rows, kindOf: (_, _) => 'heavy_top').single;
      expect(r.rawWeightLb, 247.2);
      expect(r.weightLb, closeTo(247.2 / 1.03, 1e-9));
      expect(r.impliedMax, closeTo(247.2 / 1.03 / 0.922, 1e-9));
    });

    test('pins = paused (bench, no conversion)', () {
      final v = parseVariant('bench', 'off pins');
      expect(v.factor, 1.0);
      expect(v.mismatch, isFalse);
    });

    test('squat unbelted / paused -3%; "belted, paused" -3% once', () {
      expect(parseVariant('squat', 'unbelted').factor, closeTo(0.97, 1e-12));
      expect(parseVariant('squat', 'paused').factor, closeTo(0.97, 1e-12));
      final both = parseVariant('squat', 'belted, paused');
      expect(both.factor, closeTo(0.97, 1e-12),
          reason: '"belted, paused" is a single -3%, never stacked');
      expect(both.mismatch, isFalse);
    });

    test('deadlift unbelted -4%; straps / double overhand no change', () {
      expect(parseVariant('deadlift', 'unbelted').factor, closeTo(0.96, 1e-12));
      expect(parseVariant('deadlift', 'straps').factor, 1.0);
      expect(parseVariant('deadlift', 'double overhand').factor, 1.0);
    });

    test('in-scope keyword with no conversion for the lift -> mismatch', () {
      expect(parseVariant('deadlift', 'paused at floor').mismatch, isTrue);
      expect(parseVariant('deadlift', 'touch and go').mismatch, isTrue);
      expect(parseVariant('squat', 'off pins').mismatch, isTrue);
    });

    test('out-of-scope keywords are gear notes, never variants', () {
      // The real Sep 14 2026 bench note: wrist straps, not lifting straps
      // — §7.1 expects that reading to DROP, so it must not mismatch.
      final v = parseVariant('bench', 'straps, paused');
      expect(v.mismatch, isFalse);
      expect(v.variant, 'paused');
      expect(v.factor, 1.0);
      expect(parseVariant('bench', 'belted').variant, 'paused');
      expect(parseVariant('press', 'belted').variant, 'standard');
      expect(parseVariant('press', 'belted').mismatch, isFalse);
      expect(parseVariant('squat', 'straps').variant, 'belted');
    });

    test('structured belted flag wins over notes keywords', () {
      // Explicit false beats a 'belted' note (post-hardening row edited
      // after the fact) — and vice versa.
      expect(
        parseVariant('squat', 'belted', belted: false).factor,
        closeTo(0.97, 1e-12),
      );
      expect(
        parseVariant('squat', 'no belt today', belted: true).factor,
        1.0,
      );
      expect(parseVariant('deadlift', null, belted: false).factor,
          closeTo(0.96, 1e-12));
      expect(parseVariant('deadlift', null, belted: true).factor, 1.0);
      // Notes outside the belted domain still apply alongside the flag.
      final v = parseVariant('deadlift', 'straps', belted: false);
      expect(v.variant, contains('unbelted'));
      expect(v.factor, closeTo(0.96, 1e-12));
    });

    test('structured paused flag: bench false = touch-and-go', () {
      expect(parseVariant('bench', null, paused: true).variant, 'paused');
      expect(parseVariant('bench', null, paused: true).factor, 1.0);
      final tng = parseVariant('bench', null, paused: false);
      expect(tng.variant, 'touch_and_go');
      expect(tng.factor, closeTo(1.03, 1e-12));
      // paused=false overrides a stale 'paused' note.
      expect(parseVariant('bench', 'paused', paused: false).variant,
          'touch_and_go');
      // Squat: paused=true is the -3% variant; false = default, no keyword.
      expect(parseVariant('squat', null, paused: true).factor,
          closeTo(0.97, 1e-12));
      expect(parseVariant('squat', null, paused: false).variant, 'belted');
      expect(parseVariant('squat', null, paused: false).factor, 1.0);
    });

    test('structured flags out of scope are ignored (belted bench/press)',
        () {
      expect(parseVariant('bench', null, belted: true).variant, 'paused');
      expect(parseVariant('bench', null, belted: true).mismatch, isFalse);
      expect(parseVariant('press', null, belted: false).variant, 'standard');
    });

    test('null flags = legacy notes-only behavior, unchanged', () {
      expect(parseVariant('squat', 'unbelted').factor, closeTo(0.97, 1e-12));
      expect(parseVariant('bench', 'touch and go').factor,
          closeTo(1.03, 1e-12));
    });

    test('extraction prefers structured flags on the reading row', () {
      final rows = [
        StrengthRow(
            date: _d('2026-09-22'),
            exercise: 'Barbell Squat',
            weight: 290,
            reps: 1,
            rpe: 8,
            notes: 'belted', // stale note...
            belted: false), // ...explicit flag wins
      ];
      final r = extractReadings(rows, kindOf: (_, _) => 'heavy_top').single;
      expect(r.variant, 'unbelted');
      expect(r.weightLb, closeTo(290 / 0.97, 1e-9));
      expect(r.rawWeightLb, 290);
    });
  });

  // -------------------------------------------------------------------------
  // Reading extraction
  // -------------------------------------------------------------------------
  group('reading extraction', () {
    test('heaviest-with-rpe row of the day per lift becomes the reading', () {
      final rows = [
        // warmups without rpe are never readings
        StrengthRow(
            date: _d('2026-08-17'),
            exercise: 'Flat Barbell Bench Press',
            weight: 135,
            reps: 5),
        StrengthRow(
            date: _d('2026-08-17'),
            exercise: 'Flat Barbell Bench Press',
            weight: 230,
            reps: 1,
            rpe: 8),
        StrengthRow(
            date: _d('2026-08-17'),
            exercise: 'Flat Barbell Bench Press',
            weight: 205,
            reps: 3,
            rpe: 7),
        // accessories are not main lifts -> no reading
        StrengthRow(
            date: _d('2026-08-17'),
            exercise: 'Incline Dumbbell Press',
            weight: 80,
            reps: 8,
            rpe: 8),
      ];
      final readings = extractReadings(rows, kindOf: (_, _) => 'heavy_top');
      expect(readings, hasLength(1));
      expect(readings.single.weightLb, 230);
      expect(readings.single.rpe, 8);
    });

    test('grinder: rpe >= 9.5 or notes match /grind|slow|stall|miss/', () {
      Reading one(double rpe, String? notes) => extractReadings([
            StrengthRow(
                date: _d('2026-08-17'),
                exercise: 'Barbell Squat',
                weight: 300,
                reps: 1,
                rpe: rpe,
                notes: notes),
          ], kindOf: (_, _) => 'heavy_top')
              .single;
      expect(one(9.5, null).grinder, isTrue);
      expect(one(9, 'slow off the chest').grinder, isTrue);
      expect(one(9, 'ground it out').grinder, isFalse); // 'ground' != 'grind'
      expect(one(8, 'stalled halfway').grinder, isTrue);
      expect(one(8, null).grinder, isFalse);
    });

    test('missed: reps < prescribed', () {
      final r = extractReadings(
        [
          StrengthRow(
              date: _d('2026-08-17'),
              exercise: 'Barbell Deadlift',
              weight: 315,
              reps: 2,
              rpe: 9),
        ],
        kindOf: (_, _) => 'heavy_top',
        prescribedReps: (_, _) => 3,
      ).single;
      expect(r.missed, isTrue);
    });

    test('classifyKind: week type, cap, saturday single', () {
      expect(
          classifyKind(
              lift: 'bench', date: _d('2027-03-22'), weekType: 'light'),
          'light_week');
      expect(
          classifyKind(lift: 'bench', date: _d('2027-04-20'), weekType: 'test'),
          'test');
      expect(
          classifyKind(lift: 'bench', date: _d('2026-09-07'), capActive: true),
          'capped');
      // 2026-09-26 is a Saturday.
      expect(
          classifyKind(
              lift: 'bench', date: _d('2026-09-26'), saturdaySingle: true),
          'saturday_single');
      expect(
          classifyKind(
              lift: 'deadlift', date: _d('2026-09-26'), saturdaySingle: true),
          'heavy_top');
      expect(classifyKind(lift: 'bench', date: _d('2026-09-22')), 'heavy_top');
    });
  });

  // -------------------------------------------------------------------------
  // §7.1 — REPLAY: the four real bench readings, cut_early, seed 240
  // -------------------------------------------------------------------------
  group('§7.1 bench replay (cut_early, seed 240)', () {
    final rows = [
      StrengthRow(
          date: _d('2026-08-17'),
          exercise: 'Flat Barbell Bench Press',
          weight: 230,
          reps: 1,
          rpe: 8),
      StrengthRow(
          date: _d('2026-08-24'),
          exercise: 'Flat Barbell Bench Press',
          weight: 230,
          reps: 1,
          rpe: 9),
      StrengthRow(
          date: _d('2026-09-07'),
          exercise: 'Flat Barbell Bench Press',
          weight: 185,
          reps: 5,
          rpe: 7,
          notes: 'paused'),
      StrengthRow(
          date: _d('2026-09-14'),
          exercise: 'Flat Barbell Bench Press',
          weight: 230,
          reps: 1,
          rpe: 9,
          notes: 'paused'),
    ];

    test('decision sequence: hold, drop→235 cap 8.5, hold, drop→230', () {
      final decisions = replayLift(
        lift: 'bench',
        seedWm: 240,
        rows: rows,
        policyFor: (_) => cutEarly,
      );
      expect(decisions, hasLength(4));
      expect([for (final d in decisions) d.action],
          ['hold', 'drop', 'hold', 'drop']);
      expect([for (final d in decisions) d.wmAfter], [240, 235, 235, 230]);
      expect(decisions[1].capNextTopSetRpe, 8.5);
      // Aug 24 drop caps the NEXT top set -> Sep 7 reading is kind=capped
      // (extraction-rule interpretation; capped is not in
      // readings_that_raise, so its RPE-7 still holds).
      expect(decisions[2].reading!.kind, 'capped');
      // Drops were not consecutive (hold in between).
      expect(decisions.any((d) => d.noTopSetsNextWeek), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // §7.2 — light week readings never change any wm
  // -------------------------------------------------------------------------
  group('§7.2 light week', () {
    test('even grinders / drop-worthy RPEs hold under light_week', () {
      for (final rpe in [7.0, 9.0, 9.9]) {
        final d = evaluate(
          lift: 'squat',
          policy: lightWeek,
          workingMax: 320,
          date: _d('2027-03-24'),
          reading: heavy(
              date: '2027-03-24',
              lift: 'squat',
              weight: 315,
              rpe: rpe,
              kind: 'light_week'),
        );
        expect(d.action, 'hold', reason: 'rpe $rpe');
        expect(d.wmAfter, 320, reason: 'rpe $rpe');
      }
    });

    test('week 5 resumes at week 3\'s number', () {
      // Week 3 (lifting_block): rpe 7 raise -> 325 (v9 raise trigger).
      final d3 = evaluate(
        lift: 'squat',
        policy: liftingBlock,
        workingMax: 320,
        date: _d('2027-03-15'),
        reading:
            heavy(date: '2027-03-15', lift: 'squat', weight: 300, rpe: 7),
      );
      expect(d3.action, 'raise');
      expect(d3.wmAfter, 325);
      // Week 4 (light): grinder reading, ignored.
      final d4 = evaluate(
        lift: 'squat',
        policy: lightWeek,
        workingMax: d3.wmAfter,
        date: _d('2027-03-24'),
        reading: heavy(
            date: '2027-03-24',
            lift: 'squat',
            weight: 315,
            rpe: 9.5,
            kind: 'light_week'),
        priorDecisions: [d3],
      );
      expect(d4.action, 'hold');
      // Week 5 starts from week 3's number.
      expect(d4.wmAfter, 325);
    });
  });

  // -------------------------------------------------------------------------
  // §7.3 — test single resets wm (/0.922, round DOWN to 5)
  // -------------------------------------------------------------------------
  group('§7.3 test reset', () {
    test('240x1 -> 260; 245x1 -> 265', () {
      final d1 = evaluate(
        lift: 'bench',
        policy: testWeek,
        workingMax: 250,
        date: _d('2027-04-20'),
        reading: heavy(
            date: '2027-04-20', weight: 240, rpe: 8, kind: 'test'),
      );
      expect(d1.action, 'reset');
      expect(d1.source, 'test');
      expect(d1.wmAfter, 260); // 240 / 0.922 = 260.3 -> round DOWN to 260
      final d2 = evaluate(
        lift: 'bench',
        policy: testWeek,
        workingMax: 250,
        date: _d('2027-04-20'),
        reading: heavy(
            date: '2027-04-20', weight: 245, rpe: 8, kind: 'test'),
      );
      expect(d2.wmAfter, 265); // 245 / 0.922 = 265.7 -> 265
    });
  });

  // -------------------------------------------------------------------------
  // §7.5 — pain cap
  // -------------------------------------------------------------------------
  group('§7.5 pain cap', () {
    test('"back" note maps to squat+deadlift; elbow/finger to press+bench',
        () {
      expect(painCapLiftsForNote('lower back tweaked on the last pull'),
          ['squat', 'deadlift']);
      expect(painCapLiftsForNote('elbow flare-up'), ['press', 'bench']);
      expect(painCapLiftsForNote('left middle finger pulley'),
          ['press', 'bench']);
      expect(painCapLiftsForNote('slept badly'), isEmpty);
    });

    test('freeze + cap 7; two consecutive clean heavy sessions lift it', () {
      final d1 = evaluate(
        lift: 'squat',
        policy: cutEarly,
        workingMax: 320,
        date: _d('2026-09-21'),
        reading: heavy(
            date: '2026-09-21', lift: 'squat', weight: 275, rpe: 7),
        painCapActive: true,
      );
      expect(d1.action, 'freeze');
      expect(d1.source, 'pain_cap');
      expect(d1.capNextTopSetRpe, 7);
      expect(d1.wmAfter, 320);
      expect(d1.flags, contains('PAIN_CAP'));
      expect(d1.flags, contains('PAIN_CAP_CLEAN'));
      expect(d1.flags, isNot(contains('PAIN_CAP_LIFTED')));

      final d2 = evaluate(
        lift: 'squat',
        policy: cutEarly,
        workingMax: 320,
        date: _d('2026-09-28'),
        reading: heavy(
            date: '2026-09-28', lift: 'squat', weight: 285, rpe: 7),
        priorDecisions: [d1],
        painCapActive: true,
      );
      expect(d2.flags, contains('PAIN_CAP_LIFTED'));
      expect(d2.wmAfter, 320);

      // A grinder is not a clean session — streak broken, cap stays.
      final dirty = evaluate(
        lift: 'squat',
        policy: cutEarly,
        workingMax: 320,
        date: _d('2026-09-28'),
        reading: heavy(
            date: '2026-09-28',
            lift: 'squat',
            weight: 305,
            rpe: 9.5),
        priorDecisions: [d1],
        painCapActive: true,
      );
      expect(dirty.flags, isNot(contains('PAIN_CAP_LIFTED')));
      expect(dirty.flags, isNot(contains('PAIN_CAP_CLEAN')));
    });
  });

  // -------------------------------------------------------------------------
  // §7.6 — two weeks without a reading -> NO_READING
  // -------------------------------------------------------------------------
  group('§7.6 NO_READING', () {
    test('one readingless week holds silently; two flags NO_READING', () {
      final one = evaluate(
        lift: 'press',
        policy: cutEarly,
        workingMax: 140,
        date: _d('2026-09-28'),
        weeksWithoutReading: 1,
      );
      expect(one.action, 'hold');
      expect(one.flags, isNot(contains('NO_READING')));
      final two = evaluate(
        lift: 'press',
        policy: cutEarly,
        workingMax: 140,
        date: _d('2026-10-05'),
        weeksWithoutReading: 2,
      );
      expect(two.action, 'hold');
      expect(two.wmAfter, 140);
      expect(two.flags, contains('NO_READING'));
    });
  });

  // -------------------------------------------------------------------------
  // §7.7 — a policy switch never changes wm by itself
  // -------------------------------------------------------------------------
  group('§7.7 policy switch', () {
    test('cut_early -> cut_late boundary leaves wm untouched', () {
      // Nov 15: cut_early; Nov 16: cut_late. No reading either day.
      final before = evaluate(
        lift: 'bench',
        policy: policyForDate(policies, date: _d('2026-11-15'), block: 0)!,
        workingMax: 235,
        date: _d('2026-11-15'),
      );
      final after = evaluate(
        lift: 'bench',
        policy: policyForDate(policies, date: _d('2026-11-16'), block: 0)!,
        workingMax: before.wmAfter,
        date: _d('2026-11-16'),
        priorDecisions: [before],
      );
      expect(before.wmAfter, 235);
      expect(after.action, 'hold');
      expect(after.wmAfter, 235);
    });
  });

  // -------------------------------------------------------------------------
  // Controller rules beyond the §7 list
  // -------------------------------------------------------------------------
  group('evaluate: raise/drop mechanics', () {
    test('cut_early raises only on the second consecutive rpe<=7 reading',
        () {
      final d1 = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-22'),
        reading: heavy(date: '2026-09-22', weight: 220, rpe: 7),
      );
      expect(d1.action, 'hold');
      expect(d1.raiseEligible, isTrue);
      final d2 = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-29'),
        reading: heavy(date: '2026-09-29', weight: 220, rpe: 7),
        priorDecisions: [d1],
      );
      expect(d2.action, 'raise');
      expect(d2.wmAfter, 245);
      // Streak is consumed by the raise.
      expect(d2.raiseEligible, isFalse);
    });

    test('a drop between good days breaks the raise streak', () {
      final d1 = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-22'),
        reading: heavy(date: '2026-09-22', weight: 220, rpe: 7),
      );
      final d2 = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-29'),
        reading: heavy(date: '2026-09-29', weight: 230, rpe: 9),
        priorDecisions: [d1],
      );
      expect(d2.action, 'drop');
      final d3 = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: d2.wmAfter,
        date: _d('2026-10-06'),
        reading: heavy(date: '2026-10-06', weight: 220, rpe: 7),
        priorDecisions: [d1, d2],
      );
      expect(d3.action, 'hold', reason: 'streak restarted after the drop');
    });

    test('lifting_block raises on a single rpe<=7 reading (v9: post-cut '
        'heavy = RPE 7-8, raise at <= 7; rpe 8 holds)', () {
      final d = evaluate(
        lift: 'squat',
        policy: liftingBlock,
        workingMax: 320,
        date: _d('2027-03-08'),
        reading: heavy(date: '2027-03-08', lift: 'squat', weight: 300, rpe: 7),
      );
      expect(d.action, 'raise');
      expect(d.wmAfter, 325);
      final hold = evaluate(
        lift: 'squat',
        policy: liftingBlock,
        workingMax: 320,
        date: _d('2027-03-08'),
        reading: heavy(date: '2027-03-08', lift: 'squat', weight: 305, rpe: 8),
      );
      expect(hold.action, 'hold');
    });

    test('grinder and missed drop even below the rpe threshold', () {
      final g = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-22'),
        reading: heavy(
            date: '2026-09-22', weight: 225, rpe: 8, grinder: true),
      );
      expect(g.action, 'drop');
      final m = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-22'),
        reading:
            heavy(date: '2026-09-22', weight: 225, rpe: 8, missed: true),
      );
      expect(m.action, 'drop');
    });

    test('frozen policy: drop rule still runs, raises never do', () {
      final drop = evaluate(
        lift: 'bench',
        policy: cutLate,
        workingMax: 235,
        date: _d('2026-11-20'),
        reading: heavy(date: '2026-11-20', weight: 215, rpe: 8.5),
      );
      expect(drop.action, 'drop');
      expect(drop.wmAfter, 230);
      final hold = evaluate(
        lift: 'bench',
        policy: cutLate,
        workingMax: 235,
        date: _d('2026-11-20'),
        reading: heavy(date: '2026-11-20', weight: 205, rpe: 6),
      );
      expect(hold.action, 'hold');
    });

    test('two consecutive drops fire no_top_sets_next_week', () {
      final d1 = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-22'),
        reading: heavy(date: '2026-09-22', weight: 235, rpe: 9),
      );
      expect(d1.action, 'drop');
      expect(d1.noTopSetsNextWeek, isFalse);
      final d2 = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: d1.wmAfter,
        date: _d('2026-09-29'),
        reading: heavy(date: '2026-09-29', weight: 230, rpe: 9),
        priorDecisions: [d1],
      );
      expect(d2.action, 'drop');
      expect(d2.noTopSetsNextWeek, isTrue);
    });

    test('VARIANT_MISMATCH holds (no conversion, deviation prompt)', () {
      final d = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-22'),
        reading: heavy(
            date: '2026-09-22', weight: 250, rpe: 9, variantMismatch: true),
      );
      expect(d.action, 'hold');
      expect(d.wmAfter, 240);
      expect(d.flags, contains('VARIANT_MISMATCH'));
    });

    test('TWO_SIGNALS freezes the week', () {
      final d = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-22'),
        reading: heavy(date: '2026-09-22', weight: 220, rpe: 7),
        twoSignalsThisWeek: true,
      );
      expect(d.action, 'freeze');
      expect(d.wmAfter, 240);
      expect(d.flags, contains('TWO_SIGNALS'));
    });

    test('MANUAL applies immediately', () {
      final d = evaluate(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        date: _d('2026-09-22'),
        manualValue: 250,
        manualReason: 'user set it in chat',
      );
      expect(d.action, 'manual');
      expect(d.source, 'manual');
      expect(d.wmAfter, 250);
    });

    test('roundDown5 rounds DOWN to the 5', () {
      expect(roundDown5(260.30), 260);
      expect(roundDown5(265.72), 265);
      expect(roundDown5(265.0), 265);
      expect(roundDown5(264.99), 260);
    });
  });

  // -------------------------------------------------------------------------
  // §4 prescription
  // -------------------------------------------------------------------------
  group('prescription', () {
    final warmup = version['warmup_protocol'];

    test('cut_early bench wm 240: top options, back-offs, sat single', () {
      final p = buildPrescription(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        warmupProtocol: warmup,
      );
      expect(p.policyName, 'cut_early');
      // target = upper end of target_rpe (8): chart 0.922/0.892/0.863.
      expect(p.topSetOptions[1], 220); // 221.28 -> 220
      expect(p.topSetOptions[2], 215); // 214.08 -> 215
      expect(p.topSetOptions[3], 205); // 207.12 -> 205
      // back-offs 4x3 at 82% (mid of 81-83).
      expect(p.backOffSets, 4);
      expect(p.backOffReps, 3);
      expect(p.backOffWeight, 195); // 196.8 -> 195
      // Saturday single at 8.5 where the policy allows.
      expect(p.saturdaySingle, 225); // 0.939*240 = 225.36 -> 225
      // Warm-ups ramp toward the top single (220) via v4 protocol.
      expect(
          [for (final w in p.warmups) [w.weight, w.reps]],
          [
            [45, 10],
            [90, 5], // 0.40*220 = 88 -> 90
            [130, 3], // 0.60*220 = 132 -> 130
            [175, 1], // 0.80*220 = 176 -> 175
          ]);
    });

    test('cut_late omits the saturday single; cap lowers the target', () {
      final p = buildPrescription(
        lift: 'bench',
        policy: cutLate,
        workingMax: 235,
        warmupProtocol: warmup,
      );
      expect(p.saturdaySingle, isNull);
      // target 7 -> chart[7][1] = 0.892 -> 209.6 -> 210.
      expect(p.topSetOptions[1], 210);

      final capped = buildPrescription(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        warmupProtocol: warmup,
        activeCapRpe: 7,
      );
      // Cap 7 undercuts the policy target 8.
      expect(capped.topSetOptions[1], 215); // 0.892*240 = 214.08 -> 215
    });

    test('deadlift warm-ups honor the 135 rule', () {
      final p = buildPrescription(
        lift: 'deadlift',
        policy: cutEarly,
        workingMax: 330,
        warmupProtocol: warmup,
      );
      // top single: 0.922*330 = 304.26 -> 305; 0.6*305=183->185, 0.8*305=244->245
      expect(p.topSetOptions[1], 305);
      expect(
          [for (final w in p.warmups) [w.weight, w.reps]],
          [
            [135, 5],
            [185, 3],
            [245, 1],
          ]);
    });

    test('cut wave topPct prices the single option; caps still undercut '
        '(program.yaml v11 strength_wave_cut)', () {
      // Week-1 five: pct 0.811 == chart[8][5] at cut_early's target 8.
      final p = buildPrescription(
        lift: 'squat',
        policy: cutEarly,
        workingMax: 320,
        topReps: 5,
        topPct: 0.811,
      );
      expect(p.topSetOptions.keys.toList(), [5]);
      expect(p.topSetOptions[5], 260); // 320 × 0.811 = 259.5 → 260
      // Deload 0.70 undercuts the chart price.
      final deload = buildPrescription(
        lift: 'squat',
        policy: cutEarly,
        workingMax: 320,
        topReps: 5,
        topPct: 0.70,
      );
      expect(deload.topSetOptions[5], 225); // 320 × 0.70 = 224 → 225
      // An active RPE cap (pain cap 7) wins over the wave pct:
      // min(0.811, chart[7][5] = 0.786) → 330 × 0.786 = 259.4 → 260.
      final capped = buildPrescription(
        lift: 'deadlift',
        policy: cutEarly,
        workingMax: 330,
        topReps: 5,
        topPct: 0.811,
        activeCapRpe: 7,
      );
      expect(capped.topSetOptions[5], 260);
    });

    test('microplates round bench/press to 2.5', () {
      final p = buildPrescription(
        lift: 'bench',
        policy: cutEarly,
        workingMax: 240,
        warmupProtocol: warmup,
        microplates: true,
      );
      expect(p.topSetOptions[1], 222.5); // 221.28 -> 222.5
    });
  });
}
