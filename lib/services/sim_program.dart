/// App-side sim assembly — builds the [SimProgram] from the declared
/// intent docs (coach/program.yaml + coach/phase.yaml), the
/// [SimInitialState] from a full-history [WeeklySeries], and the
/// drift-guarded refit coefficients (design doc
/// `airledger/docs/superpowers/specs/2026-09-25-sim-design.md` §8).
///
/// Lifted out of tool/sim_forecast.dart (W3) so the Program tab, the
/// nightly forecast writer, and the CLI smoke share ONE construction
/// path. Pure Dart — no Flutter, no IO.
library;

import 'program_current.dart' show currentVersion;
import 'sim_core.dart';
import 'sim_fit.dart';
import 'world_model.dart';

/// Builds the [SimProgram] the schedule generator honors from the parsed
/// intent docs. Block 0 (emphasis `cut`) IS the current cut: its end
/// date becomes [SimProgram.cutEndDate]; the cut target comes from
/// phase.yaml's `target_weight_lb` (falling back to [rules]' next-cycle
/// target). Null when program.yaml is missing/malformed or carries no
/// dated blocks.
SimProgram? simProgramFromDocs({
  required Map<Object?, Object?>? program,
  required Map<Object?, Object?>? phase,
  SimRules rules = const SimRules(),
}) {
  final version = currentVersion(program);
  final rawBlocks = version?['blocks'];
  if (rawBlocks is! List) return null;

  final phaseVersion = currentVersion(phase);
  final cutTarget = (phaseVersion?['target_weight_lb'] as num?)?.toDouble() ??
      rules.phaseRules.nextCycle.cutTargetLb;

  final blocks = <SimBlock>[];
  DateTime? cutEnd;
  DateTime? firstStart;
  for (final b in rawBlocks) {
    if (b is! Map) continue;
    final n = (b['n'] as num?)?.toInt();
    final dates = b['dates'];
    if (n == null || dates is! List || dates.length != 2) continue;
    final start = DateTime.tryParse(dates[0].toString());
    final end = DateTime.tryParse(dates[1].toString());
    if (start == null || end == null) continue;
    if (firstStart == null || start.isBefore(firstStart)) firstStart = start;
    if (n == 0) {
      // Block 0 IS the cut; its end is the declared cut end date.
      cutEnd = end;
      continue;
    }
    blocks.add(SimBlock(
      n: n,
      start: start,
      end: end,
      emphasis: b['emphasis']?.toString() ?? '',
      rate: (b['rate'] as num?)?.toDouble(),
    ));
  }
  if (cutEnd == null && firstStart == null) return null;
  return SimProgram(
    cutTargetLb: cutTarget,
    // No declared block 0 → the cut (if any) must end before the
    // program starts.
    cutEndDate: cutEnd ?? firstStart!,
    blocks: blocks,
  );
}

/// The t=0 observed state vector off the last week of [series] (design
/// §2): carried week-mean bw, per-lift best RPE-adjusted e1RM, all-time
/// raw peaks, rolling p75, and the actual-max SBD total for the Wilks
/// k-anchor (null unless all three SBD lifts have an actual max). Null
/// when the series is empty or has no bodyweight at the last week.
SimInitialState? simInitialFromSeries(WeeklySeries series) {
  if (series.length == 0) return null;
  final last = series.length - 1;
  final bw = series.bw[last];
  if (bw == null) return null;

  final e1rm0 = <String, double>{};
  final peak0 = <String, double>{};
  for (final l in simLifts) {
    final v = series.e1rm[l]![last];
    if (v == null) continue;
    e1rm0[l] = v;
    var peak = v;
    for (final raw in series.e1rmRaw[l]!) {
      if (raw != null && raw > peak) peak = raw;
    }
    peak0[l] = peak;
  }
  if (e1rm0.isEmpty) return null;

  var actualSbd = 0.0;
  var actualComplete = true;
  for (final l in simSbdLifts) {
    final v = series.bestActual[l]![last];
    if (v == null) {
      actualComplete = false;
    } else {
      actualSbd += v;
    }
  }
  return SimInitialState(
    monday: series.mondays[last],
    bw: bw,
    e1rm: e1rm0,
    peak: peak0,
    gradeP75: series.gradeP75[last],
    actualMaxSbdTotalLbs: actualComplete ? actualSbd : null,
  );
}

/// A drift-guarded refit: [coefficients] to simulate with + the
/// coefficients that tripped the guard.
typedef GuardedRefit = ({SimCoefficients coefficients, List<String> drifted});

double? _pick(SimCoefficients c, String key) {
  final parts = key.split('.');
  if (parts.length == 2) {
    final r = c.strength[parts[0]];
    if (r == null) return null;
    return parts[1] == 'a' ? r.a : r.bBw;
  }
  return switch (key) {
    'climb.c0' => c.climbC0,
    'climb.c_bw' => c.climbCBw,
    'climb.b_f' => c.climbBf,
    _ => null,
  };
}

/// Refits [SimCoefficients] from [series] and applies the ±50% drift
/// guard against the DECLARED values (design §8): a refit coefficient
/// that departs more than 50% from world_model.yaml's declared value is
/// replaced by the declared value and reported in `drifted` (the UI's
/// "model drift" tag). Coefficients the refit could not produce
/// (insufficient history) silently keep the declared value.
GuardedRefit guardedRefit({
  required WorldModel model,
  required WeeklySeries series,
}) {
  final declared = model.toCoefficients();
  final refit = fitFromSeries(series);
  final drifted = <String>[];

  double resolve(String key, double declaredV) {
    final refitV = _pick(refit, key);
    if (refitV == null) return declaredV;
    if (declaredV != 0 &&
        (refitV - declaredV).abs() > 0.5 * declaredV.abs()) {
      drifted.add(key);
      return declaredV;
    }
    return refitV;
  }

  final strength = <String, LiftResponse>{};
  for (final e in declared.strength.entries) {
    strength[e.key] = LiftResponse(
      a: resolve('${e.key}.a', e.value.a),
      bBw: resolve('${e.key}.b_bw', e.value.bBw),
    );
  }
  double? optional(String key, double? declaredV) =>
      declaredV == null ? _pick(refit, key) : resolve(key, declaredV);

  return (
    coefficients: SimCoefficients(
      strength: strength,
      pooled: declared.pooled ?? refit.pooled,
      climbC0: optional('climb.c0', declared.climbC0),
      climbCBw: optional('climb.c_bw', declared.climbCBw),
      climbBf: optional('climb.b_f', declared.climbBf),
    ),
    drifted: drifted,
  );
}
