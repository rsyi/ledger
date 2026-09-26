/// Sim fitting layer — weekly series, phase detection, response-model
/// fits, and walk-forward validation for the program simulator.
///
/// Extracted from `tool/sim_calibrate.dart` (W1) so the app and the
/// tool share ONE implementation (design doc
/// `airledger/docs/superpowers/specs/2026-09-25-sim-design.md` §7): the
/// tool is a thin shell (sheets IO + markdown) over these functions,
/// and the app refits on demand from the local ledger through the same
/// code path.
///
/// Pure Dart — no Flutter, no IO. The [WeeklySeries] JSON codec exists
/// so the W2 acceptance-gate test can run on a frozen fixture
/// (test/fixtures/sim_weekly_series.json) without touching the network.
library;

import 'dart:math' as math;

import 'program_metrics.dart'
    show StrengthRow, WeightRow, gradeSets, mainLiftByExercise,
        rpeAdjustedE1rm, weekStartOf, weeklyRollup;
import 'wilks.dart' show weeklyWilksSeries, wilksPointsLb;

/// The four main lifts the simulator models, in canonical order.
const List<String> simLifts = ['squat', 'bench', 'deadlift', 'press'];

/// The classic powerlifting three (the Wilks total).
const List<String> simSbdLifts = ['squat', 'bench', 'deadlift'];

/// One kaya ascent (date + parsed numeric V grade when the grade text
/// was a V-grade).
typedef ClimbAscent = ({DateTime date, int? vGrade});

// ---------------------------------------------------------------------------
// Small math helpers (shared by fits + tool markdown)
// ---------------------------------------------------------------------------

/// Carries the last non-null value forward through nulls.
List<double?> carryForward(List<double?> xs) {
  final out = List<double?>.from(xs);
  double? lastV;
  for (var i = 0; i < out.length; i++) {
    if (out[i] != null) {
      lastV = out[i];
    } else {
      out[i] = lastV;
    }
  }
  return out;
}

/// Linear-interpolated percentile of integer values, q in [0, 1].
double percentile(List<int> values, double q) {
  final s = [...values]..sort();
  final pos = q * (s.length - 1);
  final lo = pos.floor();
  final hi = pos.ceil();
  if (lo == hi) return s[lo].toDouble();
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

double? mean(List<double> xs) =>
    xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;

/// OLS via normal equations + Gaussian elimination (tiny k). Null when
/// the normal matrix is singular.
List<double>? ols(List<List<double>> X, List<double> y) {
  final k = X.first.length;
  final a = List.generate(k, (_) => List<double>.filled(k + 1, 0));
  for (var r = 0; r < X.length; r++) {
    for (var i = 0; i < k; i++) {
      for (var j = 0; j < k; j++) {
        a[i][j] += X[r][i] * X[r][j];
      }
      a[i][k] += X[r][i] * y[r];
    }
  }
  for (var col = 0; col < k; col++) {
    var piv = col;
    for (var r = col + 1; r < k; r++) {
      if (a[r][col].abs() > a[piv][col].abs()) piv = r;
    }
    if (a[piv][col].abs() < 1e-9) return null;
    final tmp = a[col];
    a[col] = a[piv];
    a[piv] = tmp;
    for (var r = 0; r < k; r++) {
      if (r == col) continue;
      final f = a[r][col] / a[col][col];
      for (var c = col; c <= k; c++) {
        a[r][c] -= f * a[col][c];
      }
    }
  }
  return [for (var i = 0; i < k; i++) a[i][k] / a[i][i]];
}

/// In-sample R² + MAE of an OLS fit.
({double r2, double mae}) fitStats(
  List<List<double>> X,
  List<double> y,
  List<double> beta,
) {
  final yMean = y.reduce((a, b) => a + b) / y.length;
  var sse = 0.0, sst = 0.0, absErr = 0.0;
  for (var r = 0; r < X.length; r++) {
    var hat = 0.0;
    for (var i = 0; i < beta.length; i++) {
      hat += X[r][i] * beta[i];
    }
    sse += (y[r] - hat) * (y[r] - hat);
    sst += (y[r] - yMean) * (y[r] - yMean);
    absErr += (y[r] - hat).abs();
  }
  return (r2: sst == 0 ? 0 : 1 - sse / sst, mae: absErr / X.length);
}

int? firstIndexAtOrAfter(List<DateTime> mondays, DateTime d) {
  for (var i = 0; i < mondays.length; i++) {
    if (!mondays[i].isBefore(d)) return i;
  }
  return null;
}

int? lastIndexAtOrBefore(List<DateTime> mondays, DateTime d) {
  for (var i = mondays.length - 1; i >= 0; i--) {
    if (!mondays[i].isAfter(d)) return i;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Weekly series
// ---------------------------------------------------------------------------

/// Monday-keyed weekly series over the full history — the single input
/// every fit and the walk-forward validation consume. All lists share
/// [mondays]' length and indexing. `*Raw` lists are null on weeks with
/// no fresh observation; the carried getters fill them forward.
class WeeklySeries {
  final List<DateTime> mondays;

  /// Week-mean of the week's weigh-ins (lb); null = no weigh-in.
  final List<double?> bwRaw;

  /// Per lift: weekly best RPE-adjusted e1RM; null = lift untrained.
  final Map<String, List<double?>> e1rmRaw;

  /// Per lift: weekly best actually-lifted weight; null = untrained.
  final Map<String, List<double?>> bestActualRaw;

  /// Per lift: near-max sets that week (§2.5 grading).
  final Map<String, List<int>> nearMax;

  /// Climbing sessions (distinct kaya dates) that week.
  final List<int> climbSessions;

  /// Rolling 4-week p75 of numeric V grades (>= 5 ascents in window);
  /// null when the window is too thin.
  final List<double?> gradeP75Raw;

  /// Weekly actual-max SBD Wilks; null before coverage starts.
  final List<double?> wilks;

  /// The SBD total (lb) behind [wilks]; null in lockstep with it.
  final List<double?> wilksTotalLbs;

  WeeklySeries({
    required this.mondays,
    required this.bwRaw,
    required this.e1rmRaw,
    required this.bestActualRaw,
    required this.nearMax,
    required this.climbSessions,
    required this.gradeP75Raw,
    required this.wilks,
    required this.wilksTotalLbs,
  });

  int get length => mondays.length;

  late final List<double?> bw = carryForward(bwRaw);
  late final Map<String, List<double?>> e1rm = {
    for (final l in simLifts) l: carryForward(e1rmRaw[l]!),
  };
  late final Map<String, List<double?>> bestActual = {
    for (final l in simLifts) l: carryForward(bestActualRaw[l]!),
  };
  late final Map<String, List<bool>> trained = {
    for (final l in simLifts)
      l: [for (var i = 0; i < length; i++) e1rmRaw[l]![i] != null],
  };
  late final List<double?> gradeP75 = carryForward(gradeP75Raw);

  // -- JSON codec (the frozen-fixture format; version-tagged) --------------

  Map<String, Object?> toJson() => {
        'version': 1,
        'mondays': [for (final m in mondays) _ymd(m)],
        'bw_raw': bwRaw,
        'e1rm_raw': e1rmRaw,
        'best_actual_raw': bestActualRaw,
        'near_max': nearMax,
        'climb_sessions': climbSessions,
        'grade_p75_raw': gradeP75Raw,
        'wilks': wilks,
        'wilks_total_lbs': wilksTotalLbs,
      };

  factory WeeklySeries.fromJson(Map<String, Object?> json) {
    List<double?> nums(Object? v) => [
          for (final e in v as List) e == null ? null : (e as num).toDouble(),
        ];
    List<int> ints(Object? v) => [for (final e in v as List) (e as num).toInt()];
    Map<String, List<double?>> perLift(Object? v) => {
          for (final e in (v as Map).entries) e.key as String: nums(e.value),
        };
    return WeeklySeries(
      mondays: [
        for (final m in json['mondays'] as List) DateTime.parse(m as String),
      ],
      bwRaw: nums(json['bw_raw']),
      e1rmRaw: perLift(json['e1rm_raw']),
      bestActualRaw: perLift(json['best_actual_raw']),
      nearMax: {
        for (final e in (json['near_max'] as Map).entries)
          e.key as String: ints(e.value),
      },
      climbSessions: ints(json['climb_sessions']),
      gradeP75Raw: nums(json['grade_p75_raw']),
      wilks: nums(json['wilks']),
      wilksTotalLbs: nums(json['wilks_total_lbs']),
    );
  }
}

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Number of graded main-lift sets in [rows] (study "Inputs" line).
int strengthObsGradedCount(List<StrengthRow> rows) => gradeSets(rows).length;

/// Builds the [WeeklySeries] from raw history rows — the exact W1
/// pipeline (sim_calibrate.dart), verbatim semantics: Monday-keyed ISO
/// weeks spanning the full input range.
WeeklySeries buildWeeklySeries({
  required List<StrengthRow> strengthRows,
  required List<WeightRow> weightRows,
  required List<ClimbAscent> climbs,
}) {
  final graded = gradeSets(strengthRows);
  final rollup = weeklyRollup(
    graded,
    weights: weightRows,
    climbingDates: [for (final c in climbs) c.date],
    weekStartDay: DateTime.monday,
  );
  final byMonday = {for (final w in rollup) w.weekStart: w};
  final mondays = [for (final w in rollup) w.weekStart];
  final index = {for (var i = 0; i < mondays.length; i++) mondays[i]: i};
  final n = mondays.length;

  DateTime wk(DateTime d) => weekStartOf(d, DateTime.monday);

  // Bodyweight: mean of the week's weigh-ins.
  final bwRaw = List<double?>.filled(n, null);
  {
    final sum = <DateTime, double>{};
    final cnt = <DateTime, int>{};
    for (final w in weightRows) {
      final k = wk(w.date);
      sum[k] = (sum[k] ?? 0) + w.weightLbs;
      cnt[k] = (cnt[k] ?? 0) + 1;
    }
    for (var i = 0; i < n; i++) {
      final s = sum[mondays[i]];
      if (s != null) bwRaw[i] = s / cnt[mondays[i]]!;
    }
  }

  // Per-lift weekly best actual weight + best RPE-adjusted e1RM.
  final bestActualRaw = {
    for (final l in simLifts) l: List<double?>.filled(n, null),
  };
  final e1rmRaw = {for (final l in simLifts) l: List<double?>.filled(n, null)};
  for (final r in strengthRows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || r.weight <= 0 || r.reps < 1) continue;
    final i = index[wk(r.date)];
    if (i == null) continue;
    final a = bestActualRaw[lift]!;
    if ((a[i] ?? 0) < r.weight) a[i] = r.weight;
    final e = rpeAdjustedE1rm(r.weight, r.reps, r.rpe);
    final s = e1rmRaw[lift]!;
    if ((s[i] ?? 0) < e) s[i] = e;
  }

  // Heavy exposure + climbing sessions from the rollup.
  final nearMax = {for (final l in simLifts) l: List<int>.filled(n, 0)};
  final climbSessions = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final w = byMonday[mondays[i]]!;
    for (final l in simLifts) {
      nearMax[l]![i] = w.perLift[l]?.nearMaxSets ?? 0;
    }
    climbSessions[i] = w.climbingSessions;
  }

  // Rolling 4-week grade p75 (>= 5 numeric-V ascents in window).
  final gradesByWeek = List<List<int>>.generate(n, (_) => []);
  for (final c in climbs) {
    final i = index[wk(c.date)];
    if (i != null && c.vGrade != null) gradesByWeek[i].add(c.vGrade!);
  }
  final gradeP75Raw = List<double?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    final window = <int>[];
    for (var j = math.max(0, i - 3); j <= i; j++) {
      window.addAll(gradesByWeek[j]);
    }
    if (window.length >= 5) gradeP75Raw[i] = percentile(window, 0.75);
  }

  // Weekly Wilks (actual-max display standard).
  final wilksWeeks = weeklyWilksSeries(strengthRows, weightRows);
  final wilksByMonday = {for (final w in wilksWeeks) w.weekStart: w};
  final wilks = List<double?>.filled(n, null);
  final wilksTotal = List<double?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    final w = wilksByMonday[mondays[i]];
    if (w != null) {
      wilks[i] = w.wilks;
      wilksTotal[i] = w.totalLbs;
    }
  }

  return WeeklySeries(
    mondays: mondays,
    bwRaw: bwRaw,
    e1rmRaw: e1rmRaw,
    bestActualRaw: bestActualRaw,
    nearMax: nearMax,
    climbSessions: climbSessions,
    gradeP75Raw: gradeP75Raw,
    wilks: wilks,
    wilksTotalLbs: wilksTotal,
  );
}

// ---------------------------------------------------------------------------
// Phase detection (bw trajectory)
// ---------------------------------------------------------------------------

/// One detected phase window: inclusive week indices into the series,
/// label gain|loss|flat.
typedef PhaseRun = ({int start, int end, String label});

/// Detects phase windows from the bw trajectory: centered smoothed rate,
/// gain >= +0.15 lb/wk, loss <= -0.15, runs < 4 wk merged into the
/// longer neighbor, run label from net rate (±0.1 lb/wk).
List<PhaseRun> detectPhaseRuns(WeeklySeries series) {
  final n = series.length;
  final bw = series.bw;
  final smooth = List<double?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    var s = 0.0;
    var c = 0;
    for (var j = math.max(0, i - 2); j <= math.min(n - 1, i + 2); j++) {
      if (bw[j] != null) {
        s += bw[j]!;
        c++;
      }
    }
    if (c > 0) smooth[i] = s / c;
  }
  final rate = List<double?>.filled(n, null); // centered lb/wk
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - 2);
    final hi = math.min(n - 1, i + 2);
    if (smooth[lo] != null && smooth[hi] != null && hi > lo) {
      rate[i] = (smooth[hi]! - smooth[lo]!) / (hi - lo);
    }
  }
  String cls(double? r) =>
      r == null ? 'flat' : (r >= 0.15 ? 'gain' : (r <= -0.15 ? 'loss' : 'flat'));

  var runs = <PhaseRun>[];
  var start = 0;
  for (var i = 1; i <= n; i++) {
    if (i == n || cls(rate[i]) != cls(rate[start])) {
      runs.add((start: start, end: i - 1, label: cls(rate[start])));
      start = i;
    }
  }
  var changed = true;
  while (changed && runs.length > 1) {
    changed = false;
    for (var i = 0; i < runs.length; i++) {
      final len = runs[i].end - runs[i].start + 1;
      if (len >= 4) continue;
      final prevLen = i > 0 ? runs[i - 1].end - runs[i - 1].start + 1 : -1;
      final nextLen =
          i < runs.length - 1 ? runs[i + 1].end - runs[i + 1].start + 1 : -1;
      if (prevLen < 0 && nextLen < 0) continue;
      if (prevLen >= nextLen) {
        runs[i - 1] = (
          start: runs[i - 1].start,
          end: runs[i].end,
          label: runs[i - 1].label,
        );
      } else {
        runs[i + 1] = (
          start: runs[i].start,
          end: runs[i + 1].end,
          label: runs[i + 1].label,
        );
      }
      runs.removeAt(i);
      changed = true;
      break;
    }
  }
  return [
    for (final r in runs)
      (
        start: r.start,
        end: r.end,
        label: bw[r.start] == null || bw[r.end] == null || r.end == r.start
            ? r.label
            : () {
                final netRate = (bw[r.end]! - bw[r.start]!) / (r.end - r.start);
                return netRate >= 0.1
                    ? 'gain'
                    : (netRate <= -0.1 ? 'loss' : 'flat');
              }(),
      ),
  ];
}

// ---------------------------------------------------------------------------
// Fit observations (non-overlapping 4-week blocks inside runs)
// ---------------------------------------------------------------------------

/// One strength fit observation: a 4-week block for one lift.
typedef SimStrengthObs = ({
  String lift,
  String phase,
  DateTime start,
  double velocity, // lb/wk of RPE-adj e1RM
  double bwRate, // lb/wk
  double heavy, // near-max sets/wk, this lift
});

/// One climbing velocity observation (4-week block).
typedef SimClimbObs = ({
  String phase,
  DateTime start,
  double velocity, // V/wk of rolling p75
  double freq, // sessions/wk
  double bwRate,
});

/// One climbing level observation (weekly, non-carried p75 + bw).
typedef SimLevelObs = ({DateTime monday, double bwLb, double p75});

/// Fit observations extracted from a series' phase runs.
class SimObservations {
  final List<SimStrengthObs> strength;
  final List<SimClimbObs> climb;
  final List<SimLevelObs> level;

  const SimObservations({
    required this.strength,
    required this.climb,
    required this.level,
  });
}

/// Number of weeks per fit block.
const int simBlockWeeks = 4;

/// Extracts the fit observations: strength blocks (lift trained >= 2
/// weeks in block, fresh at the endpoint), climbing velocity blocks
/// (real p75 at both endpoints), and weekly level observations.
SimObservations blockObservations(WeeklySeries series, List<PhaseRun> runs) {
  final bw = series.bw;
  final e1rm = series.e1rm;
  final trained = series.trained;
  final strengthObs = <SimStrengthObs>[];
  final climbObs = <SimClimbObs>[];

  for (final run in runs) {
    for (var i = run.start; i + simBlockWeeks <= run.end; i += simBlockWeeks) {
      final j = i + simBlockWeeks;
      if (bw[i] == null || bw[j] == null) continue;
      final bwRate = (bw[j]! - bw[i]!) / simBlockWeeks;
      for (final l in simLifts) {
        final trainedIn = [
          for (var k = i; k < j; k++)
            if (trained[l]![k]) k,
        ];
        final endFresh = trained[l]![j] || (j - 1 >= i && trained[l]![j - 1]);
        if (trainedIn.length < 2 || !endFresh) continue;
        if (e1rm[l]![i] == null || e1rm[l]![j] == null) continue;
        var heavy = 0.0;
        for (var k = i; k < j; k++) {
          heavy += series.nearMax[l]![k];
        }
        strengthObs.add((
          lift: l,
          phase: run.label,
          start: series.mondays[i],
          velocity: (e1rm[l]![j]! - e1rm[l]![i]!) / simBlockWeeks,
          bwRate: bwRate,
          heavy: heavy / simBlockWeeks,
        ));
      }
      if (series.gradeP75Raw[i] != null && series.gradeP75Raw[j] != null) {
        var sessions = 0;
        for (var k = i; k < j; k++) {
          sessions += series.climbSessions[k];
        }
        climbObs.add((
          phase: run.label,
          start: series.mondays[i],
          velocity:
              (series.gradeP75Raw[j]! - series.gradeP75Raw[i]!) / simBlockWeeks,
          freq: sessions / simBlockWeeks,
          bwRate: bwRate,
        ));
      }
    }
  }

  final levelObs = <SimLevelObs>[];
  for (var i = 0; i < series.length; i++) {
    if (series.gradeP75Raw[i] != null && bw[i] != null) {
      levelObs.add((
        monday: series.mondays[i],
        bwLb: bw[i]!,
        p75: series.gradeP75Raw[i]!,
      ));
    }
  }

  return SimObservations(
    strength: strengthObs,
    climb: climbObs,
    level: levelObs,
  );
}

// ---------------------------------------------------------------------------
// Sim coefficients (what the sim core integrates; world_model.yaml shape)
// ---------------------------------------------------------------------------

/// One lift's bw-only response: velocity = a + bBw · bw_rate.
class LiftResponse {
  final double a;
  final double bBw;

  const LiftResponse({required this.a, required this.bBw});
}

/// The coefficient set the sim core consumes — the S4 per-lift bw-rate
/// responses (+ pooled fallback) and the C2 level-anchored climbing
/// model with the C1 frequency lever term.
class SimCoefficients {
  /// Per-lift bw-only responses (S3/S4 spec). Lifts with insufficient
  /// history are absent — [strengthFor] falls back to [pooled].
  final Map<String, LiftResponse> strength;

  /// Pooled bw-only response (all lifts).
  final LiftResponse? pooled;

  /// C2 level anchor: grade_p75 = climbC0 + climbCBw · bw.
  final double? climbC0;
  final double? climbCBw;

  /// C1 frequency velocity term (V/wk per session/wk) — the climbing
  /// frequency lever, capped in-sim.
  final double? climbBf;

  const SimCoefficients({
    required this.strength,
    required this.pooled,
    required this.climbC0,
    required this.climbCBw,
    required this.climbBf,
  });

  LiftResponse? strengthFor(String lift) => strength[lift] ?? pooled;
}

/// Fits [SimCoefficients] from a full-history series — the on-demand
/// refit path (design §8) and the source of world_model.yaml's shipped
/// defaults. Same specs as the study: per-lift bw-only OLS over 4-week
/// blocks (>= 6 obs per lift), pooled fallback, C2 weekly level fit
/// (>= 8 obs), C1 velocity fit for the frequency term (>= 6 obs).
SimCoefficients fitFromSeries(WeeklySeries series) {
  final runs = detectPhaseRuns(series);
  final obs = blockObservations(series, runs);

  LiftResponse? bwOnly(List<SimStrengthObs> o) {
    if (o.length < 6) return null;
    final beta = ols(
      [for (final e in o) [1.0, e.bwRate]],
      [for (final e in o) e.velocity],
    );
    return beta == null ? null : LiftResponse(a: beta[0], bBw: beta[1]);
  }

  final strength = <String, LiftResponse>{};
  for (final l in simLifts) {
    final fit = bwOnly([for (final o in obs.strength) if (o.lift == l) o]);
    if (fit != null) strength[l] = fit;
  }
  final pooled = bwOnly(obs.strength);

  double? c0, cBw;
  if (obs.level.length >= 8) {
    final beta = ols(
      [for (final o in obs.level) [1.0, o.bwLb]],
      [for (final o in obs.level) o.p75],
    );
    if (beta != null) {
      c0 = beta[0];
      cBw = beta[1];
    }
  }

  double? bf;
  if (obs.climb.length >= 6) {
    final beta = ols(
      [for (final o in obs.climb) [1.0, o.freq, o.bwRate]],
      [for (final o in obs.climb) o.velocity],
    );
    if (beta != null) bf = beta[1];
  }

  return SimCoefficients(
    strength: strength,
    pooled: pooled,
    climbC0: c0,
    climbCBw: cBw,
    climbBf: bf,
  );
}

// ---------------------------------------------------------------------------
// Walk-forward validation (the W2 acceptance gate's engine)
// ---------------------------------------------------------------------------

/// One held-out validation window.
typedef WalkWindow = ({String name, DateTime from, DateTime to});

/// The study's three held-out windows over [series].
List<WalkWindow> defaultValidationWindows(WeeklySeries series) => [
      (
        name: '2024 bulk (Apr–Jul 2024)',
        from: DateTime(2024, 4, 1),
        to: DateTime(2024, 7, 31),
      ),
      (
        name: '2025 bulk (Nov 2024 – Oct 2025)',
        from: DateTime(2024, 11, 1),
        to: DateTime(2025, 10, 5),
      ),
      (
        name: 'current cut (since 2025-10-06)',
        from: DateTime(2025, 10, 6),
        to: series.mondays.last,
      ),
    ];

/// One row of the walk-forward MAE table. [models] keys: S1, S2, S3, S4
/// for strength rows; C1, C2 for the climb row; S4 alone for the Wilks
/// row. Null model = not fittable from prior data.
class WalkForwardRow {
  final String window;
  final String output;
  final double flat;
  final Map<String, double?> models;
  final String best;

  const WalkForwardRow({
    required this.window,
    required this.output,
    required this.flat,
    required this.models,
    required this.best,
  });
}

/// Per-window prior-data counts (the study's `_prior data_` rows).
typedef WalkPriorData = ({
  String window,
  int strengthBlocks,
  int climbBlocks,
  int levelWeeks,
});

class WalkForwardResult {
  final List<WalkForwardRow> rows;
  final List<WalkPriorData> priorData;

  const WalkForwardResult({required this.rows, required this.priorData});

  WalkForwardRow? row(String window, String output) {
    for (final r in rows) {
      if (r.window == window && r.output == output) return r;
    }
    return null;
  }
}

String _bestOf(double flat, List<double?> models, List<String> names) {
  var bestName = 'flat';
  var bestV = flat;
  for (var i = 0; i < models.length; i++) {
    final v = models[i];
    if (v != null && v < bestV) {
      bestV = v;
      bestName = names[i];
    }
  }
  return bestName;
}

/// Walk-forward validation — the exact W1 procedure: for each window
/// every model variant is refit on blocks strictly before the window
/// start, then integrated weekly from the window-start observed state
/// using OBSERVED weekly inputs (3-wk trailing bw rate; the week's
/// near-max sets; climb sessions). Baseline = flat at the window-start
/// value; MAE over weeks with a fresh (non-carried) observation.
WalkForwardResult walkForward(WeeklySeries series, {List<WalkWindow>? windows}) {
  final wins = windows ?? defaultValidationWindows(series);
  final runs = detectPhaseRuns(series);
  final obs = blockObservations(series, runs);
  final mondays = series.mondays;
  final bw = series.bw;
  final e1rm = series.e1rm;
  final trained = series.trained;
  final gradeP75 = series.gradeP75;

  DateTime wk(DateTime d) => weekStartOf(d, DateTime.monday);

  final rows = <WalkForwardRow>[];
  final priors = <WalkPriorData>[];

  for (final win in wins) {
    final i0 = firstIndexAtOrAfter(mondays, wk(win.from));
    final i1 = lastIndexAtOrBefore(mondays, wk(win.to));
    if (i0 == null || i1 == null || i1 <= i0) continue;

    final priorS = [
      for (final o in obs.strength)
        if (o.start.add(Duration(days: simBlockWeeks * 7)).isBefore(win.from)) o,
    ];
    final priorC = [
      for (final o in obs.climb)
        if (o.start.add(Duration(days: simBlockWeeks * 7)).isBefore(win.from)) o,
    ];
    final priorLevel = [
      for (final o in obs.level)
        if (o.monday.isBefore(win.from)) o,
    ];
    priors.add((
      window: win.name,
      strengthBlocks: priorS.length,
      climbBlocks: priorC.length,
      levelWeeks: priorLevel.length,
    ));

    List<double>? fit(
      List<SimStrengthObs> o,
      List<double> Function(SimStrengthObs o) row,
    ) =>
        o.length < 6
            ? null
            : ols([for (final e in o) row(e)], [for (final e in o) e.velocity]);

    final s1 = fit(priorS, (o) => [1.0, o.bwRate, o.heavy]);
    final s2 = fit(priorS, (o) => [1.0, o.bwRate]);
    final s3 = {
      for (final l in simLifts)
        l: () {
          final mine = [for (final o in priorS) if (o.lift == l) o];
          return mine.length >= 20 ? fit(mine, (o) => [1.0, o.bwRate]) : s2;
        }(),
    };
    List<double>? c1;
    if (priorC.length >= 6) {
      c1 = ols(
        [for (final o in priorC) [1.0, o.freq, o.bwRate]],
        [for (final o in priorC) o.velocity],
      );
    }
    List<double>? c2;
    if (priorLevel.length >= 8) {
      c2 = ols(
        [for (final o in priorLevel) [1.0, o.bwLb]],
        [for (final o in priorLevel) o.p75],
      );
    }

    double bwRate3(int i) {
      final j = math.max(0, i - 3);
      if (bw[i] == null || bw[j] == null || i == j) return 0;
      return (bw[i]! - bw[j]!) / (i - j);
    }

    // Strength per lift: integrate each variant weekly, score fresh weeks.
    final deltaHatS4 = <String, List<double>>{}; // for the Wilks row
    for (final l in simLifts) {
      final start = e1rm[l]![i0];
      if (start == null) continue;
      var peak = start;
      for (var i = 0; i <= i0; i++) {
        final v = series.e1rmRaw[l]![i];
        if (v != null && v > peak) peak = v;
      }
      double velocity(List<double>? beta, int i) {
        if (beta == null) return 0;
        if (beta.length == 3) {
          return beta[0] +
              beta[1] * bwRate3(i) +
              beta[2] * series.nearMax[l]![i];
        }
        return beta[0] + beta[1] * bwRate3(i);
      }

      final hats = [start, start, start, start];
      final betas = [s1, s2, s3[l], s3[l]];
      final errs = [<double>[], <double>[], <double>[], <double>[]];
      final flatErr = <double>[];
      final deltas = <double>[];
      for (var i = i0 + 1; i <= i1; i++) {
        for (var v = 0; v < 4; v++) {
          var vel = velocity(betas[v], i - 1);
          if (v == 3 && vel > 0) {
            // Saturation: full velocity below 95% of peak, zero at 105%.
            final f = ((1.05 * peak - hats[3]) / (0.10 * peak)).clamp(0.0, 1.0);
            vel *= f;
          }
          hats[v] += vel;
        }
        deltas.add(hats[3] - start);
        final fresh = e1rm[l]![i];
        if (fresh == null || !trained[l]![i]) continue; // carried → skip
        for (var v = 0; v < 4; v++) {
          if (betas[v] != null) errs[v].add((hats[v] - fresh).abs());
        }
        flatErr.add((start - fresh).abs());
      }
      deltaHatS4[l] = deltas;
      if (flatErr.isEmpty) continue;
      final fm = mean(flatErr)!;
      final ms = [for (final e in errs) mean(e)];
      rows.add(WalkForwardRow(
        window: win.name,
        output: '$l e1RM (lb)',
        flat: fm,
        models: {'S1': ms[0], 'S2': ms[1], 'S3': ms[2], 'S4': ms[3]},
        best: _bestOf(fm, ms, ['S1', 'S2', 'S3', 'S4']),
      ));
    }

    // Wilks (derived from S4, approximate).
    final w0Total = series.wilksTotalLbs[i0];
    if (w0Total != null && simSbdLifts.every(deltaHatS4.containsKey)) {
      final modelErr = <double>[];
      final flatErr = <double>[];
      for (var i = i0 + 1; i <= i1; i++) {
        final obsW = series.wilks[i];
        if (obsW == null || bw[i] == null) continue;
        var d = 0.0;
        for (final l in simSbdLifts) {
          d += deltaHatS4[l]![i - i0 - 1];
        }
        modelErr.add((wilksPointsLb(w0Total + d, bw[i]!) - obsW).abs());
        flatErr.add((wilksPointsLb(w0Total, bw[i]!) - obsW).abs());
      }
      if (modelErr.isNotEmpty) {
        final mm = mean(modelErr)!;
        final fm = mean(flatErr)!;
        rows.add(WalkForwardRow(
          window: win.name,
          output: 'Wilks (derived, S4)',
          flat: fm,
          models: {'S4': mm},
          best: mm < fm ? 'S4' : 'flat',
        ));
      }
    }

    // Climbing: C1 integrated velocity vs C2 level-anchored.
    final g0 = gradeP75[i0];
    if (g0 != null) {
      var hat = g0;
      final c1Err = <double>[];
      final c2Err = <double>[];
      final flatErr = <double>[];
      for (var i = i0 + 1; i <= i1; i++) {
        hat += c1 == null
            ? 0
            : c1[0] +
                c1[1] * series.climbSessions[i - 1] +
                c1[2] * bwRate3(i - 1);
        final fresh = series.gradeP75Raw[i];
        if (fresh == null) continue;
        if (c1 != null) c1Err.add((hat - fresh).abs());
        if (c2 != null && bw[i] != null) {
          c2Err.add((c2[0] + c2[1] * bw[i]! - fresh).abs());
        }
        flatErr.add((g0 - fresh).abs());
      }
      if (flatErr.isNotEmpty) {
        final fm = mean(flatErr)!;
        final m1 = mean(c1Err);
        final m2 = mean(c2Err);
        rows.add(WalkForwardRow(
          window: win.name,
          output: 'climb grade p75 (V)',
          flat: fm,
          models: {'C1': m1, 'C2': m2},
          best: _bestOf(fm, [m1, m2], ['C1', 'C2']),
        ));
      }
    }
  }

  return WalkForwardResult(rows: rows, priorData: priors);
}

// ---------------------------------------------------------------------------
// Sheet-tab row parsing (pure: List<List<Object?>> → typed rows) — shared
// by tool/sim_calibrate.dart and tool/sim_forecast.dart.
// ---------------------------------------------------------------------------

Map<String, int> sheetHeaderIndex(List<List<Object?>> tab) => tab.isEmpty
    ? {}
    : {
        for (var i = 0; i < tab.first.length; i++) tab.first[i].toString(): i,
      };

String sheetCell(List<Object?> row, int? i) =>
    i == null || i < 0 || i >= row.length
        ? ''
        : (row[i]?.toString() ?? '').trim();

DateTime? parseSheetDate(String s) {
  if (s.isEmpty) return null;
  final iso = DateTime.tryParse(s);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final us = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(s);
  if (us != null) {
    return DateTime(
      int.parse(us.group(3)!),
      int.parse(us.group(1)!),
      int.parse(us.group(2)!),
    );
  }
  return null;
}

/// Parses the `strength` tab. [onAnomaly] receives a label per skipped row.
List<StrengthRow> strengthRowsFromTab(
  List<List<Object?>> tab, {
  void Function(String kind)? onAnomaly,
}) {
  final head = sheetHeaderIndex(tab);
  final out = <StrengthRow>[];
  for (final r in tab.skip(1)) {
    final date = parseSheetDate(sheetCell(r, head['Date']));
    final exercise = sheetCell(r, head['Exercise']);
    if (date == null || exercise.isEmpty) {
      onAnomaly?.call('strength: missing date/exercise');
      continue;
    }
    final weight = double.tryParse(sheetCell(r, head['Weight']));
    final reps = double.tryParse(sheetCell(r, head['Reps']));
    if (mainLiftByExercise.containsKey(exercise) &&
        (weight == null || reps == null)) {
      onAnomaly?.call('strength: main lift missing weight/reps');
      continue;
    }
    final rpeText = sheetCell(r, head['RPE']);
    out.add(
      StrengthRow(
        date: date,
        exercise: exercise,
        weight: weight ?? 0,
        reps: (reps ?? 0).round(),
        rpe: rpeText.isEmpty ? null : double.tryParse(rpeText),
      ),
    );
  }
  return out;
}

/// Parses the `weight` tab.
List<WeightRow> weightRowsFromTab(
  List<List<Object?>> tab, {
  void Function(String kind)? onAnomaly,
}) {
  final head = sheetHeaderIndex(tab);
  final out = <WeightRow>[];
  for (final r in tab.skip(1)) {
    final date = parseSheetDate(sheetCell(r, head['date']));
    final lbs = double.tryParse(sheetCell(r, head['weight_lbs']));
    if (date == null || lbs == null) {
      onAnomaly?.call('weight: missing date or weight_lbs');
      continue;
    }
    out.add(WeightRow(date: date, weightLbs: lbs));
  }
  return out;
}

/// Parses the `kaya_ascents` tab (numeric V grades only get a grade).
List<ClimbAscent> climbsFromTab(
  List<List<Object?>> tab, {
  void Function(String kind)? onAnomaly,
}) {
  final head = sheetHeaderIndex(tab);
  final vRe = RegExp(r'^v(\d+)', caseSensitive: false);
  final out = <ClimbAscent>[];
  for (final r in tab.skip(1)) {
    final date = parseSheetDate(sheetCell(r, head['date']));
    if (date == null) {
      onAnomaly?.call('kaya_ascents: missing date');
      continue;
    }
    final g = vRe.firstMatch(sheetCell(r, head['grade']));
    out.add((date: date, vGrade: g == null ? null : int.parse(g.group(1)!)));
  }
  return out;
}
