/// Observed-layer helpers for the Program screen — pure Dart, no
/// Flutter/IO. Input weigh-in rows come from the airlayer semantic query
/// over the `weight` view (one averaged point per day); the windowed
/// metrics reuse the §2.5 weekly-rollup formulas from
/// [program_metrics.dart] so the screen, the flags, and the nightly
/// status job all agree on bw_7d_avg / bw_rate_lb_wk / bw_3wk_change.
library;

import 'program_metrics.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

/// Trailing 7-day average series: one output point per input day, valued
/// at the mean of all points in the 7 calendar days ending on (and
/// including) that day. Input need not be sorted.
List<WeightRow> sevenDayAvgSeries(List<WeightRow> daily) {
  final sorted = [...daily]..sort((a, b) => a.date.compareTo(b.date));
  final out = <WeightRow>[];
  var lo = 0;
  var sum = 0.0;
  for (var i = 0; i < sorted.length; i++) {
    sum += sorted[i].weightLbs;
    while (_daysBetween(sorted[lo].date, sorted[i].date) > 6) {
      sum -= sorted[lo].weightLbs;
      lo++;
    }
    out.add(WeightRow(
      date: sorted[i].date,
      weightLbs: sum / (i - lo + 1),
    ));
  }
  return out;
}

/// Linear interpolation of a block's target-weight line ([from] at
/// [start] → [to] at [end]), clamped to the block's endpoints.
double targetLineValue({
  required DateTime day,
  required DateTime start,
  required DateTime end,
  required double from,
  required double to,
}) {
  final total = _daysBetween(start, end);
  if (total <= 0) return from;
  final t = (_daysBetween(start, day) / total).clamp(0.0, 1.0);
  return from + (to - from) * t;
}

/// Current observed body-weight stats.
///
/// [bw7dAvg] is the trailing 7-day mean ending on [asOf] (what "current
/// weight" means to a human). [bwRateLbWk] / [bw3wkChange] /
/// [recentRates] come from [weeklyRollup]'s Sunday-anchored windows —
/// the exact values PHASE_MISMATCH and the nightly status job evaluate.
class ObservedWeightStats {
  final double? bw7dAvg;
  final double? bwRateLbWk;
  final double? bw3wkChange;

  /// Weekly bw_rate_lb_wk for up to the last 3 rollup weeks ending at
  /// the week containing `asOf` (oldest first). Feeds [phaseVerdict].
  final List<double?> recentRates;
  final DateTime? lastWeighIn;

  const ObservedWeightStats({
    required this.bw7dAvg,
    required this.bwRateLbWk,
    required this.bw3wkChange,
    required this.recentRates,
    required this.lastWeighIn,
  });
}

ObservedWeightStats observedWeightStats(
  List<WeightRow> daily,
  DateTime asOf,
) {
  if (daily.isEmpty) {
    return const ObservedWeightStats(
      bw7dAvg: null,
      bwRateLbWk: null,
      bw3wkChange: null,
      recentRates: [],
      lastWeighIn: null,
    );
  }
  final today = _day(asOf);

  // Trailing 7-day average ending today.
  var sum = 0.0;
  var n = 0;
  DateTime? last;
  for (final w in daily) {
    final d = w.date;
    if (last == null || d.isAfter(last)) last = d;
    final ago = _daysBetween(d, today);
    if (ago >= 0 && ago <= 6) {
      sum += w.weightLbs;
      n++;
    }
  }

  // Weekly rollup (weights only) for the flag-grade windowed metrics.
  final weeks = weeklyRollup(const [], weights: daily);
  final currentMonday = mondayOf(today);
  var idx = -1;
  for (var i = 0; i < weeks.length; i++) {
    if (!weeks[i].weekStart.isAfter(currentMonday)) idx = i;
  }
  WeeklyMetrics? cur = idx >= 0 ? weeks[idx] : null;
  final rates = <double?>[
    if (idx >= 0)
      for (var i = (idx - 2) < 0 ? 0 : idx - 2; i <= idx; i++)
        weeks[i].bwRateLbWk,
  ];

  return ObservedWeightStats(
    bw7dAvg: n == 0 ? null : sum / n,
    bwRateLbWk: cur?.bwRateLbWk,
    bw3wkChange: cur?.bw3wkChange,
    recentRates: rates,
    lastWeighIn: last,
  );
}

// ---------------------------------------------------------------------------
// Verdict — declared phase vs observed scale
// ---------------------------------------------------------------------------

enum VerdictState { agree, drift, mismatch, unknown }

class PhaseVerdict {
  final VerdictState state;

  /// Short human label, e.g. "cutting, slightly slow". Numbers are the
  /// caller's job (the UI composes the full "declared … · observed …"
  /// line).
  final String label;

  /// The observed rate the verdict was computed from: bw_3wk_change / 3
  /// when available, else the latest non-null weekly rate.
  final double? observedRateLbWk;

  const PhaseVerdict({
    required this.state,
    required this.label,
    required this.observedRateLbWk,
  });
}

/// Declared-vs-observed verdict, reusing PHASE_MISMATCH semantics
/// (program_metrics §2.6): the red state is exactly "three consecutive
/// rollup weeks of scale disagreement" — the condition under which the
/// flag would fire. Green/amber grade how well the observed 3-week rate
/// tracks the declared target rate.
PhaseVerdict phaseVerdict({
  required String phase,
  double? targetRateLbWk,
  List<double?> recentRates = const [],
  double? bw3wkChange,
}) {
  // Weekly mismatch predicate — mirrors evaluateFlags' PHASE_MISMATCH.
  bool weekMismatch(double? rate) => switch (phase) {
        'cut' => rate != null && rate >= 0.2,
        'bulk' => rate != null && rate <= -0.2,
        _ => false,
      };
  final threeWeekMismatch =
      recentRates.length >= 3 && recentRates.every(weekMismatch);

  double? observed = bw3wkChange != null ? bw3wkChange / 3 : null;
  if (observed == null) {
    for (final r in recentRates) {
      if (r != null) observed = r;
    }
  }

  PhaseVerdict v(VerdictState s, String label) =>
      PhaseVerdict(state: s, label: label, observedRateLbWk: observed);

  if (phase == 'maintain') {
    if (bw3wkChange != null && bw3wkChange.abs() > 1.5) {
      return v(VerdictState.mismatch, 'drifting off maintenance');
    }
    if (observed == null) {
      return v(VerdictState.unknown, 'not enough weigh-in data');
    }
    return v(VerdictState.agree, 'holding steady');
  }

  if (phase == 'cut') {
    if (threeWeekMismatch) {
      return v(VerdictState.mismatch, 'gaining — PHASE_MISMATCH would fire');
    }
    if (observed == null) {
      return v(VerdictState.unknown, 'not enough weigh-in data');
    }
    final target = targetRateLbWk ?? -0.5;
    if (observed >= 0.2) {
      return v(VerdictState.drift, 'gaining — mismatch fires after 3 weeks');
    }
    if (observed <= target) return v(VerdictState.agree, 'cutting, on pace');
    if (observed <= target / 2) {
      return v(VerdictState.agree, 'cutting, slightly slow');
    }
    if (observed < -0.05) return v(VerdictState.drift, 'cutting, too slow');
    return v(VerdictState.drift, 'stalled — scale is flat');
  }

  if (phase == 'bulk') {
    if (threeWeekMismatch) {
      return v(VerdictState.mismatch, 'losing — PHASE_MISMATCH would fire');
    }
    if (observed == null) {
      return v(VerdictState.unknown, 'not enough weigh-in data');
    }
    final target = targetRateLbWk ?? 0.4;
    if (observed <= -0.2) {
      return v(VerdictState.drift, 'losing — mismatch fires after 3 weeks');
    }
    if (observed >= target) return v(VerdictState.agree, 'gaining, on pace');
    if (observed >= target / 2) {
      return v(VerdictState.agree, 'gaining, slightly slow');
    }
    if (observed > 0.05) return v(VerdictState.drift, 'gaining, too slow');
    return v(VerdictState.drift, 'stalled — scale is flat');
  }

  return v(
    observed == null ? VerdictState.unknown : VerdictState.agree,
    observed == null ? 'not enough weigh-in data' : phase,
  );
}
