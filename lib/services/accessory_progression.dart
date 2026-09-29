/// Accessory double progression — RPE-nudged load suggestions
/// (program.yaml v12 `accessory_progression`, user-approved 2026-09-28).
///
/// Pure Dart — no Flutter, no IO. The week planner asks, per planned
/// accessory row, what load to suggest from the LAST logged comparable
/// session of that exercise:
///   * every set at the TOP of the rep range at <= 2 RIR (RPE >= 8,
///     RIR = 10 − RPE convention) → +`step_lb` (isolation moves get the
///     smaller `isolation_step_lb`, default 2.5);
///   * last session's average RPE > `backoff_avg_rpe_gt` (default 9)
///     → −`backoff_pct`% (default 5), rounded DOWN to the step so small
///     dumbbell loads actually decrease;
///   * otherwise → hold last session's load.
///
/// Suggestions are only made when they are computable honestly:
/// bodyweight work (no logged weight > 0) and exercises with no history
/// produce NO suggestion — the planner leaves the weight blank rather
/// than guess. Sets without an RPE can never prove the all-sets overload
/// condition (missing RPE = unknown, never guessed), but they don't
/// block a plain hold.
library;

import 'program_metrics.dart' show StrengthRow;

/// Parsed `accessory_progression` config (program.yaml v12). All fields
/// have working defaults so a missing/partial key still behaves.
class AccessoryRule {
  /// Load increment for compound/lower accessories (lb).
  final double stepLb;

  /// Load increment for upper-body isolation moves (lb).
  final double isolationStepLb;

  /// Backoff when the last session averaged above [backoffAvgRpeGt].
  final double backoffPct;
  final double backoffAvgRpeGt;

  /// Max RIR that still counts as overload-ready (<= 2 RIR ⇒ RPE >= 8).
  final double targetRirMax;

  /// Exercise names (exact) that take [isolationStepLb].
  final Set<String> isolation;

  const AccessoryRule({
    this.stepLb = 5,
    this.isolationStepLb = 2.5,
    this.backoffPct = 5,
    this.backoffAvgRpeGt = 9,
    this.targetRirMax = 2,
    this.isolation = const {},
  });

  /// RPE at/above which a set sits at <= [targetRirMax] RIR.
  double get overloadMinRpe => 10 - targetRirMax;

  /// Parses the version's `accessory_progression` map. Null/malformed
  /// → defaults (never throws).
  factory AccessoryRule.fromVersion(Map<Object?, Object?>? version) {
    final raw = version?['accessory_progression'];
    if (raw is! Map) return const AccessoryRule();
    double numOr(Object? v, double d) => v is num ? v.toDouble() : d;
    final iso = raw['isolation'];
    return AccessoryRule(
      stepLb: numOr(raw['step_lb'], 5),
      isolationStepLb: numOr(raw['isolation_step_lb'], 2.5),
      backoffPct: numOr(raw['backoff_pct'], 5),
      backoffAvgRpeGt: numOr(raw['backoff_avg_rpe_gt'], 9),
      targetRirMax: numOr(raw['target_rir_max'], 2),
      isolation: iso is List
          ? {for (final e in iso) e.toString()}
          : const {},
    );
  }

  double stepFor(String exercise) =>
      isolation.contains(exercise) ? isolationStepLb : stepLb;
}

/// One suggestion: the load to plan plus how it was decided.
class AccessorySuggestion {
  /// overload | backoff | hold.
  final String action;
  final num weightLb;

  /// The last session's reference load the suggestion moved from.
  final num lastWeightLb;
  final DateTime lastDate;
  final String reason;

  const AccessorySuggestion({
    required this.action,
    required this.weightLb,
    required this.lastWeightLb,
    required this.lastDate,
    required this.reason,
  });
}

num _roundTo(num x, num step) {
  final r = (x / step).round() * step;
  return r == r.roundToDouble() ? r.round() : r;
}

num _roundDownTo(num x, num step) {
  final r = (x / step).floorToDouble() * step;
  return r == r.roundToDouble() ? r.round() : r;
}

/// Suggests the next load for [exercise] from its last logged session
/// strictly before [asOf].
///
/// The "last comparable session" is the most recent day with at least
/// one logged row of [exercise] carrying a weight > 0; its reference
/// load is the day's heaviest set. Null when no such session exists
/// (bodyweight work / new exercises) — the caller must leave the weight
/// blank, never guess.
///
/// Decision (approved rule):
///   * backoff: the session's average logged RPE > rule.backoffAvgRpeGt
///     → last load × (1 − backoff_pct/100), rounded DOWN to the step;
///   * overload: [repRangeHigh] known AND every set that day hit
///     reps >= repRangeHigh at RPE >= 10 − target_rir_max (sets missing
///     RPE are unknown and disqualify overload) → last load + step;
///   * hold: everything else → last load unchanged.
AccessorySuggestion? suggestAccessoryLoad({
  required String exercise,
  required List<StrengthRow> history,
  required DateTime asOf,
  int? repRangeHigh,
  AccessoryRule rule = const AccessoryRule(),
}) {
  final asOfDay = DateTime.utc(asOf.year, asOf.month, asOf.day);
  DateTime dayOf(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  // Most recent pre-asOf day with a weighted row of this exercise.
  DateTime? lastDay;
  for (final r in history) {
    if (r.exercise != exercise || r.weight <= 0) continue;
    final d = dayOf(r.date);
    if (!d.isBefore(asOfDay) ||
        (lastDay != null && !d.isAfter(lastDay))) {
      continue;
    }
    lastDay = d;
  }
  if (lastDay == null) return null;

  final sets = [
    for (final r in history)
      if (r.exercise == exercise && r.weight > 0 && dayOf(r.date) == lastDay)
        r,
  ];
  var last = 0.0;
  for (final s in sets) {
    if (s.weight > last) last = s.weight;
  }

  final step = rule.stepFor(exercise);
  final rpes = [
    for (final s in sets)
      if (s.rpe != null) s.rpe!,
  ];
  final avgRpe = rpes.isEmpty
      ? null
      : rpes.reduce((a, b) => a + b) / rpes.length;

  if (avgRpe != null && avgRpe > rule.backoffAvgRpeGt) {
    var w = _roundDownTo(last * (1 - rule.backoffPct / 100), step);
    // A tiny load that rounds to zero still holds at one step.
    if (w <= 0) w = step;
    return AccessorySuggestion(
      action: 'backoff',
      weightLb: w,
      lastWeightLb: _roundTo(last, 0.5),
      lastDate: lastDay,
      reason: 'last session avg RPE '
          '${avgRpe.toStringAsFixed(1)} > ${_fmt(rule.backoffAvgRpeGt)} '
          '→ −${_fmt(rule.backoffPct)}%',
    );
  }

  final overload = repRangeHigh != null &&
      sets.isNotEmpty &&
      sets.every((s) =>
          s.reps >= repRangeHigh &&
          s.rpe != null &&
          s.rpe! >= rule.overloadMinRpe);
  if (overload) {
    return AccessorySuggestion(
      action: 'overload',
      weightLb: _roundTo(last + step, 0.5),
      lastWeightLb: _roundTo(last, 0.5),
      lastDate: lastDay,
      reason: 'all sets at ${repRangeHigh}+ reps at <= '
          '${_fmt(rule.targetRirMax)} RIR → +${_fmt(step)} lb',
    );
  }

  return AccessorySuggestion(
    action: 'hold',
    weightLb: _roundTo(last, 0.5),
    lastWeightLb: _roundTo(last, 0.5),
    lastDate: lastDay,
    reason: 'double progression: add reps toward '
        '${repRangeHigh ?? 'the top of the range'} first',
  );
}

String _fmt(num v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();
