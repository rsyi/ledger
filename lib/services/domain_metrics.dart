/// Domain-dashboard metric engine (app-IA redesign P2).
///
/// Pure computation: the domain screen gathers raw inputs (strength
/// rows off the ledger, the shared daily weigh-in series, raw weight
/// records for body-fat) and [computeMetric] turns one [MetricConfig]
/// into display data. No Flutter, no IO — everything here is
/// unit-tested; the UI stays layout-only.
///
/// Built-ins implemented in P2: pl_total, e1rm_reference,
/// all_time_best_weight (strength), bw_series, bf_series (weight).
/// The rest of the vocabulary (kcal_series, protein_series,
/// grade_pyramid, session_frequency, hr_4x4_series) returns a
/// [MetricUnavailable] placeholder until P3 — a declared-but-unbuilt
/// metric must render as "coming soon", never break the header.
library;

import 'domain_config.dart';
import 'home_synthesis.dart'
    show allTimeBestE1rms, fmtLb, synthesisLifts;
import 'program_metrics.dart'
    show StrengthRow, WeightRow, liftReferencesAsOf, mainLiftByExercise;
import 'program_observed.dart' show sevenDayAvgSeries;

// ---------------------------------------------------------------------------
// Display data types
// ---------------------------------------------------------------------------

/// One computed metric, ready to render.
sealed class MetricData {
  const MetricData();
}

/// One labeled number (a chip). [label] is short ("squat", "PL total");
/// [value] is preformatted with its unit.
class MetricStat {
  final String label;
  final String value;
  const MetricStat({required this.label, required this.value});
}

/// A group of stat chips under the metric's heading.
class MetricStats extends MetricData {
  final List<MetricStat> stats;

  /// Caveat line under the chips ("no deadlift logged yet").
  final String? note;
  const MetricStats(this.stats, {this.note});
}

/// A daily line chart: raw [points], optional smoothed [avg] overlay,
/// optional flat [goal] target line.
class MetricSeries extends MetricData {
  final List<({DateTime day, double value})> points;
  final List<({DateTime day, double value})> avg;
  final double? goal;
  final String? unit;
  const MetricSeries({
    required this.points,
    this.avg = const [],
    this.goal,
    this.unit,
  });
}

/// Declared but not computable — unknown id, P3 built-in, or the data
/// source came back empty.
class MetricUnavailable extends MetricData {
  final String message;
  const MetricUnavailable(this.message);
}

// ---------------------------------------------------------------------------
// Strength built-ins
// ---------------------------------------------------------------------------

/// Powerlifting-style total: sum of the four main lifts' all-time best
/// capped e1RMs (Epley, reps capped at 12 — same expression as the home
/// dashboard's "best" column). Returns the sum over the lifts that HAVE
/// history plus the list of missing lifts, so the UI can label an
/// incomplete total honestly. Null total when no lift has history.
({double total, List<String> missing})? plTotal(
  Map<String, double> bestE1rms,
) {
  final missing = [
    for (final lift in synthesisLifts)
      if (!bestE1rms.containsKey(lift)) lift,
  ];
  if (missing.length == synthesisLifts.length) return null;
  var total = 0.0;
  for (final lift in synthesisLifts) {
    total += bestE1rms[lift] ?? 0;
  }
  return (total: total, missing: missing);
}

/// All-time best ACTUAL weight lifted per main lift (max `weight` over
/// logged sets with weight > 0 and reps > 0), dates after [asOf]
/// excluded so future-dated rows can't inflate a "best". Distinct from
/// the best e1RM — this is a bar-loaded number, not an estimate.
Map<String, double> allTimeBestWeights(
  List<StrengthRow> rows,
  DateTime asOf,
) {
  final day = DateTime(asOf.year, asOf.month, asOf.day);
  final out = <String, double>{};
  for (final r in rows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || r.weight <= 0 || r.reps <= 0) continue;
    final d = DateTime(r.date.year, r.date.month, r.date.day);
    if (d.isAfter(day)) continue;
    if ((out[lift] ?? 0) < r.weight) out[lift] = r.weight;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Weight built-ins
// ---------------------------------------------------------------------------

/// Body-fat % series from raw weight-view records. Per record the first
/// non-null of body_fat_caliper / body_fat_omron / body_fat_withing is
/// taken (manual measurements are rarer and more deliberate than the
/// scale's estimate, so they win when present on the same row), then
/// values are averaged per day, ascending. Non-numeric/absent rows are
/// skipped; values outside (0, 75) are treated as entry noise.
List<({DateTime day, double value})> bodyFatSeriesFromRecords(
  Iterable<Map<String, Object?>> records,
) {
  final sums = <DateTime, double>{};
  final counts = <DateTime, int>{};
  for (final r in records) {
    final date = _asUtcDay(r['date']);
    if (date == null) continue;
    final pct = _asDouble(r['body_fat_caliper']) ??
        _asDouble(r['body_fat_omron']) ??
        _asDouble(r['body_fat_withing']);
    if (pct == null || pct <= 0 || pct >= 75) continue;
    sums[date] = (sums[date] ?? 0) + pct;
    counts[date] = (counts[date] ?? 0) + 1;
  }
  final days = sums.keys.toList()..sort();
  return [
    for (final d in days) (day: d, value: sums[d]! / counts[d]!),
  ];
}

DateTime? _asUtcDay(Object? v) {
  final d = v is DateTime ? v : DateTime.tryParse(v?.toString() ?? '');
  return d == null ? null : DateTime.utc(d.year, d.month, d.day);
}

double? _asDouble(Object? v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

/// Everything a domain screen has gathered for its metrics. Any input a
/// metric needs but the caller couldn't produce stays null/empty — the
/// metric degrades to [MetricUnavailable], never throws.
class DomainMetricInputs {
  /// Mapped strength rows (strength domain).
  final List<StrengthRow> strengthRows;

  /// Daily-averaged weigh-ins (weight domain, shared loader).
  final List<WeightRow> weightDaily;

  /// Raw weight-view records (body-fat columns).
  final List<Map<String, Object?>> weightRecords;

  final DateTime today;

  const DomainMetricInputs({
    this.strengthRows = const [],
    this.weightDaily = const [],
    this.weightRecords = const [],
    required this.today,
  });
}

const _p3Note = 'coming soon';

/// One metric config → display data. Total function: unknown ids and
/// empty inputs yield [MetricUnavailable].
MetricData computeMetric(MetricConfig m, DomainMetricInputs inputs) {
  final unit = m.unit == null ? '' : ' ${m.unit}';
  String withUnit(double v) => '${fmtLb(v.roundToDouble())}$unit';

  // Per-lift filter: config order wins; default to the four mains.
  final lifts = m.lifts.isEmpty ? synthesisLifts : m.lifts;

  switch (m.id) {
    case 'pl_total':
      if (inputs.strengthRows.isEmpty) {
        return const MetricUnavailable('no strength history');
      }
      final t = plTotal(allTimeBestE1rms(inputs.strengthRows));
      if (t == null) return const MetricUnavailable('no main-lift sets yet');
      return MetricStats(
        [MetricStat(label: 'total', value: withUnit(t.total))],
        note: t.missing.isEmpty ? null : 'missing: ${t.missing.join(', ')}',
      );

    case 'e1rm_reference':
      if (inputs.strengthRows.isEmpty) {
        return const MetricUnavailable('no strength history');
      }
      final refs = liftReferencesAsOf(inputs.strengthRows, inputs.today);
      return _perLiftStats(refs, lifts, withUnit);

    case 'all_time_best_weight':
      if (inputs.strengthRows.isEmpty) {
        return const MetricUnavailable('no strength history');
      }
      final best = allTimeBestWeights(inputs.strengthRows, inputs.today);
      return _perLiftStats(best, lifts, withUnit);

    case 'bw_series':
      if (inputs.weightDaily.isEmpty) {
        return const MetricUnavailable('no weigh-ins yet');
      }
      return MetricSeries(
        points: [
          for (final w in inputs.weightDaily)
            (day: w.date, value: w.weightLbs),
        ],
        avg: [
          for (final w in sevenDayAvgSeries(inputs.weightDaily))
            (day: w.date, value: w.weightLbs),
        ],
        goal: m.goal,
        unit: m.unit,
      );

    case 'bf_series':
      final points = bodyFatSeriesFromRecords(inputs.weightRecords);
      if (points.isEmpty) {
        return const MetricUnavailable('no body-fat measurements yet');
      }
      return MetricSeries(points: points, goal: m.goal, unit: m.unit);

    // P3 vocabulary — declared placeholders.
    case 'kcal_series':
    case 'protein_series':
    case 'grade_pyramid':
    case 'session_frequency':
    case 'hr_4x4_series':
      return const MetricUnavailable(_p3Note);

    default:
      return MetricUnavailable('unknown metric "${m.id}"');
  }
}

MetricStats _perLiftStats(
  Map<String, double> byLift,
  List<String> lifts,
  String Function(double) fmt,
) {
  final stats = [
    for (final lift in lifts)
      if (byLift.containsKey(lift))
        MetricStat(label: lift, value: fmt(byLift[lift]!)),
  ];
  if (stats.isEmpty) return const MetricStats([], note: 'no qualifying sets');
  final missing = [for (final l in lifts) if (!byLift.containsKey(l)) l];
  return MetricStats(
    stats,
    note: missing.isEmpty ? null : 'missing: ${missing.join(', ')}',
  );
}
