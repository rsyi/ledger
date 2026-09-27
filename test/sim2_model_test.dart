// Unit gates for the lifted sim2 core + harness (training simulator
// v2.1, wave 3). Two pinned acceptance surfaces from the fit report
// (2026-09-26-sim-v21-fit-report.md):
//   • §9.2 replay: 4/5 checkpoints pass from the 2024-01-01 anchor
//     (checkpoint 1 carries the documented Bulk-C data-basis anomaly,
//     err ≈ −47); median level |err| 31 lb over 68 obs points.
//   • §9.3 horizon: deterministic expressed total 1023 (pin 1022±1) on
//     the default (fixture) calendar from 2026-09-28; over-budget 56;
//     MC median 1022 with P(V8 sent) 0.45.
// Fixtures: tool/calibration/*.csv (tests run from the package root).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

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

    test('deterministic expressed total pins at 1022±1 (=1023)', () {
      final run = sim2Run(params: p, blocks: blocks, start: start);
      expect(run.end.s, closeTo(1022, 1.5)); // 1023 per the report
      expect(run.end.sCap, closeTo(1014, 2));
      expect(run.overBudgetWeeks, 56);
      expect(run.end.bw, closeTo(171.2, 0.3));
      expect(run.end.vo2, closeTo(49.6, 0.3));
      expect(run.end.bfPct, closeTo(17.6, 0.3)); // §5 rule μ=0.30 branch
      expect(run.end.c, closeTo(6.97, 0.1));
      // start state: RPE basis 917, capacity 968, E 0.947
      expect(run.start.s, closeTo(917, 1));
      expect(run.start.sCap, closeTo(968, 1));
      // the index line starts at the observed app index and catches up
      expect(run.weeks.first.sIdx, lessThan(run.weeks.first.sTrue));
      expect(run.last.sIdx, closeTo(run.last.sTrue, 6));
    });

    test('μ≈0 deficit branch lands BF 16.1 (13%-at-154 anchor)', () {
      final run =
          sim2Run(params: p, blocks: blocks, start: start, muDeficit: 0.0);
      expect(run.end.bfPct, closeTo(16.1, 0.3));
      expect(run.end.bw, closeTo(171.2, 0.3)); // BW path identical
    });

    test('Monte Carlo median 1022, P(V8 sent) 0.45, injuries ~2.2', () {
      final mc = sim2MonteCarlo(params: p, blocks: blocks, start: start);
      expect(mc.medianTotal, closeTo(1022, 2));
      expect(mc.p20Total, closeTo(1013, 3));
      expect(mc.p80Total, closeTo(1030, 3));
      expect(mc.pV8Sent, closeTo(0.45, 0.03));
      expect(mc.pV8Touch, closeTo(0.02, 0.02));
      expect(mc.injuryWeeksMean, closeTo(2.2, 0.5));
    });

    test('Cardio up holds VO2 ~52; Cardio off drops it toward ~46', () {
      final up = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'cardio_up');
      expect(up.end.vo2, closeTo(52.0, 0.4));
      final off = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'cardio_off');
      expect(off.end.vo2, lessThan(48));
    });

    test('Climb more: lifting gains fall, budget blows (§9.4)', () {
      final base = sim2Run(params: p, blocks: blocks, start: start);
      final climb = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'climb_more');
      expect(climb.end.s, lessThan(base.end.s - 30)); // 968 vs 1023
      expect(climb.overBudgetWeeks, greaterThan(base.overBudgetWeeks));
      expect(climb.end.f, greaterThan(0.8)); // F_end 1.06
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
      final base = sim2Run(params: p, blocks: blocks, start: start);
      final fast = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'fast_bulk');
      expect(fast.end.fm - sim2SeedFm,
          greaterThan(base.end.fm - sim2SeedFm + 8)); // +14.8 vs +1.1
      expect(fast.end.s, lessThanOrEqualTo(base.end.s + 8));
      expect(fast.end.bw, closeTo(187, 1.5));
    });

    test('Drop calisthenics decays M; dial overrides move the horizon', () {
      final base = sim2Run(params: p, blocks: blocks, start: start);
      final drop = sim2Run(
          params: p, blocks: blocks, start: start, presetId: 'drop_cal');
      expect(drop.end.m, lessThan(base.end.m - 0.5));
      // Global N override (the dials row) moves the strength horizon
      // (saturating near-max gain + its load cost: ~+3 lb at N=10).
      final n10 = sim2Run(
          params: p,
          blocks: blocks,
          start: start,
          overrides: const Sim2DialOverrides(n: 10));
      expect(n10.end.s, greaterThan(base.end.s + 2));
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
