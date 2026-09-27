// ignore_for_file: avoid_print
// sim2_replay.dart — §9.2 of the v2 training-simulator spec.
// Replays the log through the §1+§2 model with actual weekly dials from
// calibration_weekly.csv (K=0 before Aug 2024) and checks model S against
// the estimated total (total_at_start in calibration_windows.csv) at the
// spec checkpoints: Bulk C rise ~30 then fade, Bulk D 10-wk rise then
// stall (over budget), 2025-26 cut fall ~75. PASS = within ±40 lb.
//
// Run: dart run tool/sim2_replay.dart [--params priors|fitted] [--trace]

import 'dart:math';

import 'sim2_model.dart';

void main(List<String> args) {
  final usePriors = args.contains('--params') &&
      args[args.indexOf('--params') + 1] == 'priors';
  final trace = args.contains('--trace');
  var p = usePriors ? Sim2Params() : Sim2Params.fitted();
  if (args.contains('--abcd')) {
    final v = args[args.indexOf('--abcd') + 1]
        .split(',')
        .map(double.parse)
        .toList();
    p = Sim2Params(a: v[0], b: v[1], c: v[2], d: v[3]);
  }
  print('params: a=${p.a} b=${p.b} c=${p.c} d=${p.d} '
      '(${usePriors ? 'priors' : 'ridge fit'})');

  final weekly = loadWeekly('tool/calibration/calibration_weekly.csv');
  final windows = loadWindows('tool/calibration/calibration_windows.csv');
  final obsTotal = {for (final w in windows) w.start: w.total};

  for (final anchor in [DateTime(2023, 4, 10), DateTime(2024, 1, 1)]) {
    _replay(p, weekly, obsTotal, anchor, trace: trace);
  }
}

void _replay(Sim2Params p, List<WeeklyRow> weekly,
    Map<DateTime, double> obsTotal, DateTime anchorDate,
    {bool trace = false}) {
  final s0 = obsTotal[anchorDate]!;
  print('\n=== replay from $anchorDate (anchor S=$s0) ===');

  final rows =
      weekly.where((w) => !w.week.isBefore(anchorDate)).toList();

  // bw series: carry-forward; smoothed weekly rate (3-wk MA of diffs)
  final bws = <double>[];
  double lastBw = rows.first.bw ?? 170;
  for (final w in rows) {
    lastBw = w.bw ?? lastBw;
    bws.add(lastBw);
  }
  final rates = <double>[0.0];
  for (var i = 1; i < bws.length; i++) {
    rates.add(bws[i] - bws[i - 1]);
  }
  final rSm = <double>[];
  for (var i = 0; i < rates.length; i++) {
    final lo = max(0, i - 2);
    final win = rates.sublist(lo, i + 1);
    rSm.add(win.reduce((a, b) => a + b) / win.length);
  }
  // slower rate for phase detection (4-wk MA): cuts are sustained
  final rPhase = <double>[];
  for (var i = 0; i < rates.length; i++) {
    final lo = max(0, i - 3);
    final win = rates.sublist(lo, i + 1);
    rPhase.add(win.reduce((a, b) => a + b) / win.length);
  }

  var s = s0;
  var f = 0.0;
  var inDeficit = false;
  var cutStartS = s0;
  var cutStartBw = bws.first;
  var reboundPool = 0.0;
  var reboundLeft = 0;
  final cutLosses = <String, double>{}; // cut label -> (S at start − S at end)

  final errs = <(DateTime, double, double, double)>[]; // date, model, obs, F
  for (var i = 0; i < rows.length; i++) {
    final w = rows[i];
    // compare BEFORE stepping: obs total_at_start is start-of-window
    final obs = obsTotal[w.week];
    if (obs != null) errs.add((w.week, s, obs, f));

    final k = w.week.isBefore(DateTime(2024, 8, 1)) ? 0.0 : (w.k ?? 0.0);
    final dials = Dials(
        dSessions: w.dSess,
        n: w.n,
        w: w.w,
        k: k, // K_lim=0: 2024-25 climbing was unstructured [assume]
        z: 0, // no bike column in the log [assume]
        q: 0,
        r: rSm[i]);

    final l = loadL(dials);
    final cap = lCap(bw: bws[i], r: dials.r);
    final e = effectiveness(f);
    final over = max(0.0, l - cap) / cap;
    var fNext = p.fDecay * f + over;
    if (w.light) fNext *= 0.5;

    var dS = deltaS(p, dials,
        bw: bws[i], e: e, stimulusScale: w.light ? 0.4 : 1.0);

    // §2 rebound: 60% of the cut's loss back over first 3 surplus weeks.
    // Episode detection with hysteresis on a 4-wk bw-rate MA; the rebound
    // only fires for a real cut (>= 4 lb of bodyweight lost) [assume].
    if (!inDeficit && rPhase[i] < -0.2) {
      inDeficit = true;
      cutStartS = s;
      cutStartBw = bws[i];
    } else if (inDeficit && rPhase[i] > 0.1) {
      inDeficit = false;
      if (cutStartBw - bws[i] >= 4.0) {
        final loss = max(0.0, cutStartS - s);
        cutLosses[w.week.toIso8601String().substring(0, 10)] = loss;
        reboundPool = 0.6 * loss;
        reboundLeft = 3;
      }
    }
    if (reboundLeft > 0) {
      final chunk = reboundPool / reboundLeft;
      dS += chunk;
      reboundPool -= chunk;
      reboundLeft--;
    }

    s += dS;
    f = fNext;

    if (trace && obs != null) {
      print('  ${w.week.toIso8601String().substring(0, 10)} '
          'model=${s.toStringAsFixed(0).padLeft(5)} '
          'obs=${obs.toStringAsFixed(0).padLeft(5)} '
          'F=${f.toStringAsFixed(2)} e=${e.toStringAsFixed(2)} '
          'L=${l.toStringAsFixed(1)}/${cap.toStringAsFixed(1)}'
          '${l > cap ? ' OVER' : ''}');
    }
  }

  // checkpoints (obs values from calibration_windows total_at_start)
  final checkpoints = <(String, DateTime)>[
    ('Bulk C start', DateTime(2024, 3, 25)),
    ('Bulk C peak (+~30 rise)', DateTime(2024, 6, 17)),
    ('Bulk C fade', DateTime(2024, 8, 26)),
    ('Bulk D start (post-cut trough)', DateTime(2024, 12, 30)),
    ('Bulk D 12-wk rise', DateTime(2025, 3, 24)),
    ('Bulk D stall (over budget)', DateTime(2025, 6, 16)),
    ('cut start (2025-26)', DateTime(2025, 10, 20)),
    ('cut end (fall ~75)', DateTime(2026, 7, 27)),
  ];
  print('checkpoints (PASS = |model − est. total| <= 40; expr = S − 40·F,');
  print('the fatigue-masked EXPRESSED total [assume κ=40], diagnostic only):');
  var allPass = true;
  for (final (label, date) in checkpoints) {
    if (date.isBefore(anchorDate)) continue;
    final row = errs.where((e) => e.$1 == date).toList();
    if (row.isEmpty) {
      print('  $label $date: no obs row');
      continue;
    }
    final (_, model, obs, fAt) = row.first;
    final err = model - obs;
    final exprErr = model - 40 * fAt - obs;
    final pass = err.abs() <= 40;
    allPass &= pass;
    print('  ${label.padRight(31)} ${date.toIso8601String().substring(0, 10)}'
        '  model=${model.toStringAsFixed(0).padLeft(5)}'
        '  obs=${obs.toStringAsFixed(0).padLeft(5)}'
        '  err=${err.toStringAsFixed(0).padLeft(4)}  '
        '${pass ? 'PASS' : 'FAIL'}'
        '  (expr err=${exprErr.toStringAsFixed(0).padLeft(4)}, '
        'F=${fAt.toStringAsFixed(2)})');
  }
  print('  -> ${allPass ? 'ALL PASS' : 'FAILURES PRESENT'}');

  // overall tracking quality + cut-cost diagnostic (§2 prior: −3..−4/lb)
  final absErrs = errs.map((e) => (e.$2 - e.$3).abs()).toList();
  absErrs.sort();
  print('tracking: n=${errs.length} obs points, '
      'median |err|=${absErrs[absErrs.length ~/ 2].toStringAsFixed(0)}, '
      'max |err|=${absErrs.last.toStringAsFixed(0)}');
  if (cutLosses.isNotEmpty) {
    print('model cut losses (S at deficit start − at surplus resume): '
        '${cutLosses.entries.map((e) => '${e.key}: ${e.value.toStringAsFixed(0)}').join(', ')}');
  }
}
