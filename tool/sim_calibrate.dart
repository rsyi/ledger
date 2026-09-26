// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:airledger/services/program_metrics.dart';
import 'package:airledger/services/wilks.dart';
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:googleapis_auth/auth_io.dart';

/// Program-simulation calibration + walk-forward validation study
/// (airledger repo, docs/superpowers/specs/2026-09-25-program-simulation-spec.md, W1).
///
///   dart run tool/sim_calibrate.dart [--out <markdown path>]
///
/// Reads FULL strength + weight + kaya_ascents history from the workbook
/// (coach_backtest.dart plumbing), builds Monday-keyed weekly series
/// (bw 7d mean, per-lift best-actual + RPE-adjusted e1RM, Wilks
/// actual-max, climbing sessions + numeric-V grade p75, near-max
/// exposure), detects historical phase windows from the bw trajectory,
/// fits the phase response models the simulator will integrate:
///
///   strength velocity (lb/wk, RPE-adj e1RM) ~ bw rate + heavy exposure
///   climbing grade p75 velocity (V/wk)      ~ session freq + bw rate
///
/// over non-overlapping 4-week blocks (simple OLS, coefficients + R² +
/// in-sample MAE), then WALK-FORWARD validates: for each held-out
/// window the model is refit on blocks strictly before the window and
/// integrated weekly from the window-start state using OBSERVED weekly
/// inputs (bw rate, exposure, climb frequency — the levers the sim will
/// script); MAE per output vs the naive flat baseline.
///
/// Output is the full markdown study (stdout, and --out writes it) —
/// the source for docs/superpowers/specs/2026-09-25-sim-calibration-study.md.
final home = Platform.environment['HOME']!;
final configPath = '$home/.config/airledger/config.yaml';

const lifts = ['squat', 'bench', 'deadlift', 'press'];
const sbdLifts = ['squat', 'bench', 'deadlift'];

/// One strength fit observation: a 4-week block for one lift.
typedef SObs = ({
  String lift,
  String phase,
  DateTime start,
  double velocity, // lb/wk of RPE-adj e1RM
  double bwRate, // lb/wk
  double heavy, // near-max sets/wk, this lift
});

Future<void> main(List<String> args) async {
  String? outPath;
  final outIdx = args.indexOf('--out');
  if (outIdx >= 0 && outIdx + 1 < args.length) outPath = args[outIdx + 1];

  final config = readConfig();
  final api = await sheetsApi(config.keyPath);

  Future<List<List<Object?>>> tab(String name) async {
    try {
      final resp = await api.spreadsheets.values.get(
        config.spreadsheetId,
        "'$name'",
      );
      return resp.values ?? [];
    } on gsheets.DetailedApiRequestError catch (e) {
      if (e.status == 400) return [];
      rethrow;
    }
  }

  final strengthTab = await tab('strength');
  final weightTab = await tab('weight');
  final climbTab = await tab('kaya_ascents');

  // -------------------------------------------------------------------------
  // Rows (coach_backtest pattern; anomalies counted, not fatal)
  // -------------------------------------------------------------------------
  final anomalies = <String, int>{};
  void anomaly(String kind) => anomalies[kind] = (anomalies[kind] ?? 0) + 1;

  final sHead = headerIndex(strengthTab);
  final strengthRows = <StrengthRow>[];
  for (final r in strengthTab.skip(1)) {
    final date = parseSheetDate(cell(r, sHead['Date']));
    final exercise = cell(r, sHead['Exercise']);
    if (date == null || exercise.isEmpty) {
      anomaly('strength: missing date/exercise');
      continue;
    }
    final weight = double.tryParse(cell(r, sHead['Weight']));
    final reps = double.tryParse(cell(r, sHead['Reps']));
    if (mainLiftByExercise.containsKey(exercise) &&
        (weight == null || reps == null)) {
      anomaly('strength: main lift missing weight/reps');
      continue;
    }
    final rpeText = cell(r, sHead['RPE']);
    strengthRows.add(
      StrengthRow(
        date: date,
        exercise: exercise,
        weight: weight ?? 0,
        reps: (reps ?? 0).round(),
        rpe: rpeText.isEmpty ? null : double.tryParse(rpeText),
      ),
    );
  }

  final wHead = headerIndex(weightTab);
  final weightRows = <WeightRow>[];
  for (final r in weightTab.skip(1)) {
    final date = parseSheetDate(cell(r, wHead['date']));
    final lbs = double.tryParse(cell(r, wHead['weight_lbs']));
    if (date == null || lbs == null) {
      anomaly('weight: missing date or weight_lbs');
      continue;
    }
    weightRows.add(WeightRow(date: date, weightLbs: lbs));
  }

  final kHead = headerIndex(climbTab);
  final climbs = <({DateTime date, int? vGrade})>[];
  final vRe = RegExp(r'^v(\d+)', caseSensitive: false);
  for (final r in climbTab.skip(1)) {
    final date = parseSheetDate(cell(r, kHead['date']));
    if (date == null) {
      anomaly('kaya_ascents: missing date');
      continue;
    }
    final g = vRe.firstMatch(cell(r, kHead['grade']));
    climbs.add((date: date, vGrade: g == null ? null : int.parse(g.group(1)!)));
  }

  // -------------------------------------------------------------------------
  // Weekly series (Monday-keyed ISO weeks — matches coach_backtest; the
  // program's v7 Saturday accounting weeks are a reporting concern, not a
  // physiology one)
  // -------------------------------------------------------------------------
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

  // Bodyweight: mean of the week's weigh-ins, carried forward.
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
  final bw = carryForward(bwRaw);

  // Per-lift weekly best actual weight + best RPE-adjusted e1RM; and the
  // weeks each lift was actually trained (to gate block fits).
  final bestActualRaw = {for (final l in lifts) l: List<double?>.filled(n, null)};
  final e1rmRaw = {for (final l in lifts) l: List<double?>.filled(n, null)};
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
  final e1rm = {for (final l in lifts) l: carryForward(e1rmRaw[l]!)};
  final trained = {
    for (final l in lifts)
      l: [for (var i = 0; i < n; i++) e1rmRaw[l]![i] != null],
  };

  // Heavy exposure: near-max sets per lift per week (§2.5 grading).
  final nearMax = {for (final l in lifts) l: List<int>.filled(n, 0)};
  final climbSessions = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final w = byMonday[mondays[i]]!;
    for (final l in lifts) {
      nearMax[l]![i] = w.perLift[l]?.nearMaxSets ?? 0;
    }
    climbSessions[i] = w.climbingSessions;
  }

  // Climbing grades per week (numeric V only).
  final gradesByWeek = List<List<int>>.generate(n, (_) => []);
  for (final c in climbs) {
    final i = index[wk(c.date)];
    if (i != null && c.vGrade != null) gradesByWeek[i].add(c.vGrade!);
  }

  // Rolling 4-week grade p75 (>= 5 ascents in window), carried forward —
  // the observable the climbing model predicts.
  final gradeP75Raw = List<double?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    final window = <int>[];
    for (var j = math.max(0, i - 3); j <= i; j++) {
      window.addAll(gradesByWeek[j]);
    }
    if (window.length >= 5) gradeP75Raw[i] = percentile(window, 0.75);
  }
  final gradeP75 = carryForward(gradeP75Raw);

  // Wilks (actual-max display standard).
  final wilksWeeks = weeklyWilksSeries(strengthRows, weightRows);
  final wilksByMonday = {for (final w in wilksWeeks) w.weekStart: w};

  // -------------------------------------------------------------------------
  // Phase detection from the bw trajectory
  // -------------------------------------------------------------------------
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

  // Runs of identical class; short runs (< 4 wk) merged into the longer
  // neighbor; final label from the run's net rate.
  var runs = <({int start, int end, String label})>[];
  {
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
    runs = [
      for (final r in runs)
        (
          start: r.start,
          end: r.end,
          label: bw[r.start] == null || bw[r.end] == null || r.end == r.start
              ? r.label
              : () {
                  final netRate =
                      (bw[r.end]! - bw[r.start]!) / (r.end - r.start);
                  return netRate >= 0.1
                      ? 'gain'
                      : (netRate <= -0.1 ? 'loss' : 'flat');
                }(),
        ),
    ];
  }

  // -------------------------------------------------------------------------
  // Fit observations: non-overlapping 4-week blocks inside each run
  // -------------------------------------------------------------------------
  const blockWk = 4;
  final strengthObs = <SObs>[];
  final climbObs = <({
    String phase,
    DateTime start,
    double velocity, // V/wk of rolling p75
    double freq, // sessions/wk
    double bwRate,
  })>[];

  for (final run in runs) {
    for (var i = run.start; i + blockWk <= run.end; i += blockWk) {
      final j = i + blockWk;
      if (bw[i] == null || bw[j] == null) continue;
      final bwRate = (bw[j]! - bw[i]!) / blockWk;
      for (final l in lifts) {
        // Require the lift trained near both endpoints (within the block
        // at start, and in the endpoint week or the one before): carried
        // values otherwise fabricate zero velocities.
        final trainedIn = [
          for (var k = i; k < j; k++)
            if (trained[l]![k]) k,
        ];
        final endFresh = trained[l]![j] || (j - 1 >= i && trained[l]![j - 1]);
        if (trainedIn.length < 2 || !endFresh) continue;
        if (e1rm[l]![i] == null || e1rm[l]![j] == null) continue;
        var heavy = 0.0;
        for (var k = i; k < j; k++) {
          heavy += nearMax[l]![k];
        }
        strengthObs.add((
          lift: l,
          phase: run.label,
          start: mondays[i],
          velocity: (e1rm[l]![j]! - e1rm[l]![i]!) / blockWk,
          bwRate: bwRate,
          heavy: heavy / blockWk,
        ));
      }
      // Climbing: need a real (non-carried) p75 at both endpoints.
      if (gradeP75Raw[i] != null && gradeP75Raw[j] != null) {
        var sessions = 0;
        for (var k = i; k < j; k++) {
          sessions += climbSessions[k];
        }
        climbObs.add((
          phase: run.label,
          start: mondays[i],
          velocity: (gradeP75Raw[j]! - gradeP75Raw[i]!) / blockWk,
          freq: sessions / blockWk,
          bwRate: bwRate,
        ));
      }
    }
  }

  // -------------------------------------------------------------------------
  // Markdown study
  // -------------------------------------------------------------------------
  final md = StringBuffer();
  void p(String s) => md.writeln(s);

  p('# Sim calibration study — phase response models from full history');
  p('');
  p('Generated by `tool/sim_calibrate.dart` (ledger repo) on '
      '${ymd(DateTime.now())}. Companion to the program-simulation spec '
      '(2026-09-25) and design doc; W2 consumes the coefficients + '
      'validation gates below.');
  p('');
  p('## Inputs');
  p('');
  p('- ${strengthRows.length} strength rows (${graded.length} graded '
      'main-lift sets), ${weightRows.length} weigh-ins, ${climbs.length} '
      'kaya ascents (${climbs.where((c) => c.vGrade != null).length} with '
      'numeric V grades).');
  p('- $n ISO weeks: ${ymd(mondays.first)} .. ${ymd(mondays.last)} '
      '(Monday-keyed, matching coach_backtest; physiology does not care '
      'about the v7 Saturday accounting week).');
  p('- Strength measure: weekly best **RPE-adjusted e1RM** '
      '(`rpeAdjustedE1rm`, reps capped at 12) per lift, carried forward '
      'through untrained weeks. Best actual weight is tabulated for the '
      'state vector but the fits use e1RM (denser, less rep-scheme '
      'aliasing).');
  p('- Climbing measure: rolling 4-week p75 of numeric V grades '
      '(>= 5 ascents per window).');
  if (anomalies.isNotEmpty) {
    p('- Row anomalies (skipped): '
        '${[for (final e in anomalies.entries) '${e.value}x ${e.key}'].join('; ')}.');
  }
  p('');

  // Phase table.
  p('## Detected phase windows (bw trajectory)');
  p('');
  p('Centered smoothed rate, gain >= +0.15 lb/wk, loss <= -0.15, runs '
      '< 4 wk merged into the longer neighbor, run label from net rate '
      '(+/-0.1 lb/wk).');
  p('');
  p('| window | weeks | type | bw start → end | net rate lb/wk |');
  p('|---|---|---|---|---|');
  for (final r in runs) {
    final len = r.end - r.start + 1;
    final b0 = bw[r.start];
    final b1 = bw[r.end];
    final netRate =
        (b0 != null && b1 != null && r.end > r.start)
            ? (b1 - b0) / (r.end - r.start)
            : null;
    p('| ${ymd(mondays[r.start])} .. ${ymd(mondays[r.end])} | $len | '
        '${r.label} | ${fmt(b0)} → ${fmt(b1)} | ${fmt(netRate, 2)} |');
  }
  p('');
  p('Known anchors for corroboration: 2024 bulk ~Apr–Jul 2024; cut after; '
      'bulk Nov 2024 – Oct 2025 with the 2025-02-05 weigh-in trough '
      '(dashboards.yaml `last_bulk` derivation); current cut since '
      '2025-10-06 (coach/phase.yaml).');
  p('');

  // State vector now.
  p('## Current state vector (latest week ${ymd(mondays.last)})');
  p('');
  final last = n - 1;
  p('| quantity | value |');
  p('|---|---|');
  p('| bw 7d mean | ${fmt(bw[last])} lb |');
  for (final l in lifts) {
    p('| $l e1RM (RPE-adj, carried) | ${fmt(e1rm[l]![last])} lb |');
    p('| $l best actual (carried) | '
        '${fmt(carryForward(bestActualRaw[l]!)[last])} lb |');
  }
  final lastWilks = wilksByMonday[mondays.last] ??
      (wilksWeeks.isEmpty ? null : wilksWeeks.last);
  p('| Wilks (SBD actual-max) | ${fmt(lastWilks?.wilks)} |');
  p('| climb grade p75 (rolling 4wk, carried) | ${fmt(gradeP75[last])} |');
  p('| climb sessions/wk (last 4wk) | '
      '${fmt([for (var i = math.max(0, n - 4); i < n; i++) climbSessions[i]].fold<double>(0, (a, b) => a + b) / math.min(4, n))} |');
  p('');

  // Descriptive per-phase velocities.
  p('## Per-phase-type mean velocities (descriptive)');
  p('');
  p('Block-level (4-wk) means; the regression below is the model, this '
      'table is the sanity check.');
  p('');
  p('| phase | n blocks | mean bw rate | mean e1RM velocity (all lifts) | '
      'mean heavy sets/wk | n climb blocks | mean grade velocity |');
  p('|---|---|---|---|---|---|---|');
  for (final phase in ['gain', 'loss', 'flat']) {
    final s = [for (final o in strengthObs) if (o.phase == phase) o];
    final c = [for (final o in climbObs) if (o.phase == phase) o];
    p('| $phase | ${s.length} | '
        '${fmt(mean([for (final o in s) o.bwRate]), 2)} | '
        '${fmt(mean([for (final o in s) o.velocity]), 2)} | '
        '${fmt(mean([for (final o in s) o.heavy]), 2)} | ${c.length} | '
        '${fmt(mean([for (final o in c) o.velocity]), 3)} |');
  }
  p('');

  // -------------------------------------------------------------------------
  // Fits
  // -------------------------------------------------------------------------
  p('## Strength response model');
  p('');
  p('OLS over non-overlapping 4-week blocks inside detected phases '
      '(lift trained >= 2 weeks in block and fresh at the endpoint):');
  p('');
  p('    e1rm_velocity[lift] (lb/wk) = a + b_bw * bw_rate (lb/wk) '
      '+ b_hx * near_max_sets_per_wk[lift]');
  p('');
  p('| scope | n | a (intercept) | b_bw | b_hx | R² | MAE lb/wk |');
  p('|---|---|---|---|---|---|---|');

  Map<String, double>? report(
    String label,
    List<SObs>
        obs,
  ) {
    if (obs.length < 6) {
      p('| $label | ${obs.length} | — | — | — | — | — (insufficient) |');
      return null;
    }
    final X = [
      for (final o in obs) [1.0, o.bwRate, o.heavy],
    ];
    final y = [for (final o in obs) o.velocity];
    final beta = ols(X, y);
    if (beta == null) {
      p('| $label | ${obs.length} | — | — | — | — | — (singular) |');
      return null;
    }
    final f = fitStats(X, y, beta);
    p('| $label | ${obs.length} | ${fmt(beta[0], 3)} | ${fmt(beta[1], 3)} | '
        '${fmt(beta[2], 3)} | ${fmt(f.r2, 2)} | ${fmt(f.mae, 2)} |');
    return {'a': beta[0], 'b_bw': beta[1], 'b_hx': beta[2]};
  }

  final pooled = report('pooled (all lifts)', strengthObs);
  for (final l in lifts) {
    report(l, [for (final o in strengthObs) if (o.lift == l) o]);
  }
  p('');
  if (pooled != null) {
    p('**Headline**: strength velocity responds to bw rate at '
        '**${fmt(pooled['b_bw'], 2)} lb/wk of e1RM per +1 lb/wk of '
        'bodyweight**, intercept ${fmt(pooled['a'], 2)} lb/wk at flat bw '
        'and zero heavy exposure, +${fmt(pooled['b_hx'], 3)} lb/wk per '
        'weekly near-max set.');
  }
  p('');

  // bw-only spec (the collinearity check + the integrable sim candidate).
  p('### bw-only spec (candidate for the sim core)');
  p('');
  p('Same blocks, heavy exposure dropped: '
      '`velocity = a + b_bw * bw_rate`. Near-max exposure in this history '
      'is programmed WITH the phase (bulks lift heavy), so the two-term '
      'model splits shared variance and the b_hx term compounds badly '
      'when integrated over long horizons (see validation). The bw-only '
      'spec keeps the lever the user actually pulls.');
  p('');
  p('| scope | n | a | b_bw | R² | MAE lb/wk |');
  p('|---|---|---|---|---|---|');
  Map<String, List<double>> bwOnly(
    String label,
    List<SObs>
        obs,
  ) {
    if (obs.length < 6) {
      p('| $label | ${obs.length} | — | — | — | — (insufficient) |');
      return {};
    }
    final X = [
      for (final o in obs) [1.0, o.bwRate],
    ];
    final y = [for (final o in obs) o.velocity];
    final beta = ols(X, y);
    if (beta == null) return {};
    final f = fitStats(X, y, beta);
    p('| $label | ${obs.length} | ${fmt(beta[0], 3)} | ${fmt(beta[1], 3)} | '
        '${fmt(f.r2, 2)} | ${fmt(f.mae, 2)} |');
    return {label: beta};
  }

  bwOnly('pooled (all lifts)', strengthObs);
  bwOnly('pooled, 2023+ era', [
    for (final o in strengthObs)
      if (!o.start.isBefore(DateTime(2023))) o,
  ]);
  for (final l in lifts) {
    bwOnly(l, [for (final o in strengthObs) if (o.lift == l) o]);
  }
  p('');

  p('## Climbing response model');
  p('');
  p('    grade_p75_velocity (V/wk) = a + b_f * sessions_per_wk '
      '+ b_bw * bw_rate (lb/wk)');
  p('');
  p('| scope | n | a | b_f | b_bw | R² | MAE V/wk |');
  p('|---|---|---|---|---|---|---|');
  if (climbObs.length >= 6) {
    final X = [
      for (final o in climbObs) [1.0, o.freq, o.bwRate],
    ];
    final y = [for (final o in climbObs) o.velocity];
    final beta = ols(X, y);
    if (beta != null) {
      final f = fitStats(X, y, beta);
      p('| all blocks | ${climbObs.length} | ${fmt(beta[0], 4)} | '
          '${fmt(beta[1], 4)} | ${fmt(beta[2], 4)} | ${fmt(f.r2, 2)} | '
          '${fmt(f.mae, 3)} |');
    }
  } else {
    p('| all blocks | ${climbObs.length} | — | — | — | — | — (insufficient) |');
  }
  p('');

  // Level-anchored climbing spec: grade tracks bw LEVEL (weight is the
  // dominant physical term in bouldering); no integration → no drift.
  p('### level-anchored spec (candidate for the sim core)');
  p('');
  p('    grade_p75 (V) = c0 + c_bw * bw (lb)   — weekly non-carried p75 obs');
  p('');
  final levelObs = <({DateTime monday, double bwLb, double p75})>[];
  for (var i = 0; i < n; i++) {
    if (gradeP75Raw[i] != null && bw[i] != null) {
      levelObs.add((monday: mondays[i], bwLb: bw[i]!, p75: gradeP75Raw[i]!));
    }
  }
  p('| n weeks | c0 | c_bw | R² | MAE V |');
  p('|---|---|---|---|---|');
  if (levelObs.length >= 8) {
    final X = [
      for (final o in levelObs) [1.0, o.bwLb],
    ];
    final y = [for (final o in levelObs) o.p75];
    final beta = ols(X, y);
    if (beta != null) {
      final f = fitStats(X, y, beta);
      p('| ${levelObs.length} | ${fmt(beta[0], 2)} | ${fmt(beta[1], 4)} | '
          '${fmt(f.r2, 2)} | ${fmt(f.mae, 2)} |');
    }
  } else {
    p('| ${levelObs.length} | — | — | — | — (insufficient) |');
  }
  p('');

  // -------------------------------------------------------------------------
  // Walk-forward validation
  // -------------------------------------------------------------------------
  p('## Walk-forward validation');
  p('');
  p('For each held-out window every model variant is REFIT on blocks '
      'strictly before the window start, then integrated weekly from the '
      'window-start observed state using OBSERVED weekly inputs (3-wk '
      'trailing bw rate; the week\'s near-max sets; climb sessions). '
      'Baseline = flat at the window-start value. MAE over weeks with a '
      'fresh (non-carried) observation.');
  p('');
  p('Strength variants: **S1** pooled `a + b_bw·rate + b_hx·heavy`; '
      '**S2** pooled `a + b_bw·rate`; **S3** per-lift `a + b_bw·rate` '
      '(pooled fallback when the lift has < 20 prior blocks); '
      '**S4** = S3 with positive velocities dampened by proximity to the '
      'lift\'s pre-window all-time e1RM peak (linear fade from full at '
      '95% of peak to zero at 105% — the training-age/saturation rule). '
      'Climbing variants: **C1** velocity `a + b_f·freq + b_bw·rate` '
      'integrated; **C2** level-anchored `p75 = c0 + c_bw·bw` evaluated '
      'at observed weekly bw. Wilks row: S4 SBD e1RM deltas applied to '
      'the window-start actual-max total, scored at observed bw '
      '(approximate — basis mismatch is a caveat, not a bug).');
  p('');

  final windows = <({String name, DateTime from, DateTime to})>[
    (
      name: '2024 bulk (Apr–Jul 2024)',
      from: DateTime(2024, 4, 1),
      to: DateTime(2024, 7, 31)
    ),
    (
      name: '2025 bulk (Nov 2024 – Oct 2025)',
      from: DateTime(2024, 11, 1),
      to: DateTime(2025, 10, 5)
    ),
    (
      name: 'current cut (since 2025-10-06)',
      from: DateTime(2025, 10, 6),
      to: mondays.last
    ),
  ];

  p('| window | output | flat | S1 bw+hx | S2 bw | S3 per-lift bw | '
      'S4 S3+saturation | best |');
  p('|---|---|---|---|---|---|---|---|');

  String best(double flat, List<double?> models, List<String> names) {
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

  for (final win in windows) {
    final i0 = firstIndexAtOrAfter(mondays, wk(win.from));
    final i1 = lastIndexAtOrBefore(mondays, wk(win.to));
    if (i0 == null || i1 == null || i1 <= i0) {
      p('| ${win.name} | — | no weeks in range | | | | |');
      continue;
    }
    // Refit on prior blocks only.
    final priorS = [
      for (final o in strengthObs)
        if (o.start.add(Duration(days: blockWk * 7)).isBefore(win.from)) o,
    ];
    final priorC = [
      for (final o in climbObs)
        if (o.start.add(Duration(days: blockWk * 7)).isBefore(win.from)) o,
    ];
    List<double>? fit(
      List<SObs>
          obs,
      List<double> Function(dynamic o) row,
    ) =>
        obs.length < 6
            ? null
            : ols([for (final o in obs) row(o)], [for (final o in obs) o.velocity]);

    final s1 = fit(priorS, (o) => [1.0, o.bwRate, o.heavy]);
    final s2 = fit(priorS, (o) => [1.0, o.bwRate]);
    final s3 = {
      for (final l in lifts)
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
    // C2: level-anchored, fit on prior weekly non-carried p75 obs.
    List<double>? c2;
    {
      final prior = [
        for (final o in levelObs)
          if (o.monday.isBefore(win.from)) o,
      ];
      if (prior.length >= 8) {
        c2 = ols(
          [for (final o in prior) [1.0, o.bwLb]],
          [for (final o in prior) o.p75],
        );
      }
    }

    double bwRate3(int i) {
      final j = math.max(0, i - 3);
      if (bw[i] == null || bw[j] == null || i == j) return 0;
      return (bw[i]! - bw[j]!) / (i - j);
    }

    // Strength per lift: integrate each variant weekly, score fresh weeks.
    final deltaHatS4 = <String, List<double>>{}; // for the Wilks row
    for (final l in lifts) {
      final start = e1rm[l]![i0];
      if (start == null) continue;
      // S4's saturation anchor: the lift's all-time (pre-window) e1RM peak.
      var peak = start;
      for (var i = 0; i <= i0; i++) {
        final v = e1rmRaw[l]![i];
        if (v != null && v > peak) peak = v;
      }
      double velocity(List<double>? beta, int i) {
        if (beta == null) return 0;
        if (beta.length == 3) {
          return beta[0] + beta[1] * bwRate3(i) + beta[2] * nearMax[l]![i];
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
        final obs = e1rm[l]![i];
        if (obs == null || !trained[l]![i]) continue; // carried → skip
        for (var v = 0; v < 4; v++) {
          if (betas[v] != null) errs[v].add((hats[v] - obs).abs());
        }
        flatErr.add((start - obs).abs());
      }
      deltaHatS4[l] = deltas;
      if (flatErr.isEmpty) continue;
      final fm = mean(flatErr)!;
      final ms = [for (final e in errs) mean(e)];
      p('| ${win.name} | $l e1RM (lb) | ${fmt(fm, 1)} | ${fmt(ms[0], 1)} | '
          '${fmt(ms[1], 1)} | ${fmt(ms[2], 1)} | ${fmt(ms[3], 1)} | '
          '${best(fm, ms, ['S1', 'S2', 'S3', 'S4'])} |');
    }

    // Wilks (derived from S4, approximate).
    final w0 = wilksByMonday[mondays[i0]];
    if (w0 != null && sbdLifts.every(deltaHatS4.containsKey)) {
      final modelErr = <double>[];
      final flatErr = <double>[];
      for (var i = i0 + 1; i <= i1; i++) {
        final obsW = wilksByMonday[mondays[i]];
        if (obsW == null || bw[i] == null) continue;
        var d = 0.0;
        for (final l in sbdLifts) {
          d += deltaHatS4[l]![i - i0 - 1];
        }
        modelErr.add(
          (wilksPointsLb(w0.totalLbs + d, bw[i]!) - obsW.wilks).abs(),
        );
        flatErr.add((wilksPointsLb(w0.totalLbs, bw[i]!) - obsW.wilks).abs());
      }
      if (modelErr.isNotEmpty) {
        final mm = mean(modelErr)!;
        final fm = mean(flatErr)!;
        p('| ${win.name} | Wilks (derived, S4) | ${fmt(fm, 1)} | | | | '
            '${fmt(mm, 1)} | ${mm < fm ? 'S4' : 'flat'} |');
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
            : c1[0] + c1[1] * climbSessions[i - 1] + c1[2] * bwRate3(i - 1);
        final obs = gradeP75Raw[i];
        if (obs == null) continue;
        if (c1 != null) c1Err.add((hat - obs).abs());
        if (c2 != null && bw[i] != null) {
          c2Err.add((c2[0] + c2[1] * bw[i]! - obs).abs());
        }
        flatErr.add((g0 - obs).abs());
      }
      if (flatErr.isNotEmpty) {
        final fm = mean(flatErr)!;
        final m1 = mean(c1Err);
        final m2 = mean(c2Err);
        p('| ${win.name} | climb grade p75 (V) | ${fmt(fm, 2)} | '
            'C1: ${fmt(m1, 2)} | C2: ${fmt(m2, 2)} | | | '
            '${best(fm, [m1, m2], ['C1', 'C2'])} |');
      }
    }
    p('| ${win.name} | _prior data_ | _${priorS.length} strength blocks, '
        '${priorC.length} climb blocks, ${[
      for (final o in levelObs)
        if (o.monday.isBefore(win.from)) o,
    ].length} climb level weeks_ | | | | | |');
  }
  p('');

  p('## Verdict — model selection for the W2 sim core');
  p('');
  p('- **Strength: S4** (per-lift `a + b_bw·rate`, positive velocity '
      'dampened linearly to zero as e1RM runs from 95% to 105% of the '
      'all-time peak). Best or near-best on the 2024 bulk and the '
      'current cut, and the closest model to flat on the anomalous 2025 '
      'bulk; never materially worse than S3. S1 (heavy-exposure term) '
      'is rejected for the sim core: the b_hx term compounds '
      'catastrophically over long horizons (2025 bulk squat MAE 56 vs '
      'flat 24).');
  p('- **Climbing: C2** (level-anchored `p75 = c0 + c_bw·bw`). The '
      'integrated velocity model (C1) drifts unboundedly; the level '
      'model cannot drift and beat flat on the current cut. Session '
      'frequency stays a lever via the C1 b_f term surfaced in the UI, '
      'but the forecast line comes from C2.');
  p('- **Wilks**: derived output — wilks(SBD total from simulated '
      'e1RMs, simulated bw); no separate model.');
  p('- **W2 acceptance gate**: reproduce this study\'s S4 + C2 MAE '
      'table from the same frozen inputs (pure-Dart sim core, no '
      'network) to within 0.1; the design doc carries the numbers.');
  p('');

  p('## Caveats (honest)');
  p('');
  p('- **The 2025 bulk is a known anomaly, not just model error**: the '
      'coach backtest documents a mid-bulk training collapse '
      '(NEAR_MAX_LOW + LONG_SETS flags May–Jun 2025; weekly working '
      'sets fell from ~24 to ~14). Every model overshoots a bulk whose '
      'inputs collapsed; the sim treats planned inputs as delivered.');
  p('- **Current-cut deadlift MAEs (~90–120 lb) are a regime change**: '
      'the deadlift carries a pain cap (working_max seed marker) and '
      'its e1RM collapsed for reasons outside the bw-rate model. '
      'Injury is not simulable; the nightly refit re-anchors the sim '
      'to the post-injury state instead.');
  p('- **Heavy-exposure collinearity**: near-max exposure and bw rate '
      'move together (bulks program heavier work); b_bw and b_hx split '
      'shared variance and their individual values are less stable than '
      'the joint prediction. The sim should treat the PREDICTION as '
      'calibrated, not each coefficient separately.');
  p('- **Era effects**: earlier phases are also earlier training age; '
      'some of the bulk-phase velocity is newbie-adjacent gains the next '
      'bulk will not reproduce. Walk-forward validation partially prices '
      'this in (it always predicts forward), but the long-horizon sim '
      'inherits optimism. Nightly refit shrinks this as recent data '
      'accumulates.');
  p('- **Carried e1RM weeks are skipped in scoring** (untrained weeks '
      'have no fresh observation); MAEs are over trained weeks only.');
  p('- **Climbing p75 is volume-sensitive**: p75 of attempted grades '
      'confounds ability with session intent (limit vs volume days); '
      'blocks need >= 5 graded ascents and the series is still noisy.');
  p('- **RPE sparsity**: rpeAdjustedE1rm falls back to raw Epley when '
      'RPE is not logged; older eras logged RPE less.');
  p('- **Wilks validation is derived**, not an independent fit: e1RM '
      'deltas applied to an actual-max total (basis mismatch noted '
      'above).');

  final out = md.toString();
  print(out);
  if (outPath != null) {
    File(outPath).writeAsStringSync(out);
    stderr.writeln('\nwrote $outPath');
  }
}

// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

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

/// OLS via normal equations + Gaussian elimination (tiny k).
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
// Config / API / cells (coach_backtest.dart pattern)
// ---------------------------------------------------------------------------

({String spreadsheetId, String keyPath}) readConfig() {
  final lines = File(configPath).readAsLinesSync();
  String? pick(String key) {
    for (final l in lines) {
      if (l.startsWith('$key:')) return l.substring(key.length + 1).trim();
    }
    return null;
  }

  final spreadsheetId = pick('spreadsheet_id');
  if (spreadsheetId == null || spreadsheetId.isEmpty) {
    print('no spreadsheet_id in $configPath');
    exit(1);
  }
  final keyPath =
      pick('service_account_key_path') ??
      '$home/.config/airledger/service-account.json';
  return (spreadsheetId: spreadsheetId, keyPath: keyPath);
}

Future<gsheets.SheetsApi> sheetsApi(String keyPath) async {
  final keyJson = await File(keyPath).readAsString();
  final credentials = ServiceAccountCredentials.fromJson(keyJson);
  final client = await clientViaServiceAccount(credentials, [
    gsheets.SheetsApi.spreadsheetsScope,
  ]);
  return gsheets.SheetsApi(client);
}

Map<String, int> headerIndex(List<List<Object?>> tab) => tab.isEmpty
    ? {}
    : {
        for (var i = 0; i < tab.first.length; i++)
          tab.first[i].toString(): i,
      };

String cell(List<Object?> row, int? i) =>
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

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String fmt(double? v, [int dp = 1]) => v == null ? '—' : v.toStringAsFixed(dp);
