// ignore_for_file: avoid_print
// sim2_fit.dart — §9.1 of the v2 training-simulator spec.
// Fits a, b, c, d (§2, functional form held) on calibration_windows.csv,
// target gain_14wk_from_start/14; validates on gain_14wk_after_window/14.
// Ridge toward the spec priors, weighted for the ~45 effective sample
// (174 windows overlap with step 2 wk). Also: §2 marginal-bin reproduction
// and the §1 budget anchors (under / under / over).
//
// Run: dart run tool/sim2_fit.dart

import 'dart:math';

import 'sim2_model.dart';

const priors = [3.0, 0.4, 2.5, 0.8]; // a, b, c, d
const priorSd = [1.5, 0.2, 1.25, 0.4]; // ridge scale: 50% of prior [assume]

void main() {
  final windows = loadWindows('tool/calibration/calibration_windows.csv');
  final weekly = loadWeekly('tool/calibration/calibration_weekly.csv');

  // --- design matrix -------------------------------------------------------
  // y' = y + pen = a·x1 + b·x2 + c·x3 + d·x4   with x4 = −1
  // x1 = e·(1−exp(−N/4)), x2 = e·(W−20)/10, x3 = clip(r,−1,.5)
  // e from steady-state F for the window's sustained load (Z=Q=0, K_lim=0:
  // the historical log has no bike/calisthenics/limit columns) [assume].
  List<double> features(WindowRow w) {
    final l = loadL(Dials(
        dSessions: w.dSess, n: w.n, w: w.w, k: w.k, r: w.r));
    final e = effectiveness(steadyF(l, lCap(bw: w.bw, r: w.r)));
    return [
      e * (1 - exp(-w.n / 4)),
      e * (w.w - 20) / 10,
      w.r.clamp(-1.0, 0.5),
      -1.0,
    ];
  }

  double target(WindowRow w, double y) => y + (w.bw > 176 ? 0.5 : 0.0);

  final train = windows.where((w) => w.yStart != null).toList();
  final xs = train.map(features).toList();
  final ys = train.map((w) => target(w, w.yStart!)).toList();

  // --- OLS + ridge ---------------------------------------------------------
  final ols = _solveRidge(xs, ys, lambdaScale: 0);
  // effective sample ~45 of 174 → weight each row 45/174; prior worth ~1 obs
  // per unit of (θ−θ0)/σ². Implemented by scaling the data term.
  final wRow = 45.0 / train.length;
  final ridge = _solveRidge(xs, ys, lambdaScale: 1.0, rowWeight: wRow);

  print('=== §9.1 FIT (n=${train.length} windows, effective ~45) ===');
  print('            a       b       c       d');
  print('priors   ${_fmtRow(priors)}');
  print('OLS      ${_fmtRow(ols)}');
  print('ridge    ${_fmtRow(ridge)}   <-- shipped (Sim2Params.fitted)');

  for (final entry in {'priors': priors, 'OLS': ols, 'ridge': ridge}.entries) {
    final th = entry.value;
    final r2t = _r2(windows.where((w) => w.yStart != null),
        (w) => _pred(features(w), th) - (w.bw > 176 ? 0.5 : 0.0),
        (w) => w.yStart!);
    final r2v = _r2(windows.where((w) => w.yAfter != null),
        (w) => _pred(features(w), th) - (w.bw > 176 ? 0.5 : 0.0),
        (w) => w.yAfter!);
    print('${entry.key.padRight(7)} R² train(from_start)='
        '${r2t.toStringAsFixed(3)}  validate(after_window)='
        '${r2v.toStringAsFixed(3)}');
  }

  // --- §2 marginal-bin reproduction ---------------------------------------
  double predRidge(WindowRow w) =>
      _pred(features(w), ridge) - (w.bw > 176 ? 0.5 : 0.0);

  print('\n=== §2 marginal bins: observed mean vs model mean (lb/wk on total) ===');
  _bins('near-max N', windows, (w) => w.n, [
    ('<=2', 0, 2, -2.9),
    ('2-4', 2, 4, -0.3),
    ('4-6', 4, 6, 1.2),
    ('6-10', 6, 10, 2.4),
    ('10+', 10, 999, 2.5),
  ], predRidge);
  _bins('working W', windows, (w) => w.w, [
    ('<10', 0, 10, -0.5),
    ('10-15', 10, 15, -0.2),
    ('15-20', 15, 20, 0.5),
    ('20-25', 20, 25, 1.1),
    ('30+', 30, 999, 2.8),
  ], predRidge);
  _bins('bw rate r', windows, (w) => w.r, [
    ('<-0.5', -99, -0.5, -1.4),
    ('-0.5..-0.2', -0.5, -0.2, -1.0),
    ('-0.2..0.1', -0.2, 0.1, -0.2),
    ('0.1..0.35', 0.1, 0.35, 0.7),
    ('0.35..0.6', 0.35, 0.6, 1.7),
    ('>0.6', 0.6, 99, 1.1),
  ], predRidge);

  // --- §1 budget anchors ---------------------------------------------------
  // (a) The spec's own anchor arithmetic (§1 stated dials through the L
  // formula's session terms; caps: surplus 7.0, bw>176 5.5).
  print('\n=== §1 budget anchors, spec-stated dials (must be under/under/over) ===');
  void stated(String label, double l, double cap) => print(
      '  $label: L=${l.toStringAsFixed(1)} vs cap ${cap.toStringAsFixed(1)}'
      ' -> ${l > cap ? 'OVER' : 'under'}');
  stated('Bulk C (4.5 lift, 0 climb, ~1 cardio)', 4.5 + 0.7, 7.0);
  stated('Dec24-Feb25 (3.6 lift, ~2 climb)     ', 3.6 + 2.0, 7.0);
  stated('Bulk D wk11-19 (4.3 lift, 3-4 climb, bw>176)', 4.3 + 3.5, 5.5);

  // (b) Recomputed from calibration_weekly.csv (cap from period-avg bw;
  // note where the data disagrees with the anchor arithmetic).
  print('\n--- same periods recomputed from calibration_weekly.csv ---');
  _anchor('Bulk C  2024-03-25..2024-06-09 (Z=1 per spec)', weekly,
      DateTime(2024, 3, 25), DateTime(2024, 6, 9), z: 1);
  _anchor('Dec24-Feb25  2024-12-02..2025-02-23', weekly,
      DateTime(2024, 12, 2), DateTime(2025, 2, 23));
  _anchor('Bulk D wk11-19  2025-03-10..2025-05-11', weekly,
      DateTime(2025, 3, 10), DateTime(2025, 5, 11));
  print('  note: the weekly data adds the 0.15·(N−4) term the spec anchors'
      ' omit\n  (Dec24-Feb25 ran N≈13.7 — that term alone is +1.5), and Bulk'
      ' D wk11-19\n  logged ~1.8 climbs/wk, not 3-4; it is over budget there'
      ' via bw>176 (cap 5.5).');
}

double _pred(List<double> x, List<double> th) {
  var s = 0.0;
  for (var i = 0; i < 4; i++) s += x[i] * th[i];
  return s;
}

List<double> _solveRidge(List<List<double>> xs, List<double> ys,
    {required double lambdaScale, double rowWeight = 1.0}) {
  final ata = List.generate(4, (_) => List.filled(4, 0.0));
  final atb = List.filled(4, 0.0);
  for (var k = 0; k < xs.length; k++) {
    for (var i = 0; i < 4; i++) {
      atb[i] += rowWeight * xs[k][i] * ys[k];
      for (var j = 0; j < 4; j++) {
        ata[i][j] += rowWeight * xs[k][i] * xs[k][j];
      }
    }
  }
  if (lambdaScale > 0) {
    for (var i = 0; i < 4; i++) {
      final lam = lambdaScale / (priorSd[i] * priorSd[i]);
      ata[i][i] += lam;
      atb[i] += lam * priors[i];
    }
  }
  return _gauss4(ata, atb);
}

List<double> _gauss4(List<List<double>> a, List<double> b) {
  final m = [for (var i = 0; i < 4; i++) [...a[i], b[i]]];
  for (var col = 0; col < 4; col++) {
    var piv = col;
    for (var r = col + 1; r < 4; r++) {
      if (m[r][col].abs() > m[piv][col].abs()) piv = r;
    }
    final t = m[col]; m[col] = m[piv]; m[piv] = t;
    for (var r = 0; r < 4; r++) {
      if (r == col) continue;
      final f = m[r][col] / m[col][col];
      for (var c2 = col; c2 <= 4; c2++) m[r][c2] -= f * m[col][c2];
    }
  }
  return [for (var i = 0; i < 4; i++) m[i][4] / m[i][i]];
}

double _r2(Iterable<WindowRow> rows, double Function(WindowRow) pred,
    double Function(WindowRow) actual) {
  final ys = rows.map(actual).toList();
  final mean = ys.reduce((a, b) => a + b) / ys.length;
  var sse = 0.0, sst = 0.0;
  var i = 0;
  for (final w in rows) {
    final e = actual(w) - pred(w);
    sse += e * e;
    sst += (ys[i] - mean) * (ys[i] - mean);
    i++;
  }
  return 1 - sse / sst;
}

String _fmtRow(List<double> th) =>
    th.map((v) => v.toStringAsFixed(2).padLeft(6)).join('  ');

void _bins(
    String label,
    List<WindowRow> windows,
    double Function(WindowRow) dial,
    List<(String, double, double, double)> bins,
    double Function(WindowRow) pred) {
  print('$label:');
  print('  bin          n   spec-obs   data-obs   model');
  for (final (name, lo, hi, specObs) in bins) {
    final rows = windows
        .where((w) => w.yStart != null && dial(w) >= lo && dial(w) < hi)
        .toList();
    if (rows.isEmpty) {
      print('  ${name.padRight(11)} 0   ${specObs.toStringAsFixed(1).padLeft(7)}        —       —');
      continue;
    }
    final obs =
        rows.map((w) => w.yStart!).reduce((a, b) => a + b) / rows.length;
    final mod = rows.map(pred).reduce((a, b) => a + b) / rows.length;
    print('  ${name.padRight(11)} ${rows.length.toString().padRight(3)} '
        '${specObs.toStringAsFixed(1).padLeft(7)}  '
        '${obs.toStringAsFixed(1).padLeft(8)}  '
        '${mod.toStringAsFixed(1).padLeft(6)}');
  }
}

void _anchor(String label, List<WeeklyRow> weekly, DateTime from, DateTime to,
    {double z = 0}) {
  final rows = weekly
      .where((w) => !w.week.isBefore(from) && !w.week.isAfter(to))
      .toList();
  double avg(double Function(WeeklyRow) f) =>
      rows.map(f).reduce((a, b) => a + b) / rows.length;
  final d = avg((w) => w.dSess);
  final n = avg((w) => w.n);
  final k = avg((w) => w.k ?? 0);
  final bws = rows.where((w) => w.bw != null).map((w) => w.bw!).toList();
  final bw = bws.isEmpty ? 170.0 : bws.reduce((a, b) => a + b) / bws.length;
  final bwMax = bws.isEmpty ? bw : bws.reduce(max);
  final rRate = bws.length > 1 ? (bws.last - bws.first) / (rows.length - 1) : 0.0;
  final l = loadL(Dials(dSessions: d, n: n, w: 0, k: k, z: z, r: rRate));
  final cap = lCap(bw: bw, r: rRate); // period-average bw
  // weekly over-budget count, the way the sim applies §1
  var overWeeks = 0;
  for (final w in rows) {
    final wl = loadL(Dials(
        dSessions: w.dSess, n: w.n, w: 0, k: w.k ?? 0, z: z, r: rRate));
    if (wl > lCap(bw: w.bw ?? bw, r: rRate)) overWeeks++;
  }
  print('$label\n'
      '  D=${d.toStringAsFixed(1)} N=${n.toStringAsFixed(1)} '
      'K=${k.toStringAsFixed(1)} Z=$z bw_avg=${bw.toStringAsFixed(1)} '
      'bw_max=${bwMax.toStringAsFixed(1)} r=${rRate.toStringAsFixed(2)}\n'
      '  avg L=${l.toStringAsFixed(2)} vs L_cap=${cap.toStringAsFixed(1)} -> '
      '${l > cap ? 'OVER' : 'under'}'
      '  (weekly: $overWeeks/${rows.length} weeks over budget)');
}
