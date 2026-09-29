/// forecast_calibration.dart — AUTO-RECALIBRATION for the single-
/// trajectory forecast (user directive 2026-09-28: "I'd also like it to
/// adjust based on how it tracks over time with my actual progression").
/// Pure Dart — no Flutter, no IO; run nightly by
/// tool/program_status_update.dart and read by the Plan tab through the
/// `forecast_meta` tab.
///
/// DESIGN:
///  * TRACKING CHECK — a replay, not a stored-prediction diff (the
///    nightly `forecast` tab is replace-all, so past predictions are
///    not retained): re-run the sim from the Monday [weeksBack] weeks
///    ago, anchored to the ACTUALS at that Monday (7-day-avg bw + the
///    observed Epley index total), with the same nutrition-derived
///    r/P the published forecast used. Compare each subsequent week's
///    predicted bw against the actual 7-day average and the predicted
///    INDEX line (sIdx — the measurable surface) against the observed
///    weekly index total.
///  * PERSISTENT ERROR — the last [persistWeeks] consecutive weekly
///    checks all land outside the band (bw [bwBandLb] ≈ scale noise on
///    a 7d average; strength [strengthBandLb] ≈ the v2.1 fit report's
///    replay median level error ~31 lb, tightened slightly).
///  * GUARDED REFIT — persistent strength error scales the capacity
///    gain terms (a, b) by the actual/predicted progression ratio,
///    CLAMPED to ±50% of the fitted values (the drift guard);
///    persistent bw error becomes a maintenance-kcal offset
///    (rate error × 3500/7), clamped to ±[maxMaintenanceOffsetKcal].
///    Every applied adjustment is recorded as a recalibration event.
///  * The result is written to the `forecast_meta` tab (key/value —
///    codec below) each night; the Plan tab renders "model tracking:
///    on / adjusted <date> (<what moved>)" from it and applies the
///    scales/offset to its own local run so app and nightly agree.
library;

import 'dart:convert';
import 'dart:math';

import 'program_metrics.dart' show WeightRow;
import 'program_observed.dart' show sevenDayAvgSeries;
import 'sim2_harness.dart';
import 'sim2_model.dart';

// ---------------------------------------------------------------------------
// Tracking check (replay vs actuals)
// ---------------------------------------------------------------------------

/// One weekly predicted-vs-actual comparison.
class WeeklyCheck {
  final DateTime monday;
  final double predicted, actual;

  const WeeklyCheck(this.monday, this.predicted, this.actual);

  double get error => predicted - actual;
}

/// The trailing tracking result.
class ForecastCalibration {
  final List<WeeklyCheck> bw, strength;
  final double bwBandLb, strengthBandLb;
  final int persistWeeks;

  const ForecastCalibration({
    required this.bw,
    required this.strength,
    required this.bwBandLb,
    required this.strengthBandLb,
    required this.persistWeeks,
  });

  static double _mae(List<WeeklyCheck> c) => c.isEmpty
      ? 0
      : c.fold<double>(0, (s, w) => s + w.error.abs()) / c.length;

  double get bwMae => _mae(bw);
  double get strengthMae => _mae(strength);

  static bool _persistent(List<WeeklyCheck> c, double band, int k) {
    if (c.length < k) return false;
    return c
        .sublist(c.length - k)
        .every((w) => w.error.abs() > band);
  }

  /// The last [persistWeeks] bw checks all outside the band.
  bool get bwPersistent => _persistent(bw, bwBandLb, persistWeeks);

  /// The last [persistWeeks] strength checks all outside the band.
  bool get strengthPersistent =>
      _persistent(strength, strengthBandLb, persistWeeks);
}

/// 7-day-average bodyweight ending on [day] (null when no weigh-in
/// falls in the trailing week).
double? bw7dAvgAt(List<WeightRow> daily, DateTime day) {
  final end = DateTime.utc(day.year, day.month, day.day);
  final start = end.subtract(const Duration(days: 6));
  var sum = 0.0;
  var n = 0;
  for (final w in daily) {
    final d = DateTime.utc(w.date.year, w.date.month, w.date.day);
    if (d.isBefore(start) || d.isAfter(end)) continue;
    sum += w.weightLbs;
    n++;
  }
  return n == 0 ? null : sum / n;
}

DateTime _mondayOnOrBefore(DateTime d) {
  final day = DateTime.utc(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// Runs the tracking check. [observedIndexByMonday] carries the weekly
/// observed Epley index totals (SBD sum, carry-forward weeks fine —
/// callers build it from sim_fit's WeeklySeries). [rReplayLbWk] /
/// [pReplay] are the nutrition-derived dials the published forecast
/// used (null → the block dials, same fallback the forecast takes).
/// Null when the anchors are missing (no bw or index at the start
/// Monday) — tracking is then simply "on" with no evidence.
ForecastCalibration? calibrateForecast({
  required Sim2Params params,
  required List<Sim2Block> blocks,
  required List<WeightRow> dailyWeighIns,
  required Map<DateTime, double> observedIndexByMonday,
  required DateTime today,
  double? rReplayLbWk,
  double? pReplay,
  int weeksBack = 6,
  int persistWeeks = 3,
  double bwBandLb = 1.25,
  double strengthBandLb = 25,
}) {
  if (blocks.isEmpty) return null;
  final startMonday =
      _mondayOnOrBefore(today).subtract(Duration(days: 7 * weeksBack));
  if (startMonday.isBefore(blocks.first.start)) return null;
  final anchorBw = bw7dAvgAt(dailyWeighIns, startMonday);
  final anchorIdx = observedIndexByMonday[startMonday];
  if (anchorBw == null) return null;

  final run = sim2Run(
    params: params,
    blocks: blocks,
    start: startMonday,
    horizon: _mondayOnOrBefore(today),
    overrides: Sim2DialOverrides(r: rReplayLbWk, p: pReplay),
    observedBw: anchorBw,
    observedIndexTotal: anchorIdx,
  );

  // ALIGNMENT: a sim week point at monday m carries the state AFTER
  // that week's step — compare it against the actuals at m+7 (for a
  // linear trend the 7d average at m+7 equals the anchored predicted
  // state exactly, no half-week bias).
  final bwChecks = <WeeklyCheck>[];
  final sChecks = <WeeklyCheck>[];
  for (final w in run.weeks) {
    final actualDay = w.monday.add(const Duration(days: 7));
    if (actualDay.isAfter(DateTime.utc(today.year, today.month, today.day))) {
      continue;
    }
    final actualBw = bw7dAvgAt(dailyWeighIns, actualDay);
    if (actualBw != null) bwChecks.add(WeeklyCheck(actualDay, w.bw, actualBw));
    final actualIdx = observedIndexByMonday[actualDay];
    if (actualIdx != null && anchorIdx != null) {
      sChecks.add(WeeklyCheck(actualDay, w.sIdx, actualIdx));
    }
  }
  return ForecastCalibration(
    bw: bwChecks,
    strength: sChecks,
    bwBandLb: bwBandLb,
    strengthBandLb: strengthBandLb,
    persistWeeks: persistWeeks,
  );
}

// ---------------------------------------------------------------------------
// Guarded refit (±50% drift guard)
// ---------------------------------------------------------------------------

/// The adjustments a refit applies. Multiplicative scales on the
/// capacity gain terms (a, b) and an additive maintenance offset; all
/// identity when nothing moved.
class RefitResult {
  final double aScale, bScale;
  final double maintenanceOffsetKcal;

  /// Human-readable "what moved" fragments (empty = nothing).
  final List<String> moved;

  const RefitResult({
    this.aScale = 1,
    this.bScale = 1,
    this.maintenanceOffsetKcal = 0,
    this.moved = const [],
  });

  bool get any => moved.isNotEmpty;

  /// Applies the scales to a params copy (the drift guard already
  /// bounded them).
  Sim2Params apply(Sim2Params p) {
    final out = p.copy();
    out.a *= aScale;
    out.b *= bScale;
    return out;
  }
}

/// Computes the guarded refit from a tracking result. Strength: the
/// observed vs predicted index PROGRESSION over the window (last −
/// first check) sets a common scale on a and b, clamped to
/// [minScale]..[maxScale] (±50% of fitted — the existing drift guard);
/// a near-flat predicted progression (< [minSlopeLb] over the window)
/// refuses to scale (ratio unidentified) and falls back to no-op.
/// Bodyweight: the mean weekly rate error becomes a maintenance
/// offset (× 3500/7), clamped to ±[maxMaintenanceOffsetKcal].
RefitResult guardedRefit(
  ForecastCalibration cal, {
  double minScale = 0.5,
  double maxScale = 1.5,
  double maxMaintenanceOffsetKcal = 500,
  double minSlopeLb = 4,
}) {
  var aScale = 1.0, bScale = 1.0, offset = 0.0;
  final moved = <String>[];

  if (cal.strengthPersistent && cal.strength.length >= 2) {
    final predDelta =
        cal.strength.last.predicted - cal.strength.first.predicted;
    final actDelta = cal.strength.last.actual - cal.strength.first.actual;
    if (predDelta.abs() >= minSlopeLb) {
      final ratio = (actDelta / predDelta).clamp(minScale, maxScale);
      if ((ratio - 1).abs() > 0.01) {
        aScale = ratio;
        bScale = ratio;
        moved.add('capacity gain ×${ratio.toStringAsFixed(2)}');
      }
    }
  }

  if (cal.bwPersistent && cal.bw.length >= 2) {
    final weeks = cal.bw.length - 1;
    final predRate = (cal.bw.last.predicted - cal.bw.first.predicted) / weeks;
    final actRate = (cal.bw.last.actual - cal.bw.first.actual) / weeks;
    final raw = (predRate - actRate) * 3500 / 7;
    offset = raw.clamp(-maxMaintenanceOffsetKcal, maxMaintenanceOffsetKcal);
    if (offset.abs() >= 25) {
      moved.add('maintenance ${offset >= 0 ? '+' : ''}'
          '${offset.round()} kcal');
    } else {
      offset = 0;
    }
  }

  return RefitResult(
    aScale: aScale,
    bScale: bScale,
    maintenanceOffsetKcal: offset,
    moved: moved,
  );
}

// ---------------------------------------------------------------------------
// forecast_meta tab codec (key/value; REPLACE-ALL nightly)
// ---------------------------------------------------------------------------

const String forecastMetaTabName = 'forecast_meta';
const List<String> forecastMetaHeaders = ['key', 'value'];

/// One recalibration event ("what moved" on a date).
class RecalEvent {
  final DateTime date;
  final String what;

  const RecalEvent(this.date, this.what);

  Map<String, Object?> toJson() => {'date': _ymd(date), 'what': what};

  static RecalEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    final d = DateTime.tryParse('${j['date']}');
    final w = j['what']?.toString();
    if (d == null || w == null) return null;
    return RecalEvent(DateTime.utc(d.year, d.month, d.day), w);
  }
}

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The nightly forecast metadata: the nutrition inputs the trajectory
/// ran on, tracking state, and the (guarded) refit currently in force.
class ForecastMeta {
  final DateTime? generatedAt;
  final double? maintenanceKcal, maintenanceBandKcal;
  final String? maintenanceMethod;
  final int? maintenancePairedDays;
  final double? intake14Kcal, protein14G, carbs14G;
  final double? rProjectedLbWk;

  /// 'on' (tracking, no adjustment in force) or 'adjusted'.
  final String tracking;
  final double aScale, bScale, maintenanceOffsetKcal;

  /// Newest-first recal events (capped at [maxEvents] on write).
  final List<RecalEvent> events;

  static const maxEvents = 8;

  const ForecastMeta({
    this.generatedAt,
    this.maintenanceKcal,
    this.maintenanceBandKcal,
    this.maintenanceMethod,
    this.maintenancePairedDays,
    this.intake14Kcal,
    this.protein14G,
    this.carbs14G,
    this.rProjectedLbWk,
    this.tracking = 'on',
    this.aScale = 1,
    this.bScale = 1,
    this.maintenanceOffsetKcal = 0,
    this.events = const [],
  });

  bool get adjusted => tracking == 'adjusted';

  RecalEvent? get lastEvent => events.isEmpty ? null : events.first;

  /// key/value rows (no header) for the REPLACE-ALL write.
  List<List<Object?>> toRows() => [
        if (generatedAt != null)
          ['generated_at', generatedAt!.toIso8601String()],
        if (maintenanceKcal != null)
          ['maintenance_kcal', maintenanceKcal!.round()],
        if (maintenanceBandKcal != null)
          ['maintenance_band_kcal', maintenanceBandKcal!.round()],
        if (maintenanceMethod != null)
          ['maintenance_method', maintenanceMethod],
        if (maintenancePairedDays != null)
          ['maintenance_paired_days', maintenancePairedDays],
        if (intake14Kcal != null) ['intake_14d_kcal', intake14Kcal!.round()],
        if (protein14G != null) ['protein_14d_g', protein14G!.round()],
        if (carbs14G != null) ['carbs_14d_g', carbs14G!.round()],
        if (rProjectedLbWk != null)
          ['r_projected_lb_wk', double.parse(rProjectedLbWk!.toStringAsFixed(3))],
        ['tracking', tracking],
        ['a_scale', double.parse(aScale.toStringAsFixed(4))],
        ['b_scale', double.parse(bScale.toStringAsFixed(4))],
        ['maintenance_offset_kcal', maintenanceOffsetKcal.round()],
        [
          'events_json',
          jsonEncode([
            for (final e in events.take(maxEvents)) e.toJson(),
          ]),
        ],
      ];

  /// Decodes a raw tab (header + key/value rows). Unknown keys are
  /// ignored; malformed values degrade to null/defaults — never throws.
  static ForecastMeta fromTab(List<List<Object?>> tab) {
    final kv = <String, String>{};
    for (final r in tab.skip(1)) {
      if (r.isEmpty) continue;
      final k = r[0]?.toString().trim() ?? '';
      if (k.isEmpty) continue;
      kv[k] = r.length > 1 ? (r[1]?.toString() ?? '') : '';
    }
    double? d(String k) => double.tryParse(kv[k] ?? '');
    final events = <RecalEvent>[];
    final rawEvents = kv['events_json'];
    if (rawEvents != null && rawEvents.isNotEmpty) {
      try {
        final list = jsonDecode(rawEvents);
        if (list is List) {
          for (final e in list) {
            final ev = RecalEvent.fromJson(e);
            if (ev != null) events.add(ev);
          }
        }
      } catch (_) {/* malformed events degrade to empty */}
    }
    return ForecastMeta(
      generatedAt: DateTime.tryParse(kv['generated_at'] ?? ''),
      maintenanceKcal: d('maintenance_kcal'),
      maintenanceBandKcal: d('maintenance_band_kcal'),
      maintenanceMethod: kv['maintenance_method'],
      maintenancePairedDays: d('maintenance_paired_days')?.round(),
      intake14Kcal: d('intake_14d_kcal'),
      protein14G: d('protein_14d_g'),
      carbs14G: d('carbs_14d_g'),
      rProjectedLbWk: d('r_projected_lb_wk'),
      tracking: (kv['tracking'] ?? 'on') == 'adjusted' ? 'adjusted' : 'on',
      aScale: d('a_scale') ?? 1,
      bScale: d('b_scale') ?? 1,
      maintenanceOffsetKcal: d('maintenance_offset_kcal') ?? 0,
      events: events,
    );
  }
}

/// Merges tonight's refit into the carried-forward meta: a NEW
/// adjustment (moved non-empty) prepends an event (deduped by
/// date+what) and flips tracking to 'adjusted'; no adjustment keeps
/// the event history but reports the refit's identity scales (the
/// refit is recomputed nightly from the trailing window — it is not
/// cumulative, by design: yesterday's scale times today's would
/// compound past the drift guard).
ForecastMeta mergeRecalibration({
  required ForecastMeta previous,
  required RefitResult refit,
  required DateTime today,
}) {
  final events = [...previous.events];
  if (refit.any) {
    final what = refit.moved.join(', ');
    final day = DateTime.utc(today.year, today.month, today.day);
    final dup = events.any((e) => e.date == day && e.what == what);
    if (!dup) events.insert(0, RecalEvent(day, what));
  }
  return ForecastMeta(
    generatedAt: previous.generatedAt,
    maintenanceKcal: previous.maintenanceKcal,
    maintenanceBandKcal: previous.maintenanceBandKcal,
    maintenanceMethod: previous.maintenanceMethod,
    maintenancePairedDays: previous.maintenancePairedDays,
    intake14Kcal: previous.intake14Kcal,
    protein14G: previous.protein14G,
    carbs14G: previous.carbs14G,
    rProjectedLbWk: previous.rProjectedLbWk,
    tracking: refit.any ? 'adjusted' : 'on',
    aScale: refit.aScale,
    bScale: refit.bScale,
    maintenanceOffsetKcal: refit.maintenanceOffsetKcal,
    events: events.take(ForecastMeta.maxEvents).toList(),
  );
}

/// Observed weekly index totals (SBD e1rm sum, carry-forward) from
/// sim_fit's WeeklySeries shape — passed as parallel lists to stay
/// import-light: [mondays] with per-lift carry-forward e1rm values.
Map<DateTime, double> observedIndexTotals({
  required List<DateTime> mondays,
  required List<double?> squat,
  required List<double?> bench,
  required List<double?> deadlift,
}) {
  final out = <DateTime, double>{};
  final n = min(mondays.length, min(squat.length, min(bench.length, deadlift.length)));
  for (var i = 0; i < n; i++) {
    final s = squat[i], b = bench[i], d = deadlift[i];
    if (s == null || b == null || d == null) continue;
    final m = mondays[i];
    out[DateTime.utc(m.year, m.month, m.day)] = s + b + d;
  }
  return out;
}
