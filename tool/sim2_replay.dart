// ignore_for_file: avoid_print
// sim2_replay.dart — §9.2 of the v2 training-simulator spec, REVISED §2
// (two-layer). Replays the log through §1+§2 with actual weekly dials from
// calibration_weekly.csv (K=0 before Aug 2024): capacity S_cap steps from
// the weekly features; expression E comes from the series' dep/rust/bw/F;
// the model's INDEX-basis total is S_cap · gatedEma(E, N) (the Epley index
// re-reads strength only in attempt weeks — see Sim2Params.idxKAttempt).
// Checked against the
// estimated total (total_at_start, index basis) at the five revised
// checkpoints, ±40 lb, WITH the capacity-vs-expression decomposition of
// each segment — that split is the point of the revision:
//   1. Bulk C: rise ~30 then fade as F builds at 181+
//   2. 2024 cut: fall ~50, MOSTLY expression
//   3. Dec 2024–Mar 2025: +55, E recovering AND capacity rising
//   4. Bulk D wk 11–19: stall (L > L_cap)
//   5. 2025–26 cut: fall ~75 on the index, capacity ≤ ~30 of it
//
// Run: dart run tool/sim2_replay.dart [--params priors] [--trace]

import 'dart:math';

import 'sim2_model.dart';

void main(List<String> args) {
  final usePriors = args.contains('--params') &&
      args[args.indexOf('--params') + 1] == 'priors';
  final trace = args.contains('--trace');
  final p = usePriors ? Sim2Params() : Sim2Params.fitted();
  print('params: a=${p.a} b=${p.b} c=${p.c} cCut=${p.cCut} d=${p.d}  '
      'E(dep=${p.eDep}, bw=${p.eBw}, rust=${p.eRust}, F=${p.eF})  '
      'index kAttempt=${p.idxKAttempt}/kIdle=${p.idxKIdle} '
      '(${usePriors ? 'priors' : 'two-pass fit'})');

  final weekly = loadWeekly('tool/calibration/calibration_weekly.csv');
  final windows = loadWindows('tool/calibration/calibration_windows.csv');
  final obsTotal = {for (final w in windows) w.start: w.total};
  final series = buildSeries(weekly);

  // expression paths over the whole log (true + index-smoothed)
  final eTrue = series.eSeries(p);
  final eIdx = series.eIdxSeries(p);

  for (final anchor in [DateTime(2023, 4, 10), DateTime(2024, 1, 1)]) {
    _replay(p, series, eTrue, eIdx, obsTotal, anchor, trace: trace);
  }
}

void _replay(
    Sim2Params p,
    WeeklySeries s,
    List<double> eTrue,
    List<double> eIdx,
    Map<DateTime, double> obsTotal,
    DateTime anchorDate,
    {bool trace = false}) {
  final j0 = s.index[anchorDate]!;
  final s0 = obsTotal[anchorDate]!;
  print('\n=== replay from ${anchorDate.toIso8601String().substring(0, 10)} '
      '(anchor index=$s0 -> S_cap=${(s0 / eIdx[j0]).toStringAsFixed(0)} at '
      'E_idx=${eIdx[j0].toStringAsFixed(3)}) ===');

  // capacity path
  final sCap = List<double>.filled(s.rows.length, 0);
  sCap[j0] = s0 / eIdx[j0];
  for (var t = j0; t < s.rows.length - 1; t++) {
    final row = s.rows[t];
    final es = s.e[t] * s.stim[t];
    final dCap = es * (p.a * (1 - exp(-row.n / 4)) + p.b * (row.w - 20) / 10) +
        p.c * s.rSm[t].clamp(0.0, 0.5) -
        p.cCut * max(0.0, -s.rSm[t]) -
        p.d -
        (s.bw[t] > 176 ? 0.5 : 0.0);
    sCap[t + 1] = sCap[t] + dCap;
  }

  double modelIdx(int t) => sCap[t] * eIdx[t];
  double modelTrue(int t) => sCap[t] * eTrue[t];

  if (trace) {
    for (var t = j0; t < s.rows.length; t++) {
      final obs = obsTotal[s.rows[t].week];
      if (obs == null) continue;
      print('  ${s.rows[t].week.toIso8601String().substring(0, 10)} '
          'idx=${modelIdx(t).toStringAsFixed(0).padLeft(5)} '
          'obs=${obs.toStringAsFixed(0).padLeft(5)} '
          'true=${modelTrue(t).toStringAsFixed(0)} '
          'cap=${sCap[t].toStringAsFixed(0)} '
          'E=${eTrue[t].toStringAsFixed(3)}/${eIdx[t].toStringAsFixed(3)} '
          'F=${s.f[t].toStringAsFixed(2)} dep=${s.dep[t].toStringAsFixed(2)} '
          'rust=${s.rust[t].toStringAsFixed(2)}');
    }
  }

  // ---- five revised checkpoints (±40 lb gate on the model index) ----------
  final checkpoints = <(String, String, String)>[
    // label, segment start, checkpoint/segment end
    ('1. Bulk C rise ~30 then fade ', '2024-03-25', '2024-06-17'),
    ('2. 2024 cut fall ~50 mostly E', '2024-08-26', '2024-12-30'),
    ('3. Dec24-Mar25 +55 (E + cap) ', '2024-12-30', '2025-03-24'),
    ('4. Bulk D wk11-19 stall      ', '2025-03-24', '2025-06-16'),
    ('5. 2025-26 cut fall ~75      ', '2025-10-20', '2026-07-27'),
  ];
  print('checkpoints (gate: |model index − est. total| <= 40 at segment end;');
  print('Δ split: capacity = Ē·ΔS_cap, expression = S̄_cap·ΔE_idx — exact):');
  var allPass = true;
  for (final (label, d0s, d1s) in checkpoints) {
    final d0 = DateTime.parse(d0s), d1 = DateTime.parse(d1s);
    if (d0.isBefore(anchorDate)) {
      print('  $label — before anchor, skipped');
      continue;
    }
    final t0 = s.index[d0]!, t1 = s.index[d1]!;
    final obs0 = obsTotal[d0], obs1 = obsTotal[d1];
    final err = modelIdx(t1) - (obs1 ?? double.nan);
    final pass = err.abs() <= 40;
    allPass &= pass;
    // exact midpoint decomposition of the MODEL index change
    final dCap = sCap[t1] - sCap[t0];
    final dE = eIdx[t1] - eIdx[t0];
    final eBar = (eIdx[t1] + eIdx[t0]) / 2;
    final cBar = (sCap[t1] + sCap[t0]) / 2;
    print('  $label $d1s  model=${modelIdx(t1).toStringAsFixed(0).padLeft(4)} '
        'obs=${obs1?.toStringAsFixed(0).padLeft(4)} '
        'err=${err.toStringAsFixed(0).padLeft(4)}  ${pass ? 'PASS' : 'FAIL'}');
    print('     segment Δ: model=${(modelIdx(t1) - modelIdx(t0)).toStringAsFixed(0).padLeft(4)} '
        '(obs ${obs0 == null || obs1 == null ? '  — ' : (obs1 - obs0).toStringAsFixed(0).padLeft(4)})'
        '  = capacity ${(eBar * dCap).toStringAsFixed(0).padLeft(4)}'
        '  + expression ${(cBar * dE).toStringAsFixed(0).padLeft(4)}'
        '   [true-E expressed Δ: ${(modelTrue(t1) - modelTrue(t0)).toStringAsFixed(0)}]');
  }
  print('  -> ${allPass ? 'ALL PASS' : 'FAILURES PRESENT'}');

  // overall tracking quality
  final errs = <double>[];
  for (var t = j0; t < s.rows.length; t++) {
    final obs = obsTotal[s.rows[t].week];
    if (obs != null) errs.add((modelIdx(t) - obs).abs());
  }
  errs.sort();
  print('tracking: n=${errs.length} obs points, '
      'median |err|=${errs[errs.length ~/ 2].toStringAsFixed(0)}, '
      'max |err|=${errs.last.toStringAsFixed(0)}');
}
