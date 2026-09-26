/// Program-simulation core — the pure week stepper (design doc
/// `airledger/docs/superpowers/specs/2026-09-25-sim-design.md` §§2–5).
///
/// Weekly state (bw, per-lift RPE-adjusted e1RM, running peaks, climb
/// grade p75, Wilks) evolved from the CURRENT observed state through an
/// adaptively generated phase schedule:
///
///   bw(t+1)      = bw(t) + rate(phase(t))            // controlled input
///   v_raw[l](t)  = a[l] + b_bw[l] · rate(phase(t))   // S4 per-lift
///   damp[l](t)   = clamp((zero·peak − e1rm) / ((zero−full)·peak), 0, 1)
///   v[l](t)      = v_raw > 0 ? v_raw · damp : v_raw  // gains only
///   e1rm[l](t+1) = e1rm[l](t) + v[l](t)
///   peak[l](t+1) = max(peak[l](t), e1rm[l](t+1))     // in-sim peak update
///   grade_p75(t) = c0 + c_bw · bw(t) + b_f · (freq − 2) · min(t, 26)  // C2
///   wilks(t)     = wilksPointsLb(k · Σ_sbd e1rm(t), bw(t))
///                  k = actual-max SBD total / e1RM SBD total at t0
///
/// Phase rules (§4): the current cut ends at target-or-date (lighter
/// now ⇒ shorter cut), an early end fills with maintain until block 1,
/// program blocks keep their calendar dates with the bulk lever scaling
/// their rates, and after the program's last block cycles auto-generate
/// (hold → cut → reverse → bulk to band top) out to the horizon.
///
/// Pure Dart — no Flutter, no IO; levers re-run this synchronously.
library;

import 'sim_fit.dart' show SimCoefficients, simLifts, simSbdLifts;
import 'wilks.dart' show wilksPointsLb;
import 'world_model.dart' show SimRules;

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// The user-facing levers (design §5). Null [bulkRateLbWk] keeps each
/// block's declared rate; a value scales every block rate by
/// value / 0.4 (the blocks-2–5 default) and sets the next-cycle bulk
/// rate directly.
class SimLevers {
  final double? bulkRateLbWk;
  final double cutRateLbWk;
  final int climbFrequency;
  final int horizonYears;

  const SimLevers({
    this.bulkRateLbWk,
    this.cutRateLbWk = -0.75,
    this.climbFrequency = 2,
    this.horizonYears = 3,
  });
}

/// One declared program block (calendar-dated, coach/program.yaml).
class SimBlock {
  final int n;
  final DateTime start;

  /// Inclusive end date.
  final DateTime end;

  /// reverse | climbing | lifting (emphasis; reverse gets the reverse
  /// rate, everything else is a bulk block).
  final String emphasis;

  /// Declared gain rate lb/wk; null on the reverse block.
  final double? rate;

  const SimBlock({
    required this.n,
    required this.start,
    required this.end,
    required this.emphasis,
    this.rate,
  });
}

/// The declared program the schedule generator honors: the current
/// cut's target + end date (coach/phase.yaml) and the dated blocks
/// (coach/program.yaml current version, blocks 1..7 — block 0 IS the
/// cut and is represented by [cutTargetLb]/[cutEndDate]).
class SimProgram {
  final double cutTargetLb;

  /// The declared cut end (exclusive: the cut can run through the week
  /// before this date).
  final DateTime cutEndDate;
  final List<SimBlock> blocks;

  const SimProgram({
    required this.cutTargetLb,
    required this.cutEndDate,
    required this.blocks,
  });
}

/// The observed state the sim starts from (t=0 = latest week).
class SimInitialState {
  /// Monday of the current week.
  final DateTime monday;

  /// 7-day mean of the latest week's weigh-ins (carried), lb.
  final double bw;

  /// Per-lift weekly best RPE-adjusted e1RM (carried), lb.
  final Map<String, double> e1rm;

  /// Per-lift all-time e1RM peak (history ∪ current), lb. Missing
  /// lifts default to their current e1RM.
  final Map<String, double> peak;

  /// Rolling 4-week p75 of numeric-V ascents (carried); null when no
  /// climbing history.
  final double? gradeP75;

  /// Actual-max SBD total (lb) at t0 — the Wilks k-anchor numerator.
  /// Null → Wilks is computed on the raw e1RM total (k = 1).
  final double? actualMaxSbdTotalLbs;

  const SimInitialState({
    required this.monday,
    required this.bw,
    required this.e1rm,
    this.peak = const {},
    this.gradeP75,
    this.actualMaxSbdTotalLbs,
  });
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

/// One simulated week.
class SimWeek {
  final DateTime monday;

  /// cut | maintain | reverse | bulk.
  final String phase;

  /// The scripted bw rate applied FROM this week to the next, lb/wk.
  final double rateLbWk;
  final double bw;
  final Map<String, double> e1rm;
  final Map<String, double> peak;

  /// C2 forecast grade; null when the model has no climbing terms.
  final double? gradeP75;

  /// Derived Wilks via the k-anchor.
  final double wilks;

  const SimWeek({
    required this.monday,
    required this.phase,
    required this.rateLbWk,
    required this.bw,
    required this.e1rm,
    required this.peak,
    required this.gradeP75,
    required this.wilks,
  });
}

/// One contiguous run of same-phase weeks.
class SimSegment {
  final String phase;

  /// Monday of the segment's first week.
  final DateTime start;

  /// Monday of the segment's last week (inclusive).
  final DateTime end;
  final int weeks;

  /// State at the segment's first / last week.
  final SimWeek first;
  final SimWeek last;

  const SimSegment({
    required this.phase,
    required this.start,
    required this.end,
    required this.weeks,
    required this.first,
    required this.last,
  });
}

/// The full simulated trajectory.
class SimResult {
  final List<SimWeek> weeks;

  const SimResult({required this.weeks});

  /// Consecutive same-phase weeks grouped into segments — the phase
  /// bands + milestone boundaries the UI renders (W3 chart accessor).
  List<SimSegment> get segments {
    final out = <SimSegment>[];
    var i = 0;
    while (i < weeks.length) {
      var j = i;
      while (j + 1 < weeks.length && weeks[j + 1].phase == weeks[i].phase) {
        j++;
      }
      out.add(SimSegment(
        phase: weeks[i].phase,
        start: weeks[i].monday,
        end: weeks[j].monday,
        weeks: j - i + 1,
        first: weeks[i],
        last: weeks[j],
      ));
      i = j + 1;
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------

DateTime _addWeeks(DateTime monday, int weeks) =>
    DateTime(monday.year, monday.month, monday.day + 7 * weeks);

/// The S4 saturation damper applied to a positive raw velocity: full
/// below `full·peak`, linearly fading to zero at `zero·peak`; negative
/// velocities pass through undamped. At the all-time frontier
/// (e1rm == peak, with the shipped 0.95/1.05 bounds) this is exactly
/// 0.5× — the "advanced trainee at the ceiling" asymptote.
double dampedVelocity({
  required double vRaw,
  required double e1rm,
  required double peak,
  double fullBelowPctOfPeak = 0.95,
  double zeroAtPctOfPeak = 1.05,
}) {
  if (vRaw <= 0 || peak <= 0) return vRaw;
  final span = (zeroAtPctOfPeak - fullBelowPctOfPeak) * peak;
  if (span <= 0) return vRaw;
  final f = ((zeroAtPctOfPeak * peak - e1rm) / span).clamp(0.0, 1.0);
  return vRaw * f;
}

/// One scheduled week: the phase label + the scripted bw rate.
typedef PhaseWeek = ({String phase, double rateLbWk});

/// Generates the adaptive per-week phase schedule (design §4), scripting
/// bw as it goes (cut ends depend on the simulated bw). Returns exactly
/// [horizonWeeks] entries for weeks t = 0 .. horizonWeeks-1.
List<PhaseWeek> generatePhaseSchedule({
  required DateTime t0Monday,
  required double bw0,
  required SimProgram program,
  required SimRules rules,
  SimLevers levers = const SimLevers(),
  required int horizonWeeks,
}) {
  final next = rules.phaseRules.nextCycle;
  final reverseRate = rules.phaseRules.reverseRateLbWk;
  double blockRate(SimBlock b) {
    final declared = b.rate ?? 0;
    final lever = levers.bulkRateLbWk;
    if (lever == null) return declared;
    return declared * (lever / 0.4); // 0.4 = the blocks-2–5 default
  }

  final lastBlockEnd = program.blocks.isEmpty
      ? program.cutEndDate
      : program.blocks
          .map((b) => b.end)
          .reduce((a, b) => a.isAfter(b) ? a : b);

  final out = <PhaseWeek>[];
  var bw = bw0;
  var initialCutEnded = false;
  // Next-cycle state machine (design §4 rule 4).
  String cycleState = 'hold';
  var cycleWeeksLeft = next.holdWeeks;

  for (var t = 0; t < horizonWeeks; t++) {
    final monday = _addWeeks(t0Monday, t);
    PhaseWeek week;

    if (!initialCutEnded &&
        bw > program.cutTargetLb &&
        monday.isBefore(program.cutEndDate)) {
      // Rule 1: cut ends at target-or-date, whichever first.
      week = (phase: 'cut', rateLbWk: levers.cutRateLbWk);
    } else if (!monday.isAfter(lastBlockEnd)) {
      initialCutEnded = true;
      SimBlock? inBlock;
      for (final b in program.blocks) {
        if (!monday.isBefore(b.start) && !monday.isAfter(b.end)) {
          inBlock = b;
          break;
        }
      }
      if (inBlock == null) {
        // Rule 2: early cut end fills with maintain until block 1.
        week = (phase: rules.phaseRules.earlyCutFiller, rateLbWk: 0);
      } else if (inBlock.emphasis == 'reverse') {
        week = (phase: 'reverse', rateLbWk: reverseRate);
      } else {
        // Rule 3: bulk blocks keep dates; rate is the lever.
        week = (phase: 'bulk', rateLbWk: blockRate(inBlock));
      }
    } else {
      // Rule 4: next-cycle auto-generation to the horizon. The inner
      // loop re-dispatches the SAME week after a state transition
      // (e.g. hold exhausted → this week is already a cut week).
      while (true) {
        if (cycleState == 'hold') {
          if (cycleWeeksLeft <= 0) {
            cycleState = 'cut';
            continue;
          }
          cycleWeeksLeft--;
          week = (phase: 'maintain', rateLbWk: 0);
        } else if (cycleState == 'cut') {
          if (bw <= next.cutTargetLb) {
            cycleState = 'reverse';
            cycleWeeksLeft = next.reverseWeeks;
            continue;
          }
          week = (phase: 'cut', rateLbWk: levers.cutRateLbWk);
        } else if (cycleState == 'reverse') {
          if (cycleWeeksLeft <= 0) {
            cycleState = 'bulk';
            continue;
          }
          cycleWeeksLeft--;
          week = (phase: 'reverse', rateLbWk: reverseRate);
        } else {
          // bulk
          if (bw >= next.bandTopLb) {
            cycleState = 'hold';
            cycleWeeksLeft = next.holdWeeks;
            continue;
          }
          week = (phase: 'bulk', rateLbWk: levers.bulkRateLbWk ?? 0.4);
        }
        break;
      }
    }

    out.add(week);
    bw += week.rateLbWk;
  }
  return out;
}

// ---------------------------------------------------------------------------
// The simulator
// ---------------------------------------------------------------------------

/// Runs the full sim from [initial] through [levers.horizonYears] × 52
/// weeks. Week 0 is the observed current state (labeled with the
/// schedule's first phase); every later week is stepped per the library
/// docs. Lifts absent from [coefficients] fall back to the pooled fit;
/// lifts with NO fit hold flat.
SimResult simulate({
  required SimInitialState initial,
  required SimCoefficients coefficients,
  required SimRules rules,
  required SimProgram program,
  SimLevers levers = const SimLevers(),
}) {
  final horizonWeeks = levers.horizonYears * 52;
  final schedule = generatePhaseSchedule(
    t0Monday: initial.monday,
    bw0: initial.bw,
    program: program,
    rules: rules,
    levers: levers,
    horizonWeeks: horizonWeeks,
  );

  // Wilks k-anchor (design §2): actual-max SBD total / e1RM SBD total
  // at t0, held constant.
  var e1rmSbd0 = 0.0;
  for (final l in simSbdLifts) {
    e1rmSbd0 += initial.e1rm[l] ?? 0;
  }
  final k = (initial.actualMaxSbdTotalLbs != null && e1rmSbd0 > 0)
      ? initial.actualMaxSbdTotalLbs! / e1rmSbd0
      : 1.0;

  final lifts = [
    for (final l in simLifts)
      if (initial.e1rm.containsKey(l)) l,
  ];
  var bw = initial.bw;
  var e1rm = {for (final l in lifts) l: initial.e1rm[l]!};
  var peak = {
    for (final l in lifts)
      l: (initial.peak[l] ?? initial.e1rm[l]!) > initial.e1rm[l]!
          ? initial.peak[l]!
          : initial.e1rm[l]!,
  };

  double? gradeAt(int t, double bwAt) {
    final c0 = coefficients.climbC0;
    final cBw = coefficients.climbCBw;
    if (c0 == null || cBw == null) return null;
    final bf = coefficients.climbBf ?? 0;
    final freqWeeks = t < 26 ? t : 26; // honestly bounded, ~6 months
    return c0 + cBw * bwAt + bf * (levers.climbFrequency - 2) * freqWeeks;
  }

  double wilksAt(Map<String, double> e, double bwAt) {
    var total = 0.0;
    for (final l in simSbdLifts) {
      total += e[l] ?? 0;
    }
    return wilksPointsLb(k * total, bwAt);
  }

  final weeks = <SimWeek>[];
  for (var t = 0; t < horizonWeeks; t++) {
    final plan = schedule[t];
    weeks.add(SimWeek(
      monday: _addWeeks(initial.monday, t),
      phase: plan.phase,
      rateLbWk: plan.rateLbWk,
      bw: bw,
      e1rm: Map.unmodifiable(e1rm),
      peak: Map.unmodifiable(peak),
      gradeP75: gradeAt(t, bw),
      wilks: wilksAt(e1rm, bw),
    ));

    // Step to t+1 (S4 per-lift + in-sim peak update).
    final nextE1rm = <String, double>{};
    final nextPeak = <String, double>{};
    for (final l in lifts) {
      final resp = coefficients.strengthFor(l);
      final vRaw = resp == null ? 0.0 : resp.a + resp.bBw * plan.rateLbWk;
      final v = dampedVelocity(
        vRaw: vRaw,
        e1rm: e1rm[l]!,
        peak: peak[l]!,
        fullBelowPctOfPeak: rules.saturation.fullBelowPctOfPeak,
        zeroAtPctOfPeak: rules.saturation.zeroAtPctOfPeak,
      );
      final e = e1rm[l]! + v;
      nextE1rm[l] = e;
      nextPeak[l] = e > peak[l]! ? e : peak[l]!;
    }
    e1rm = nextE1rm;
    peak = nextPeak;
    bw += plan.rateLbWk;
  }

  return SimResult(weeks: weeks);
}
