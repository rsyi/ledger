// ignore_for_file: avoid_print
// sim2_model.dart — shared model core for the training-simulator v2
// (spec: airledger docs/superpowers/specs/2026-09-26-training-simulator-spec.md).
// Pure Dart, no Flutter. Wave 1: consumed by tool/sim2_fit.dart,
// tool/sim2_replay.dart, tool/sim2_horizon.dart. Wave 2 lifts this into lib/.
//
// PROVENANCE LABELS (§9.5): every constant is tagged
//   [fit]    — fitted on calibration_windows.csv by tool/sim2_fit.dart
//   [log]    — anchored on the user's log (spec anchors)
//   [lit]    — literature / published anchor per spec
//   [assume] — assumption (spec's or this implementation's, noted)

import 'dart:io';
import 'dart:math';

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

class Sim2Params {
  // §2 strength — priors a=3.0, b=0.4, c=2.5, d=0.8; defaults below are the
  // ridge fit from tool/sim2_fit.dart (run it to regenerate). [fit]
  double a; // near-max saturating gain, lb/wk
  double b; // working-volume slope per 10 sets around 20, lb/wk
  double c; // food slope per lb/wk of bw rate, lb/wk
  double d; // drift with no stimulus, lb/wk

  // §1 budget [log anchors, form fixed by spec]
  final double fDecay = 0.7; // fatigue carries 70% week to week
  final double eSlope = 1.5; // e = 1/(1+1.5F)

  // §3 climbing [lit/log anchors per spec]
  final double kC = 0.013; // V/wk at K=3 baseline [lit]
  // §4 VO2 [log/assume]. ADAPTATION: the spec's form (gain ∝ Z_eff) cannot
  // satisfy both anchors "1/wk holds Vabs" and "2/wk gains +1 pt/8wk"; we use
  // gain ∝ max(0, Z_eff − 1) so Z_eff=1 holds exactly. [assume]
  final double vo2Ceiling = 58; // [assume, exposed per spec]
  final double kV = 0.089; // L/min per wk per session above maintenance [log]
  final double vDelta = 0.0024; // weekly Vabs decay when Z_eff < 0.5 [log]

  Sim2Params(
      {this.a = 3.0, this.b = 0.4, this.c = 2.5, this.d = 0.8}); // priors

  /// Ridge fit 2026-09-26 (tool/sim2_fit.dart on calibration_windows.csv):
  /// R² 0.331 train (gain_14wk_from_start) / 0.277 validate (after_window).
  factory Sim2Params.fitted() =>
      Sim2Params(a: 4.06, b: 0.51, c: 1.59, d: 1.54);
}

// ---------------------------------------------------------------------------
// Dials (§0)
// ---------------------------------------------------------------------------

class Dials {
  double dSessions; // D lifting sessions/wk
  double n; // N near-max sets/wk
  double w; // W working sets/wk
  double k; // K climbing sessions/wk
  double kLim; // of which limit sessions
  double h; // hangboard 0/1
  double z; // 4x4 bike sessions/wk
  double z2; // zone-2 minutes/wk
  double q; // calisthenics sessions/wk
  double r; // bw rate lb/wk
  double p; // protein g/lb
  double benchDays;

  Dials(
      {required this.dSessions,
      required this.n,
      required this.w,
      this.k = 0,
      this.kLim = 0,
      this.h = 0,
      this.z = 0,
      this.z2 = 0,
      this.q = 0,
      this.r = 0,
      this.p = 0.9,
      this.benchDays = 2});

  Dials copy() => Dials(
      dSessions: dSessions, n: n, w: w, k: k, kLim: kLim, h: h, z: z, z2: z2,
      q: q, r: r, p: p, benchDays: benchDays);
}

// ---------------------------------------------------------------------------
// §1 recovery budget
// ---------------------------------------------------------------------------

double loadL(Dials x) =>
    1.0 * x.dSessions +
    0.15 * max(0, x.n - 4) +
    1.0 * (x.k - x.kLim) +
    1.4 * x.kLim +
    0.7 * x.z +
    0.3 * (x.z2 / 60) +
    0.3 * x.q;

double lCap({required double bw, required double r}) {
  if (bw > 176) return 5.5;
  return r >= 0 ? 7.0 : 6.0;
}

double effectiveness(double f) => 1 / (1 + 1.5 * f);

/// Steady-state F for a sustained load (window-level fitting; F* = over/0.3).
double steadyF(double l, double cap) {
  final over = max(0.0, l - cap) / cap;
  return min(over / 0.3, 1.5);
}

// ---------------------------------------------------------------------------
// §2 strength (one week)
// ---------------------------------------------------------------------------

double deltaS(Sim2Params p, Dials x,
    {required double bw,
    required double e,
    double stimulusScale = 1.0 // light week = 0.4 (§8)
    }) {
  final gN = p.a * (1 - exp(-x.n / 4));
  final gW = p.b * (x.w - 20) / 10;
  final gR = p.c * x.r.clamp(-1.0, 0.5);
  final pen = bw > 176 ? 0.5 : 0.0;
  return e * stimulusScale * (gN + gW) + gR - p.d - pen;
}

// ---------------------------------------------------------------------------
// Full weekly state step (§1–§6) — used by replay (strength path) and horizon.
// ---------------------------------------------------------------------------

class Sim2State {
  double s; // strength total (squat+bench+deadlift), lb
  double squat, bench, deadlift, press;
  double cSkill; // §3 climbing skill component
  double c; // displayed grade, lags C_pot by ~4 wk
  double vabs; // L/min
  double bw, fm, lm;
  double f; // fatigue
  double m; // muscle-up reps
  double cutStartS; // S when the current deficit began (rebound bookkeeping)
  double reboundPool; // remaining +0.6*cut_loss to release
  int reboundWeeksLeft;
  bool inDeficit;

  Sim2State(
      {required this.s,
      required this.squat,
      required this.bench,
      required this.deadlift,
      required this.press,
      required this.cSkill,
      required this.vabs,
      required this.bw,
      required this.fm,
      required this.lm,
      this.f = 0,
      this.m = 0,
      double? c,
      this.cutStartS = 0,
      this.reboundPool = 0,
      this.reboundWeeksLeft = 0,
      this.inDeficit = false})
      : c = c ?? cSkill;

  double get vo2 => vabs / (bw * 0.45359) * 1000;
  double get bfPct => fm / bw * 100;

  Sim2State copy() => Sim2State(
      s: s, squat: squat, bench: bench, deadlift: deadlift, press: press,
      cSkill: cSkill, vabs: vabs, bw: bw, fm: fm, lm: lm, f: f, m: m, c: c,
      cutStartS: cutStartS, reboundPool: reboundPool,
      reboundWeeksLeft: reboundWeeksLeft, inDeficit: inDeficit);
}

enum WeekType { normal, light, test }

class WeekResult {
  final double l, cap, e, dS;
  final bool overBudget;
  WeekResult(this.l, this.cap, this.e, this.dS, this.overBudget);
}

/// One week. Mutates [st]. Per-lift split per §2: ΔS distributed by each
/// lift's share of N × frequency factor (2 heavy exposures = 1.0, 1 = 0.6);
/// press follows bench at 0.55×. Baseline shares squat/bench .375 each,
/// deadlift .25 [assume from the weekly template]; freq 1.0/1.0/0.6.
WeekResult stepWeek(Sim2Params p, Sim2State st, Dials x, WeekType wk,
    {Random? rng, double sNoise = 0, double cNoise = 0}) {
  final dials = x.copy();
  double stim = 1.0;
  if (wk == WeekType.light) {
    stim = 0.4; // §8
    dials.k = max(0, dials.k - 1); // program: "one fewer" climb
    dials.h = 0;
    dials.n = min(dials.n, 2);
  } else if (wk == WeekType.test) {
    dials.n = 4; // §8: N counts the four singles
    dials.w = 10; // [assume] reduced volume on test week
  }

  final l = loadL(dials);
  final cap = lCap(bw: st.bw, r: dials.r);
  final e = effectiveness(st.f); // e from start-of-week F
  final over = max(0.0, l - cap) / cap;
  var fNext = p.fDecay * st.f + over;
  if (wk == WeekType.light) fNext *= 0.5;

  // §2 strength
  var dS = deltaS(p, dials, bw: st.bw, e: e, stimulusScale: stim);
  if (rng != null && sNoise > 0) dS += _gauss(rng) * sNoise;

  // §2 time-to-return: deficit episode tracking + 60% rebound over 3 wk [log]
  const deficitEnter = -0.15, surplusEnter = 0.05;
  if (!st.inDeficit && dials.r < deficitEnter) {
    st.inDeficit = true;
    st.cutStartS = st.s;
  } else if (st.inDeficit && dials.r > surplusEnter) {
    st.inDeficit = false;
    final loss = max(0.0, st.cutStartS - st.s);
    st.reboundPool = 0.6 * loss;
    st.reboundWeeksLeft = 3;
  }
  if (st.reboundWeeksLeft > 0) {
    final chunk = st.reboundPool / st.reboundWeeksLeft;
    dS += chunk;
    st.reboundPool -= chunk;
    st.reboundWeeksLeft--;
  }

  // per-lift split
  const shares = [0.375, 0.375, 0.25]; // squat, bench, deadlift share of N
  const freq = [1.0, 1.0, 0.6];
  final wts = [for (var i = 0; i < 3; i++) shares[i] * freq[i]];
  final wSum = wts.reduce((a, b) => a + b);
  st.squat += dS * wts[0] / wSum;
  st.bench += dS * wts[1] / wSum;
  st.deadlift += dS * wts[2] / wSum;
  st.press += 0.55 * dS * wts[1] / wSum;
  st.s += dS;

  // §5 body composition (BW driven by r)
  final dBW = dials.r;
  double dLM, dFM;
  if (dBW > 0) {
    final lam = ((0.65 - 0.5 * max(0, dials.r - 0.3)).clamp(0.25, 0.70)) *
        _pf(dials.p) *
        _tf(dials.w);
    dLM = lam * dBW;
    dFM = (1 - lam) * dBW;
  } else {
    final mu = (dBW.abs() <= 0.5 && dials.w >= 15 && dials.benchDays >= 2)
        ? 0.15
        : 0.30;
    dLM = mu * dBW;
    dFM = (1 - mu) * dBW;
  }
  final lmPrev = st.lm;
  st.lm += dLM;
  st.fm += dFM;
  st.bw += dBW;

  // §3 climbing
  var dCs = e *
          stim *
          p.kC *
          pow(dials.k / 3, 0.7) *
          (1 + 0.3 * dials.h) *
          (1 + 0.5 * dials.kLim / max(dials.k, 1)) -
      (dials.k < 1 ? 0.01 : 0);
  if (rng != null && cNoise > 0) dCs += _gauss(rng) * cNoise;
  st.cSkill += dCs;
  final cPot = st.cSkill + (0.06 * (168 - st.bw)).clamp(-1.0, 1.0);
  st.c += 0.25 * (cPot - st.c); // 4-week lag toward potential

  // §4 VO2 (adapted maintenance-threshold form, see Sim2Params)
  final zEff = dials.z + 0.25 * (dials.z2 / 60);
  final vo2Now = st.vo2;
  var dVabs = e * stim * p.kV * max(0, zEff - 1) * (1 - vo2Now / p.vo2Ceiling);
  if (zEff < 0.5) dVabs -= p.vDelta * st.vabs;
  st.vabs += dVabs;
  st.vabs *= 1 + 0.02 * (st.lm - lmPrev) / lmPrev; // lean-mass O2 term (§4)

  // §6 calisthenics
  st.m += e * stim * 0.05 * (dials.q - 1) -
      (dials.q == 0 ? 0.03 : 0) -
      0.02 * dBW +
      (dials.k >= 2 ? 0.01 : 0);

  st.f = fNext;
  return WeekResult(l, cap, e, dS, l > cap);
}

double _pf(double p) {
  if (p >= 0.8) return 1.0;
  if (p >= 0.6) return 0.85 + (p - 0.6) / 0.2 * 0.15;
  if (p >= 0.5) return 0.7 + (p - 0.5) / 0.1 * 0.15;
  return 0.7;
}

double _tf(double w) {
  if (w >= 20) return 1.0;
  if (w >= 15) return 0.8 + (w - 15) / 5 * 0.2;
  if (w >= 10) return 0.6 + (w - 10) / 5 * 0.2;
  return 0.6;
}

double _gauss(Random rng) {
  final u1 = rng.nextDouble().clamp(1e-12, 1.0), u2 = rng.nextDouble();
  return sqrt(-2 * log(u1)) * cos(2 * pi * u2);
}

// ---------------------------------------------------------------------------
// CSV loading
// ---------------------------------------------------------------------------

class WindowRow {
  final DateTime start;
  final double bw, r, total, dSess, w, n, k;
  final double? yStart, yAfter; // gain_14wk / 14 (per-week)
  WindowRow(this.start, this.bw, this.r, this.total, this.dSess, this.w,
      this.n, this.k, this.yStart, this.yAfter);
}

List<WindowRow> loadWindows(String path) {
  final lines = File(path).readAsLinesSync();
  final header = lines.first.split(',');
  int col(String name) => header.indexOf(name);
  final rows = <WindowRow>[];
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final f = line.split(',');
    double? num(String name) {
      final v = f[col(name)].trim();
      return v.isEmpty ? null : double.parse(v);
    }

    rows.add(WindowRow(
      DateTime.parse(f[col('window_start')]),
      num('bodyweight_lb')!,
      num('bw_rate_lb_wk')!,
      num('total_at_start')!,
      num('lift_sessions_wk')!,
      num('working_sets_wk')!,
      num('near_max_sets_wk_95pct')!,
      num('climb_sessions_wk') ?? 0,
      num('gain_14wk_from_start') == null
          ? null
          : num('gain_14wk_from_start')! / 14,
      num('gain_14wk_after_window') == null
          ? null
          : num('gain_14wk_after_window')! / 14,
    ));
  }
  return rows;
}

class WeeklyRow {
  final DateTime week;
  final double dSess, sets, w, n;
  final bool light;
  final double? bw, k;
  WeeklyRow(this.week, this.dSess, this.sets, this.w, this.n, this.light,
      this.bw, this.k);
}

List<WeeklyRow> loadWeekly(String path) {
  final lines = File(path).readAsLinesSync();
  final header = lines.first.split(',');
  int col(String name) => header.indexOf(name);
  final rows = <WeeklyRow>[];
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final f = line.split(',');
    double? num(String name) {
      final i = col(name);
      if (i < 0 || i >= f.length) return null;
      final v = f[i].trim();
      return v.isEmpty ? null : double.parse(v);
    }

    rows.add(WeeklyRow(
      DateTime.parse(f[col('week_start')]),
      num('lift_sessions') ?? 0,
      num('sets_incl_warmups') ?? 0,
      num('working_sets') ?? 0,
      num('near_max_sets') ?? 0,
      f[col('light_week')].trim() == 'True',
      num('bodyweight_7d'),
      num('climb_sessions'),
    ));
  }
  return rows;
}
