// ignore_for_file: avoid_print
// sim2_horizon.dart — §8 harness core + §9.3 horizon estimate + §9.4 presets.
// Minimal tool implementation for wave 1 (full lib/UI is wave 2): all
// modules §2-§6, light/test-week rules, block calendar from
// airledger-fitness coach/program.yaml v1 (bulk-2026-27), Monte Carlo
// with the §7 injury module + weekly noise for P(V8).
//
// Run: dart run tool/sim2_horizon.dart

import 'dart:math';

import 'sim2_model.dart';

// --- block calendar (coach/program.yaml v1, bulk-2026-27) -------------------
class Block {
  final int n;
  final DateTime start, end;
  final String emphasis; // cut / reverse / climbing / lifting
  final double r;
  Block(this.n, this.start, this.end, this.emphasis, this.r);
}

final blocks = [
  Block(0, DateTime.utc(2026, 9, 21), DateTime.utc(2026, 12, 13), 'cut', -0.75),
  Block(1, DateTime.utc(2026, 12, 14), DateTime.utc(2027, 1, 3), 'reverse', 0.15),
  Block(2, DateTime.utc(2027, 1, 4), DateTime.utc(2027, 2, 28), 'climbing', 0.4),
  Block(3, DateTime.utc(2027, 3, 1), DateTime.utc(2027, 4, 25), 'lifting', 0.4),
  Block(4, DateTime.utc(2027, 4, 26), DateTime.utc(2027, 6, 20), 'climbing', 0.4),
  Block(5, DateTime.utc(2027, 6, 21), DateTime.utc(2027, 8, 15), 'lifting', 0.4),
  Block(6, DateTime.utc(2027, 8, 16), DateTime.utc(2027, 10, 10), 'climbing', 0.2),
  Block(7, DateTime.utc(2027, 10, 11), DateTime.utc(2027, 12, 5), 'lifting', 0.2),
];

// --- baseline dials per block type ------------------------------------------
// [log/assume] cut dials from current logged weeks (D~3.5, W~14, N~2-3,
// K=2 with the Tuesday limit session); bulk-block dials from spec §0 +
// program targets. Climbing-block N=3 [assume]: top-set RPE cap 8 kills
// most sets that count as near-max (RPE 8.5+).
Dials dialsFor(Block b) {
  switch (b.emphasis) {
    case 'cut':
      return Dials(
          dSessions: 3.5, n: 3, w: 14, k: 2, kLim: 1, z: 1, q: 1, r: b.r);
    case 'reverse':
      return Dials(
          dSessions: 4, n: 3, w: 20, k: 2, kLim: 1, z: 1, q: 1, r: b.r);
    case 'climbing':
      return Dials(
          dSessions: 4, n: 3, w: 28, k: 3, kLim: 1, h: 1, z: 1, q: 1, r: b.r);
    default: // lifting
      return Dials(
          dSessions: 4, n: 6, w: 28, k: 2, kLim: 0, z: 1, q: 1, r: b.r);
  }
}

WeekType weekTypeFor(Block b, int weekInBlock) {
  if (b.n < 2) return WeekType.normal; // blocks 0-1: every week normal
  final w = weekInBlock % 8;
  if (w == 3) return WeekType.light; // week 4 of 8
  if (w == 7) return WeekType.test; // week 8 of 8
  return WeekType.normal;
}

// --- current state, Sep 26 2026 (spec §0) ------------------------------------
Sim2State initialState() => Sim2State(
      s: 878, // per spec §0 (per-lift values below sum 884; total kept at 878)
      squat: 310, bench: 238, deadlift: 336, press: 138,
      cSkill: 6.6, // C=6.6 read as skill level; C_pot adds the bw term [assume]
      vabs: 52 * (163 * 0.45359) / 1000, // 3.85 L/min
      bw: 163, fm: 29, lm: 134, f: 0.3, m: 2,
      // the 2025-26 cut so far: model replay loss ~50 through Jul-2026 +
      // remaining sim-cut loss accrues on top. Seeded via cutStartS: the
      // §2 rebound returns 0.6·(cut total). Cut-start total 975 [log:
      // windows total ~978 at 2025-10-20]. [assume]
      cutStartS: 975,
      inDeficit: true,
    );

const horizon = '2027-12-05';

class RunResult {
  final Sim2State st;
  final int overBudgetWeeks;
  final List<String> redFlagWeeks;
  final double maxCPot;
  final Map<String, Sim2State> blockEnds; // 'B3' -> state copy
  final int injuryWeeks;
  RunResult(this.st, this.overBudgetWeeks, this.redFlagWeeks, this.maxCPot,
      this.blockEnds, this.injuryWeeks);
}

RunResult run(Sim2Params p,
    {Dials Function(Block)? dials,
    Random? rng,
    double sNoise = 0,
    double cNoise = 0,
    bool injuries = false,
    bool trace = false,
    double? eOverride,
    double zOverrideFromBlock3 = -1}) {
  final st = initialState();
  final d = dials ?? dialsFor;
  var over = 0;
  var injuryWeeks = 0;
  final redFlags = <String>[];
  final blockEnds = <String, Sim2State>{};
  var maxCPot = st.c;
  // injury state
  var injAffectedWeeks = 0, hangBanWeeks = 0;

  var date = DateTime.utc(2026, 9, 28); // first sim Monday
  final end = DateTime.parse('$horizon 00:00:00Z');
  while (!date.isAfter(end)) {
    final b = blocks.lastWhere((b) => !date.isBefore(b.start),
        orElse: () => blocks.first);
    final weekInBlock = date.difference(b.start).inDays ~/ 7;
    final x = d(b).copy();
    if (zOverrideFromBlock3 >= 0 && b.n >= 3) x.z = zOverrideFromBlock3;

    // §7 injury effects
    if (injAffectedWeeks > 0) {
      x.n = 0;
      x.kLim = 0;
      injAffectedWeeks--;
      injuryWeeks++;
    }
    if (hangBanWeeks > 0) {
      x.h = 0;
      hangBanWeeks--;
    }

    final wt = weekTypeFor(b, weekInBlock);
    final res = stepWeek(p, st, x, wt,
        rng: rng, sNoise: sNoise, cNoise: cNoise, eOverride: eOverride);
    if (trace) {
      print('  ${date.toIso8601String().substring(0, 10)} B${b.n} '
          '${wt.name.padRight(6)} S=${st.s.toStringAsFixed(0)} '
          'dS=${res.dS.toStringAsFixed(1).padLeft(5)} '
          'F=${st.f.toStringAsFixed(2)} e=${res.e.toStringAsFixed(2)} '
          'L=${res.l.toStringAsFixed(1)}/${res.cap.toStringAsFixed(1)} '
          'bw=${st.bw.toStringAsFixed(1)} pool=${st.reboundPool.toStringAsFixed(0)}');
    }
    if (res.overBudget) {
      over++;
      redFlags.add(
          '${date.toIso8601String().substring(0, 10)} B${b.n} ${b.emphasis}'
          ' L=${res.l.toStringAsFixed(1)}>${res.cap.toStringAsFixed(1)}'
          ' F=${st.f.toStringAsFixed(2)}');
    }
    final cPot = st.cSkill + (0.06 * (168 - st.bw)).clamp(-1.0, 1.0);
    maxCPot = max(maxCPot, cPot);

    // §7 injury hazard
    if (injuries && rng != null) {
      final h = 0.004 +
          0.008 * x.h +
          0.008 * x.kLim +
          0.02 * max(0, st.f - 0.5); // no heavy-lower-on-climb-day in plan
      if (rng.nextDouble() < h) {
        injAffectedWeeks = 3;
        if (rng.nextDouble() < 0.5) hangBanWeeks = 4; // finger/elbow half
      }
    }

    final nextDate = date.add(const Duration(days: 7));
    if (nextDate.isAfter(b.end) && !blockEnds.containsKey('B${b.n}')) {
      blockEnds['B${b.n}'] = st.copy();
    }
    date = nextDate;
  }
  return RunResult(st, over, redFlags, maxCPot, blockEnds, injuryWeeks);
}

void main() {
  final p = Sim2Params.fitted();
  print('params: a=${p.a} b=${p.b} c=${p.c} d=${p.d} (ridge fit; '
      '§3-§6 modules are priors)');

  // ---- baseline deterministic ----------------------------------------------
  final base = run(p, trace: const String.fromEnvironment('TRACE') == '1');
  _report('BASELINE (deterministic, Z=1)', base);

  // VO2 at Z=2 from block 3 (the "Cardio up" preset doubles as the §9.3 check)
  final z2 = run(p, zOverrideFromBlock3: 2);
  print('\nVO2 with Z=2 from block 3: ${z2.st.vo2.toStringAsFixed(1)} '
      '(vs ${base.st.vo2.toStringAsFixed(1)} at Z=1)');

  // sensitivity: no budget bite (e forced to 1) — quantifies how much of the
  // C and S gaps vs §9.3 come purely from the plan running over L_cap
  final noBite = run(p, eOverride: 1.0);
  print('sensitivity e=1 (no §1 budget bite): total='
      '${noBite.st.s.toStringAsFixed(0)}, C=${noBite.st.c.toStringAsFixed(2)} '
      '(skill ${noBite.st.cSkill.toStringAsFixed(2)})');

  // ---- Monte Carlo ----------------------------------------------------------
  const paths = 200;
  final totals = <double>[], cs = <double>[];
  var v8Touch = 0, v8Sent = 0;
  var injWeeksTotal = 0;
  for (var i = 0; i < paths; i++) {
    final rng = Random(42 + i);
    final r = run(p, rng: rng, sNoise: 1.5, cNoise: 0.05, injuries: true);
    totals.add(r.st.s);
    cs.add(r.st.c);
    if (r.maxCPot >= 8.0) v8Touch++;
    // "sent V8" = peak C_pot + 0.4 send margin >= 8.0. Margin from the
    // spec's own state: C=6.6 is defined as "V7 once, V6 regular", i.e.
    // hardest send runs ~0.4 above the continuous grade. [log]
    if (r.maxCPot + 0.4 >= 8.0) v8Sent++;
    injWeeksTotal += r.injuryWeeks;
  }
  totals.sort();
  cs.sort();
  print('\n=== Monte Carlo ($paths paths: §7 injuries + weekly noise '
      'σS=1.5 lb, σC=0.05 V [assume]) ===');
  print('total  median=${totals[paths ~/ 2].toStringAsFixed(0)}  '
      'p20=${totals[paths ~/ 5].toStringAsFixed(0)}  '
      'p80=${totals[4 * paths ~/ 5].toStringAsFixed(0)}');
  print('C      median=${cs[paths ~/ 2].toStringAsFixed(1)}   '
      'p20=${cs[paths ~/ 5].toStringAsFixed(1)}');
  print('P(V8 sent: peak C_pot+0.4 send margin >= 8.0) = '
      '${(v8Sent / paths).toStringAsFixed(2)}   [§9.3 expects ~0.45]');
  print('P(continuous C_pot itself touches 8.0) = '
      '${(v8Touch / paths).toStringAsFixed(2)}');
  print('injury-weeks mean = ${(injWeeksTotal / paths).toStringAsFixed(1)}');

  // ---- §9.4 preset sanity ----------------------------------------------------
  print('\n=== §9.4 preset: Climb more (K=4, H=1 all year) ===');
  final climbMore = run(p, dials: (b) {
    final x = dialsFor(b);
    x.k = 4;
    x.kLim = 1;
    x.h = 1;
    return x;
  });
  _presetVsBase('Climb more', climbMore, base);
  final liftGainBase = _liftingBlockGain(p, base, dialsFor);
  final liftGainClimb = _liftingBlockGain(p, climbMore, (b) {
    final x = dialsFor(b);
    x.k = 4;
    x.kLim = 1;
    x.h = 1;
    return x;
  });
  print('  lifting-block strength gain: baseline '
      '+${liftGainBase.toStringAsFixed(0)} lb vs climb-more '
      '+${liftGainClimb.toStringAsFixed(0)} lb '
      '-> ${liftGainClimb < liftGainBase ? 'FALLS (expected)' : 'DOES NOT FALL (unexpected)'}');

  print('\n=== §9.4 preset: Fast bulk (r=0.9 blocks 2-5) ===');
  final fastBulk = run(p, dials: (b) {
    final x = dialsFor(b);
    if (b.n >= 2 && b.n <= 5) x.r = 0.9;
    return x;
  });
  _presetVsBase('Fast bulk', fastBulk, base);
  print('  fat gained: baseline +${(base.st.fm - 29).toStringAsFixed(1)} lb '
      'vs fast-bulk +${(fastBulk.st.fm - 29).toStringAsFixed(1)} lb');
  print('  strength: baseline ${base.st.s.toStringAsFixed(0)} vs fast-bulk '
      '${fastBulk.st.s.toStringAsFixed(0)} '
      '(${fastBulk.st.s <= base.st.s + 8 ? 'no extra strength above r=0.5 (expected)' : 'UNEXPECTED extra strength'})');
}

double _liftingBlockGain(
    Sim2Params p, RunResult r, Dials Function(Block) dials) {
  // sum of S change across lifting blocks (3, 5, 7) from block-end snapshots
  double gain = 0;
  for (final n in [3, 5, 7]) {
    final endS = r.blockEnds['B$n']?.s;
    final startS = r.blockEnds['B${n - 1}']?.s;
    if (endS != null && startS != null) gain += endS - startS;
  }
  return gain;
}

void _presetVsBase(String label, RunResult r, RunResult base) {
  print('  $label: total=${r.st.s.toStringAsFixed(0)} '
      '(base ${base.st.s.toStringAsFixed(0)}), '
      'BW=${r.st.bw.toStringAsFixed(0)}, BF=${r.st.bfPct.toStringAsFixed(1)}%, '
      'C=${r.st.c.toStringAsFixed(1)}, F_end=${r.st.f.toStringAsFixed(2)}, '
      'over-budget weeks=${r.overBudgetWeeks} (base ${base.overBudgetWeeks})');
}

void _report(String label, RunResult r) {
  final st = r.st;
  print('\n=== $label -> $horizon ===');
  print('total   ${st.s.toStringAsFixed(0)}  '
      '(squat ${st.squat.toStringAsFixed(0)}, bench ${st.bench.toStringAsFixed(0)}, '
      'deadlift ${st.deadlift.toStringAsFixed(0)}; press ${st.press.toStringAsFixed(0)})'
      '   [§9.3 expects 980, 940-1020]');
  print('BW      ${st.bw.toStringAsFixed(1)} lb   [expects 169]');
  print('BF%     ${st.bfPct.toStringAsFixed(1)}  (FM ${st.fm.toStringAsFixed(1)}, '
      'LM ${st.lm.toStringAsFixed(1)})   [expects 15-16%]');
  print('C       ${st.c.toStringAsFixed(2)} (skill ${st.cSkill.toStringAsFixed(2)}, '
      'peak C_pot ${r.maxCPot.toStringAsFixed(2)})   [expects ~7.3]');
  print('VO2     ${st.vo2.toStringAsFixed(1)}   [expects ~49 at Z=1]');
  print('M       ${st.m.toStringAsFixed(1)} reps');
  print('F end   ${st.f.toStringAsFixed(2)};  over-budget weeks: '
      '${r.overBudgetWeeks}');
  if (r.redFlagWeeks.isNotEmpty) {
    print('red-flag weeks (L > L_cap — model confidence collapses here):');
    for (final w in r.redFlagWeeks.take(12)) {
      print('  $w');
    }
    if (r.redFlagWeeks.length > 12) {
      print('  ... ${r.redFlagWeeks.length - 12} more');
    }
  }
  print('block-end totals: ${r.blockEnds.entries.map((e) => '${e.key}='
      '${e.value.s.toStringAsFixed(0)}/bw${e.value.bw.toStringAsFixed(0)}').join(' ')}');
}
