/// Domain-dashboard metric engine (app-IA redesign P2).
///
/// Pure computation: the domain screen gathers raw inputs (strength
/// rows off the ledger, the shared daily weigh-in series, raw weight
/// records for body-fat) and [computeMetric] turns one [MetricConfig]
/// into display data. No Flutter, no IO — everything here is
/// unit-tested; the UI stays layout-only.
///
/// Full built-in vocabulary (P2 + P3): pl_total, e1rm_reference,
/// all_time_best_weight (strength), bw_series, bf_series (weight),
/// kcal_series, protein_series (meals — daily sums; protein carries a
/// bodyweight-scaled goal band), grade_pyramid, session_frequency
/// (climbing), hr_4x4_series (cardio). Unknown ids return a
/// [MetricUnavailable] placeholder — a declared-but-unknown metric must
/// render as a dim note, never break the header.
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
/// optional flat [goal] target line, optional shaded goal band
/// ([bandLow]..[bandHigh] — both set or both null).
class MetricSeries extends MetricData {
  final List<({DateTime day, double value})> points;
  final List<({DateTime day, double value})> avg;
  final double? goal;
  final double? bandLow;
  final double? bandHigh;
  final String? unit;
  const MetricSeries({
    required this.points,
    this.avg = const [],
    this.goal,
    this.bandLow,
    this.bandHigh,
    this.unit,
  });
}

/// A horizontal bar list (grade pyramid): one labeled count per bar,
/// already in display order.
class MetricBars extends MetricData {
  final List<({String label, int count})> bars;

  /// Caveat line under the bars ("3 routes not shown").
  final String? note;
  const MetricBars(this.bars, {this.note});
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
// Meals built-ins
// ---------------------------------------------------------------------------

/// Sums [valueKey] per day (day taken from [dateKey], date or datetime),
/// ascending. Rows without a parseable date or a numeric value are
/// skipped; days where NO row had a numeric value are omitted entirely
/// (a day of meals with unlogged calories isn't a zero-calorie day).
List<({DateTime day, double value})> dailySumSeries(
  Iterable<Map<String, Object?>> records, {
  required String dateKey,
  required String valueKey,
}) {
  final sums = <DateTime, double>{};
  for (final r in records) {
    final day = _asUtcDay(r[dateKey]);
    final v = _asDouble(r[valueKey]);
    if (day == null || v == null) continue;
    sums[day] = (sums[day] ?? 0) + v;
  }
  final days = sums.keys.toList()..sort();
  return [for (final d in days) (day: d, value: sums[d]!)];
}

// ---------------------------------------------------------------------------
// Climbing built-ins
// ---------------------------------------------------------------------------

final _numericVGrade = RegExp(r'^v(\d+)', caseSensitive: false);

/// Boulder pyramid: ascent count per v-grade. Numeric v-grades sort
/// high→low (the pyramid shape); non-numeric v-grades (vIntro, vB, v?)
/// follow, by count. Route grades (anything not v-prefixed, e.g.
/// `5.12a`) are NOT bars — the pyramid is about bouldering — but their
/// count comes back in [routesExcluded] so the UI can say so. Grade
/// comparison is case-folded ("V5" and "v5" are one bar; first-seen
/// spelling wins the label).
({List<({String label, int count})> bars, int routesExcluded}) gradePyramid(
  Iterable<Map<String, Object?>> records,
) {
  final counts = <String, int>{}; // case-folded key → count
  final labels = <String, String>{}; // case-folded key → display label
  var routes = 0;
  for (final r in records) {
    final grade = r['grade']?.toString().trim() ?? '';
    if (grade.isEmpty) continue;
    if (!grade.toLowerCase().startsWith('v')) {
      routes++;
      continue;
    }
    final key = grade.toLowerCase();
    counts[key] = (counts[key] ?? 0) + 1;
    labels[key] ??= grade;
  }
  int? vNum(String key) =>
      int.tryParse(_numericVGrade.firstMatch(key)?.group(1) ?? '');
  final keys = counts.keys.toList()
    ..sort((a, b) {
      final na = vNum(a);
      final nb = vNum(b);
      if (na != null && nb != null) return nb.compareTo(na); // v10 … v0
      if (na != null) return -1; // numerics above the vIntro/vB tail
      if (nb != null) return 1;
      return counts[b]!.compareTo(counts[a]!); // tail: by volume
    });
  return (
    bars: [for (final k in keys) (label: labels[k]!, count: counts[k]!)],
    routesExcluded: routes,
  );
}

/// Sessions per ISO week: distinct days with at least one row, bucketed
/// by week (Monday start), zero-filled over the trailing [weeks] weeks
/// ending with today's week. Points are (week's Monday, count).
List<({DateTime day, double value})> sessionsPerWeek(
  Iterable<Map<String, Object?>> records, {
  required DateTime today,
  int weeks = 12,
  String dateKey = 'date',
}) {
  DateTime monday(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day - (d.weekday - 1));
  final thisMonday = monday(today);
  final firstMonday = thisMonday.subtract(Duration(days: 7 * (weeks - 1)));

  final sessionDays = <DateTime>{
    for (final r in records) ?_asUtcDay(r[dateKey]),
  };
  final perWeek = <DateTime, int>{};
  for (final d in sessionDays) {
    final wk = monday(d);
    if (wk.isBefore(firstMonday) || wk.isAfter(thisMonday)) continue;
    perWeek[wk] = (perWeek[wk] ?? 0) + 1;
  }
  return [
    for (var i = 0; i < weeks; i++)
      (
        day: firstMonday.add(Duration(days: 7 * i)),
        value: (perWeek[firstMonday.add(Duration(days: 7 * i))] ?? 0)
            .toDouble(),
      ),
  ];
}

// ---------------------------------------------------------------------------
// Cardio built-ins
// ---------------------------------------------------------------------------

/// Max numeric [valueKey] per day, ascending. Zero / blank / non-numeric
/// readings are skipped (a 0 max-HR is an unrecorded one, not a datum);
/// days with no valid reading are omitted.
List<({DateTime day, double value})> maxPerDaySeries(
  Iterable<Map<String, Object?>> records, {
  String dateKey = 'date',
  required String valueKey,
}) {
  final best = <DateTime, double>{};
  for (final r in records) {
    final day = _asUtcDay(r[dateKey]);
    final v = _asDouble(r[valueKey]);
    if (day == null || v == null || v <= 0) continue;
    if ((best[day] ?? 0) < v) best[day] = v;
  }
  final days = best.keys.toList()..sort();
  return [for (final d in days) (day: d, value: best[d]!)];
}

// ---------------------------------------------------------------------------
// Dispatcher
// ---------------------------------------------------------------------------

/// Everything a domain screen has gathered for its metrics. Any input a
/// metric needs but the caller couldn't produce stays null/empty — the
/// metric degrades to [MetricUnavailable], never throws.
class DomainMetricInputs {
  /// Mapped strength rows (strength domain).
  final List<StrengthRow> strengthRows;

  /// Daily-averaged weigh-ins. The weight domain's own series
  /// (bw_series/bf_series) AND the bodyweight reference other domains'
  /// metrics scale against (protein_series band).
  final List<WeightRow> weightDaily;

  /// The domain's primary-view records, raw — body-fat columns
  /// (weight), meals rows, climbing ascents, cardio sets.
  final List<Map<String, Object?>> records;

  final DateTime today;

  const DomainMetricInputs({
    this.strengthRows = const [],
    this.weightDaily = const [],
    this.records = const [],
    required this.today,
  });
}

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
      final points = bodyFatSeriesFromRecords(inputs.records);
      if (points.isEmpty) {
        return const MetricUnavailable('no body-fat measurements yet');
      }
      return MetricSeries(points: points, goal: m.goal, unit: m.unit);

    case 'kcal_series':
    case 'protein_series':
      final points = dailySumSeries(
        inputs.records,
        dateKey: 'eaten_at',
        valueKey: m.id == 'kcal_series' ? 'calories' : 'protein_g',
      );
      if (points.isEmpty) return const MetricUnavailable('no meals logged yet');
      // Protein's goal band is declared per-lb of bodyweight; scale it
      // by the current 7-day average. No weigh-ins → no band, series
      // still plots.
      final band = m.id == 'protein_series' ? m.goalBandPerLb : null;
      final bw = inputs.weightDaily.isEmpty
          ? null
          : sevenDayAvgSeries(inputs.weightDaily).last.weightLbs;
      return MetricSeries(
        points: points,
        goal: m.goal,
        bandLow: band == null || bw == null ? null : band.low * bw,
        bandHigh: band == null || bw == null ? null : band.high * bw,
        unit: m.unit,
      );

    case 'grade_pyramid':
      final p = gradePyramid(inputs.records);
      if (p.bars.isEmpty) {
        return const MetricUnavailable('no boulder ascents yet');
      }
      return MetricBars(
        p.bars,
        note: p.routesExcluded == 0
            ? null
            : '${p.routesExcluded} route${p.routesExcluded == 1 ? '' : 's'}'
                ' not shown',
      );

    case 'session_frequency':
      if (inputs.records.isEmpty) {
        return const MetricUnavailable('no sessions yet');
      }
      return MetricSeries(
        points: sessionsPerWeek(inputs.records, today: inputs.today),
        goal: m.goal,
        unit: m.unit,
      );

    case 'hr_4x4_series':
      final points = maxPerDaySeries(inputs.records, valueKey: 'max_hr');
      if (points.isEmpty) {
        return const MetricUnavailable('no max-HR readings yet');
      }
      return MetricSeries(points: points, goal: m.goal, unit: m.unit);

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
