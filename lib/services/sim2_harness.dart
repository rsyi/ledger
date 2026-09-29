/// sim2_harness.dart — the §8 simulation harness for the training
/// simulator v2.1 (spec `2026-09-26-training-simulator-spec.md` §8, fit
/// report §6). Generalizes tool/sim2_horizon.dart's run loop so the
/// Program tab's FORECAST section, the nightly forecast writer
/// (tool/program_status_update.dart) and the CLI horizon tool share ONE
/// construction path: block calendar (from coach/program.yaml or the
/// pinned default), baseline dials per block, week types, the §8 preset
/// scenarios, global dial overrides (the dials row; per-block overrides
/// are a later wave), the weekly run with the attempt-gated INDEX line
/// next to true expressed strength, and the §7 Monte Carlo for P(V8).
///
/// Pure Dart except dart:isolate (the MC helper); no Flutter.
library;

import 'dart:isolate';
import 'dart:math';

import 'program_current.dart' show currentVersion;
import 'sim2_model.dart';

// ---------------------------------------------------------------------------
// Block calendar
// ---------------------------------------------------------------------------

class Sim2Block {
  final int n;
  final DateTime start, end;
  final String emphasis; // cut / reverse / climbing / lifting
  final double r; // target bw rate, lb/wk

  const Sim2Block(this.n, this.start, this.end, this.emphasis, this.r);
}

/// The pinned bulk-2026-27 calendar (coach/program.yaml v1 blocks — v8
/// keeps them verbatim) — the fixture the §9.3 horizon numbers are
/// pinned on. Reverse r = 0.15 [assume: ~150 kcal/day ramp averages
/// under the naive weight-endpoint slope]; the doc-derived calendar
/// (below) uses the endpoints instead.
///
/// RECOMP NOTE (2026-09-26, program.yaml v8): the per-block r values
/// for blocks 2-7 are the SUPERSEDED bulk rates — kept so the
/// 'Bulk plan (inactive)' preset can restore them. The BASELINE dials
/// override them with the recomp rate ([sim2RecompR], the 0..0.15
/// band's midpoint); the recomp weight band/cap in force is
/// 152-162 / hold 158-161 / hard cap 165 (v8), which the baseline
/// trajectory stays inside by construction (~154 → ~158).
List<Sim2Block> sim2DefaultBlocks() => [
      Sim2Block(0, DateTime.utc(2026, 9, 21), DateTime.utc(2026, 12, 13),
          'cut', -0.75),
      Sim2Block(1, DateTime.utc(2026, 12, 14), DateTime.utc(2027, 1, 3),
          'reverse', 0.15),
      Sim2Block(2, DateTime.utc(2027, 1, 4), DateTime.utc(2027, 2, 28),
          'climbing', 0.4),
      Sim2Block(3, DateTime.utc(2027, 3, 1), DateTime.utc(2027, 4, 25),
          'lifting', 0.4),
      Sim2Block(4, DateTime.utc(2027, 4, 26), DateTime.utc(2027, 6, 20),
          'climbing', 0.4),
      Sim2Block(5, DateTime.utc(2027, 6, 21), DateTime.utc(2027, 8, 15),
          'lifting', 0.4),
      Sim2Block(6, DateTime.utc(2027, 8, 16), DateTime.utc(2027, 10, 10),
          'climbing', 0.2),
      Sim2Block(7, DateTime.utc(2027, 10, 11), DateTime.utc(2027, 12, 5),
          'lifting', 0.2),
    ];

/// Block calendar from the parsed coach/program.yaml map (§8: "the block
/// calendar from the program"). r = the block's declared `rate`, falling
/// back to the weight-endpoint slope (w1 − w0) / weeks. Null when the doc
/// is missing/malformed or carries no dated blocks.
List<Sim2Block>? sim2BlocksFromProgramDocs(Map<Object?, Object?>? program) {
  final version = currentVersion(program);
  final rawBlocks = version?['blocks'];
  if (rawBlocks is! List) return null;
  final blocks = <Sim2Block>[];
  for (final b in rawBlocks) {
    if (b is! Map) continue;
    final n = (b['n'] as num?)?.toInt();
    final dates = b['dates'];
    if (n == null || dates is! List || dates.length != 2) continue;
    final start = DateTime.tryParse('${dates[0]}');
    final end = DateTime.tryParse('${dates[1]}');
    if (start == null || end == null) continue;
    var r = (b['rate'] as num?)?.toDouble();
    if (r == null) {
      final wt = b['weight'];
      if (wt is List && wt.length == 2 && wt[0] is num && wt[1] is num) {
        final weeks = (end.difference(start).inDays + 1) / 7;
        if (weeks > 0) {
          r = ((wt[1] as num) - (wt[0] as num)) / weeks;
        }
      }
    }
    blocks.add(Sim2Block(n, DateTime.utc(start.year, start.month, start.day),
        DateTime.utc(end.year, end.month, end.day),
        b['emphasis']?.toString() ?? 'lifting', r ?? 0));
  }
  if (blocks.isEmpty) return null;
  blocks.sort((a, b) => a.start.compareTo(b.start));
  return blocks;
}

/// "I want to just stick with this program long-term" (user directive
/// 2026-09-28): the default trajectory runs the DECLARED calendar and
/// then holds the recomp steady-state indefinitely — ONE flat
/// continuation block (lifting-emphasis post-cut template, block rate
/// [sim2RecompR]) appended after the last declared block for
/// [extraWeeks]. Deliberately NO auto-generated bulk/cut cycles beyond
/// the calendar (the v1 sim_core rule-4 next-cycle machine is retired
/// from the default path). The continuation block keeps the 8-week
/// light/test cadence (n ≥ 2).
List<Sim2Block> sim2ExtendSteadyState(List<Sim2Block> blocks,
    {int extraWeeks = 52}) {
  if (blocks.isEmpty || extraWeeks <= 0) return blocks;
  final last = blocks.last;
  return [
    ...blocks,
    Sim2Block(last.n + 1, last.end.add(const Duration(days: 1)),
        last.end.add(Duration(days: extraWeeks * 7)), 'lifting', sim2RecompR),
  ];
}

// ---------------------------------------------------------------------------
// One-year EXPECTATION ranges (program.yaml v10 `expectations_1yr`,
// final post-cut spec) — NOT targets. The forecast section renders them
// as a faint band labeled "expectation range, not target"; they are
// never fed to flags or the controller.
// ---------------------------------------------------------------------------

class Sim2Expectations {
  final List<double>? bodyweightLb, bfPct, benchLb, squatLb, deadliftLb, ohpLb;
  final String? climbing, vo2;

  const Sim2Expectations({
    this.bodyweightLb,
    this.bfPct,
    this.benchLb,
    this.squatLb,
    this.deadliftLb,
    this.ohpLb,
    this.climbing,
    this.vo2,
  });

  /// SBD-total expectation band (the strength chart's y unit): the sum
  /// of the three lifts' range ends. Null unless all three are present.
  List<double>? get sbdTotalLb {
    final s = squatLb, b = benchLb, d = deadliftLb;
    if (s == null || b == null || d == null) return null;
    return [s[0] + b[0] + d[0], s[1] + b[1] + d[1]];
  }
}

/// Parses `expectations_1yr` from the CURRENT program version. Null when
/// the key is absent (pre-v10) or carries no numeric ranges.
Sim2Expectations? sim2ExpectationsFromProgramDocs(
    Map<Object?, Object?>? program) {
  final version = currentVersion(program);
  final raw = version?['expectations_1yr'];
  if (raw is! Map) return null;
  List<double>? range(String key) {
    final v = raw[key];
    if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
      return [(v[0] as num).toDouble(), (v[1] as num).toDouble()];
    }
    return null;
  }

  final out = Sim2Expectations(
    bodyweightLb: range('bodyweight_lb'),
    bfPct: range('bf_pct'),
    benchLb: range('bench_lb'),
    squatLb: range('squat_lb'),
    deadliftLb: range('deadlift_lb'),
    ohpLb: range('ohp_lb'),
    climbing: raw['climbing']?.toString(),
    vo2: raw['vo2']?.toString(),
  );
  final any = out.bodyweightLb != null ||
      out.bfPct != null ||
      out.sbdTotalLb != null ||
      out.ohpLb != null;
  return any ? out : null;
}

// ---------------------------------------------------------------------------
// Baseline dials per block type + week types (from tool/sim2_horizon.dart)
// ---------------------------------------------------------------------------

/// Recomposition-variant baseline rate for blocks 2-7 (program.yaml v9
/// soft band [-0.1, 0.25] — flat-to-modest-rise; midpoint ≈ 0.075 kept
/// from the v8 [0, 0.15] band, the "hold ~flat" intent). [log]
const double sim2RecompR = 0.075;

/// Recomp protein baseline, g/lb: v9's ABSOLUTE 160-175 g/day at the
/// expected ~157-160 lb maintenance bw ≈ 1.0-1.1 g/lb — midpoint kept.
/// [log]
const double sim2RecompProtein = 1.05;

/// POST-CUT template dials (program.yaml v10, post-cut-final-spec
/// 2026-09-27): N = the heavy exposures — ONE wave top set (5/3/1 @
/// RPE 7-8) per lift per week = 4, UNCHANGED from v9 (the wave varies
/// the top's REPS, not the heavy count) [log]. W = counted from the
/// v10 planned lists (the final spec prescribes accessories
/// concretely, ~tripling v9's prose estimate): 18 main-lift working
/// sets + 39 accessory sets, EXCLUDING skill work (muscle-up, pistol —
/// they ride the Q dial) and the spec's "easy" external rotations —
/// 57 on a lifting-emphasis normal week [log: counted]. CAVEAT: the
/// §2 b-slope was fitted around W≈20; W=57 is extrapolation and the
/// horizon's volume term should be read with that in mind.
const double sim2PostCutN = 4;
const double sim2PostCutW = 57;

/// Climbing-emphasis blocks: non-top lifting volume ×0.65
/// (emphasis_volume, final spec "reduce lifting volume 30-40%,
/// preserve heavy exposures") — 4 tops + 53×0.65 ≈ 38. [log]
const double sim2PostCutWClimb = 38;

/// Block 1 (maintenance calibration): volume_ramp averages the three
/// weeks — accessories at 0.65 / 0.85 / 1.0 → (43 + 51 + 57)/3 ≈ 50.
/// [log]
const double sim2PostCutWReverse = 50;

/// CUT dials (program.yaml v11, approved cut-training revision
/// 2026-09-28 — supersedes the logged-weeks estimate D~3.5/N~3/W~14):
/// N = 4 (one wave top per lift per week, 5/4/3/deload @ RPE 7-8);
/// W counted from the v11 block-0 planned lists — Mon 13 (top + BSS 3
/// + bench 4 + laterals 3 + triceps 2) / Wed 13 (top + bench 3 +
/// squat 3 + OHP 3 + pull-ups 3) / Thu 6 (dips 3 + curls 3; muscle-up
/// skill rides Q) / Fri 8 (top + DL 2 + RDL 2 + bench 3) / Sat 15
/// (top + OHP 3 + row 3 + pull-ups 3 + laterals 3 + face pulls 2;
/// "easy" external rotations excluded, v10 convention) = 55 on normal
/// weeks; the sim has no block-0 week types, so W carries the
/// 4-week-wave AVERAGE with the deload's halved non-top volume
/// ((3×55 + 30)/4 ≈ 49). D = 4.5 lifting sessions (4 full days + the
/// short Thu arms/skill day) [assume]. K=2 with Tue now the HARD
/// session (kLim=1 unchanged); Z=1 (Tue AM 4x4) + Q=1. The Tue
/// AM-4x4 + PM-hard-climb double session plus 4.5 lifting days runs
/// L ≈ 7.9 vs the deficit cap 6.0 — every cut week is over budget by
/// construction; the fatigue term (not the calendar) is where that
/// honesty lands. [log: counted]
const double sim2CutN = 4;
const double sim2CutW = 49;
const double sim2CutD = 4.5;

/// Post-cut training dials from the v10 template
/// ([sim2PostCutN]/[sim2PostCutW] + the per-emphasis W variants).
///
/// RECOMP BASELINE (v10, 2026-09-27): blocks 1-7 run the final
/// post-cut template — N=4 heavy exposures (wave 5/3/1 tops), W per
/// emphasis (57 lifting / 38 climbing / 50 reverse-ramp) — with
/// r = [sim2RecompR] and p = [sim2RecompProtein] for the rated blocks
/// (2-7). The reverse block keeps N=3 (its tops are capped at RPE 7 —
/// sub-near-max) but carries the ramped template volume. The cut
/// (block 0) is untouched. The superseded bulk trajectory is reachable
/// via the 'Bulk plan (inactive)' preset, which restores the bulk-era
/// rates/protein AND the bulk template's N/W.
Dials sim2BaselineDials(Sim2Block b) {
  switch (b.emphasis) {
    case 'cut':
      return Dials(
          dSessions: sim2CutD, n: sim2CutN, w: sim2CutW, k: 2, kLim: 1,
          z: 1, q: 1, r: b.r);
    case 'reverse':
      return Dials(
          dSessions: 4, n: 3, w: sim2PostCutWReverse, k: 2, kLim: 1, z: 1,
          q: 1, r: b.r);
    case 'climbing':
      return Dials(
          dSessions: 4, n: sim2PostCutN, w: sim2PostCutWClimb, k: 3, kLim: 1,
          h: 1, z: 1, q: 1, r: sim2RecompR, p: sim2RecompProtein);
    default: // lifting
      return Dials(
          dSessions: 4, n: sim2PostCutN, w: sim2PostCutW, k: 2, kLim: 1,
          z: 1, q: 1, r: sim2RecompR, p: sim2RecompProtein);
  }
}

/// Blocks 2+ run 8-week cadence: week 4 light, week 8 test (§8 / program
/// week_types); blocks 0-1 every week normal.
WeekType sim2WeekTypeFor(Sim2Block b, int weekInBlock) {
  if (b.n < 2) return WeekType.normal;
  final w = weekInBlock % 8;
  if (w == 3) return WeekType.light;
  if (w == 7) return WeekType.test;
  return WeekType.normal;
}

// ---------------------------------------------------------------------------
// Initial state (Sep 26 2026 seeds, [log])
// ---------------------------------------------------------------------------

/// §2 anchors: RPE-implied maxes Sep 2026 — bench 225×1@8 → 244, squat
/// 305@8 → 331, deadlift 315@8 → 342; press follows bench's ratio. [log]
const sim2SeedRpeSquat = 331.0;
const sim2SeedRpeBench = 244.0;
const sim2SeedRpeDeadlift = 342.0;
const sim2SeedRpePress = 138.0 * (244.0 / 238.0); // [assume]
const sim2SeedBw = 163.0; // the bw the RPE readings were taken at [log]
const sim2SeedIndexTotal = 878.0; // the app's Epley index, Sep 26 2026 [log]
const sim2SeedDep = 1.0; // the 2025-26 deficit never closed [log]
const sim2SeedRust = 0.0; // the RPE readings ARE attempts [log]
const sim2SeedF = 0.3; // spec §0 [log]
const sim2SeedCSkill = 6.6; // V7 once, V6 regular [log]
const sim2SeedVo2 = 52.0; // [log]
const sim2SeedFm = 29.0, sim2SeedLm = 134.0; // DEXA basis [log]
const sim2SeedM = 2.0; // muscle-up reps at the Aug 19 standard [log]

/// S_cap seeded from the RPE readings divided by the per-lift E AT THE
/// READING bw (163) — the seed is a property of the readings, not of
/// today's scale weight; [observedBw] (the live 7-day average, when the
/// app has one) only moves the state's starting bodyweight.
Sim2State sim2InitialState(Sim2Params p, {double? observedBw}) {
  double e0(double scale) => exprE(p,
      dep: sim2SeedDep,
      bw: sim2SeedBw,
      rust: sim2SeedRust,
      f: sim2SeedF,
      bwScale: scale);
  final st = Sim2State(
    sCap: 0,
    squatCap: sim2SeedRpeSquat / e0(liftBwScale[0]),
    benchCap: sim2SeedRpeBench / e0(liftBwScale[1]),
    deadliftCap: sim2SeedRpeDeadlift / e0(liftBwScale[2]),
    pressCap: sim2SeedRpePress / e0(liftBwScale[1]),
    cSkill: sim2SeedCSkill,
    vabs: sim2SeedVo2 * (sim2SeedBw * 0.45359) / 1000,
    bw: observedBw ?? sim2SeedBw,
    fm: sim2SeedFm,
    lm: sim2SeedLm,
    dep: sim2SeedDep,
    rust: sim2SeedRust,
    f: sim2SeedF,
    m: sim2SeedM,
  );
  st.sCap = st.squatCap + st.benchCap + st.deadliftCap;
  st.refreshObserved(p);
  return st;
}

/// The block containing [day] (the last block started on/before it,
/// same lookup the run loop uses); null before the calendar starts or
/// on an empty calendar.
int? sim2CurrentBlockN(List<Sim2Block> blocks, DateTime day) {
  final d = DateTime.utc(day.year, day.month, day.day);
  int? n;
  for (final b in blocks) {
    if (!d.isBefore(b.start)) n = b.n;
  }
  return n;
}

/// The Monday the sim steps from: [today] if it is a Monday, else the
/// next one.
DateTime sim2StartMonday(DateTime today) {
  final d = DateTime.utc(today.year, today.month, today.day);
  return d.add(Duration(days: (8 - d.weekday) % 7));
}

// ---------------------------------------------------------------------------
// Global dial overrides (the dials row). Per-block overrides are a later
// wave — a global override applies to EVERY week of the scenario.
// ---------------------------------------------------------------------------

class Sim2DialOverrides {
  final double? n, w, k, kLim, h, z, z2, q, r, p;

  const Sim2DialOverrides(
      {this.n,
      this.w,
      this.k,
      this.kLim,
      this.h,
      this.z,
      this.z2,
      this.q,
      this.r,
      this.p});

  bool get isEmpty =>
      n == null &&
      w == null &&
      k == null &&
      kLim == null &&
      h == null &&
      z == null &&
      z2 == null &&
      q == null &&
      r == null &&
      p == null;

  Dials apply(Dials d) {
    if (n != null) d.n = n!;
    if (w != null) d.w = w!;
    if (k != null) d.k = k!;
    if (kLim != null) d.kLim = kLim!;
    if (h != null) d.h = h!;
    if (z != null) d.z = z!;
    if (z2 != null) d.z2 = z2!;
    if (q != null) d.q = q!;
    if (r != null) d.r = r!;
    if (p != null) d.p = p!;
    return d;
  }
}

// ---------------------------------------------------------------------------
// §8 presets
// ---------------------------------------------------------------------------

class Sim2Preset {
  final String id, label, blurb;

  /// Mutates [d] for [b] given the running [st] (Stay light is bw-aware).
  final void Function(Sim2Block b, Dials d, Sim2State st) apply;

  const Sim2Preset(this.id, this.label, this.blurb, this.apply);
}

final List<Sim2Preset> sim2Presets = [
  Sim2Preset('baseline', 'Baseline', 'the declared plan', (b, d, st) {}),
  // The superseded bulk trajectory (program.yaml inactive_bulk_variant):
  // restores the calendar's block rates (0.4 blocks 2-5, 0.2 blocks
  // 6-7 — b.r carries them verbatim), the bulk-era 0.8-1.0 protein AND
  // the bulk template's training shape (N=6 lifting / 3 climbing,
  // W=28; reverse W=20) — v9's post-cut N/W belong to the recomp
  // template only, so this preset must reproduce the ORIGINAL
  // fit-report pins. Block 0 was never under the variant.
  Sim2Preset('bulk_plan', 'Bulk plan (inactive)',
      'the superseded 154→170 bulk — old rates, protein and template',
      (b, d, st) {
    if (b.emphasis == 'reverse') d.w = 20;
    if (b.n >= 2) {
      d.r = b.r;
      d.p = 0.9;
      d.w = 28;
      d.n = b.emphasis == 'climbing' ? 3 : 6;
      // Bulk lifting blocks climbed below limit ("both below limit");
      // the v10 baseline carries a weekly limit session, so pin the
      // bulk shape explicitly to keep the original fit-report numbers.
      d.kLim = b.emphasis == 'climbing' ? 1 : 0;
    }
  }),
  Sim2Preset('climb_more', 'Climb more', 'K=4, H=1 all year — the budget bites lifting',
      (b, d, st) {
    d.k = 4;
    d.kLim = max(1, d.kLim);
    d.h = 1;
  }),
  Sim2Preset('lift_more', 'Lift more', 'lifting emphasis every block, K=2',
      (b, d, st) {
    if (b.n >= 2) {
      d.dSessions = 4;
      d.n = 6;
      d.w = 28;
      d.kLim = 0;
      d.h = 0;
      d.z = 1;
      d.q = 1;
    }
    d.k = 2;
  }),
  Sim2Preset('cardio_up', 'Cardio up', 'Z=2 from block 3 — hold VO2 ~52',
      (b, d, st) {
    if (b.n >= 3) d.z = 2;
  }),
  Sim2Preset('cardio_off', 'Cardio off', 'Z=0 — watch the score fall',
      (b, d, st) => d.z = 0),
  Sim2Preset('drop_cal', 'Drop calisthenics', 'Q=0 — M decays',
      (b, d, st) => d.q = 0),
  Sim2Preset('fast_bulk', 'Fast bulk', 'r=0.9 blocks 2-5 — the 2025 rerun',
      (b, d, st) {
    if (b.n >= 2 && b.n <= 5) d.r = 0.9;
  }),
  Sim2Preset('stay_light', 'Stay light',
      'hold ~160 from block 4 [assume: trim at -0.5 if above] — climbing-first',
      (b, d, st) {
    if (b.n >= 4) d.r = st.bw > 160.25 ? -0.5 : 0.0;
  }),
];

Sim2Preset sim2PresetById(String id) =>
    sim2Presets.firstWhere((p) => p.id == id, orElse: () => sim2Presets.first);

// ---------------------------------------------------------------------------
// The weekly run
// ---------------------------------------------------------------------------

class Sim2WeekPoint {
  final DateTime monday;
  final int blockN;
  final String emphasis;
  final WeekType weekType;
  final double l, lCap;
  final bool overBudget; // L > L_cap: red-flag, confidence collapses (§8)
  final double sTrue; // true expressed total, S_cap · E (RPE basis)
  final double sIdx; // what the app's Epley index would show (gated EMA)
  final double sCap; // capacity
  final double squat, bench, deadlift, press;
  final double bw, bfPct, c, vo2, f, m;

  const Sim2WeekPoint(
      {required this.monday,
      required this.blockN,
      required this.emphasis,
      required this.weekType,
      required this.l,
      required this.lCap,
      required this.overBudget,
      required this.sTrue,
      required this.sIdx,
      required this.sCap,
      required this.squat,
      required this.bench,
      required this.deadlift,
      required this.press,
      required this.bw,
      required this.bfPct,
      required this.c,
      required this.vo2,
      required this.f,
      required this.m});
}

class Sim2Run {
  final List<Sim2WeekPoint> weeks;
  final Sim2State start, end;
  final int overBudgetWeeks;
  final double maxCPot; // peak climbing potential over the run
  final Map<int, Sim2State> blockEnds; // block n → end-of-block state
  final int injuryWeeks;

  const Sim2Run(this.weeks, this.start, this.end, this.overBudgetWeeks,
      this.maxCPot, this.blockEnds, this.injuryWeeks);

  Sim2WeekPoint get last => weeks.last;
}

/// One scenario run over [blocks]: preset then global [overrides] on top
/// of the baseline dials, week by week from [start] (default: the first
/// Monday on/after the calendar start) to [horizon] (default: the
/// calendar end). Deterministic unless [rng]+noise/injuries are given
/// (the Monte Carlo path).
Sim2Run sim2Run({
  required Sim2Params params,
  required List<Sim2Block> blocks,
  DateTime? start,
  DateTime? horizon,
  String presetId = 'baseline',
  Sim2DialOverrides overrides = const Sim2DialOverrides(),

  /// Per-block overrides (block n → dials), applied AFTER the global
  /// [overrides]. The nutrition-driven forecast (2026-09-28) scopes
  /// its observed-intake r/P to the CURRENT block this way — later
  /// blocks keep the DECLARED calendar rates ("phase declarations
  /// stay"; current eating shouldn't rewrite next year's plan).
  Map<int, Sim2DialOverrides> blockOverrides = const {},
  double? muDeficit, // §5 deficit μ branch (0.30 rule vs ≈0), pending DEXA
  double? observedBw,
  double? observedIndexTotal,
  Random? rng,
  double sNoise = 0,
  double cNoise = 0,
  bool injuries = false,
}) {
  assert(blocks.isNotEmpty);
  final preset = sim2PresetById(presetId);
  final st = sim2InitialState(params, observedBw: observedBw);
  final startState = st.copy();
  // Attempt-gated index line: starts at the app's observed index (the
  // ~39 lb under-read closes as near-max attempts resume — measurement
  // catch-up, not physiology).
  var eIdx = (observedIndexTotal ?? sim2SeedIndexTotal) / st.sCap;

  var date = start ?? sim2StartMonday(blocks.first.start);
  final end = horizon ?? blocks.last.end;
  final weeks = <Sim2WeekPoint>[];
  final blockEnds = <int, Sim2State>{};
  var over = 0, injuryWeeks = 0;
  var maxCPot = st.c;
  var injAffectedWeeks = 0, hangBanWeeks = 0;

  while (!date.isAfter(end)) {
    final b = blocks.lastWhere((b) => !date.isBefore(b.start),
        orElse: () => blocks.first);
    final weekInBlock = date.difference(b.start).inDays ~/ 7;
    final x = sim2BaselineDials(b);
    preset.apply(b, x, st);
    overrides.apply(x);
    blockOverrides[b.n]?.apply(x);
    if (muDeficit != null && x.r < 0) x.muOverride = muDeficit;

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

    final wt = sim2WeekTypeFor(b, weekInBlock);
    final res =
        stepWeek(params, st, x, wt, rng: rng, sNoise: sNoise, cNoise: cNoise);
    if (res.overBudget) over++;

    // index measurement step (gated EMA toward the new true E)
    final kIdx = res.effN >= params.idxGateN
        ? params.idxKAttempt
        : params.idxKIdle;
    eIdx += kIdx * (st.ex - eIdx);

    final cPot =
        st.cSkill + (params.cBwPerLb * (168 - st.bw)).clamp(-1.0, 1.0);
    maxCPot = max(maxCPot, cPot);

    weeks.add(Sim2WeekPoint(
      monday: date,
      blockN: b.n,
      emphasis: b.emphasis,
      weekType: wt,
      l: res.l,
      lCap: res.cap,
      overBudget: res.overBudget,
      sTrue: st.s,
      sIdx: st.sCap * eIdx,
      sCap: st.sCap,
      squat: st.squat,
      bench: st.bench,
      deadlift: st.deadlift,
      press: st.press,
      bw: st.bw,
      bfPct: st.bfPct,
      c: st.c,
      vo2: st.vo2,
      f: st.f,
      m: st.m,
    ));

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
    if (nextDate.isAfter(b.end) && !blockEnds.containsKey(b.n)) {
      blockEnds[b.n] = st.copy();
    }
    date = nextDate;
  }
  return Sim2Run(
      weeks, startState, st, over, maxCPot, blockEnds, injuryWeeks);
}

// ---------------------------------------------------------------------------
// §7 Monte Carlo — P(V8 sent) etc. Pure function + an Isolate.run helper
// so the UI never blocks on the 200 paths (report §6 / task contract).
// ---------------------------------------------------------------------------

class Sim2McSummary {
  final int paths;
  final double medianTotal, p20Total, p80Total;
  final double medianC, p20C;
  final double pV8Sent; // peak C_pot + send margin ≥ 8.0 [log, W1 adaptation]
  final double pV8Touch; // continuous C_pot itself ≥ 8.0
  final double injuryWeeksMean;

  const Sim2McSummary(
      {required this.paths,
      required this.medianTotal,
      required this.p20Total,
      required this.p80Total,
      required this.medianC,
      required this.p20C,
      required this.pV8Sent,
      required this.pV8Touch,
      required this.injuryWeeksMean});
}

/// 200 seeded paths with the §7 injury module + weekly noise
/// (σcap = 1.5 lb, σC = 0.05 V [assume]) — same protocol as
/// tool/sim2_horizon.dart, so the baseline reproduces the report's
/// median 1022 / P(V8) 0.45.
Sim2McSummary sim2MonteCarlo({
  required Sim2Params params,
  required List<Sim2Block> blocks,
  DateTime? start,
  DateTime? horizon,
  String presetId = 'baseline',
  Sim2DialOverrides overrides = const Sim2DialOverrides(),
  Map<int, Sim2DialOverrides> blockOverrides = const {},
  double? muDeficit,
  double? observedBw,
  double? observedIndexTotal,
  int paths = 200,
}) {
  final totals = <double>[], cs = <double>[];
  var v8Sent = 0, v8Touch = 0, injTotal = 0;
  for (var i = 0; i < paths; i++) {
    final r = sim2Run(
      params: params,
      blocks: blocks,
      start: start,
      horizon: horizon,
      presetId: presetId,
      overrides: overrides,
      blockOverrides: blockOverrides,
      muDeficit: muDeficit,
      observedBw: observedBw,
      observedIndexTotal: observedIndexTotal,
      rng: Random(42 + i),
      sNoise: 1.5,
      cNoise: 0.05,
      injuries: true,
    );
    totals.add(r.end.s);
    cs.add(r.end.c);
    if (r.maxCPot >= 8.0) v8Touch++;
    if (r.maxCPot + params.sendMargin >= 8.0) v8Sent++;
    injTotal += r.injuryWeeks;
  }
  totals.sort();
  cs.sort();
  return Sim2McSummary(
    paths: paths,
    medianTotal: totals[paths ~/ 2],
    p20Total: totals[paths ~/ 5],
    p80Total: totals[4 * paths ~/ 5],
    medianC: cs[paths ~/ 2],
    p20C: cs[paths ~/ 5],
    pV8Sent: v8Sent / paths,
    pV8Touch: v8Touch / paths,
    injuryWeeksMean: injTotal / paths,
  );
}

/// Off-the-UI-thread Monte Carlo (Isolate.run — closures are sendable
/// within the isolate group). The forecast section shows the
/// deterministic line while this computes.
Future<Sim2McSummary> sim2MonteCarloInIsolate({
  required Sim2Params params,
  required List<Sim2Block> blocks,
  DateTime? start,
  DateTime? horizon,
  String presetId = 'baseline',
  Sim2DialOverrides overrides = const Sim2DialOverrides(),
  Map<int, Sim2DialOverrides> blockOverrides = const {},
  double? muDeficit,
  double? observedBw,
  double? observedIndexTotal,
  int paths = 200,
}) {
  final p = params.copy(); // isolate gets its own mutable copy
  return Isolate.run(() => sim2MonteCarlo(
        params: p,
        blocks: blocks,
        start: start,
        horizon: horizon,
        presetId: presetId,
        overrides: overrides,
        blockOverrides: blockOverrides,
        muDeficit: muDeficit,
        observedBw: observedBw,
        observedIndexTotal: observedIndexTotal,
        paths: paths,
      ));
}
