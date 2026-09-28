// ignore_for_file: avoid_print
// sim2_horizon.dart — §8 harness core + §9.3 horizon estimate + §9.4 presets,
// REVISED §2 (two-layer: capacity × expression). All modules §2-§6,
// light/test-week rules, block calendar from airledger-fitness
// coach/program.yaml v1 (bulk-2026-27), Monte Carlo with the §7 injury
// module + weekly noise for P(V8).
//
// W1 adaptations KEPT (labeled): VO2 gain ∝ max(0, Z_eff − 1) (see
// Sim2Params.kV note); P(V8 sent) uses peak C_pot + 0.4 send margin
// (C=6.6 is defined as "V7 once, V6 regular" → hardest send runs ~0.4
// above the continuous grade) [log].
//
// v2.1: S_cap is seeded from TODAY'S RPE-IMPLIED maxes (§2 anchors: bench
// 244, squat 331, deadlift 342 → total 917), the spec's preferred S_obs
// basis; the Epley index (878) sits below through the dep-depressed,
// attempt-sparse cut (measurement gap ≈ 39 lb that closes as near-max
// attempts resume — index catch-up, not physiology). The horizon reports
// TRUE expressed strength (S_cap·E, no index smoothing) and splits every
// gain into capacity vs expression. §5's deficit μ runs as two branches
// (μ=0.30 per the §5 rule at r=−0.75, and μ≈0 which is what the spec's
// own 13%-at-154 anchor implies) pending the Nov DEXA.
//
// Run: dart run tool/sim2_horizon.dart
//
// NOTE (2026-09-27): this CLI still carries the v8 bulk/recomp dials it
// was written with. The AUTHORITATIVE dials + presets live in
// lib/services/sim2_harness.dart (sim2BaselineDials — v9 post-cut
// template: N=4, W=30), pinned by test/sim2_model_test.dart; prefer the
// harness for current horizon numbers.

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
// K=2 with the Tuesday limit session); training dials for blocks 2-7
// from spec §0 + program targets. Climbing-block N=3 [assume]: top-set
// RPE cap 8 kills most sets that count as near-max (RPE 8.5+).
//
// RECOMP BASELINE (2026-09-26, program.yaml v8): blocks 2-7 run the
// recomposition variant — r = 0.075 (the 0..0.15 band's midpoint,
// replacing the calendar's superseded bulk rates kept in `blocks`
// above) and p = 1.05 (protein 1.0-1.1 g/lb). Matches the shipped
// harness (lib/services/sim2_harness.dart sim2BaselineDials); the old
// bulk trajectory is the harness's 'Bulk plan (inactive)' preset.
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
          dSessions: 4, n: 3, w: 28, k: 3, kLim: 1, h: 1, z: 1, q: 1,
          r: 0.075, p: 1.05);
    default: // lifting
      return Dials(
          dSessions: 4, n: 6, w: 28, k: 2, kLim: 0, z: 1, q: 1,
          r: 0.075, p: 1.05);
  }
}

WeekType weekTypeFor(Block b, int weekInBlock) {
  if (b.n < 2) return WeekType.normal; // blocks 0-1: every week normal
  final w = weekInBlock % 8;
  if (w == 3) return WeekType.light; // week 4 of 8
  if (w == 7) return WeekType.test; // week 8 of 8
  return WeekType.normal;
}

// --- current state, Sep 26 2026 ----------------------------------------------
// S_cap seeded from the RPE-implied readings (§2 anchors) divided by
// today's per-lift E. Overlay state today: dep = 1 (the 2025-26 deficit
// never really closed — bw was still falling through mid-Sep [log:
// calibration_weekly]), rust = 0 on the RPE basis (the readings ARE
// attempts), F = 0.3 (spec §0).
const rpeSquat = 331.0, rpeBench = 244.0, rpeDeadlift = 342.0; // [log]
const rpePress = 138.0 * (244.0 / 238.0); // press follows bench's ratio [assume]
const dep0 = 1.0, rust0 = 0.0, f0 = 0.3, bw0 = 163.0;

Sim2State initialState(Sim2Params p) {
  double e0(double scale) =>
      exprE(p, dep: dep0, bw: bw0, rust: rust0, f: f0, bwScale: scale);
  final st = Sim2State(
    sCap: 0,
    squatCap: rpeSquat / e0(liftBwScale[0]),
    benchCap: rpeBench / e0(liftBwScale[1]),
    deadliftCap: rpeDeadlift / e0(liftBwScale[2]),
    pressCap: rpePress / e0(liftBwScale[1]),
    cSkill: 6.6, // C=6.6 read as skill level; C_pot adds the bw term [assume]
    vabs: 52 * (163 * 0.45359) / 1000, // 3.85 L/min
    bw: bw0, fm: 29, lm: 134,
    dep: dep0, rust: rust0, f: f0, m: 2,
  );
  st.sCap = st.squatCap + st.benchCap + st.deadliftCap;
  st.refreshObserved(p);
  return st;
}

const horizon = '2027-12-05';

class RunResult {
  final Sim2State st;
  final Sim2State start;
  final int overBudgetWeeks;
  final List<String> redFlagWeeks;
  final double maxCPot;
  final Map<String, Sim2State> blockEnds; // 'B3' -> state copy
  final int injuryWeeks;
  RunResult(this.st, this.start, this.overBudgetWeeks, this.redFlagWeeks,
      this.maxCPot, this.blockEnds, this.injuryWeeks);
}

RunResult run(Sim2Params p,
    {Dials Function(Block)? dials,
    Random? rng,
    double sNoise = 0,
    double cNoise = 0,
    bool injuries = false,
    bool trace = false,
    double? eOverride,
    double? muOverride, // §5 deficit lean-loss branch (μ≈0 pending DEXA)
    double zOverrideFromBlock3 = -1}) {
  final st = initialState(p);
  final start = st.copy();
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
    if (muOverride != null && x.r < 0) x.muOverride = muOverride;

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
          'cap=${st.sCap.toStringAsFixed(0)} E=${st.ex.toStringAsFixed(3)} '
          'dep=${st.dep.toStringAsFixed(2)} '
          'dCap=${res.dCap.toStringAsFixed(1).padLeft(5)} '
          'F=${st.f.toStringAsFixed(2)} e=${res.e.toStringAsFixed(2)} '
          'L=${res.l.toStringAsFixed(1)}/${res.cap.toStringAsFixed(1)} '
          'bw=${st.bw.toStringAsFixed(1)}');
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
  return RunResult(st, start, over, redFlags, maxCPot, blockEnds, injuryWeeks);
}

void main() {
  final p = Sim2Params.fitted();
  print('params: a=${p.a} b=${p.b} c=${p.c} cCut=${p.cCut} d=${p.d}  '
      'E(dep=${p.eDep}, bw=${p.eBw}, rust=${p.eRust}, F=${p.eF}) '
      '(two-pass fit; §3-§6 modules are priors)');
  final st0 = initialState(p);
  print('start: expressed ${st0.s.toStringAsFixed(0)} (RPE basis 917; index '
      '878, gap = attempt-sparse measurement) / capacity '
      '${st0.sCap.toStringAsFixed(0)} / E ${st0.ex.toStringAsFixed(3)}');

  // ---- baseline deterministic ----------------------------------------------
  final base = run(p, trace: const String.fromEnvironment('TRACE') == '1');
  _report('BASELINE (deterministic, Z=1, §5 rule μ=0.30 in the cut)', base);
  _split('E-vs-capacity split of the baseline gain', base);

  // §5 μ≈0 branch (spec's 13%-at-154 anchor; pending Nov DEXA)
  final mu0 = run(p, muOverride: 0.0);
  print('\n=== §5 deficit-μ branches (BW path identical; pending Nov DEXA) ===');
  print('  μ=0.30 (§5 rule at r=-0.75): '
      'BW ${base.st.bw.toStringAsFixed(1)}, '
      'LM ${base.st.lm.toStringAsFixed(1)}, FM ${base.st.fm.toStringAsFixed(1)}'
      ' -> BF ${base.st.bfPct.toStringAsFixed(1)}%');
  print('  μ≈0   (13%-at-154 anchor):   '
      'BW ${mu0.st.bw.toStringAsFixed(1)}, '
      'LM ${mu0.st.lm.toStringAsFixed(1)}, FM ${mu0.st.fm.toStringAsFixed(1)}'
      ' -> BF ${mu0.st.bfPct.toStringAsFixed(1)}%   [§9.3 expects 15-16%]');

  // VO2 at Z=2 from block 3 (the "Cardio up" preset doubles as the §9.3 check)
  final z2 = run(p, zOverrideFromBlock3: 2);
  print('\nVO2 with Z=2 from block 3: ${z2.st.vo2.toStringAsFixed(1)} '
      '(vs ${base.st.vo2.toStringAsFixed(1)} at Z=1)   '
      '[§9.3 expects ~52 / ~49]');

  // sensitivity: no budget bite (e forced to 1) — quantifies how much of the
  // C and S gaps vs §9.3 come purely from the plan running over L_cap
  final noBite = run(p, eOverride: 1.0);
  print('sensitivity e=1 (no §1 budget bite): total='
      '${noBite.st.s.toStringAsFixed(0)}, C=${noBite.st.c.toStringAsFixed(2)} '
      '(skill ${noBite.st.cSkill.toStringAsFixed(2)})');

  // ---- Monte Carlo ----------------------------------------------------------
  const paths = 200;
  final totals = <double>[], caps = <double>[], cs = <double>[];
  var v8Touch = 0, v8Sent = 0;
  var injWeeksTotal = 0;
  for (var i = 0; i < paths; i++) {
    final rng = Random(42 + i);
    final r = run(p, rng: rng, sNoise: 1.5, cNoise: 0.05, injuries: true);
    totals.add(r.st.s);
    caps.add(r.st.sCap);
    cs.add(r.st.c);
    if (r.maxCPot >= 8.0) v8Touch++;
    // "sent V8" = peak C_pot + 0.4 send margin >= 8.0 [log, W1 adaptation]
    if (r.maxCPot + 0.4 >= 8.0) v8Sent++;
    injWeeksTotal += r.injuryWeeks;
  }
  totals.sort();
  caps.sort();
  cs.sort();
  print('\n=== Monte Carlo ($paths paths: §7 injuries + weekly noise '
      'σcap=1.5 lb, σC=0.05 V [assume]) ===');
  print('expressed total  median=${totals[paths ~/ 2].toStringAsFixed(0)}  '
      'p20=${totals[paths ~/ 5].toStringAsFixed(0)}  '
      'p80=${totals[4 * paths ~/ 5].toStringAsFixed(0)}   '
      '[§9.3 expects ~1040 (990-1080)]');
  print('capacity         median=${caps[paths ~/ 2].toStringAsFixed(0)}');
  print('C      median=${cs[paths ~/ 2].toStringAsFixed(1)}   '
      'p20=${cs[paths ~/ 5].toStringAsFixed(1)}');
  print('P(V8 sent: peak C_pot+0.4 send margin >= 8.0) = '
      '${(v8Sent / paths).toStringAsFixed(2)}   [§9.3 expects ~0.45]');
  print('P(continuous C_pot itself touches 8.0) = '
      '${(v8Touch / paths).toStringAsFixed(2)}');
  print('injury-weeks mean = ${(injWeeksTotal / paths).toStringAsFixed(1)}');

  // ---- §9.4 preset sanity ----------------------------------------------------
  print('\n=== §9.4 preset: Climb more (K=4, H=1 all year) ===');
  Dials climbMoreDials(Block b) {
    final x = dialsFor(b);
    x.k = 4;
    x.kLim = 1;
    x.h = 1;
    return x;
  }

  final climbMore = run(p, dials: climbMoreDials);
  _presetVsBase('Climb more', climbMore, base);
  final liftGainBase = _liftingBlockGain(base);
  final liftGainClimb = _liftingBlockGain(climbMore);
  print('  lifting-block strength gain (expressed): baseline '
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

double _liftingBlockGain(RunResult r) {
  // sum of expressed-S change across lifting blocks (3, 5, 7)
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

void _split(String label, RunResult r) {
  // exact midpoint decomposition: ΔS_obs = Ē·ΔS_cap + S̄_cap·ΔE
  final e0 = r.start.ex, e1 = r.st.ex;
  final dCap = r.st.sCap - r.start.sCap;
  final dE = e1 - e0;
  final eBar = (e0 + e1) / 2, cBar = (r.start.sCap + r.st.sCap) / 2;
  final gain = r.st.s - r.start.s;
  print('\n=== $label ===');
  print('  expressed ${r.start.s.toStringAsFixed(0)} -> '
      '${r.st.s.toStringAsFixed(0)} (+${gain.toStringAsFixed(0)})'
      '  =  capacity ${(eBar * dCap).toStringAsFixed(0)}'
      '  +  expression ${(cBar * dE).toStringAsFixed(0)}'
      '   (E ${e0.toStringAsFixed(3)} -> ${e1.toStringAsFixed(3)}: dep '
      '${dep0.toStringAsFixed(1)}->'
      '${r.st.dep.toStringAsFixed(1)}, bw leverage, F)');
  print('  vs the app INDEX (878 today): index-basis gain would add the '
      '~${(r.start.s - 878).toStringAsFixed(0)} lb measurement catch-up '
      '(attempt-sparse under-read, §2 anchor) on top of the expression '
      'term — [§9.3\'s "~60 from E" reads on this basis]');
}

void _report(String label, RunResult r) {
  final st = r.st;
  print('\n=== $label -> $horizon ===');
  print('expressed total ${st.s.toStringAsFixed(0)}  '
      '(squat ${st.squat.toStringAsFixed(0)}, bench ${st.bench.toStringAsFixed(0)}, '
      'deadlift ${st.deadlift.toStringAsFixed(0)}; press ${st.press.toStringAsFixed(0)})'
      '   [§9.3 expects ~1040, 990-1080]');
  print('capacity        ${st.sCap.toStringAsFixed(0)}  '
      '(E at horizon ${st.ex.toStringAsFixed(3)})');
  print('BW      ${st.bw.toStringAsFixed(1)} lb   [expects 169]');
  print('BF%     ${st.bfPct.toStringAsFixed(1)}  (FM ${st.fm.toStringAsFixed(1)}, '
      'LM ${st.lm.toStringAsFixed(1)})   [expects 15-16%; see μ branches]');
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
  print('block-end expressed/capacity: ${r.blockEnds.entries.map((e) => '${e.key}='
      '${e.value.s.toStringAsFixed(0)}/${e.value.sCap.toStringAsFixed(0)}'
      '/bw${e.value.bw.toStringAsFixed(0)}').join(' ')}');
}
