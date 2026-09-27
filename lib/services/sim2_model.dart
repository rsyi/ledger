/// sim2_model.dart — shared model core for the training-simulator v2.1
/// (spec: airledger docs/superpowers/specs/2026-09-26-training-simulator-spec.md,
/// REVISED §2: capacity and expression are two different things).
/// Pure Dart, no Flutter. LIFTED from tool/sim2_model.dart in wave 3;
/// the tools (tool/sim2_fit.dart, tool/sim2_replay.dart,
/// tool/sim2_horizon.dart) delegate here via an export shim, and the
/// Program tab's FORECAST section + the nightly forecast writer consume
/// it through lib/services/sim2_harness.dart.
///
/// v2.1 (revision wave): §2 is two layers — slow capacity S_cap moved only by
/// training/food/time, and an expression overlay E (energy-state dep, body-mass
/// leverage, rust, fatigue) with S_obs = S_cap · E. The v2.0 explicit rebound
/// term is REMOVED: the post-cut snap-back is emergent via dep decaying 1→0
/// over the first 3 surplus weeks.
///
/// S_obs basis note: the spec prefers RPE-implied maxes where a reading exists
/// and the Epley index as fallback. BOTH calibration CSVs are index-basis
/// (total_at_start / gains are the app's Epley index), so fit and replay run
/// on the index; the index's under-read in cuts is carried by the dep + rust
/// terms (few near-max attempts is exactly what rust measures). The horizon
/// seeds S_cap from the RPE-implied readings (§2 anchors, Sep 2026).
///
/// PROVENANCE LABELS (§9.5): every constant is tagged
///   [fit]    — fitted on calibration CSVs by tool/sim2_fit.dart
///   [log]    — anchored on the user's log (spec anchors)
///   [lit]    — literature / published anchor per spec
///   [assume] — assumption (spec's or this implementation's, noted)
/// The [sim2ParamDefs] registry exposes each constant (value, prior,
/// tag, note) for the §9.5 parameter sheet; §3–§6 constants are priors,
/// not fits — the log only calibrates strength and the budget.
library;

import 'dart:io';
import 'dart:math';

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

class Sim2Params {
  // §2 capacity layer — priors a=2.5, b=0.4, c=1.5, c_cut=1.0, d=0.6 (revised
  // spec). Defaults are the priors; Sim2Params.fitted() is pass 2. [fit]
  double a; // near-max saturating gain, lb/wk
  double b; // working-volume slope per 10 sets around 20, lb/wk
  double c; // food slope per lb/wk of SURPLUS bw rate (clip 0..+0.5), lb/wk
  double cCut; // cut cost per lb/wk of deficit rate, lb/wk
  double d; // drift with no stimulus, lb/wk

  // §2 expression layer E — priors 0.06 / 0.0025 / 0.04 (revised spec).
  // Defaults are the priors; Sim2Params.fitted() is pass 1. [fit]
  double eDep; // energy-state depletion, fraction of S_cap at dep=1
  double eBw; // body-mass leverage per lb around 165
  double eRust; // rust (no near-max attempts) fraction at rust=1
  double eF; // fatigue term, held at prior (not fitted) [assume]

  // Measurement model for the app's EPLEY INDEX (the calibration basis):
  // the index is built from whatever sets happened, so it re-reads true
  // expressed strength only when near-max attempts occur — attempt weeks
  // converge fast (kAttempt), attempt-sparse weeks are nearly frozen
  // (kIdle). Log evidence: Dec-2024→Mar-2025 (N≈13.7/wk) the index caught
  // the E snap-back within weeks (+88 lb/14 wk at 2025-01-13), while the
  // 2025-26 cut's attempt-sparse onset shows only −12 on the index over 14
  // weeks as E crashed, the fall arriving with the N≈8-13 attempt burst of
  // Feb-Mar 2026. Applied by smoothing the E path:
  // E_idx = gatedEma(E, N, kAttempt, kIdle); used ONLY when comparing model
  // S_obs to the index (fit, replay) and for the app's "index" display
  // line — the true expressed output carries no smoothing. [fit]
  double idxKAttempt;
  double idxKIdle;
  final double idxGateN = 2; // attempt week: N ≥ 2 [assume]

  // §1 budget [log anchors, form fixed by spec]
  double fDecay; // fatigue carries 70% week to week [log]
  double eSlope; // e = 1/(1+1.5F) [assume]
  double capSurplus; // L_cap in a surplus [log]
  double capDeficit; // L_cap in a deficit [log]
  double capHeavy; // L_cap when BW > heavyBw [log]
  double heavyBw; // "nothing good has happened above 178" threshold [log]
  double heavyPen; // capacity drift penalty above heavyBw, lb/wk [assume]
  double loadNx; // load per near-max set above 4 [assume]
  double loadKLim; // load per limit climbing session [log]
  double loadZ; // load per 4x4 session [assume]
  double loadZ2; // load per zone-2 hour [assume]
  double loadQ; // load per calisthenics session [assume]

  // §3 climbing [lit/log anchors per spec — PRIORS, not fits]
  double kC; // V/wk at K=3 baseline [lit]
  double cBwPerLb; // C_pot slope, V per lb around 168, cap ±1.0 [log]
  double sendMargin; // hardest send runs ~this above continuous C [log]

  // §4 VO2 [log/assume — PRIORS]. W1 ADAPTATION (kept, labeled): the spec's
  // form (gain ∝ Z_eff) cannot satisfy both anchors "1/wk holds Vabs" and
  // "2/wk gains +1 pt/8wk"; we use gain ∝ max(0, Z_eff − 1) so Z_eff=1
  // holds exactly. [assume]
  double vo2Ceiling; // [assume, exposed per spec]
  double kV; // L/min per wk per session above maintenance [log]
  double vDelta; // weekly Vabs decay when Z_eff < 0.5 [log]

  // §6 calisthenics [assume — PRIORS]
  double mGain; // reps/wk per session above 1
  double mDecay; // reps/wk at Q = 0
  double mBwCost; // reps per lb of bodyweight gained

  Sim2Params(
      {this.a = 2.5,
      this.b = 0.4,
      this.c = 1.5,
      this.cCut = 1.0,
      this.d = 0.6,
      this.eDep = 0.06,
      this.eBw = 0.0025,
      this.eRust = 0.04,
      this.eF = 0.03,
      this.idxKAttempt = 0.4,
      this.idxKIdle = 0.05,
      this.fDecay = 0.7,
      this.eSlope = 1.5,
      this.capSurplus = 7.0,
      this.capDeficit = 6.0,
      this.capHeavy = 5.5,
      this.heavyBw = 176,
      this.heavyPen = 0.5,
      this.loadNx = 0.15,
      this.loadKLim = 1.4,
      this.loadZ = 0.7,
      this.loadZ2 = 0.3,
      this.loadQ = 0.3,
      this.kC = 0.013,
      this.cBwPerLb = 0.06,
      this.sendMargin = 0.4,
      this.vo2Ceiling = 58,
      this.kV = 0.089,
      this.vDelta = 0.0024,
      this.mGain = 0.05,
      this.mDecay = 0.03,
      this.mBwCost = 0.02}); // priors

  /// Two-pass fit 2026-09-26 (tool/sim2_fit.dart, calibration CSVs, 2 sweeps
  /// per cell; cell — index response × eDep — selected by the §9.2 replay
  /// checkpoints, see the tool's selection-rule note):
  /// pass 1 (E, flip windows) eBw/eRust ridge-fit, eDep replay-selected;
  /// pass 2 (capacity, steady windows, capacity-basis target) a,b,c,cCut,d.
  /// Replay 4/5 (only the documented Bulk-C level anomaly fails), median
  /// level |err| 31 lb. Values regenerated by running the fit tool; see the
  /// v2.1 fit report (airledger docs/superpowers/specs) for R², bins and
  /// the identification caveats.
  factory Sim2Params.fitted() => Sim2Params(
      a: 2.49,
      b: 0.39,
      c: 1.44,
      cCut: 0.92,
      d: 0.59,
      eDep: 0.0400,
      eBw: 0.0020,
      eRust: 0.0075,
      idxKAttempt: 0.7,
      idxKIdle: 0.1);

  Sim2Params copy() => Sim2Params(
      a: a,
      b: b,
      c: c,
      cCut: cCut,
      d: d,
      eDep: eDep,
      eBw: eBw,
      eRust: eRust,
      eF: eF,
      idxKAttempt: idxKAttempt,
      idxKIdle: idxKIdle,
      fDecay: fDecay,
      eSlope: eSlope,
      capSurplus: capSurplus,
      capDeficit: capDeficit,
      capHeavy: capHeavy,
      heavyBw: heavyBw,
      heavyPen: heavyPen,
      loadNx: loadNx,
      loadKLim: loadKLim,
      loadZ: loadZ,
      loadZ2: loadZ2,
      loadQ: loadQ,
      kC: kC,
      cBwPerLb: cBwPerLb,
      sendMargin: sendMargin,
      vo2Ceiling: vo2Ceiling,
      kV: kV,
      vDelta: vDelta,
      mGain: mGain,
      mDecay: mDecay,
      mBwCost: mBwCost);
}

// ---------------------------------------------------------------------------
// §9.5 parameter registry — every constant with prior + provenance tag,
// consumed by the Program tab's parameter sheet. Getter/setter pairs so
// the UI edits a Sim2Params copy in place and re-runs the sim.
// ---------------------------------------------------------------------------

class Sim2ParamDef {
  final String id;
  final String label;
  final String group; // '§2 capacity' / '§2 expression' / …
  final String tag; // fit / log / lit / assume
  final double prior; // spec prior (differs from fitted value for [fit])
  final String note;
  final double Function(Sim2Params) get;
  final void Function(Sim2Params, double) set;

  const Sim2ParamDef(this.id, this.label, this.group, this.tag, this.prior,
      this.note, this.get, this.set);
}

/// The exposed constants (spec §9.5: "every parameter is exposed in the
/// view with its prior and its source"). §3–§6 entries are PRIORS — the
/// log only calibrates strength (§2) and the budget (§1). eDep carries
/// the identification caveat from the v2.1 fit report §2.
final List<Sim2ParamDef> sim2ParamDefs = [
  Sim2ParamDef('a', 'a — near-max gain (saturating)', '§2 capacity', 'fit',
      2.5, 'lb/wk at N→∞; e·a·(1−exp(−N/4))',
      (p) => p.a, (p, v) => p.a = v),
  Sim2ParamDef('b', 'b — working-volume slope', '§2 capacity', 'fit', 0.4,
      'lb/wk per 10 sets around W=20', (p) => p.b, (p, v) => p.b = v),
  Sim2ParamDef('c', 'c — surplus food slope', '§2 capacity', 'fit', 1.5,
      'lb/wk per lb/wk of bw rate, clipped 0..+0.5',
      (p) => p.c, (p, v) => p.c = v),
  Sim2ParamDef('c_cut', 'c_cut — deficit capacity cost', '§2 capacity', 'fit',
      1.0, 'lb/wk per lb/wk of deficit rate',
      (p) => p.cCut, (p, v) => p.cCut = v),
  Sim2ParamDef('d', 'd — drift with no stimulus', '§2 capacity', 'fit', 0.6,
      'lb/wk lost with zero training', (p) => p.d, (p, v) => p.d = v),
  Sim2ParamDef('e_dep', 'eDep — energy-state depletion', '§2 expression',
      'fit', 0.06,
      'REPLAY-PINNED, not window-fitted: the window likelihood is flat in '
      '[0, 0.06] (fit report §2); edits move the horizon but are NOT '
      're-validated against the log checkpoints in-app',
      (p) => p.eDep, (p, v) => p.eDep = v),
  Sim2ParamDef('e_bw', 'eBw — body-mass leverage', '§2 expression', 'fit',
      0.0025, 'per lb around 165; per-lift split ×1.4/1.0/0.6 (B/S/D)',
      (p) => p.eBw, (p, v) => p.eBw = v),
  Sim2ParamDef('e_rust', 'eRust — no-attempt rust', '§2 expression', 'fit',
      0.04, 'mostly absorbed by the attempt-gated index model',
      (p) => p.eRust, (p, v) => p.eRust = v),
  Sim2ParamDef('e_f', 'eF — fatigue term in E', '§2 expression', 'assume',
      0.03, 'held at prior (not fitted)', (p) => p.eF, (p, v) => p.eF = v),
  Sim2ParamDef('k_attempt', 'kAttempt — index convergence (attempt wk)',
      'index measurement', 'fit', 0.7,
      'Epley index re-reads strength only in attempt weeks (N ≥ 2)',
      (p) => p.idxKAttempt, (p, v) => p.idxKAttempt = v),
  Sim2ParamDef('k_idle', 'kIdle — index convergence (idle wk)',
      'index measurement', 'fit', 0.1, 'attempt-sparse weeks nearly frozen',
      (p) => p.idxKIdle, (p, v) => p.idxKIdle = v),
  Sim2ParamDef('f_decay', 'F decay', '§1 budget', 'log', 0.7,
      'fatigue carries 70% week to week', (p) => p.fDecay,
      (p, v) => p.fDecay = v),
  Sim2ParamDef('e_slope', 'e slope', '§1 budget', 'assume', 1.5,
      'e = 1/(1 + slope·F)', (p) => p.eSlope, (p, v) => p.eSlope = v),
  Sim2ParamDef('l_cap_surplus', 'L_cap (surplus)', '§1 budget', 'log', 7.0,
      'Bulk C ≈5.2 under; Bulk D wk11-19 ≈7.5-8.3 over → stall',
      (p) => p.capSurplus, (p, v) => p.capSurplus = v),
  Sim2ParamDef('l_cap_deficit', 'L_cap (deficit)', '§1 budget', 'log', 6.0,
      '', (p) => p.capDeficit, (p, v) => p.capDeficit = v),
  Sim2ParamDef('l_cap_heavy', 'L_cap (BW > 176)', '§1 budget', 'log', 5.5,
      'nothing good has happened above 178', (p) => p.capHeavy,
      (p, v) => p.capHeavy = v),
  Sim2ParamDef('load_klim', 'load per limit session', '§1 budget', 'log', 1.4,
      'limit climbing costs more than volume (1.0)', (p) => p.loadKLim,
      (p, v) => p.loadKLim = v),
  Sim2ParamDef('load_z', 'load per 4×4 session', '§1 budget', 'assume', 0.7,
      '', (p) => p.loadZ, (p, v) => p.loadZ = v),
  Sim2ParamDef('load_q', 'load per calisthenics session', '§1 budget',
      'assume', 0.3, '', (p) => p.loadQ, (p, v) => p.loadQ = v),
  Sim2ParamDef('k_c', 'k_c — climbing skill gain', '§3 climbing (prior)',
      'lit', 0.013,
      'V/wk at K=3 with hangboard+limit ≈ +1 V/yr (fast end at V6-V7)',
      (p) => p.kC, (p, v) => p.kC = v),
  Sim2ParamDef('c_bw', 'C_pot bw slope', '§3 climbing (prior)', 'log', 0.06,
      'V per lb around 168 (V6 at 171-182, V7 at 167), cap ±1.0',
      (p) => p.cBwPerLb, (p, v) => p.cBwPerLb = v),
  Sim2ParamDef('send_margin', 'send margin for P(V8)', '§3 climbing (prior)',
      'log', 0.4,
      'hardest send runs ~0.4 above continuous C (W1 adaptation)',
      (p) => p.sendMargin, (p, v) => p.sendMargin = v),
  Sim2ParamDef('vo2_ceiling', 'VO2 ceiling', '§4 VO2 (prior)', 'assume', 58,
      'exposed per spec', (p) => p.vo2Ceiling, (p, v) => p.vo2Ceiling = v),
  Sim2ParamDef('k_v', 'k_v — VO2 gain', '§4 VO2 (prior)', 'log', 0.089,
      'L/min/wk per session above maintenance (gain ∝ max(0, Z_eff − 1), '
      'W1 adaptation so Z_eff=1 holds exactly)',
      (p) => p.kV, (p, v) => p.kV = v),
  Sim2ParamDef('v_delta', 'δ — Vabs decay', '§4 VO2 (prior)', 'log', 0.0024,
      'weekly fraction lost when Z_eff < 0.5', (p) => p.vDelta,
      (p, v) => p.vDelta = v),
  Sim2ParamDef('m_gain', 'muscle-up gain', '§6 calisthenics (prior)',
      'assume', 0.05, 'reps/wk per session above 1', (p) => p.mGain,
      (p, v) => p.mGain = v),
  Sim2ParamDef('m_decay', 'muscle-up decay at Q=0', '§6 calisthenics (prior)',
      'assume', 0.03, 'a rep in ~8 weeks', (p) => p.mDecay,
      (p, v) => p.mDecay = v),
  Sim2ParamDef('m_bw', 'muscle-up bw cost', '§6 calisthenics (prior)',
      'assume', 0.02, 'reps per lb gained', (p) => p.mBwCost,
      (p, v) => p.mBwCost = v),
];

final Sim2Params _defaults = Sim2Params();

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
  double? muOverride; // §5 deficit lean-loss fraction override (μ branches)

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
      this.benchDays = 2,
      this.muOverride});

  Dials copy() => Dials(
      dSessions: dSessions, n: n, w: w, k: k, kLim: kLim, h: h, z: z, z2: z2,
      q: q, r: r, p: p, benchDays: benchDays, muOverride: muOverride);
}

// ---------------------------------------------------------------------------
// §1 recovery budget
// ---------------------------------------------------------------------------

double loadL(Dials x, [Sim2Params? params]) {
  final p = params ?? _defaults;
  return 1.0 * x.dSessions +
      p.loadNx * max(0, x.n - 4) +
      1.0 * (x.k - x.kLim) +
      p.loadKLim * x.kLim +
      p.loadZ * x.z +
      p.loadZ2 * (x.z2 / 60) +
      p.loadQ * x.q;
}

double lCap({required double bw, required double r, Sim2Params? params}) {
  final p = params ?? _defaults;
  if (bw > p.heavyBw) return p.capHeavy;
  return r >= 0 ? p.capSurplus : p.capDeficit;
}

double effectiveness(double f, [double slope = 1.5]) => 1 / (1 + slope * f);

/// Steady-state F for a sustained load (F* = over/0.3).
double steadyF(double l, double cap) {
  final over = max(0.0, l - cap) / cap;
  return min(over / 0.3, 1.5);
}

// ---------------------------------------------------------------------------
// §2 expression layer E
// ---------------------------------------------------------------------------

/// dep ramps 0→1 over 3 weeks in a deficit, decays 1→0 over 3 weeks in a
/// surplus (spec §2). Maintenance (|r| ≤ 0.05) holds [assume]; the series
/// builder uses a hysteresis deficit flag instead of raw r (see below).
double depNext(double dep, {required bool inDeficit, bool inSurplus = true}) {
  if (inDeficit) return min(1.0, dep + 1 / 3);
  if (inSurplus) return max(0.0, dep - 1 / 3);
  return dep;
}

/// rust ramps 0→1 over 4 weeks with N < 2, clears over 2 weeks of N ≥ 4
/// (spec §2); 2 ≤ N < 4 holds [assume].
double rustNext(double rust, double n) {
  if (n < 2) return min(1.0, rust + 0.25);
  if (n >= 4) return max(0.0, rust - 0.5);
  return rust;
}

/// E = 1 − eDep·dep + eBw·(BW−165) − eRust·rust − eF·F.
/// [bwScale]: per-lift leverage split (spec: +2.5%/10 lb total, split
/// bench/squat/deadlift 0.35/0.25/0.15 %/lb → scale 1.4/1.0/0.6 on eBw;
/// press follows bench).
double exprE(Sim2Params p,
        {required double dep,
        required double bw,
        required double rust,
        required double f,
        double bwScale = 1.0}) =>
    1 - p.eDep * dep + p.eBw * bwScale * (bw - 165) - p.eRust * rust - p.eF * f;

const liftBwScale = [1.0, 1.4, 0.6]; // squat, bench, deadlift [log split]

// ---------------------------------------------------------------------------
// §2 capacity layer (one week)
// ---------------------------------------------------------------------------

double deltaSCap(Sim2Params p, Dials x,
    {required double bw,
    required double e,
    double stimulusScale = 1.0 // light week = 0.4 (§8)
    }) {
  final gN = p.a * (1 - exp(-x.n / 4));
  final gW = p.b * (x.w - 20) / 10;
  final gR = p.c * x.r.clamp(0.0, 0.5) - p.cCut * max(0.0, -x.r);
  final pen = bw > p.heavyBw ? p.heavyPen : 0.0;
  return e * stimulusScale * (gN + gW) + gR - p.d - pen;
}

// ---------------------------------------------------------------------------
// Full weekly state step (§1–§6) — used by the horizon harness.
// ---------------------------------------------------------------------------

class Sim2State {
  // capacity layer (slow)
  double sCap; // capacity total (squat+bench+deadlift), lb
  double squatCap, benchCap, deadliftCap, pressCap;
  // expression overlay state
  double dep; // energy-state depletion 0..1
  double rust; // 0..1
  // observed (cached S_cap·E at the current state; refreshed by stepWeek)
  double s = 0;
  double squat = 0, bench = 0, deadlift = 0, press = 0;

  double cSkill; // §3 climbing skill component
  double c; // displayed grade, lags C_pot by ~4 wk
  double vabs; // L/min
  double bw, fm, lm;
  double f; // fatigue
  double m; // muscle-up reps

  Sim2State(
      {required this.sCap,
      required this.squatCap,
      required this.benchCap,
      required this.deadliftCap,
      required this.pressCap,
      required this.cSkill,
      required this.vabs,
      required this.bw,
      required this.fm,
      required this.lm,
      this.dep = 0,
      this.rust = 0,
      this.f = 0,
      this.m = 0,
      double? c})
      : c = c ?? cSkill;

  double get vo2 => vabs / (bw * 0.45359) * 1000;
  double get bfPct => fm / bw * 100;

  /// Total-level expression multiplier implied by the cached observed total.
  double get ex => s / sCap;

  /// Refresh cached observed values from the current overlay state.
  void refreshObserved(Sim2Params p) {
    final caps = [squatCap, benchCap, deadliftCap];
    final obs = <double>[];
    for (var i = 0; i < 3; i++) {
      obs.add(caps[i] *
          exprE(p, dep: dep, bw: bw, rust: rust, f: f, bwScale: liftBwScale[i]));
    }
    squat = obs[0];
    bench = obs[1];
    deadlift = obs[2];
    press = pressCap *
        exprE(p, dep: dep, bw: bw, rust: rust, f: f, bwScale: liftBwScale[1]);
    s = obs[0] + obs[1] + obs[2];
  }

  Sim2State copy() => Sim2State(
      sCap: sCap, squatCap: squatCap, benchCap: benchCap,
      deadliftCap: deadliftCap, pressCap: pressCap,
      cSkill: cSkill, vabs: vabs, bw: bw, fm: fm, lm: lm,
      dep: dep, rust: rust, f: f, m: m, c: c)
    ..s = s
    ..squat = squat
    ..bench = bench
    ..deadlift = deadlift
    ..press = press;
}

enum WeekType { normal, light, test }

class WeekResult {
  final double l, cap, e, dCap, ex;
  final bool overBudget;

  /// Effective near-max sets after the week-type adjustment (light week
  /// caps N at 2, test week sets N=4) — the index measurement gate input.
  final double effN;

  WeekResult(this.l, this.cap, this.e, this.dCap, this.ex, this.overBudget,
      {this.effN = 0});
}

/// One week. Mutates [st]. Per-lift split per §2: ΔS_cap distributed by each
/// lift's share of N × frequency factor (2 heavy exposures = 1.0, 1 = 0.6);
/// press follows bench at 0.55×. Baseline shares squat/bench .375 each,
/// deadlift .25 [assume from the weekly template]; freq 1.0/1.0/0.6.
WeekResult stepWeek(Sim2Params p, Sim2State st, Dials x, WeekType wk,
    {Random? rng, double sNoise = 0, double cNoise = 0, double? eOverride}) {
  final dials = x.copy();
  double stim = 1.0;
  if (wk == WeekType.light) {
    stim = 0.4; // §8
    dials.k = max(0, dials.k - 1); // program: "one fewer" climb
    dials.h = 0;
    dials.n = min(dials.n, 2);
  } else if (wk == WeekType.test) {
    dials.n = 4; // §8: N counts the four singles (also clears rust, §2)
    dials.w = 10; // [assume] reduced volume on test week
  }

  final l = loadL(dials, p);
  final cap = lCap(bw: st.bw, r: dials.r, params: p);
  final e = eOverride ?? effectiveness(st.f, p.eSlope); // e from start-of-week F
  final over = max(0.0, l - cap) / cap;
  var fNext = p.fDecay * st.f + over;
  if (wk == WeekType.light) fNext *= 0.5;

  // §2 capacity
  var dCap = deltaSCap(p, dials, bw: st.bw, e: e, stimulusScale: stim);
  if (rng != null && sNoise > 0) dCap += _gauss(rng) * sNoise;

  // per-lift capacity split
  const shares = [0.375, 0.375, 0.25]; // squat, bench, deadlift share of N
  const freq = [1.0, 1.0, 0.6];
  final wts = [for (var i = 0; i < 3; i++) shares[i] * freq[i]];
  final wSum = wts.reduce((a, b) => a + b);
  st.squatCap += dCap * wts[0] / wSum;
  st.benchCap += dCap * wts[1] / wSum;
  st.deadliftCap += dCap * wts[2] / wSum;
  st.pressCap += 0.55 * dCap * wts[1] / wSum;
  st.sCap += dCap;

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
    final mu = dials.muOverride ??
        ((dBW.abs() <= 0.5 && dials.w >= 15 && dials.benchDays >= 2)
            ? 0.15
            : 0.30);
    dLM = mu * dBW;
    dFM = (1 - mu) * dBW;
  }
  final lmPrev = st.lm;
  st.lm += dLM;
  st.fm += dFM;
  st.bw += dBW;

  // §2 expression overlay state (deficit/surplus from the dialed r [assume
  // ±0.05 deadband; the fit/replay use a hysteresis flag on logged bw])
  st.dep = depNext(st.dep,
      inDeficit: dials.r < -0.05, inSurplus: dials.r > 0.05);
  st.rust = rustNext(st.rust, dials.n);

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
  final cPot = st.cSkill + (p.cBwPerLb * (168 - st.bw)).clamp(-1.0, 1.0);
  st.c += 0.25 * (cPot - st.c); // 4-week lag toward potential

  // §4 VO2 (adapted maintenance-threshold form, see Sim2Params)
  final zEff = dials.z + 0.25 * (dials.z2 / 60);
  final vo2Now = st.vo2;
  var dVabs = e * stim * p.kV * max(0, zEff - 1) * (1 - vo2Now / p.vo2Ceiling);
  if (zEff < 0.5) dVabs -= p.vDelta * st.vabs;
  st.vabs += dVabs;
  st.vabs *= 1 + 0.02 * (st.lm - lmPrev) / lmPrev; // lean-mass O2 term (§4)

  // §6 calisthenics
  st.m += e * stim * p.mGain * (dials.q - 1) -
      (dials.q == 0 ? p.mDecay : 0) -
      p.mBwCost * dBW +
      (dials.k >= 2 ? 0.01 : 0);

  st.f = fNext;
  st.refreshObserved(p); // observed S = capacity × E at the new state
  return WeekResult(l, cap, e, dCap, st.ex, l > cap, effN: dials.n);
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
// Weekly state series from the log (shared by fit + replay).
// Start-of-week states for bw, deficit flag, dep, rust, F, e, stim.
// ---------------------------------------------------------------------------

class WeeklySeries {
  final List<WeeklyRow> rows;
  final List<double> bw; // carry-forward 7-day bw
  final List<double> rSm; // 3-wk MA of weekly bw diffs (capacity g_r input)
  final List<double> dep, rust, f; // start-of-week overlay states
  final List<double> e, stim; // that week's effectiveness & stimulus scale
  final List<bool> deficit; // hysteresis energy-state flag, start of week
  final Map<DateTime, int> index;
  WeeklySeries(this.rows, this.bw, this.rSm, this.dep, this.rust, this.f,
      this.e, this.stim, this.deficit, this.index);

  /// True expression E at start of week i.
  double eAt(Sim2Params p, int i) =>
      exprE(p, dep: dep[i], bw: bw[i], rust: rust[i], f: f[i]);

  /// Full true-E series for [p], for index smoothing via [gatedEma].
  List<double> eSeries(Sim2Params p) =>
      [for (var i = 0; i < rows.length; i++) eAt(p, i)];

  /// Index-basis E path for [p]: gated on the log's weekly near-max sets.
  List<double> eIdxSeries(Sim2Params p) => gatedEma(eSeries(p),
      [for (final r in rows) r.n], p.idxKAttempt, p.idxKIdle,
      gate: p.idxGateN);
}

/// N-gated EMA: the trail converges on x at rate [kAttempt] in weeks with
/// n ≥ [gate] near-max sets (an attempt re-reads current strength) and at
/// [kIdle] otherwise (the Epley-index measurement model, see
/// Sim2Params.idxKAttempt/idxKIdle).
List<double> gatedEma(List<double> x, List<double> n, double kAttempt,
    double kIdle, {double gate = 2}) {
  final out = <double>[x.first];
  for (var i = 1; i < x.length; i++) {
    final k = n[i] >= gate ? kAttempt : kIdle;
    out.add(out.last + k * (x[i] - out.last));
  }
  return out;
}

/// Builds the full weekly overlay-state series from calibration_weekly.csv.
/// K = 0 before Aug 2024 (§9.2); Z = Q = 0, K_lim = 0 (no columns) [assume].
/// Energy state: hysteresis on a 4-wk MA of bw diffs — enter deficit below
/// −0.2 lb/wk, exit above +0.1 [assume, carried from W1 replay] — then
/// runs shorter than 4 weeks are merged into the preceding state (weekly
/// bw noise flickers the raw flag ~90 times over 12 years; real energy
/// phases last months), and the flag is shifted [detectShift] weeks left
/// to compensate the trailing-MA detection lag [assume]. dep decays
/// whenever not in deficit (maintenance counts as recovery) [assume].
/// NOTE: this is the CALIBRATION basis — it deliberately runs on the
/// default (prior) budget constants, not an edited Sim2Params.
WeeklySeries buildSeries(List<WeeklyRow> weekly, {int detectShift = 3}) {
  final rows = weekly;
  // bw carry-forward
  final bws = <double>[];
  double? last;
  for (final w in rows) {
    last = w.bw ?? last;
    bws.add(last ?? 170.0);
  }
  // backfill the pre-first-reading stretch with the first reading
  final firstIdx = rows.indexWhere((w) => w.bw != null);
  if (firstIdx > 0) {
    for (var i = 0; i < firstIdx; i++) {
      bws[i] = rows[firstIdx].bw!;
    }
  }
  final diffs = <double>[0.0];
  for (var i = 1; i < bws.length; i++) {
    diffs.add(bws[i] - bws[i - 1]);
  }
  List<double> ma(int k) => [
        for (var i = 0; i < diffs.length; i++)
          diffs
                  .sublist(max(0, i - (k - 1)), i + 1)
                  .reduce((a, b) => a + b) /
              (i - max(0, i - (k - 1)) + 1)
      ];
  final rSm = ma(3), rPhase = ma(4);

  // raw hysteresis energy state, then min-run filtering
  final deficit = <bool>[];
  var inDef = false;
  for (var i = 0; i < rows.length; i++) {
    if (!inDef && rPhase[i] < -0.2) inDef = true;
    if (inDef && rPhase[i] > 0.1) inDef = false;
    deficit.add(inDef);
  }
  _mergeShortRuns(deficit, 4);
  // Detection-lag compensation [assume]: the trailing 4-wk MA + threshold
  // flags an energy-state change ~2-3 weeks after it happens; shift the
  // flag left so dep ramps when the state actually changed.
  for (var i = 0; i < deficit.length; i++) {
    deficit[i] =
        deficit[min(deficit.length - 1, i + detectShift)];
  }

  final dep = <double>[], rust = <double>[], f = <double>[];
  final e = <double>[], stim = <double>[];
  final index = <DateTime, int>{};
  var depS = 0.0, rustS = 0.0, fS = 0.0;
  for (var i = 0; i < rows.length; i++) {
    final w = rows[i];
    index[w.week] = i;
    dep.add(depS);
    rust.add(rustS);
    f.add(fS);
    final st = w.light ? 0.4 : 1.0;
    stim.add(st);
    e.add(effectiveness(fS));
    // advance to next week's start
    final k = w.week.isBefore(DateTime(2024, 8, 1)) ? 0.0 : (w.k ?? 0.0);
    final l = loadL(
        Dials(dSessions: w.dSess, n: w.n, w: w.w, k: k, r: rSm[i]));
    final cap = lCap(bw: bws[i], r: rSm[i]);
    var fNext = 0.7 * fS + max(0.0, l - cap) / cap;
    if (w.light) fNext *= 0.5;
    fS = fNext;
    depS = depNext(depS, inDeficit: deficit[i]);
    rustS = rustNext(rustS, w.n);
  }
  return WeeklySeries(rows, bws, rSm, dep, rust, f, e, stim, deficit, index);
}

/// Merge runs shorter than [minRun] into the preceding run's state,
/// repeating until stable.
void _mergeShortRuns(List<bool> flags, int minRun) {
  var changed = true;
  while (changed) {
    changed = false;
    var i = 1; // never rewrite the initial state
    while (i < flags.length) {
      var j = i;
      while (j < flags.length && flags[j] == flags[i]) {
        j++;
      }
      if (flags[i] != flags[i - 1] && j - i < minRun) {
        for (var k = i; k < j; k++) {
          flags[k] = flags[i - 1];
        }
        changed = true;
      }
      i = j;
    }
  }
}

// ---------------------------------------------------------------------------
// CSV loading
// ---------------------------------------------------------------------------

class WindowRow {
  final DateTime start;
  final double bw, r, total, dSess, w, n, k;
  final double? yStart, yAfter; // 14-wk gains, lb (index basis)
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
      num('gain_14wk_from_start'),
      num('gain_14wk_after_window'),
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
