/// nutrition_model.dart — NUTRITION AS THE FORECAST INPUT (user
/// directive 2026-09-28: "remove this whole lever-based computation …
/// the only lever really be based on my caloric intake — my carbs, my
/// protein, and my total caloric intake (from macrofactor)").
///
/// The forecast's bodyweight rate r and protein dial P are DERIVED from
/// actual Macrofactor logging instead of scenario dials. Pure Dart —
/// no Flutter, no IO; consumed by the Plan tab's forecast section and
/// the nightly forecast writer (tool/program_status_update.dart).
///
/// METHOD (the documented adaptive-maintenance estimate):
///  * Day aggregation: meals rows (Macrofactor → Health Connect →
///    meals view) sum per calendar day. A day counts as LOGGED only
///    when its calorie total ≥ [completeDayKcalFloor] — Macrofactor
///    exports whole days, so a tiny total means a partial/failed
///    export; days with NO rows are missing data, never zero.
///  * Weight trend: the 7-day trailing average of daily weigh-ins
///    (program_observed.sevenDayAvgSeries — the same series every
///    other surface uses). Pairing needs a trend value on EXACTLY day
///    d and day d+1 — a missing weigh-in day simply drops the pair
///    (carrying values forward would fabricate zero-delta days and
///    bias maintenance toward intake).
///  * Adaptive maintenance over the trailing [maintenanceWindowDays]:
///    each logged day d with trend at d and d+1 contributes an implied
///    maintenance sample
///        m_d = kcal_d − 3500 · (trend_{d+1} − trend_d)
///    (energy balance at 3500 kcal/lb). With ≥ [regressionMinDays]
///    pairs the estimate instead comes from the OLS regression
///    ΔW_d = α + β·kcal_d (maintenance = −α/β) when the fitted β lands
///    inside a physiologically sane band around 1/3500 (0.5–2×);
///    otherwise — and always below the threshold — the fixed-slope
///    mean of m_d is used. Uncertainty band = 2·SD(m_d)/√n, floored at
///    [minBandKcal]: small samples are HONESTLY wide.
///  * Fewer than [minPairedDays] pairs → null estimate; callers fall
///    back to the program's declared block rate and say so.
///  * Projection: r = (14-day avg intake − maintenance)/3500 × 7
///    lb/wk; protein/carbs are 14-day averages. The ONE what-if lever
///    is a calorie delta: r shifts by delta/3500×7 and protein/carbs
///    scale proportionally with total intake (macro composition
///    assumed stable under small deltas — a documented approximation).
library;

import 'dart:math';

import 'program_metrics.dart' show WeightRow;
import 'program_observed.dart' show sevenDayAvgSeries;
import 'recomp_review.dart' show MealRow;

/// Below this many kcal a day is treated as a partial/failed export,
/// not a real intake day.
const double completeDayKcalFloor = 800;

/// Trailing window the maintenance estimate runs on.
const int maintenanceWindowDays = 28;

/// Minimum paired days for ANY estimate (below → null, honest "no
/// data").
const int minPairedDays = 5;

/// Paired days needed before the free-slope regression is trusted.
const int regressionMinDays = 21;

/// The uncertainty band never reports tighter than this.
const double minBandKcal = 100;

/// kcal per lb of tissue (the energy-balance constant, also the sim's).
const double kcalPerLb = 3500;

// ---------------------------------------------------------------------------
// Day aggregation
// ---------------------------------------------------------------------------

/// One calendar day of logged nutrition (sums over that day's meals).
class NutritionDay {
  final DateTime day; // UTC midnight
  final double kcal, proteinG, carbsG, fatG;

  const NutritionDay({
    required this.day,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });
}

DateTime _utcDay(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// Sums meals per calendar day (all rows; the completeness floor is
/// applied by consumers via [isLoggedDay]). Ascending by day.
List<NutritionDay> nutritionDays(Iterable<MealRow> meals) {
  final kcal = <DateTime, double>{};
  final protein = <DateTime, double>{};
  final carbs = <DateTime, double>{};
  final fat = <DateTime, double>{};
  for (final m in meals) {
    final d = _utcDay(m.eatenAt);
    kcal[d] = (kcal[d] ?? 0) + (m.calories ?? 0);
    protein[d] = (protein[d] ?? 0) + (m.proteinG ?? 0);
    carbs[d] = (carbs[d] ?? 0) + (m.carbsG ?? 0);
    fat[d] = (fat[d] ?? 0) + (m.fatG ?? 0);
  }
  final days = kcal.keys.toList()..sort();
  return [
    for (final d in days)
      NutritionDay(
        day: d,
        kcal: kcal[d]!,
        proteinG: protein[d]!,
        carbsG: carbs[d]!,
        fatG: fat[d]!,
      ),
  ];
}

/// A day whose calorie total clears the completeness floor.
bool isLoggedDay(NutritionDay d) => d.kcal >= completeDayKcalFloor;

/// Raw meals-view records (as `repo.list()` returns them) → MealRows.
/// Rows without a parseable `eaten_at` are skipped.
List<MealRow> mealRowsFromRecords(Iterable<Map<String, Object?>> records) {
  double? num_(Object? v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
  final out = <MealRow>[];
  for (final r in records) {
    final raw = r['eaten_at'];
    final d = raw is DateTime ? raw : DateTime.tryParse(raw?.toString() ?? '');
    if (d == null) continue;
    out.add(MealRow(
      eatenAt: d,
      calories: num_(r['calories']),
      proteinG: num_(r['protein_g']),
      carbsG: num_(r['carbs_g']),
      fatG: num_(r['fat_g']),
    ));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Window averages
// ---------------------------------------------------------------------------

/// Averages over the LOGGED days inside a trailing window.
class NutritionAvg {
  final int loggedDays; // days that cleared the floor
  final int windowDays; // the window they were drawn from
  final double kcal, proteinG, carbsG;

  const NutritionAvg({
    required this.loggedDays,
    required this.windowDays,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
  });
}

/// Average intake over the logged days in (today − window, today].
/// Null when NO day in the window cleared the floor.
NutritionAvg? nutritionWindowAvg(
  List<NutritionDay> days, {
  required DateTime today,
  required int windowDays,
}) {
  final end = _utcDay(today);
  final start = end.subtract(Duration(days: windowDays - 1));
  final inWindow = [
    for (final d in days)
      if (!d.day.isBefore(start) && !d.day.isAfter(end) && isLoggedDay(d)) d,
  ];
  if (inWindow.isEmpty) return null;
  double avg(double Function(NutritionDay) f) =>
      inWindow.map(f).reduce((a, b) => a + b) / inWindow.length;
  return NutritionAvg(
    loggedDays: inWindow.length,
    windowDays: windowDays,
    kcal: avg((d) => d.kcal),
    proteinG: avg((d) => d.proteinG),
    carbsG: avg((d) => d.carbsG),
  );
}

// ---------------------------------------------------------------------------
// Adaptive maintenance
// ---------------------------------------------------------------------------

/// The adaptive maintenance estimate (see the library method note).
class MaintenanceEstimate {
  final double kcal;

  /// ± band, 2·SD(implied samples)/√n floored at [minBandKcal].
  final double bandKcal;
  final int pairedDays;

  /// 'regression' (OLS, sane β) or 'energy_balance' (fixed 1/3500).
  final String method;

  const MaintenanceEstimate({
    required this.kcal,
    required this.bandKcal,
    required this.pairedDays,
    required this.method,
  });
}

/// Estimates maintenance from logged intake vs the weigh-in trend.
/// Null when fewer than [minPairedDays] (kcal, Δtrend) pairs exist in
/// the window — the caller must fall back and SAY so.
MaintenanceEstimate? estimateMaintenance({
  required List<NutritionDay> days,
  required List<WeightRow> weighIns,
  required DateTime today,
  int windowDays = maintenanceWindowDays,
}) {
  if (weighIns.isEmpty) return null;
  // Trend lookup: 7d trailing average, exact days only (see the
  // library note — carry-forward would fabricate zero-delta pairs).
  final trend = sevenDayAvgSeries(weighIns);
  final byDay = {for (final w in trend) _utcDay(w.date): w.weightLbs};
  double? trendAt(DateTime d) => byDay[d];

  final end = _utcDay(today);
  final start = end.subtract(Duration(days: windowDays - 1));
  final xs = <double>[]; // kcal_d
  final ys = <double>[]; // trend_{d+1} − trend_d, lb
  for (final d in days) {
    if (d.day.isBefore(start) || d.day.isAfter(end) || !isLoggedDay(d)) {
      continue;
    }
    final t0 = trendAt(d.day);
    final t1 = trendAt(d.day.add(const Duration(days: 1)));
    if (t0 == null || t1 == null) continue;
    xs.add(d.kcal);
    ys.add(t1 - t0);
  }
  final n = xs.length;
  if (n < minPairedDays) return null;

  // Implied per-day maintenance samples (fixed physiological slope).
  final samples = [for (var i = 0; i < n; i++) xs[i] - kcalPerLb * ys[i]];
  final mean = samples.reduce((a, b) => a + b) / n;
  final varSum = samples.fold<double>(0, (s, v) => s + (v - mean) * (v - mean));
  final sd = n > 1 ? sqrt(varSum / (n - 1)) : 0.0;
  final band = max(minBandKcal, 2 * sd / sqrt(n));

  // Free-slope regression only with enough data AND a sane β.
  if (n >= regressionMinDays) {
    final mx = xs.reduce((a, b) => a + b) / n;
    final my = ys.reduce((a, b) => a + b) / n;
    var sxx = 0.0, sxy = 0.0;
    for (var i = 0; i < n; i++) {
      sxx += (xs[i] - mx) * (xs[i] - mx);
      sxy += (xs[i] - mx) * (ys[i] - my);
    }
    if (sxx > 0) {
      final beta = sxy / sxx;
      final alpha = my - beta * mx;
      const b0 = 1 / kcalPerLb;
      if (beta >= 0.5 * b0 && beta <= 2 * b0) {
        return MaintenanceEstimate(
          kcal: -alpha / beta,
          bandKcal: band,
          pairedDays: n,
          method: 'regression',
        );
      }
    }
  }
  return MaintenanceEstimate(
    kcal: mean,
    bandKcal: band,
    pairedDays: n,
    method: 'energy_balance',
  );
}

// ---------------------------------------------------------------------------
// The forecast-facing summary (+ the ONE what-if lever)
// ---------------------------------------------------------------------------

/// Everything the forecast needs from nutrition, plus the calorie-delta
/// what-if. Immutable; [withDelta] returns a shifted copy.
class NutritionForecast {
  final NutritionAvg? avg7, avg14;
  final MaintenanceEstimate? maintenance;

  /// The ONE lever: a what-if kcal/day shift applied to the PROJECTION
  /// only (never to the displayed actuals).
  final double calorieDelta;

  const NutritionForecast({
    required this.avg7,
    required this.avg14,
    required this.maintenance,
    this.calorieDelta = 0,
  });

  /// True when the model can project (maintenance + 14d intake known).
  bool get canProject => maintenance != null && avg14 != null;

  /// Intake the projection runs on (14d average + delta).
  double? get projectedIntakeKcal =>
      avg14 == null ? null : avg14!.kcal + calorieDelta;

  /// r = (intake − maintenance)/3500 × 7 lb/wk.
  double? get rProjectedLbWk => !canProject
      ? null
      : (projectedIntakeKcal! - maintenance!.kcal) / kcalPerLb * 7;

  /// r at delta = 0 (the current-intake rate, for the card).
  double? get rCurrentLbWk =>
      !canProject ? null : (avg14!.kcal - maintenance!.kcal) / kcalPerLb * 7;

  double? get _scale => avg14 == null || avg14!.kcal <= 0
      ? null
      : (avg14!.kcal + calorieDelta) / avg14!.kcal;

  /// Projected macros: proportional to total intake under the delta.
  double? get projectedProteinG =>
      _scale == null ? null : avg14!.proteinG * _scale!;
  double? get projectedCarbsG =>
      _scale == null ? null : avg14!.carbsG * _scale!;

  /// Protein dial for the sim's §5 pf() — g/lb at [bwLb].
  double? proteinGPerLb(double? bwLb) =>
      projectedProteinG == null || bwLb == null || bwLb <= 0
          ? null
          : projectedProteinG! / bwLb;

  NutritionForecast withDelta(double delta) => NutritionForecast(
        avg7: avg7,
        avg14: avg14,
        maintenance: maintenance,
        calorieDelta: delta,
      );
}

/// Assembles the forecast-facing nutrition summary from raw meals +
/// weigh-ins. Degrades field by field (null = honest "no data").
NutritionForecast buildNutritionForecast({
  required List<MealRow> meals,
  required List<WeightRow> weighIns,
  required DateTime today,
  double calorieDelta = 0,
}) {
  final days = nutritionDays(meals);
  return NutritionForecast(
    avg7: nutritionWindowAvg(days, today: today, windowDays: 7),
    avg14: nutritionWindowAvg(days, today: today, windowDays: 14),
    maintenance:
        estimateMaintenance(days: days, weighIns: weighIns, today: today),
    calorieDelta: calorieDelta,
  );
}
