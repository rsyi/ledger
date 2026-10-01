/// Domain-dashboard metric engine (app-IA redesign P2).
///
/// Pure computation: the domain screen gathers raw inputs (strength
/// rows off the ledger, the shared daily weigh-in series, raw weight
/// records for body-fat) and [computeMetric] turns one [MetricConfig]
/// into display data. No Flutter, no IO — everything here is
/// unit-tested; the UI stays layout-only.
///
/// Full built-in vocabulary (P2 + P3): pl_total, e1rm_reference,
/// recent_e1rm_rpe (per-lift recent best on the RPE-adjusted capped
/// e1RM — the airlayer `max_e1rm_rpe` basis, 2026-09-25),
/// all_time_best_weight, wilks, wilks_series (strength — wilks is the
/// WILKS-2020 SBD score, weekly-current stat; wilks_series is the
/// MONTHLY trend; both on the ACTUAL-MAX basis since 2026-09-22 —
/// heaviest weight actually lifted, not e1RM — see services/wilks.dart),
/// bw_series, bf_series (weight),
/// kcal_series, protein_series (meals — daily sums; protein carries a
/// bodyweight-scaled goal band), grade_pyramid, session_frequency
/// (climbing), hr_4x4_series (cardio). Unknown ids return a
/// [MetricUnavailable] placeholder — a declared-but-unknown metric must
/// render as a dim note, never break the header.
///
/// [headlineStats] additionally reduces a domain's headline metrics to
/// one-number chips for the compact strip atop the domain screen's
/// records mode (the full dashboard lives in its Trends mode).
library;

import 'domain_config.dart';
import 'home_synthesis.dart'
    show allTimeBestE1rms, fmtLb, fmtMonthTag, recentBestE1rm, synthesisLifts;
import 'program_metrics.dart'
    show StrengthRow, WeightRow, gradeSets, liftReferencesAsOf,
        mainLiftByExercise, weekStartOf;
import 'program_observed.dart' show sevenDayAvgSeries;
import 'wilks.dart';

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
/// optional flat [goal] target line, optional acceptable-drop [floor]
/// line (a second dashed line under the goal — wilks_series' "act if
/// you sink under this" during a cut), optional all-time [benchmark]
/// line with its caption [benchmarkNote] ("best ever 342.1 · Mar '25"
/// — wilks_series' absolute-max yardstick), optional shaded goal band
/// ([bandLow]..[bandHigh] — both set or both null). [fullHistory] asks
/// the chart to plot the whole series instead of its default trailing
/// window (monthly series — a month-cadence trend inside an 84-day
/// window is 3 points).
class MetricSeries extends MetricData {
  final List<({DateTime day, double value})> points;
  final List<({DateTime day, double value})> avg;
  final double? goal;
  final double? floor;
  final double? benchmark;
  final String? benchmarkNote;
  final double? bandLow;
  final double? bandHigh;
  final String? unit;
  final bool fullHistory;
  const MetricSeries({
    required this.points,
    this.avg = const [],
    this.goal,
    this.floor,
    this.benchmark,
    this.benchmarkNote,
    this.bandLow,
    this.bandHigh,
    this.unit,
    this.fullHistory = false,
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
/// capped e1RMs (Epley, reps capped at 12 — home_synthesis
/// [allTimeBestE1rms]; the home card's all-time top column is ACTUAL
/// weight since 2026-09-22 and no longer shares this expression).
/// Returns the sum over the lifts that HAVE
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
/// logged sets with weight > 0 and reps > 0 — any reps ≥ 1, so a
/// 405×2 counts as 405), WITH the day it was set (→ age tags); dates
/// after [asOf] excluded so future-dated rows can't inflate a "best".
/// Ties keep the more recent date (an age tag should say "you matched
/// this 3d ago", not point at 2024). Distinct from the best e1RM —
/// this is a bar-loaded number, not an estimate. Consumers: the
/// strength Trends `all_time_best_weight` metric AND the home STRENGTH
/// card's all-time top column (2026-09-22 — user: "the all-time top
/// should be based on my actual 1RM not my e1RM").
Map<String, ({double value, DateTime date})> allTimeBestWeights(
  List<StrengthRow> rows,
  DateTime asOf,
) {
  final day = DateTime(asOf.year, asOf.month, asOf.day);
  final out = <String, ({double value, DateTime date})>{};
  for (final r in rows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || r.weight <= 0 || r.reps <= 0) continue;
    final d = DateTime(r.date.year, r.date.month, r.date.day);
    if (d.isAfter(day)) continue;
    final cur = out[lift];
    if (cur == null ||
        r.weight > cur.value ||
        (r.weight == cur.value && d.isAfter(cur.date))) {
      out[lift] = (value: r.weight, date: d);
    }
  }
  return out;
}

/// The heaviest weight ACTUALLY lifted per main lift INSIDE a date
/// window (inclusive on both ends) — [allTimeBestWeights]' conventions
/// (any reps ≥ 1, ties keep the newer date, non-main exercises
/// dropped) bounded to `[start, end]`. Feeds the home STRENGTH card's
/// "last bulk" column (2026-09-22, user: "show my numbers from my last
/// bulk"); the window itself comes from dashboards.yaml `last_bulk`
/// (domain_config parseLastBulkWindow).
Map<String, ({double value, DateTime date})> bestWeightsInWindow(
  List<StrengthRow> rows, {
  required DateTime start,
  required DateTime end,
}) {
  final startDay = DateTime(start.year, start.month, start.day);
  return allTimeBestWeights(
    [
      for (final r in rows)
        if (!DateTime(r.date.year, r.date.month, r.date.day).isBefore(startDay))
          r,
    ],
    end,
  );
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

  /// Accounting-week start (program.yaml v7 `week_start`; DateTime
  /// weekday constant). Keys the WEEKLY Wilks stat + the wilks_series
  /// reference anchor; the monthly trend is untouched. Default Monday
  /// (ISO) so callers without program access change nothing.
  final int weekStartDay;

  const DomainMetricInputs({
    this.strengthRows = const [],
    this.weightDaily = const [],
    this.records = const [],
    required this.today,
    this.weekStartDay = DateTime.monday,
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

    // Current-1RM ESTIMATE for progress tracking (2026-09-25): per-lift
    // best over the trailing 14 days of real work (warm-ups excluded;
    // window widens to the newest qualifying set), valued on the
    // RPE-adjusted capped e1RM — the airlayer `max_e1rm_rpe` measure's
    // basis (RIR = 10 − RPE counts as reps, total capped at 12; no RPE
    // → plain capped Epley). Distinct from e1rm_reference on purpose:
    // that one is the §2.5 42-day GRADING reference and stays plain.
    case 'recent_e1rm_rpe':
      if (inputs.strengthRows.isEmpty) {
        return const MetricUnavailable('no strength history');
      }
      final graded = gradeSets(inputs.strengthRows);
      final recents = <String, double>{};
      for (final lift in lifts) {
        final r = recentBestE1rm(
          graded,
          lift,
          inputs.today,
          rpeAdjusted: true,
        );
        if (r != null) recents[lift] = r.value;
      }
      return _perLiftStats(recents, lifts, withUnit);

    case 'all_time_best_weight':
      if (inputs.strengthRows.isEmpty) {
        return const MetricUnavailable('no strength history');
      }
      final best = allTimeBestWeights(inputs.strengthRows, inputs.today);
      return _perLiftStats(
        {for (final e in best.entries) e.key: e.value.value},
        lifts,
        withUnit,
      );

    case 'wilks':
      // WILKS-2020 SBD score (squat+bench+deadlift only — NOT the
      // 4-lift pl_total). The stat stays WEEKLY-current, on the
      // ACTUAL-MAX basis (2026-09-22): heaviest weight actually lifted
      // per lift that week (any reps >= 1, carried forward when
      // untrained) at that week's 7-day-avg bodyweight. All semantics
      // + verified constants: wilks.dart.
      if (inputs.strengthRows.isEmpty) {
        return const MetricUnavailable('no strength history');
      }
      if (inputs.weightDaily.isEmpty) {
        return const MetricUnavailable('no weigh-ins for bodyweight');
      }
      final weeks = weeklyWilksSeries(
        inputs.strengthRows,
        inputs.weightDaily,
        through: inputs.today,
        weekStartDay: inputs.weekStartDay,
      );
      if (weeks.isEmpty) {
        return const MetricUnavailable(
          'no squat/bench/deadlift sets with reps ≤ 5 yet',
        );
      }
      final last = weeks.last;
      return MetricStats(
        [
          MetricStat(
            label: 'Wilks (SBD)',
            value: last.wilks.toStringAsFixed(1),
          ),
        ],
        note: 'total ${fmtLb(last.totalLbs.roundToDouble())} lb @ '
            '${last.bodyweightLbs.toStringAsFixed(1)} lb bw'
            '${last.carried.isEmpty ? '' : ' · carried: ${last.carried.join(', ')}'}',
      );

    case 'wilks_series':
      // The TREND is month-to-month (user 2026-09-21: "month-to-month
      // measurements, rather than week-to-week, since I have deload
      // weeks") — best-of-calendar-month per lift so a deload week
      // can't drag a point, monthly-mean bodyweight carried through
      // months with no weigh-in (which is what lets the series run
      // back through sparse weigh-in eras instead of truncating).
      // Basis = ACTUAL MAX (2026-09-22, user: "done against actually
      // max lift numbers, not e1RM") — the heaviest weight lifted, so
      // the series tracks real strength through the cut, and its
      // all-time max is the benchmark line below.
      if (inputs.strengthRows.isEmpty) {
        return const MetricUnavailable('no strength history');
      }
      if (inputs.weightDaily.isEmpty) {
        return const MetricUnavailable('no weigh-ins for bodyweight');
      }
      final months = monthlyWilksSeries(
        inputs.strengthRows,
        inputs.weightDaily,
        through: inputs.today,
      );
      if (months.isEmpty) {
        return const MetricUnavailable(
          'no squat/bench/deadlift sets with reps ≤ 5 yet',
        );
      }
      // `window_years:` no longer clips HERE (2026-09-22, range
      // selectors): the series carries full computable history and
      // MetricChart turns window_years into the DEFAULT range chip
      // (4 → '4Y'), so "All" can genuinely widen past it. The chart
      // clips client-side by date — same data, user-tunable window.
      final points = [
        for (final mo in months) (day: mo.monthStart, value: mo.wilks),
      ];
      // The BENCHMARK: the all-time max of the monthly series, drawn
      // as its own line + "best ever 3XX · Mmm 'yy" caption — the
      // absolute-max yardstick the user tracks against.
      final bench = wilksBenchmark(months);
      // `from` anchors the dashed REFERENCE at the WEEKLY value as of
      // that date — the Wilks the cut was walked into with. Weekly,
      // not monthly, on purpose: the cut-start month's point keeps
      // absorbing best-of-month sets logged during the cut itself,
      // which would move the yardstick. Recomputed on the actual-max
      // basis since 2026-09-22 (same basis as the series — apples to
      // apples). The series shows the full computable history (user
      // 2026-09-22: "wilks should be tracked for longer"). floor_pct
      // then hangs the acceptable-drop line under the reference:
      // reference × (1 − pct/100); 3+ weeks below the floor = the act
      // signal.
      double? reference;
      final from = m.from;
      if (from != null) {
        final weeks = weeklyWilksSeries(
          inputs.strengthRows,
          inputs.weightDaily,
          through: inputs.today,
          weekStartDay: inputs.weekStartDay,
        );
        if (weeks.isNotEmpty) {
          final fromMonday = weekStartOf(from, inputs.weekStartDay);
          var ref = weeks.first;
          for (final w in weeks) {
            if (!w.weekStart.isAfter(fromMonday)) ref = w;
          }
          reference = ref.wilks;
        }
      }
      final floorPct = m.floorPct;
      final floor = reference == null || floorPct == null
          ? null
          : reference * (1 - floorPct / 100);
      return MetricSeries(
        points: points,
        goal: reference,
        floor: floor,
        benchmark: bench?.wilks,
        benchmarkNote: bench == null
            ? null
            : 'best ever ${bench.wilks.toStringAsFixed(1)} · '
                '${fmtMonthTag(bench.monthStart)}',
        unit: m.unit,
        fullHistory: true,
      );

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

    // Recovery domain (Whoop API → recovery tab): one row per day, so a
    // per-day max over the named numeric column IS the daily value.
    case 'recovery_score':
    case 'hrv_ms':
    case 'sleep_hours':
      final points = maxPerDaySeries(inputs.records, valueKey: m.id);
      if (points.isEmpty) {
        return const MetricUnavailable('no recovery data yet');
      }
      return MetricSeries(points: points, goal: m.goal, unit: m.unit);

    // Whoop workouts (Whoop API → whoop_workouts tab): a day can carry
    // MULTIPLE workouts, so the series plots the day's HARDEST workout
    // (max strain) — the top cardiovascular load that day.
    case 'strain_series':
      final points = maxPerDaySeries(inputs.records, valueKey: 'strain');
      if (points.isEmpty) {
        return const MetricUnavailable('no workouts yet');
      }
      return MetricSeries(points: points, goal: m.goal, unit: m.unit);

    default:
      return MetricUnavailable('unknown metric "${m.id}"');
  }
}

// ---------------------------------------------------------------------------
// Headline strip
// ---------------------------------------------------------------------------

/// Short display names for the headline strip — the full `label:` from
/// dashboards.yaml is a heading, not a chip. Unknown ids fall back to
/// the raw id.
const _headlineLabels = {
  'pl_total': 'PL',
  'e1rm_reference': 'e1RM',
  'recent_e1rm_rpe': 'e1RM (RPE-adj)',
  'all_time_best_weight': 'best',
  'wilks': 'Wilks',
  'wilks_series': 'Wilks',
  'bw_series': 'bw',
  'bf_series': 'bf',
  'kcal_series': 'kcal',
  'protein_series': 'protein',
  'grade_pyramid': 'top',
  'session_frequency': 'sess/wk',
  'hr_4x4_series': 'max HR',
  'recovery_score': 'recovery',
  'hrv_ms': 'HRV',
  'sleep_hours': 'sleep',
  'strain_series': 'strain',
};

/// Which metrics feed the headline strip. Declared `headline:` ids win
/// (config order, unknown ids skipped); absent/empty → sensible default:
/// stat/best kinds first, then the rest, capped at three — a strip, not
/// a dashboard.
List<MetricConfig> headlineConfigs(DomainConfig domain) {
  final byId = {for (final m in domain.metrics) m.id: m};
  final declared = [
    for (final id in domain.headline) ?byId[id],
  ];
  if (declared.isNotEmpty) return declared;
  final stats = [
    for (final m in domain.metrics)
      if (m.kind != MetricKind.series) m,
  ];
  final series = [
    for (final m in domain.metrics)
      if (m.kind == MetricKind.series) m,
  ];
  return [...stats, ...series].take(3).toList();
}

/// One metric reduced to a single headline number, or null when it has
/// nothing to say (unavailable / empty — the strip simply omits it).
/// Stats take their first chip (per-lift stats keep the lift name so
/// "e1RM squat 315 lb" stays honest); series take the latest point;
/// bar lists take the top bar's label (grade pyramid → hardest grade).
MetricStat? headlineStat(MetricConfig m, DomainMetricInputs inputs) {
  final label = _headlineLabels[m.id] ?? m.id;
  switch (computeMetric(m, inputs)) {
    case MetricStats(stats: final stats) when stats.isNotEmpty:
      final first = stats.first;
      return MetricStat(
        label: stats.length == 1 ? label : '$label ${first.label}',
        value: first.value,
      );
    case MetricSeries(points: final points, unit: final unit)
        when points.isNotEmpty:
      final v = points.last.value;
      final num_ = v == v.roundToDouble()
          ? v.round().toString()
          : v.toStringAsFixed(1);
      return MetricStat(
        label: label,
        value: unit == null ? num_ : '$num_ $unit',
      );
    case MetricBars(bars: final bars) when bars.isNotEmpty:
      return MetricStat(label: label, value: bars.first.label);
    default:
      return null;
  }
}

/// The whole strip: headline metrics reduced to stats, nulls dropped.
List<MetricStat> headlineStats(DomainConfig domain, DomainMetricInputs inputs) {
  return [
    for (final m in headlineConfigs(domain)) ?headlineStat(m, inputs),
  ];
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
