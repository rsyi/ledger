// TWO-LOOP TM — slow-loop median estimator (program.yaml v13
// `tm_rule: median_implied_max`) unit tests against inline rules/
// policies (no live-YAML dependency; the shared fixtures in
// airledger-fitness/coach/fixtures/wm_evaluate_cases.yaml pin the live
// program for both twins).
//
// The user-specified architecture: recent training history →
// deterministic TM estimate (median of qualifying top-set implied
// maxes) → percentage-based program → perform workout → observed RPE →
// the existing small auto-adjustments (grinder drop, caps) when
// necessary. The v12 ±5/session raise cap is SUPERSEDED by the median's
// own outlier damping — proven below with the +15 lb outlier case.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/program_metrics.dart' show StrengthRow;
import 'package:airledger/services/wm_tabs.dart';
import 'package:airledger/services/working_max.dart';

const _slow = TmRule(mode: tmModeMedian); // 21d ∨ 5 sets, round 5, outvote 3

LoadPolicy _policy({bool frozen = false}) => LoadPolicy(
      name: 'test_policy',
      targetRpeLow: 7.5,
      targetRpeHigh: 8,
      raiseIfRpeLte: null,
      raiseRequiresConsecutive: 1,
      holdBand: null,
      dropIfRpeGte: null,
      stepLb: const {'bench': 5, 'press': 5, 'squat': 5, 'deadlift': 5},
      frozen: frozen,
      capRpe: 8.5,
      capAfterDropRpe: 8.5,
      consecutiveDropsAction: 'no_top_sets_next_week',
      readingsThatRaise: const [],
      readingsThatLower: const [],
      resetOnTest: true,
      readingsIgnored: false,
      saturdaySingle: false,
      applies: const {},
    );

Reading _sample(
  int day, {
  double weight = 195,
  int reps = 5,
  double rpe = 8,
  String kind = 'heavy_top',
  bool grinder = false,
  bool missed = false,
  bool mismatch = false,
}) =>
    Reading(
      date: DateTime.utc(2026, 9, day),
      lift: 'squat',
      variant: 'belted',
      weightLb: weight,
      rawWeightLb: weight,
      reps: reps,
      rpe: rpe,
      kind: kind,
      grinder: grinder || rpe >= 9.5,
      missed: missed,
      variantMismatch: mismatch,
    );

void main() {
  group('slowTmEstimate', () {
    test('median of the window, rounded to 5 — deterministic', () {
      // Five day-tops 195×5@8 → implied 195/0.811 = 240.4 each.
      final samples = [for (final d in [1, 4, 8, 11, 15]) _sample(d)];
      final est = slowTmEstimate(
          samples: samples, currentTm: 240, rule: _slow)!;
      expect(est.value, 240);
      expect(est.median, closeTo(240.4, 0.1));
      expect(est.sampleCount, 5);
      // Identical history ⇒ identical TM (pure function, no clock).
      final again = slowTmEstimate(
          samples: List.of(samples.reversed), currentTm: 240, rule: _slow)!;
      expect(again.value, est.value);
      expect(again.median, est.median);
    });

    test('OUTLIER DAMPING PROOF: one +15 lb outlier day moves TM ≤ 5 lb '
        '(moves 0 here)', () {
      // Baseline: five sets implying 240.4 → TM 240.
      final base = [for (final d in [1, 4, 8, 11, 15]) _sample(d)];
      final tmBase =
          slowTmEstimate(samples: base, currentTm: 240, rule: _slow)!.value;
      expect(tmBase, 240);
      // One anomalous day: 207.5×5@8 → implied 255.9 (+15.4 lb).
      final withOutlier = [
        for (final d in [1, 4, 8, 11]) _sample(d),
        _sample(15, weight: 207.5),
      ];
      final tmOut = slowTmEstimate(
              samples: withOutlier, currentTm: 240, rule: _slow)!
          .value;
      expect((tmOut - tmBase).abs(), lessThanOrEqualTo(5));
      expect(tmOut, 240); // the median never saw it move
      // ...and the mirror-image low day is damped identically.
      final withLow = [
        for (final d in [1, 4, 8, 11]) _sample(d),
        _sample(15, weight: 182.5), // implied 225.0 (−15.4)
      ];
      expect(
          slowTmEstimate(samples: withLow, currentTm: 240, rule: _slow)!
              .value,
          240);
    });

    test('window: 21 days ∨ last 5 sets, whichever holds MORE data', () {
      // 6 qualifying sets inside 21 days of the newest → all 6 used.
      final dense = [for (final d in [8, 10, 12, 14, 16, 18]) _sample(d)];
      expect(
          slowTmEstimate(samples: dense, currentTm: 240, rule: _slow)!
              .sampleCount,
          6);
      // Only 2 inside the window → fall back to the last 5 sets.
      final sparse = [
        _sample(1, weight: 190), // implied 234.3
        _sample(2, weight: 190),
        _sample(3, weight: 190),
        _sample(27),
        _sample(28),
      ];
      final est = slowTmEstimate(
          samples: sparse, currentTm: 240, rule: _slow)!;
      expect(est.sampleCount, 5);
      expect(est.from, DateTime.utc(2026, 9, 1));
    });

    test('qualifier: reps ≤ 8, non-deload weeks, converted variants, '
        '≥ min_top_fraction × TM; grinders stay in', () {
      final samples = [
        _sample(1),
        _sample(2, reps: 10), // hypertrophy set — out
        _sample(3, kind: 'light_week'), // out
        _sample(4, kind: 'deload'), // out
        _sample(5, mismatch: true), // unconvertible variant — out
        _sample(6, weight: 160, reps: 8), // 160 < 0.78×240 — out
        _sample(7, rpe: 9.5), // grinder — IN (real evidence)
      ];
      final qual = qualifyingTmSamples(samples, 240, _slow);
      expect([for (final r in qual) r.date.day], [1, 7]);
    });

    test('null when nothing qualifies — callers hold, never guess', () {
      expect(
          slowTmEstimate(
              samples: [_sample(1, weight: 100)],
              currentTm: 240,
              rule: _slow),
          isNull);
    });
  });

  group('evaluate — median mode', () {
    WmDecision eval({
      required double wm,
      required Reading reading,
      required List<Reading> history,
      ManualPin? pin,
      List<WmDecision> priors = const [],
    }) =>
        evaluate(
          lift: 'squat',
          policy: _policy(),
          workingMax: wm,
          date: reading.date,
          reading: reading,
          priorDecisions: priors,
          tmRule: _slow,
          slowTm: slowTmEstimate(
            samples: [...history, reading],
            currentTm: wm,
            rule: _slow,
            asOf: reading.date,
            notBefore: pin?.since,
          ),
          manualPin: pin,
        );

    test('raise applies the median IN FULL — the ±5 session cap is '
        'superseded by design', () {
      // Five sets all implying 255.9 → median 255.9 → 255. v12 would
      // have raised 240 → 245 only.
      final history = [
        for (final d in [1, 4, 8, 11]) _sample(d, weight: 207.5),
      ];
      final d = eval(
        wm: 240,
        reading: _sample(15, weight: 207.5),
        history: history,
      );
      expect(d.action, 'raise');
      expect(d.wmAfter, 255);
      expect(d.reason, contains('slow loop'));
      expect(d.reason, contains('median'));
    });

    test('a single strong day cannot raise the TM (outvoted)', () {
      final history = [for (final d in [1, 4, 8, 11]) _sample(d)];
      final d = eval(
        wm: 240,
        reading: _sample(15, weight: 207.5), // implied 255.9, alone
        history: history,
      );
      expect(d.action, 'hold');
      expect(d.wmAfter, 240);
    });

    test('a single hard (non-grinder) day cannot drop the TM either', () {
      final history = [for (final d in [1, 4, 8, 11]) _sample(d)];
      final d = eval(
        wm: 240,
        reading: _sample(15, weight: 195, rpe: 9), // implied 233.0
        history: history,
      );
      expect(d.action, 'hold');
      expect(d.wmAfter, 240);
    });

    test('sustained decline drops in full with the fast-loop cap', () {
      // Majority of the window says ~230: 190×5@8.5 → implied 230.6
      // (above the 0.78×240 = 187.2 sub-top gate — real top work).
      final history = [
        _sample(1),
        _sample(4, weight: 190, rpe: 8.5),
        _sample(8, weight: 190, rpe: 8.5),
        _sample(11, weight: 190, rpe: 8.5),
      ];
      final d = eval(
        wm: 240,
        reading: _sample(15, weight: 190, rpe: 8.5),
        history: history,
      );
      expect(d.action, 'drop');
      expect(d.wmAfter, 230);
      expect(d.capNextTopSetRpe, 8.5); // fast loop kept
    });

    test('grinder still drops immediately (fast safety), min −5', () {
      final history = [for (final d in [1, 4, 8, 11]) _sample(d)];
      final d = eval(
        wm: 240,
        reading: _sample(15, weight: 235, reps: 1, rpe: 9.5),
        history: history,
      );
      expect(d.action, 'drop');
      expect(d.wmAfter, 235); // min(implied 240.3 → 240, 240−5)
    });

    test('manual pin holds until outvoted; the count is honest', () {
      final pin = (
        since: DateTime.utc(2026, 9, 3),
        newSets: 2,
        needed: 3,
      );
      final d = eval(
        wm: 260, // manual optimism
        reading: _sample(15, weight: 210), // 210 ≥ 0.78×260 — real top
        history: [_sample(10, weight: 210)],
        pin: pin,
      );
      expect(d.action, 'hold');
      expect(d.wmAfter, 260);
      expect(d.reason, contains('manual TM (2026-09-03) pinned'));
      expect(d.reason, contains('2 of 3'));
    });

    test('outvoted manual: estimator runs on post-manual sets only', () {
      final pin = (
        since: DateTime.utc(2026, 9, 3),
        newSets: 3,
        needed: 3,
      );
      final d = eval(
        wm: 260,
        // Pre-manual sets implied 271.3 (220×5@8) — with them the full
        // 6-set median would be 262.0 → hold at 260; post-manual-only
        // the three 205×5@8 sets (implied 252.8) → 255. The drop to
        // 255 proves the overridden history never resurrects.
        history: [
          _sample(1, weight: 220),
          _sample(2, weight: 220),
          _sample(3, weight: 220),
          _sample(10, weight: 205),
          _sample(12, weight: 205),
        ],
        reading: _sample(15, weight: 205),
        pin: pin,
      );
      expect(d.action, 'drop');
      expect(d.wmAfter, 255);
    });

    test('grinder drops THROUGH a manual pin — safety beats the pin', () {
      final pin = (
        since: DateTime.utc(2026, 9, 3),
        newSets: 0,
        needed: 3,
      );
      final d = eval(
        wm: 260,
        reading: _sample(15, weight: 225, reps: 1, rpe: 9.5),
        history: const [],
        pin: pin,
      );
      expect(d.action, 'drop');
      expect(d.wmAfter, 230); // implied 225/0.978 = 230.1 → 230 < 255
    });
  });

  group('replayLift — median mode', () {
    test('threads the growing history; one hard day is outvoted', () {
      final rows = [
        StrengthRow(
            date: DateTime(2026, 9, 1),
            exercise: 'Barbell Squat',
            weight: 250,
            reps: 5,
            rpe: 8), // implied 308.3
        StrengthRow(
            date: DateTime(2026, 9, 8),
            exercise: 'Barbell Squat',
            weight: 255,
            reps: 5,
            rpe: 8), // implied 314.4
        StrengthRow(
            date: DateTime(2026, 9, 15),
            exercise: 'Barbell Squat',
            weight: 245,
            reps: 5,
            rpe: 9), // implied 292.7 — hard but not a grinder
      ];
      final decisions = replayLift(
        lift: 'squat',
        seedWm: 300,
        rows: rows,
        policyFor: (_) => _policy(),
        tmRule: _slow,
      );
      expect([for (final d in decisions) d.action], ['raise', 'hold', 'hold']);
      // d1: median [308.3] → 310 (in full, no +5 cap).
      expect(decisions[0].wmAfter, 310);
      // d2: median [308.3, 314.4] = 311.4 → rounds back to 310 → hold.
      expect(decisions[1].wmAfter, 310);
      // d3: median [292.7, 308.3, 314.4] = 308.3 → 310 → hold: the one
      // hard day is outvoted by the window.
      expect(decisions[2].wmAfter, 310);
    });
  });

  group('runWmChain — nightly slow-loop recompute', () {
    final seedRow = WorkingMaxRow(
      lift: 'squat',
      variant: 'belted',
      valueLb: 320,
      effectiveFrom: DateTime.utc(2026, 9, 21),
      source: 'seed',
      reason: 'seed',
      confirmed: true,
    );
    final storedReading = ReadingRow(
      id: '2026-09-21|squat',
      date: DateTime.utc(2026, 9, 21),
      lift: 'squat',
      variant: 'belted',
      weightLb: 275,
      reps: 2,
      rpe: 8,
      kind: 'heavy_top',
      grinder: false,
      missed: false,
      impliedMax: 308.3,
      decision: 'hold',
      wmAfter: 320,
    );
    final strengthRows = [
      StrengthRow(
          date: DateTime(2026, 9, 21),
          exercise: 'Barbell Squat',
          weight: 275,
          reps: 2,
          rpe: 8), // implied 275/0.892 = 308.3 → 310
    ];

    WmChainResult run(List<WorkingMaxRow> wmRows) => runWmChain(
          snapshot: (workingMax: wmRows, readings: [storedReading]),
          strengthRows: strengthRows,
          policyFor: (_) => _policy(),
          today: DateTime.utc(2026, 9, 28),
          tmRule: _slow,
        );

    test('recomputes an already-evaluated history when the rule changes — '
        'writes ONE row, only because the value changed', () {
      final chain = run([seedRow]);
      expect(chain.newReadings, isEmpty); // nothing new to evaluate
      expect(chain.newWorkingMaxRows, hasLength(1));
      final row = chain.newWorkingMaxRows.single;
      expect(row.valueLb, 310); // median [308.3] → 310
      expect(row.source, 'rule');
      expect(row.reason, contains('slow loop nightly recompute'));
      expect(row.reason, contains('median implied 308.3'));
    });

    test('idempotent: a second run over the reconciled tab is a no-op', () {
      final first = run([seedRow]);
      final second = run([seedRow, ...first.newWorkingMaxRows]);
      expect(second.newReadings, isEmpty);
      expect(second.newWorkingMaxRows, isEmpty);
    });

    test('manual pin blocks the recompute until outvoted', () {
      final manual = WorkingMaxRow(
        lift: 'squat',
        variant: 'belted',
        valueLb: 340,
        effectiveFrom: DateTime.utc(2026, 9, 25),
        source: 'manual',
        reason: 'user says 340',
        confirmed: true,
      );
      final chain = run([seedRow, manual]);
      expect(chain.newWorkingMaxRows, isEmpty,
          reason: 'no qualifying sets after the manual date — pinned');
    });

    test('manual outvoted by three post-manual sets → slow loop resumes '
        'on post-manual data only', () {
      final manual = WorkingMaxRow(
        lift: 'squat',
        variant: 'belted',
        valueLb: 340,
        effectiveFrom: DateTime.utc(2026, 9, 21),
        source: 'manual',
        reason: 'user says 340',
        confirmed: true,
      );
      final rows = [
        ...strengthRows, // 09-21: at/before the pin — excluded
        StrengthRow(
            date: DateTime(2026, 9, 22),
            exercise: 'Barbell Squat',
            weight: 290,
            reps: 1,
            rpe: 8), // implied 314.5
        StrengthRow(
            date: DateTime(2026, 9, 24),
            exercise: 'Barbell Squat',
            weight: 295,
            reps: 1,
            rpe: 8), // implied 320.0
        StrengthRow(
            date: DateTime(2026, 9, 26),
            exercise: 'Barbell Squat',
            weight: 300,
            reps: 1,
            rpe: 8), // implied 325.4
      ];
      final chain = runWmChain(
        snapshot: (workingMax: [seedRow, manual], readings: [storedReading]),
        strengthRows: rows,
        policyFor: (_) => _policy(),
        today: DateTime.utc(2026, 9, 28),
        tmRule: _slow,
      );
      // Candidates 09-22 (1 of 3) and 09-24 (2 of 3) hold under the
      // pin; 09-26 reaches the quorum and applies the post-manual
      // median 320 (the 09-21 308.3 never resurrects).
      expect([for (final r in chain.newReadings) r.decision],
          ['hold', 'hold', 'drop']);
      expect(chain.newReadings.last.wmAfter, 320);
      final valueRows = [
        for (final r in chain.newWorkingMaxRows)
          if (r.source == 'rule') r,
      ];
      expect(valueRows, hasLength(1));
      expect(valueRows.single.valueLb, 320);
    });
  });
}
