// Unit gates for the lifted sim2 core + harness (training simulator
// v2.1, wave 3). Two pinned acceptance surfaces:
//   • §9.2 replay (fit report 2026-09-26-sim-v21-fit-report.md): 4/5
//     checkpoints pass from the 2024-01-01 anchor (checkpoint 1
//     carries the documented Bulk-C data-basis anomaly, err ≈ −47);
//     median level |err| 31 lb over 68 obs points. HISTORY — these
//     pins never move with plan changes.
//   • §9.3 horizon, V13 ROUTINE-AUDIT BASELINE (2026-09-29, user
//     directive: dials read off the ACTUAL v13 week, not superseded
//     plans). Two corrections on the v11 pins: cut D 4.5→4 (the short
//     Thu skill/arms day rides Q only — it was half-counted in BOTH
//     dials) and reverse-block N 3→4 (one wave top per lift happens
//     every week; the RPE-7 cap governs intensity, not the count).
//     Z=1 in EVERY block type forever (the 4x4 never changes) and
//     K=2/kLim=1 (cut Tue-hard, post-cut Fri-limit; climbing blocks
//     K=3) were already right. The cut now runs L=7.4 vs the deficit
//     cap 6.0 — still every cut week over budget, but F peaks ~0.77
//     (was ~1.04): end-of-cut EXPRESSED 889.3 (was 879.8), capacity
//     969.5. Full-horizon deterministic total 1006.2 (v11 pin
//     1003.2, +3.0); over-budget weeks stay 59; VO2 stays 53.4 (Z=1
//     holds absolute capacity — the score is bodyweight-driven); MC
//     median ~1004 with P(V8 sent) ~0.76 (less fatigue → fewer
//     injuries, mean injury weeks 2.9→2.75). W=49 carries the same
//     b-slope extrapolation caveat as the post-cut W=57.
//     The 'Bulk plan (inactive)' preset shares the corrected cut +
//     reverse blocks, so its pins move too (1031.6 det / MC 1030 /
//     P(V8) 0.39); the recomp gap holds ≈ 25 lb SBD by Dec 2027.
// Fixtures: tool/calibration/*.csv (tests run from the package root).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/forecast_tab.dart'
    show forecastTabHeaders, parseForecastTab, sim2ForecastTabRows;
import 'package:airledger/services/sim2_harness.dart';
import 'package:airledger/services/sim2_model.dart';

void main() {
  group('§9.2 replay checkpoints (calibration fixtures)', () {
    late WeeklySeries series;
    late Map<DateTime, double> obsTotal;

    setUpAll(() {
      final weekly = loadWeekly('tool/calibration/calibration_weekly.csv');
      final windows = loadWindows('tool/calibration/calibration_windows.csv');
      obsTotal = {for (final w in windows) w.start: w.total};
      series = buildSeries(weekly);
    });

    test('4/5 pass from the 2024-01-01 anchor; median |err| 31', () {
      final p = Sim2Params.fitted();
      final eIdx = series.eIdxSeries(p);
      final anchor = DateTime(2024, 1, 1);
      final j0 = series.index[anchor]!;
      final s0 = obsTotal[anchor]!;

      // capacity path from the anchored index (tool/sim2_replay.dart)
      final sCap = List<double>.filled(series.rows.length, 0);
      sCap[j0] = s0 / eIdx[j0];
      for (var t = j0; t < series.rows.length - 1; t++) {
        final row = series.rows[t];
        final es = series.e[t] * series.stim[t];
        final dCap =
            es * (p.a * (1 - exp(-row.n / 4)) + p.b * (row.w - 20) / 10) +
                p.c * series.rSm[t].clamp(0.0, 0.5) -
                p.cCut * max(0.0, -series.rSm[t]) -
                p.d -
                (series.bw[t] > 176 ? 0.5 : 0.0);
        sCap[t + 1] = sCap[t] + dCap;
      }
      double modelIdx(DateTime d) {
        final t = series.index[d]!;
        return sCap[t] * eIdx[t];
      }

      double err(String d) =>
          modelIdx(DateTime.parse(d)) - obsTotal[DateTime.parse(d)]!;

      // Checkpoint 1 (Bulk C level): the documented data-basis anomaly —
      // the CSV's gain columns say ~0 while its level columns spiked;
      // pinned as a KNOWN fail at err ≈ −47, NOT gated.
      expect(err('2024-06-17'), closeTo(-47, 6));
      // Checkpoints 2–5: the gate, ±40 lb at the segment end.
      expect(err('2024-12-30').abs(), lessThanOrEqualTo(40),
          reason: '2024 cut checkpoint');
      expect(err('2025-03-24').abs(), lessThanOrEqualTo(40),
          reason: 'Dec24-Mar25 rebound checkpoint');
      expect(err('2025-06-16').abs(), lessThanOrEqualTo(40),
          reason: 'Bulk D stall checkpoint');
      expect(err('2026-07-27').abs(), lessThanOrEqualTo(40),
          reason: '2025-26 cut checkpoint');

      // Level-tracking quality over the whole anchored stretch.
      final errs = <double>[];
      for (var t = j0; t < series.rows.length; t++) {
        final obs = obsTotal[series.rows[t].week];
        if (obs != null) errs.add((sCap[t] * eIdx[t] - obs).abs());
      }
      errs.sort();
      expect(errs.length, 68);
      expect(errs[errs.length ~/ 2], closeTo(31, 3));
      expect(errs.last, lessThanOrEqualTo(75));
    });
  });

  group('§9.3 horizon (fixture calendar, 2026-09-28 start)', () {
    final p = Sim2Params.fitted();
    final blocks = sim2DefaultBlocks();
    final start = DateTime.utc(2026, 9, 28);

    test('v13 baseline: deterministic expressed total ~1006, BW '
        'holds ~158.8 inside the soft band', () {
      final run = sim2Run(params: p, blocks: blocks, start: start);
      expect(run.end.s, closeTo(1006.2, 1.5));
      expect(run.end.sCap, closeTo(1023.7, 2));
      // The weekly limit session (final spec: Fri = limit, year-round)
      // costs +0.4 load — normal lifting weeks run 7.4 vs cap 7.0, so
      // most are (slightly) over budget: the plan's honest red flag.
      expect(run.overBudgetWeeks, 59);
      expect(run.end.bw, closeTo(158.8, 0.3)); // inside soft band 154-165
      expect(run.end.bw, lessThan(165)); // advisory tripwire untouched
      expect(run.end.vo2, closeTo(53.4, 0.3)); // lighter year helps VO2
      expect(run.end.bfPct, closeTo(15.6, 0.3)); // §5 rule μ=0.30 branch
      expect(run.end.c, closeTo(7.70, 0.1)); // and the climbing
      // start state: RPE basis 917, capacity 968, E 0.947
      expect(run.start.s, closeTo(917, 1));
      expect(run.start.sCap, closeTo(968, 1));
      // the index line starts at the observed app index and catches up
      expect(run.weeks.first.sIdx, lessThan(run.weeks.first.sTrue));
      expect(run.last.sIdx, closeTo(run.last.sTrue, 6));
    });

    test('μ≈0 deficit branch lands BF 14.0 (13%-at-154 anchor)', () {
      final run =
          sim2Run(params: p, blocks: blocks, start: start, muDeficit: 0.0);
      expect(run.end.bfPct, closeTo(14.0, 0.3));
      expect(run.end.bw, closeTo(158.8, 0.3)); // BW path identical
    });

    test("'Bulk plan (inactive)' preset — now on the SHARED revised cut "
        'block + reverse (v13 audit), so the fit-report pins shift; '
        'recomp gap ≈ 25 lb SBD', () {
      final bulk = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'bulk_plan');
      expect(bulk.end.s, closeTo(1031.6, 1.5)); // was 1023 pre-revision
      expect(bulk.end.sCap, closeTo(1022.1, 2));
      expect(bulk.end.bw, closeTo(171.2, 0.3));
      expect(bulk.end.vo2, closeTo(49.6, 0.3));
      expect(bulk.end.bfPct, closeTo(17.6, 0.3));
      expect(bulk.end.c, closeTo(6.95, 0.1));
      // The recomp cost on the SBD total — still ~25 lb (both arms
      // gained the cut revision's capacity).
      final base = sim2Run(params: p, blocks: blocks, start: start);
      expect(bulk.end.s - base.end.s, closeTo(25, 3));
      // μ≈0 branch of the bulk plan keeps its old pin too.
      final bulkMu0 = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'bulk_plan',
          muDeficit: 0.0);
      expect(bulkMu0.end.bfPct, closeTo(16.1, 0.3));
    });

    test('Monte Carlo (v13 baseline) median ~1004, P(V8 sent) ~0.76, '
        'injuries ~2.75; bulk preset (shared cut) median 1030 / 0.39', () {
      final mc = sim2MonteCarlo(params: p, blocks: blocks, start: start);
      expect(mc.medianTotal, closeTo(1004, 2));
      expect(mc.p20Total, closeTo(996, 3));
      expect(mc.p80Total, closeTo(1015, 3));
      expect(mc.pV8Sent, closeTo(0.76, 0.04));
      expect(mc.pV8Touch, closeTo(0.35, 0.05));
      expect(mc.injuryWeeksMean, closeTo(2.75, 0.5));
      final bulkMc = sim2MonteCarlo(
          params: p, blocks: blocks, start: start, presetId: 'bulk_plan');
      expect(bulkMc.medianTotal, closeTo(1030, 2));
      expect(bulkMc.pV8Sent, closeTo(0.39, 0.03));
    });

    test('Cardio up pushes VO2 toward ~55; Cardio off drops it toward ~46',
        () {
      final up = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'cardio_up');
      expect(up.end.vo2, closeTo(54.9, 0.4));
      final off = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'cardio_off');
      expect(off.end.vo2, lessThan(48));
    });

    test('Climb more: lifting gains fall, budget blows (§9.4)', () {
      final base = sim2Run(params: p, blocks: blocks, start: start);
      final climb = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'climb_more');
      expect(climb.end.s, lessThan(base.end.s - 30)); // 948 vs 1003
      expect(climb.overBudgetWeeks, greaterThan(base.overBudgetWeeks));
      expect(climb.end.f, greaterThan(0.8)); // F_end 0.98
      // lifting-block expressed gain falls (report: +25 vs +87)
      double liftGain(Sim2Run r) {
        var g = 0.0;
        for (final n in [3, 5, 7]) {
          final e = r.blockEnds[n]?.s, s = r.blockEnds[n - 1]?.s;
          if (e != null && s != null) g += e - s;
        }
        return g;
      }

      expect(liftGain(climb), lessThan(liftGain(base) - 30));
    });

    test('Fast bulk: more fat, no extra strength above r=0.5 (§9.4)', () {
      // The r-saturation claim compares against the BULK plan (r=0.4)
      // — the recomp baseline (r=0.075) is fed less, so fast_bulk does
      // beat IT; the point is that r=0.9 buys nothing over r=0.4.
      final bulk = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'bulk_plan');
      final fast = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'fast_bulk');
      expect(fast.end.fm - sim2SeedFm,
          greaterThan(bulk.end.fm - sim2SeedFm + 8)); // +14.1 vs +1.1
      expect(fast.end.s, lessThanOrEqualTo(bulk.end.s + 8));
      expect(fast.end.bw, closeTo(185, 1.5)); // blocks 6-7 recomp-based
    });

    test('Drop calisthenics decays M; dial overrides move the horizon', () {
      final base = sim2Run(params: p, blocks: blocks, start: start);
      final drop = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'drop_cal');
      expect(drop.end.m, lessThan(base.end.m - 0.5));
      // Global N override (the dials row) moves the strength horizon.
      // At the v13 baseline (already over budget on the cut + normal
      // lifting weeks) forcing N=10 deepens the overage — the load
      // cost OUTWEIGHS the saturating near-max gain (~-8 lb; v11 was
      // ~-7, v10 ~-5, v9 ~-2, v8's N=6 baseline ~+3).
      final n10 = sim2Run(
          params: p,
          blocks: blocks,
          start: start,
          overrides: const Sim2DialOverrides(n: 10));
      expect(n10.end.s, lessThan(base.end.s));
      expect(n10.end.s, closeTo(base.end.s - 8.4, 2));
    });
  });

  group('nightly forecast tab (sim2 re-point)', () {
    test('v1 tab shape kept; values are sim2 baseline', () {
      final run = sim2Run(
          params: Sim2Params.fitted(),
          blocks: sim2DefaultBlocks(),
          start: DateTime.utc(2026, 9, 28));
      final rows = sim2ForecastTabRows(run);
      expect(rows.length, run.weeks.length);
      // Round-trips through the UNCHANGED v1 parser (the MCP block's
      // contract): monday/phase/bw/e1rm_*/wilks/grade_p75.
      final parsed = parseForecastTab([forecastTabHeaders, ...rows]);
      expect(parsed.length, run.weeks.length);
      expect(parsed.first.phase, 'cut'); // block emphasis in the column
      expect(parsed.last.phase, 'lifting');
      expect(parsed.last.e1rm['squat'], closeTo(run.last.squat, 0.06));
      expect(parsed.last.e1rm['press'], closeTo(run.last.press, 0.06));
      expect(parsed.last.bw, closeTo(158.8, 0.3)); // recomp baseline
      expect(parsed.last.wilks, greaterThan(200)); // SBD Wilks at 171 lb
      expect(parsed.last.gradeP75, closeTo(run.last.c, 0.06)); // sim2 C
    });
  });

  group('harness plumbing', () {
    test('blocks from program docs: rate kept, weight-slope fallback', () {
      final blocks = sim2BlocksFromProgramDocs({
        'versions': [
          {
            'version': 1,
            'effective_from': '2026-09-21',
            'blocks': [
              {
                'n': 0,
                'dates': ['2026-09-21', '2026-12-13'],
                'emphasis': 'cut',
                'weight': [163, 154],
              },
              {
                'n': 2,
                'dates': ['2027-01-04', '2027-02-28'],
                'emphasis': 'climbing',
                'weight': [154, 157],
                'rate': 0.4,
              },
            ],
          }
        ]
      });
      expect(blocks, isNotNull);
      expect(blocks!.length, 2);
      expect(blocks[0].emphasis, 'cut');
      expect(blocks[0].r, closeTo(-0.75, 0.01)); // (154-163)/12wk
      expect(blocks[1].r, 0.4); // declared rate wins
      expect(sim2BlocksFromProgramDocs(null), isNull);
      expect(sim2BlocksFromProgramDocs({'versions': []}), isNull);
    });

    test('start Monday: today if Monday, else next', () {
      expect(sim2StartMonday(DateTime(2026, 9, 26)), // a Saturday
          DateTime.utc(2026, 9, 28));
      expect(sim2StartMonday(DateTime(2026, 9, 28)),
          DateTime.utc(2026, 9, 28));
    });

    test('§9.5 registry: every def is wired to its field (get/set)', () {
      final ids = sim2ParamDefs.map((d) => d.id).toSet();
      expect(ids.length, sim2ParamDefs.length, reason: 'ids unique');
      for (final def in sim2ParamDefs) {
        final p = Sim2Params.fitted();
        final before = def.get(p);
        def.set(p, before + 1);
        expect(def.get(p), before + 1, reason: '${def.id} setter wired');
        expect(['fit', 'log', 'lit', 'assume'], contains(def.tag));
      }
      // fitted values match the report's coefficient table
      final f = Sim2Params.fitted();
      expect(f.a, 2.49);
      expect(f.b, 0.39);
      expect(f.c, 1.44);
      expect(f.cCut, 0.92);
      expect(f.d, 0.59);
      expect(f.eDep, 0.04);
      expect(f.eBw, 0.002);
      expect(f.eRust, 0.0075);
      expect(f.idxKAttempt, 0.7);
      expect(f.idxKIdle, 0.1);
    });
  });
}
