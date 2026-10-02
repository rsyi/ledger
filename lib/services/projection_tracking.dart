/// projection_tracking.dart — how you're tracking against a FROZEN phase
/// projection (projection_snapshot.dart; spec
/// docs/superpowers/specs/2026-10-02-phase-projections-design.md).
///
/// ACTUAL DEFINITIONS (mirrored verbatim by the ledger-mcp worker's
/// phase_tracking block — src/phase_tracking.ts; shared cases in
/// ledger-mcp/test/fixtures/phase_tracking_cases.json):
///   * bodyweight — 7-day average ending on the day: the mean of the
///     PER-DAY means of every weigh-in in [day−6, day] (several weigh-ins
///     on one day count once).
///   * body_fat — scale/DEXA body-fat %: per row the first non-blank of
///     withings → omron → caliper; the mean of per-day means over
///     [day−6, day]; when that week has none, the latest reading in
///     [day−27, day]; else null. (No DEXA source exists yet.)
///   * `e1rm_<lift>` — "latest e1RM": the best RPE-adjusted e1RM
///     (weight × (1 + min(12, min(reps,12) + (10 − RPE))/30)) in the most
///     recent Monday-start week (rows dated ≤ day) in which the lift has
///     a set; strength_total = squat + bench + deadlift (null unless all
///     three exist). Same basis as the forecast's observed index.
///   * climbing_grade — the 4-week rolling p75 of numeric V grades
///     (≥ 5 ascents) for the Monday-week containing the day, stepping
///     back up to 12 weeks when the window is thin.
///   * vo2max — no measured source → always null (status no_data).
///
/// STATUS: inside the band → on_track; outside → ahead/behind by the
/// metric's GOOD DIRECTION: strength, per-lift, VO2 and climbing are
/// "up"; body fat is "down"; bodyweight is "down" in a cut, "up" when
/// the block projects a gain of ≥ 2 lb, else "hold" (outside the band
/// either way = behind, worded above/below).
///
/// Pure Dart (no Flutter, no IO).
library;

import 'program_metrics.dart'
    show StrengthRow, WeightRow, mainLiftByExercise, rpeAdjustedE1rm;
import 'projection_snapshot.dart';
import 'sim_fit.dart' show ClimbAscent;

// ---------------------------------------------------------------------------
// Actuals
// ---------------------------------------------------------------------------

/// One body-fat reading (scale or DEXA).
class BodyFatReading {
  final DateTime date;
  final double pct;

  const BodyFatReading(this.date, this.pct);
}

DateTime _d(DateTime d) => DateTime.utc(d.year, d.month, d.day);

int _days(DateTime a, DateTime b) => _d(b).difference(_d(a)).inDays;

DateTime _monday(DateTime d) {
  final day = _d(d);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// Mean of per-day means for values dated in [from, to] (inclusive).
double? _dayMeanAvg(
  Iterable<(DateTime, double)> values,
  DateTime from,
  DateTime to,
) {
  final sum = <DateTime, double>{}, n = <DateTime, int>{};
  for (final (date, v) in values) {
    final d = _d(date);
    if (d.isBefore(_d(from)) || d.isAfter(_d(to))) continue;
    sum[d] = (sum[d] ?? 0) + v;
    n[d] = (n[d] ?? 0) + 1;
  }
  if (sum.isEmpty) return null;
  var total = 0.0;
  for (final d in sum.keys) {
    total += sum[d]! / n[d]!;
  }
  return total / sum.length;
}

/// 7-day average bodyweight ending on [day] (see the library note).
double? bodyweightActualAt(List<WeightRow> weighIns, DateTime day) =>
    _dayMeanAvg(
      [for (final w in weighIns) (w.date, w.weightLbs)],
      _d(day).subtract(const Duration(days: 6)),
      day,
    );

/// Body fat % at [day] (see the library note).
double? bodyFatActualAt(List<BodyFatReading> readings, DateTime day) {
  final week = _dayMeanAvg(
    [for (final r in readings) (r.date, r.pct)],
    _d(day).subtract(const Duration(days: 6)),
    day,
  );
  if (week != null) return week;
  BodyFatReading? latest;
  for (final r in readings) {
    final age = _days(r.date, day);
    if (age < 0 || age > 27) continue;
    if (latest == null || r.date.isAfter(latest.date)) latest = r;
  }
  return latest?.pct;
}

/// Latest e1RM per main lift at [day] (see the library note). Lifts
/// never trained by [day] are absent.
Map<String, double> e1rmActualsAt(List<StrengthRow> rows, DateTime day) {
  final end = _d(day);
  final bestWeek = <String, DateTime>{};
  final best = <String, double>{};
  for (final r in rows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || r.weight <= 0 || r.reps < 1) continue;
    if (_d(r.date).isAfter(end)) continue;
    final wk = _monday(r.date);
    final e = rpeAdjustedE1rm(r.weight, r.reps, r.rpe);
    final cur = bestWeek[lift];
    if (cur == null || wk.isAfter(cur)) {
      bestWeek[lift] = wk;
      best[lift] = e;
    } else if (wk == cur && e > best[lift]!) {
      best[lift] = e;
    }
  }
  return best;
}

/// p75 by linear interpolation (sim_fit.percentile's definition).
double _p75(List<int> values) {
  final s = [...values]..sort();
  final pos = 0.75 * (s.length - 1);
  final lo = pos.floor(), hi = pos.ceil();
  return lo == hi ? s[lo].toDouble() : s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

/// 4-week rolling p75 V grade for the week containing [day] (see the
/// library note). Null when no window in the last 12 weeks has ≥ 5
/// numeric grades.
double? climbingActualAt(List<ClimbAscent> climbs, DateTime day) {
  final end = _d(day);
  final thisMonday = _monday(day);
  for (var j = 0; j < 12; j++) {
    final wkMonday = thisMonday.subtract(Duration(days: 7 * j));
    final from = wkMonday.subtract(const Duration(days: 21));
    final to = wkMonday.add(const Duration(days: 6));
    final grades = <int>[
      for (final c in climbs)
        if (c.vGrade != null &&
            !_d(c.date).isBefore(from) &&
            !_d(c.date).isAfter(to) &&
            !_d(c.date).isAfter(end))
          c.vGrade!,
    ];
    if (grades.length >= 5) return _p75(grades);
  }
  return null;
}

/// Every metric's actual at [day] (null = no data).
Map<String, double?> projectionActualsAt({
  required DateTime day,
  List<WeightRow> weighIns = const [],
  List<BodyFatReading> bodyFat = const [],
  List<StrengthRow> strength = const [],
  List<ClimbAscent> climbs = const [],
}) {
  final e = e1rmActualsAt(strength, day);
  final s = e['squat'], b = e['bench'], d = e['deadlift'];
  return {
    ProjectionMetric.bodyweight: bodyweightActualAt(weighIns, day),
    ProjectionMetric.bodyFat: bodyFatActualAt(bodyFat, day),
    ProjectionMetric.strengthTotal:
        s == null || b == null || d == null ? null : s + b + d,
    for (final l in ProjectionMetric.lifts) ProjectionMetric.e1rm(l): e[l],
    ProjectionMetric.vo2max: null,
    ProjectionMetric.climbingGrade: climbingActualAt(climbs, day),
  };
}

// ---------------------------------------------------------------------------
// Tracking
// ---------------------------------------------------------------------------

enum TrackingStatus {
  onTrack('on_track'),
  ahead('ahead'),
  behind('behind'),
  noData('no_data');

  final String wire;
  const TrackingStatus(this.wire);
}

/// Which way is good for a metric in a block.
enum GoodDirection { up, down, hold }

/// Projected value + band at [day], linearly interpolated between the
/// weekly points and clamped to the last point (past the block end the
/// end-of-block projection holds). Null before the first point or with
/// no points.
ProjectionPoint? projectionAt(List<ProjectionPoint> points, DateTime day) {
  if (points.isEmpty) return null;
  final d = _d(day);
  if (d.isBefore(points.first.weekStart)) return null;
  if (!d.isBefore(points.last.weekStart)) return points.last;
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i], b = points[i + 1];
    if (d.isBefore(a.weekStart) || !d.isBefore(b.weekStart)) continue;
    final t = _days(a.weekStart, d) / _days(a.weekStart, b.weekStart);
    double lerp(double x, double y) => x + (y - x) * t;
    return ProjectionPoint(
      d,
      lerp(a.projected, b.projected),
      lerp(a.lo, b.lo),
      lerp(a.hi, b.hi),
    );
  }
  return points.last;
}

/// The metric's good direction (see the library note).
GoodDirection goodDirectionFor(
  String metric, {
  String? emphasis,
  List<ProjectionPoint> points = const [],
}) {
  switch (metric) {
    case ProjectionMetric.bodyFat:
      return GoodDirection.down;
    case ProjectionMetric.bodyweight:
      if (emphasis == 'cut') return GoodDirection.down;
      if (points.length >= 2 &&
          points.last.projected - points.first.projected >= 2) {
        return GoodDirection.up;
      }
      return GoodDirection.hold;
    default:
      return GoodDirection.up;
  }
}

/// One metric's tracking result.
class MetricTracking {
  final String metric;
  final DateTime day;
  final double? actual;
  final double? projected, lo, hi;
  final TrackingStatus status;
  final GoodDirection direction;

  const MetricTracking({
    required this.metric,
    required this.day,
    required this.actual,
    required this.projected,
    required this.lo,
    required this.hi,
    required this.status,
    required this.direction,
  });

  double? get delta =>
      actual == null || projected == null ? null : actual! - projected!;

  /// Plain-language line ("0.4 lb ahead of projection").
  String get line => trackingLine(this);
}

/// Tracks [actual] against [points] at [day].
MetricTracking trackMetric({
  required String metric,
  required List<ProjectionPoint> points,
  required DateTime day,
  required double? actual,
  String? emphasis,
}) {
  final p = projectionAt(points, day);
  final dir = goodDirectionFor(metric, emphasis: emphasis, points: points);
  TrackingStatus status;
  if (p == null || actual == null) {
    status = TrackingStatus.noData;
  } else if (actual >= p.lo && actual <= p.hi) {
    status = TrackingStatus.onTrack;
  } else {
    final above = actual > p.hi;
    status = switch (dir) {
      GoodDirection.up =>
        above ? TrackingStatus.ahead : TrackingStatus.behind,
      GoodDirection.down =>
        above ? TrackingStatus.behind : TrackingStatus.ahead,
      GoodDirection.hold => TrackingStatus.behind,
    };
  }
  return MetricTracking(
    metric: metric,
    day: _d(day),
    actual: actual,
    projected: p?.projected,
    lo: p?.lo,
    hi: p?.hi,
    status: status,
    direction: dir,
  );
}

/// Unit + decimals per metric for the plain-language line.
({String unit, int decimals}) metricUnit(String metric) => switch (metric) {
      ProjectionMetric.bodyweight => (unit: ' lb', decimals: 1),
      ProjectionMetric.bodyFat => (unit: ' pts', decimals: 1),
      ProjectionMetric.vo2max => (unit: '', decimals: 1),
      ProjectionMetric.climbingGrade => (unit: ' V', decimals: 1),
      _ => (unit: ' lb', decimals: 0),
    };

String _num(double v, int decimals) => v.abs().toStringAsFixed(decimals);

/// Signed with a true minus sign; "±0" collapses to "0".
String _signed(double v, int decimals) {
  final s = _num(v, decimals);
  if (double.parse(s) == 0) return s;
  return '${v > 0 ? '+' : '−'}$s';
}

/// "0.4 lb ahead of projection", "−12 lb vs projection (within range)",
/// "1.8 lb above projection" (hold metrics), "no data yet".
String trackingLine(MetricTracking t) {
  final delta = t.delta;
  if (t.status == TrackingStatus.noData || delta == null) {
    return t.projected == null ? 'no projection for this date' : 'no data yet';
  }
  final u = metricUnit(t.metric);
  final mag = '${_num(delta, u.decimals)}${u.unit}';
  switch (t.status) {
    case TrackingStatus.onTrack:
      if (double.parse(_num(delta, u.decimals)) == 0) {
        return 'on projection (within range)';
      }
      return '${_signed(delta, u.decimals)}${u.unit} vs projection '
          '(within range)';
    case TrackingStatus.ahead:
      return '$mag ahead of projection';
    case TrackingStatus.behind:
      if (t.direction == GoodDirection.hold) {
        return '$mag ${delta > 0 ? 'above' : 'below'} projection';
      }
      return '$mag behind projection';
    case TrackingStatus.noData:
      return 'no data yet';
  }
}

/// Tracks every metric of [snapshot] at [day] against [actuals].
Map<String, MetricTracking> trackSnapshot(
  ProjectionSnapshot snapshot,
  Map<String, double?> actuals,
  DateTime day,
) =>
    {
      for (final e in snapshot.metrics.entries)
        e.key: trackMetric(
          metric: e.key,
          points: e.value,
          day: day,
          actual: actuals[e.key],
          emphasis: snapshot.emphasis,
        ),
    };

// ---------------------------------------------------------------------------
// Past-block result line
// ---------------------------------------------------------------------------

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// One-line result for a finished (or in-progress) block: "Cut: 163 →
/// 155.8 vs projected 154; strength −1.5% vs projected −3%". The start
/// values are the snapshot's week-0 anchors (the observed values on
/// the start day); [endActuals] are the actuals at [endDay] (the block's
/// last day for past blocks). Segments without data are dropped; null
/// when neither bodyweight nor strength can be said.
String? blockResultLine(
  ProjectionSnapshot snapshot,
  Map<String, double?> endActuals,
  DateTime endDay,
) {
  final parts = <String>[];
  final bw = snapshot.metrics[ProjectionMetric.bodyweight];
  final bwEnd = endActuals[ProjectionMetric.bodyweight];
  final bwProj = bw == null ? null : projectionAt(bw, endDay);
  if (bw != null && bw.isNotEmpty && bwEnd != null && bwProj != null) {
    parts.add('${_fmt1(bw.first.projected)} → ${_fmt1(bwEnd)} vs projected '
        '${_fmt1(bwProj.projected)}');
  }
  final st = snapshot.metrics[ProjectionMetric.strengthTotal];
  final stEnd = endActuals[ProjectionMetric.strengthTotal];
  final stProj = st == null ? null : projectionAt(st, endDay);
  if (st != null &&
      st.isNotEmpty &&
      stEnd != null &&
      stProj != null &&
      st.first.projected > 0) {
    final s0 = st.first.projected;
    String pct(double v) {
      final p = (v / s0 - 1) * 100;
      final s = p.abs().toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
      return '${p > 0.05 ? '+' : (p < -0.05 ? '−' : '')}$s%';
    }

    parts.add('strength ${pct(stEnd)} vs projected ${pct(stProj.projected)}');
  }
  if (parts.isEmpty) return null;
  final name = snapshot.emphasis == null
      ? 'Block ${snapshot.block}'
      : _cap(snapshot.emphasis!);
  return '$name: ${parts.join('; ')}';
}

String _fmt1(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
