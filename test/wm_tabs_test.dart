// Tests for the pure working-max tab layer (WM-2): sheet-row codecs,
// §5 seeds, tab-state reconstruction, and the nightly evaluation chain
// (runWmChain) that appends readings + working_max rows on top of the
// WM-1 controller. Policies come from the REAL program.yaml v5 so the
// YAML contract stays pinned.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_metrics.dart' show StrengthRow;
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/services/working_max.dart';

const _fitnessRepo = '../airledger-fitness/coach';

DateTime _d(String s) => DateTime.parse(s);

void main() {
  final program = loadYaml(
          File('$_fitnessRepo/program.yaml').readAsStringSync())
      as Map<Object?, Object?>;
  // The chain-mechanics tests pin the LEGACY band behavior against the
  // v11 entry still in the versions history (the live v12 program moved
  // TM movement to tm_rule — chain runs under it are covered below).
  final legacyVersion = Map<Object?, Object?>.from(
      (program['versions'] as List)
          .firstWhere((v) => v is Map && v['version'] == 11) as Map);
  final policies = loadPolicies(legacyVersion);
  final cutEarly = policies.firstWhere((p) => p.name == 'cut_early');
  final testWeek = policies.firstWhere((p) => p.name == 'test_week');
  LoadPolicy? always(DateTime _) => cutEarly;

  StrengthRow bench(String date, double w, int reps, double rpe,
          [String? notes]) =>
      StrengthRow(
          date: _d(date),
          exercise: 'Flat Barbell Bench Press',
          weight: w,
          reps: reps,
          rpe: rpe,
          notes: notes);

  StrengthRow deadlift(String date, double w, int reps, double rpe) =>
      StrengthRow(
          date: _d(date),
          exercise: 'Barbell Deadlift',
          weight: w,
          reps: reps,
          rpe: rpe);

  // ---------------------------------------------------------------------
  // §5 seeds
  // ---------------------------------------------------------------------
  group('seedWorkingMaxRows', () {
    final seeds = seedWorkingMaxRows();

    test('four §5 value rows + the deadlift pain_cap marker', () {
      expect(seeds, hasLength(5));
      final byLift = {
        for (final r in seeds.where((r) => r.source == 'seed')) r.lift: r,
      };
      expect(byLift['bench']!.valueLb, 240);
      expect(byLift['bench']!.variant, 'paused');
      expect(byLift['squat']!.valueLb, 320);
      expect(byLift['squat']!.variant, 'belted');
      expect(byLift['deadlift']!.valueLb, 330);
      expect(byLift['deadlift']!.variant, 'belted');
      expect(byLift['press']!.valueLb, 140);
      expect(byLift['press']!.variant, 'standard');
      for (final r in byLift.values) {
        expect(r.source, 'seed');
        expect(r.confirmed, isFalse, reason: '${r.lift} pending');
        expect(r.effectiveFrom, DateTime.utc(2026, 9, 21));
      }
      final painCap = seeds.last;
      expect(painCap.lift, 'deadlift');
      expect(painCap.source, 'pain_cap');
      expect(painCap.valueLb, 330);
      expect(painCap.confirmed, isNull); // marker rows carry no confirm bit
      expect(painCap.reason, contains('RPE 7'));
    });

    test('pain_cap marker makes the deadlift cap active from seed', () {
      expect(painCapActive(seeds, 'deadlift'), isTrue);
      expect(painCapActive(seeds, 'squat'), isFalse);
      // A later "pain cap lifted" row clears it.
      final lifted = [
        ...seeds,
        WorkingMaxRow(
            lift: 'deadlift',
            variant: 'belted',
            valueLb: 330,
            effectiveFrom: _d('2026-10-01'),
            source: 'rule',
            reason: '$painCapLiftedReasonPrefix — two consecutive clean '
                'heavy sessions',
            readingId: '2026-10-01|deadlift'),
      ];
      expect(painCapActive(lifted, 'deadlift'), isFalse);
    });
  });

  // ---------------------------------------------------------------------
  // Codecs
  // ---------------------------------------------------------------------
  group('sheet codecs', () {
    test('WorkingMaxRow round-trips through sheet cells (string cells)', () {
      final row = WorkingMaxRow(
          lift: 'bench',
          variant: 'paused',
          valueLb: 240,
          effectiveFrom: DateTime.utc(2026, 9, 21),
          source: 'seed',
          reason: 'seed reason',
          readingId: '',
          confirmed: false);
      final head = {
        for (var i = 0; i < wmTabHeaders.length; i++) wmTabHeaders[i]: i,
      };
      // Simulate the Sheets read path: everything comes back as strings.
      final cells = [for (final c in row.toSheetRow()) '$c'];
      final back = WorkingMaxRow.fromCells(head, cells)!;
      expect(back.lift, 'bench');
      expect(back.variant, 'paused');
      expect(back.valueLb, 240);
      expect(back.effectiveFrom, DateTime.utc(2026, 9, 21));
      expect(back.source, 'seed');
      expect(back.reason, 'seed reason');
      expect(back.confirmed, isFalse);
      // Marker rows: empty confirmed cell -> null.
      final marker = WorkingMaxRow.fromCells(
          head, ['deadlift', 'belted', '330', '2026-09-21', 'pain_cap',
          'r', '', ''])!;
      expect(marker.confirmed, isNull);
      // TRUE from a sheet checkbox parses too.
      final confirmed = WorkingMaxRow.fromCells(
          head, ['bench', 'paused', '240', '2026-09-21', 'seed',
          'r', '', 'TRUE'])!;
      expect(confirmed.confirmed, isTrue);
    });

    test('ReadingRow round-trips through sheet cells', () {
      final row = ReadingRow(
          id: '2026-09-22|bench',
          date: DateTime.utc(2026, 9, 22),
          lift: 'bench',
          variant: 'paused',
          weightLb: 225,
          reps: 1,
          rpe: 8.5,
          kind: 'heavy_top',
          grinder: false,
          missed: false,
          impliedMax: 239.6,
          decision: 'hold',
          wmAfter: 240);
      final head = {
        for (var i = 0; i < readingsTabHeaders.length; i++)
          readingsTabHeaders[i]: i,
      };
      final cells = [for (final c in row.toSheetRow()) '$c'];
      final back = ReadingRow.fromCells(head, cells)!;
      expect(back.id, '2026-09-22|bench');
      expect(back.date, DateTime.utc(2026, 9, 22));
      expect(back.weightLb, 225);
      expect(back.reps, 1);
      expect(back.rpe, 8.5);
      expect(back.grinder, isFalse);
      expect(back.impliedMax, 239.6);
      expect(back.decision, 'hold');
      expect(back.wmAfter, 240);
    });
  });

  // ---------------------------------------------------------------------
  // Tab-state helpers
  // ---------------------------------------------------------------------
  group('tab state', () {
    final seeds = seedWorkingMaxRows();

    test('currentWorkingMax: last row per lift wins (incl. markers)', () {
      // Deadlift's last row is the pain_cap marker — value is still 330.
      expect(currentWorkingMax(seeds, 'deadlift')!.valueLb, 330);
      expect(currentWorkingMax(seeds, 'bench')!.valueLb, 240);
      expect(currentWorkingMax(seeds, 'kettlebell'), isNull);
      final withManual = [
        ...seeds,
        WorkingMaxRow(
            lift: 'bench',
            variant: 'paused',
            valueLb: 250,
            effectiveFrom: _d('2026-09-25'),
            source: 'manual',
            reason: 'felt strong',
            readingId: '',
            confirmed: true),
      ];
      expect(currentWorkingMax(withManual, 'bench')!.valueLb, 250);
    });

    test('needsConfirmation: seed pending until a confirmed row lands', () {
      for (final lift in ['bench', 'squat', 'deadlift', 'press']) {
        expect(needsConfirmation(seeds, lift), isTrue, reason: lift);
      }
      final confirmed = [
        ...seeds,
        WorkingMaxRow(
            lift: 'bench',
            variant: 'paused',
            valueLb: 240,
            effectiveFrom: _d('2026-09-21'),
            source: 'seed',
            reason: 'user confirmed seed',
            readingId: '',
            confirmed: true),
      ];
      expect(needsConfirmation(confirmed, 'bench'), isFalse);
      // The deadlift pain_cap marker (confirmed=null) must NOT count as
      // a confirmation.
      expect(needsConfirmation(confirmed, 'deadlift'), isTrue);
    });

    test('workingMaxAsOf: last change on or before the date', () {
      final rows = [
        ...seeds,
        WorkingMaxRow(
            lift: 'bench',
            variant: 'paused',
            valueLb: 235,
            effectiveFrom: _d('2026-09-29'),
            source: 'rule',
            reason: 'drop',
            readingId: '2026-09-29|bench'),
      ];
      expect(workingMaxAsOf(rows, 'bench', _d('2026-09-27')), 240);
      expect(workingMaxAsOf(rows, 'bench', _d('2026-09-29')), 235);
      expect(workingMaxAsOf(rows, 'bench', _d('2026-09-20')), isNull);
    });

    test('wmDecisionsForWeek formats the week readings', () {
      final readings = [
        ReadingRow(
            id: '2026-09-22|bench',
            date: _d('2026-09-22'),
            lift: 'bench',
            variant: 'paused',
            weightLb: 225,
            reps: 1,
            rpe: 8,
            kind: 'heavy_top',
            grinder: false,
            missed: false,
            impliedMax: 244,
            decision: 'hold',
            wmAfter: 240),
        ReadingRow(
            id: '2026-09-24|deadlift',
            date: _d('2026-09-24'),
            lift: 'deadlift',
            variant: 'belted',
            weightLb: 300,
            reps: 1,
            rpe: 9.5,
            kind: 'heavy_top',
            grinder: true,
            missed: false,
            impliedMax: 306,
            decision: 'drop',
            wmAfter: 325),
        // Next week's reading is excluded.
        ReadingRow(
            id: '2026-09-29|bench',
            date: _d('2026-09-29'),
            lift: 'bench',
            variant: 'paused',
            weightLb: 225,
            reps: 1,
            rpe: 8,
            kind: 'heavy_top',
            grinder: false,
            missed: false,
            impliedMax: 244,
            decision: 'hold',
            wmAfter: 240),
      ];
      expect(wmDecisionsForWeek(readings, _d('2026-09-21')),
          'bench:hold; deadlift:drop→325');
      expect(wmDecisionsForWeek(readings, _d('2026-09-28')), 'bench:hold');
      expect(wmDecisionsForWeek(readings, _d('2026-10-05')), '');
    });
  });

  // ---------------------------------------------------------------------
  // runWmChain — the nightly append chain
  // ---------------------------------------------------------------------
  group('runWmChain', () {
    final seeds = seedWorkingMaxRows();
    WmSnapshot snap(List<WorkingMaxRow> wm, [List<ReadingRow>? r]) =>
        (workingMax: wm, readings: r ?? const []);

    test('hold: appends the reading row, no working_max row', () {
      final res = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-09-22', 225, 1, 8)],
        policyFor: always,
        today: _d('2026-09-22'),
      );
      expect(res.newReadings, hasLength(1));
      final r = res.newReadings.single;
      expect(r.id, '2026-09-22|bench');
      expect(r.kind, 'heavy_top');
      expect(r.decision, 'hold');
      expect(r.wmAfter, 240);
      expect(res.newWorkingMaxRows, isEmpty);
    });

    test('drop: appends reading + working_max rows; idempotent re-run', () {
      final res = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-09-22', 235, 1, 9)],
        policyFor: always,
        today: _d('2026-09-22'),
      );
      expect(res.newReadings.single.decision, 'drop');
      expect(res.newWorkingMaxRows, hasLength(1));
      final wm = res.newWorkingMaxRows.single;
      expect(wm.lift, 'bench');
      expect(wm.valueLb, 235);
      expect(wm.source, 'rule');
      expect(wm.readingId, '2026-09-22|bench');
      expect(wm.confirmed, isNull);

      // Re-run with the appended rows in the snapshot: nothing new.
      final rerun = runWmChain(
        snapshot: snap([...seeds, ...res.newWorkingMaxRows],
            [...res.newReadings]),
        strengthRows: [bench('2026-09-22', 235, 1, 9)],
        policyFor: always,
        today: _d('2026-09-23'),
      );
      expect(rerun.newReadings, isEmpty);
      expect(rerun.newWorkingMaxRows, isEmpty);
    });

    test('post-drop cap: the next reading is kind=capped', () {
      final run1 = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-09-22', 235, 1, 9)],
        policyFor: always,
        today: _d('2026-09-22'),
      );
      final run2 = runWmChain(
        snapshot:
            snap([...seeds, ...run1.newWorkingMaxRows], run1.newReadings),
        strengthRows: [
          bench('2026-09-22', 235, 1, 9),
          bench('2026-09-29', 215, 3, 7),
        ],
        policyFor: always,
        today: _d('2026-09-29'),
      );
      expect(run2.newReadings.single.kind, 'capped');
      expect(run2.newReadings.single.decision, 'hold');
    });

    test('cut_early raise streak survives the run boundary', () {
      final run1 = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-09-22', 220, 1, 7)],
        policyFor: always,
        today: _d('2026-09-22'),
      );
      expect(run1.newReadings.single.decision, 'hold'); // 1 of 2
      final run2 = runWmChain(
        snapshot: snap(seeds, run1.newReadings),
        strengthRows: [
          bench('2026-09-22', 220, 1, 7),
          bench('2026-09-29', 220, 1, 7),
        ],
        policyFor: always,
        today: _d('2026-09-29'),
      );
      expect(run2.newReadings.single.decision, 'raise');
      expect(run2.newWorkingMaxRows.single.valueLb, 245);
    });

    test('readings before the seed effective date are never appended', () {
      final res = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-08-17', 230, 1, 8)],
        policyFor: always,
        today: _d('2026-09-22'),
      );
      expect(res.newReadings, isEmpty);
    });

    test('lift without any working_max row is skipped entirely', () {
      final res = runWmChain(
        snapshot: snap(const []),
        strengthRows: [bench('2026-09-22', 225, 1, 8)],
        policyFor: always,
        today: _d('2026-09-22'),
      );
      expect(res.newReadings, isEmpty);
      expect(res.newWorkingMaxRows, isEmpty);
    });

    test('deadlift pain cap: freeze x2 clean → lifted marker appended', () {
      // Run 1: first clean capped session under the seeded pain cap.
      final run1 = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [deadlift('2026-09-24', 280, 1, 6.5)],
        policyFor: always,
        today: _d('2026-09-24'),
      );
      final r1 = run1.newReadings.single;
      expect(r1.kind, 'capped'); // pain cap caps the top set
      expect(r1.decision, 'freeze');
      expect(r1.wmAfter, 330);
      expect(run1.newWorkingMaxRows, isEmpty); // not lifted yet

      // Run 2: second consecutive clean session → cap lifted.
      final run2 = runWmChain(
        snapshot: snap(seeds, run1.newReadings),
        strengthRows: [
          deadlift('2026-09-24', 280, 1, 6.5),
          deadlift('2026-10-01', 290, 1, 7),
        ],
        policyFor: always,
        today: _d('2026-10-01'),
      );
      expect(run2.newReadings.single.decision, 'freeze');
      final lifted = run2.newWorkingMaxRows.single;
      expect(lifted.lift, 'deadlift');
      expect(lifted.valueLb, 330);
      expect(lifted.reason, startsWith(painCapLiftedReasonPrefix));

      // Run 3: cap is off — a normal heavy_top hold.
      final run3 = runWmChain(
        snapshot: snap([...seeds, ...run2.newWorkingMaxRows],
            [...run1.newReadings, ...run2.newReadings]),
        strengthRows: [
          deadlift('2026-09-24', 280, 1, 6.5),
          deadlift('2026-10-01', 290, 1, 7),
          deadlift('2026-10-08', 305, 1, 8),
        ],
        policyFor: always,
        today: _d('2026-10-08'),
      );
      final r3 = run3.newReadings.single;
      expect(r3.kind, 'heavy_top');
      expect(r3.decision, 'hold');
    });

    test('a grinder under the pain cap breaks the clean streak', () {
      final run1 = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [deadlift('2026-09-24', 280, 1, 6.5)],
        policyFor: always,
        today: _d('2026-09-24'),
      );
      final run2 = runWmChain(
        snapshot: snap(seeds, run1.newReadings),
        strengthRows: [
          deadlift('2026-09-24', 280, 1, 6.5),
          deadlift('2026-10-01', 320, 1, 9.5), // grinder
        ],
        policyFor: always,
        today: _d('2026-10-01'),
      );
      expect(run2.newWorkingMaxRows, isEmpty,
          reason: 'no lifted marker after a dirty session');
    });

    test('pain note activates a cap for the mapped lifts', () {
      final res = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-09-25', 225, 1, 8)],
        policyFor: always,
        today: _d('2026-09-25'),
        painNotes: [(date: _d('2026-09-23'), text: 'elbow pain flaring')],
      );
      // pain_cap markers for press + bench, then the bench reading is a
      // frozen capped session.
      final caps = res.newWorkingMaxRows
          .where((r) => r.source == 'pain_cap')
          .toList();
      expect(caps.map((r) => r.lift).toSet(), {'press', 'bench'});
      expect(res.newReadings.single.decision, 'freeze');
      expect(res.newReadings.single.kind, 'capped');

      // Re-run with the markers present: no duplicate markers.
      final rerun = runWmChain(
        snapshot: snap(
            [...seeds, ...res.newWorkingMaxRows], res.newReadings),
        strengthRows: [bench('2026-09-25', 225, 1, 8)],
        policyFor: always,
        today: _d('2026-09-26'),
        painNotes: [(date: _d('2026-09-23'), text: 'elbow pain flaring')],
      );
      expect(rerun.newWorkingMaxRows, isEmpty);
    });

    test('touch-and-go bench is converted before evaluation', () {
      final res = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-09-22', 247.2, 1, 8, 'touch and go')],
        policyFor: always,
        today: _d('2026-09-22'),
      );
      final r = res.newReadings.single;
      expect(r.variant, 'touch_and_go');
      expect(r.weightLb, closeTo(247.2 / 1.03, 1e-9));
    });

    test('light week: recorded + ignored; test week: reset', () {
      final light = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-09-23', 235, 1, 9.5)],
        policyFor: (_) => policies.firstWhere((p) => p.name == 'light_week'),
        weekTypeOf: (_) => 'light',
        today: _d('2026-09-23'),
      );
      expect(light.newReadings.single.kind, 'light_week');
      expect(light.newReadings.single.decision, 'hold');
      expect(light.newWorkingMaxRows, isEmpty);

      final reset = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-09-23', 240, 1, 8)],
        policyFor: (_) => testWeek,
        weekTypeOf: (_) => 'test',
        today: _d('2026-09-23'),
      );
      expect(reset.newReadings.single.decision, 'reset');
      expect(reset.newWorkingMaxRows.single.valueLb, 260); // 240/0.922 ↓5
      expect(reset.newWorkingMaxRows.single.source, 'test');
    });

    test('NO_READING flags a lift after two readingless weeks', () {
      final res = runWmChain(
        snapshot: snap(seeds),
        strengthRows: const [],
        policyFor: always,
        today: _d('2026-10-06'), // 15 days after seed
      );
      expect(res.flagsByLift['press'], contains('NO_READING'));
      final fresh = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-10-01', 225, 1, 8)],
        policyFor: always,
        today: _d('2026-10-06'),
      );
      expect(fresh.flagsByLift['bench'] ?? const [],
          isNot(contains('NO_READING')));
    });
  });

  // ---------------------------------------------------------------------
  // runWmChain under the live v12 tm_rule (guarded implied-max)
  // ---------------------------------------------------------------------
  group('runWmChain under tm_rule (program.yaml v12)', () {
    final v12 = currentVersion(program)!;
    final v12Policies = loadPolicies(v12);
    final v12CutEarly = v12Policies.firstWhere((p) => p.name == 'cut_early');
    final rule = tmRuleOf(v12)!;
    final seeds = seedWorkingMaxRows();
    WmSnapshot snap(List<WorkingMaxRow> wm, [List<ReadingRow>? r]) =>
        (workingMax: wm, readings: r ?? const []);

    test('easy wave top raises +5 (capped); hard top drops in full', () {
      // Bench seed 240. 195×5@7 → implied 248.1 → 250 capped → 245.
      final raise = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-10-05', 195, 5, 7)],
        policyFor: (_) => v12CutEarly,
        today: _d('2026-10-05'),
        tmRule: rule,
      );
      expect(raise.newReadings.single.decision, 'raise');
      expect(raise.newWorkingMaxRows.single.valueLb, 245);

      // 195×5@9 → implied 233.0 → 235: full drop.
      final drop = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-10-05', 195, 5, 9)],
        policyFor: (_) => v12CutEarly,
        today: _d('2026-10-05'),
        tmRule: rule,
      );
      expect(drop.newReadings.single.decision, 'drop');
      expect(drop.newWorkingMaxRows.single.valueLb, 235);
    });

    test('%TM volume day-top is recorded but never moves the TM', () {
      // Wed squat volume 3x8@65%: 210×8@7 against squat TM 320 —
      // implied 297 would be a 25 lb crater without the guard.
      final res = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [
          StrengthRow(
              date: _d('2026-10-07'),
              exercise: 'Barbell Squat',
              weight: 210,
              reps: 8,
              rpe: 7),
        ],
        policyFor: (_) => v12CutEarly,
        today: _d('2026-10-07'),
        tmRule: rule,
      );
      expect(res.newReadings.single.decision, 'hold');
      expect(res.newWorkingMaxRows, isEmpty);
    });

    test('cut-wave deload week readings are ignored via weekTypeOf', () {
      // Deload top 5@70%: 170×5@7 — implied 216 must NOT drop the TM.
      final res = runWmChain(
        snapshot: snap(seeds),
        strengthRows: [bench('2026-10-19', 170, 5, 7)],
        policyFor: (_) => v12CutEarly,
        weekTypeOf: (_) => 'deload',
        today: _d('2026-10-19'),
        tmRule: rule,
      );
      expect(res.newReadings.single.kind, 'deload');
      expect(res.newReadings.single.decision, 'hold');
      expect(res.newWorkingMaxRows, isEmpty);
    });
  });
}
