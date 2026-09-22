/// Wilks (SBD) strength score — WILKS-2020 male coefficients.
///
/// Classic 3-lift Wilks: total = squat + bench + deadlift ONLY. The
/// app's `pl_total` is a 4-lift sum (it includes press), so it is NOT
/// comparable to powerlifting references — this metric is, and the UI
/// labels it "Wilks (SBD, actual lifts)" to make the distinction
/// explicit.
///
/// TWO BASES ([WilksBasis]), one shared engine:
///
///   • [WilksBasis.actualMax] — THE DISPLAY STANDARD (user 2026-09-22:
///     "my wilks should be tracked against my absolute max score for
///     wilks ever. That should be the benchmark, but done against
///     actually max lift numbers, not e1RM"). Per period per lift the
///     value is the heaviest weight ACTUALLY lifted over sets with any
///     reps >= 1 and weight > 0 — a 405×2 counts as 405: it is a
///     lifted number, not an estimate, so the rep count neither
///     inflates it (no Epley) nor disqualifies it (no reps cap).
///     The all-time max of the monthly series is the benchmark the
///     current score is tracked against ([wilksBenchmark]).
///   • [WilksBasis.e1rm] — the original estimate basis: best capped
///     e1RM (Epley, reps capped at 12 — the same [epleyE1rm]
///     expression used everywhere) over sets with reps <= 5 and
///     weight > 0. Retired from display 2026-09-22; kept for
///     comparisons/tests. (The §2.5 effort-grading reference machinery
///     in program_metrics.dart is separate and untouched.)
///
/// Weekly cadence (ISO weeks keyed by Monday, matching the §2.5
/// rollup):
///   • per lift, the week's value = the basis' best qualifying number
///     over sets logged that week; when a lift wasn't trained that
///     week the last known weekly value carries forward (the
///     maintenance cut trains each lift weekly, so carries stay
///     short);
///   • bodyweight = that ISO week's 7-day average — the mean of the
///     daily weigh-in series over Mon..Sun — carried forward across
///     weeks with no weigh-ins;
///   • wilks = total_kg × coeff(bw_kg).
///
/// Monthly cadence ([monthlyWilksSeries], the trend chart — user
/// 2026-09-21: "month-to-month measurements, rather than week-to-week,
/// since I have deload weeks"): same per-lift best-of rule but over the
/// CALENDAR MONTH, so a deload week inside a month can never drag the
/// point (the month's heaviest qualifying set wins). Bodyweight = the
/// mean of the month's weigh-ins, carried forward through months with
/// no weigh-in at all ([WilksMonth.bwCarried]) — this is what lets the
/// series run back through sparse weigh-in eras instead of truncating.
///
/// WILKS-2020 ("Wilks-2", March 2020 revision) male constants,
/// verified 2026-09-21 against
/// https://en.wikipedia.org/wiki/Wilks_coefficient — the revision
/// rebased the numerator 500 → 600 and refit the polynomial:
///
///   coeff(x) = 600 / (a + b·x + c·x² + d·x³ + e·x⁴ + f·x⁵)
///   x = bodyweight in kg
///   a =  47.46178854
///   b =   8.472061379
///   c =   0.07369410346
///   d =  -0.001395833811
///   e =   7.07665973070743e-6
///   f =  -1.20804336482315e-8
///
/// Pure Dart — no Flutter, no IO.
library;

import 'program_metrics.dart'
    show StrengthRow, WeightRow, epleyE1rm, mainLiftByExercise, weekStartOf;

/// Exact lb → kg factor (international avoirdupois pound).
const double kgPerLb = 0.45359237;

/// The classic powerlifting three: the lifts a Wilks total sums.
const List<String> wilksLifts = ['squat', 'bench', 'deadlift'];

/// Which per-set number a Wilks series is built from (library docs).
enum WilksBasis {
  /// Best capped e1RM over reps <= 5 sets — the retired estimate basis.
  e1rm,

  /// Heaviest weight actually lifted, any reps >= 1 — the display
  /// standard (405×2 counts as 405).
  actualMax,
}

/// The basis' qualifying value for one set, or null when the set does
/// not qualify. THE one place both series functions read a set.
double? _basisValue(StrengthRow r, WilksBasis basis) {
  if (r.weight <= 0 || r.reps <= 0) return null;
  switch (basis) {
    case WilksBasis.e1rm:
      if (r.reps > 5) return null;
      return epleyE1rm(r.weight, r.reps);
    case WilksBasis.actualMax:
      return r.weight;
  }
}

/// WILKS-2020 male coefficient at [bodyweightKg] (see library docs for
/// the constants and their source).
double wilks2020MaleCoeff(double bodyweightKg) {
  const a = 47.46178854;
  const b = 8.472061379;
  const c = 0.07369410346;
  const d = -0.001395833811;
  const e = 7.07665973070743e-6;
  const f = -1.20804336482315e-8;
  final x = bodyweightKg;
  // Horner form of a + bx + cx² + dx³ + ex⁴ + fx⁵.
  return 600 / (a + x * (b + x * (c + x * (d + x * (e + x * f)))));
}

/// Wilks points of ONE lift in lb at a bodyweight in lb:
/// weight_kg × coeff(bw_kg). The home STRENGTH card's per-lift
/// normalization (2026-09-22): a lift done at a heavier bodyweight is
/// worth fewer points, which is what makes an old fat-bulk PR
/// comparable to today's cut numbers.
double wilksPointsLb(double weightLbs, double bodyweightLbs) =>
    weightLbs * kgPerLb * wilks2020MaleCoeff(bodyweightLbs * kgPerLb);

/// Contemporaneous bodyweight (lbs) AS OF [date] — the same monthly
/// bodyweight machinery as [monthlyWilksSeries]: the mean of [date]'s
/// calendar-month weigh-ins (the WHOLE month, even weigh-ins after
/// [date] — a month is one bodyweight era here), else the nearest
/// EARLIER month's mean carried forward across gaps. Null when no
/// weigh-in exists in or before [date]'s month — never guesses.
///
/// This is what prices an all-time PR in Wilks points at the
/// bodyweight it was actually lifted at (contemporaneous bw), not at
/// today's.
double? contemporaneousBodyweightLbs(
  List<WeightRow> weighIns,
  DateTime date,
) {
  final target = DateTime(date.year, date.month);
  final sum = <DateTime, double>{};
  final n = <DateTime, int>{};
  for (final w in weighIns) {
    final mo = DateTime(w.date.year, w.date.month);
    if (mo.isAfter(target)) continue;
    sum[mo] = (sum[mo] ?? 0) + w.weightLbs;
    n[mo] = (n[mo] ?? 0) + 1;
  }
  if (sum.isEmpty) return null;
  final best = sum.keys.reduce((a, b) => a.isAfter(b) ? a : b);
  return sum[best]! / n[best]!;
}

/// One weekly Wilks point.
class WilksWeek {
  /// The week's start day (ISO Monday by default; the configured
  /// accounting week start when the series was keyed differently).
  final DateTime weekStart;
  final double wilks;

  /// SBD total in lbs (best-of-week per-lift values on the series'
  /// [WilksBasis], carries included).
  final double totalLbs;

  /// The week's bodyweight reference in lbs (7-day average, possibly
  /// carried from an earlier week).
  final double bodyweightLbs;

  /// Lifts whose value this week is carried forward (no qualifying set
  /// on the series' basis this week).
  final List<String> carried;

  const WilksWeek({
    required this.weekStart,
    required this.wilks,
    required this.totalLbs,
    required this.bodyweightLbs,
    this.carried = const [],
  });
}

/// Weekly Wilks series per the library-doc semantics. Points start at
/// the first week where all three lifts AND a bodyweight are known and
/// run contiguously through the last week with any input — or through
/// [through]'s week when that is later (so the current, not-yet-trained
/// week still gets a carried point). Empty when the inputs never cover
/// all three lifts plus a weigh-in.
///
/// [weekStartDay] keys the weeks (program.yaml v7 `week_start` —
/// saturday makes a Saturday PR count toward the CURRENT week's stat).
/// The monthly trend series below is untouched by the key.
///
/// [basis] selects the per-set number (library docs); the default is
/// the actual-max display standard.
List<WilksWeek> weeklyWilksSeries(
  List<StrengthRow> strengthRows,
  List<WeightRow> weighIns, {
  DateTime? through,
  int weekStartDay = DateTime.monday,
  WilksBasis basis = WilksBasis.actualMax,
}) {
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
  DateTime wk(DateTime d) => weekStartOf(d, weekStartDay);

  // Best qualifying value per (week start, lift).
  final bestByWeek = <DateTime, Map<String, double>>{};
  for (final r in strengthRows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || !wilksLifts.contains(lift)) continue;
    final e = _basisValue(r, basis);
    if (e == null) continue;
    final m = bestByWeek[wk(r.date)] ??= {};
    if ((m[lift] ?? 0) < e) m[lift] = e;
  }

  // Weekly bodyweight: mean of the daily series over the week.
  final bwSum = <DateTime, double>{};
  final bwN = <DateTime, int>{};
  for (final w in weighIns) {
    final k = wk(w.date);
    bwSum[k] = (bwSum[k] ?? 0) + w.weightLbs;
    bwN[k] = (bwN[k] ?? 0) + 1;
  }

  final mondays = <DateTime>{...bestByWeek.keys, ...bwSum.keys};
  if (mondays.isEmpty) return const [];
  final sorted = mondays.toList()..sort();
  final first = sorted.first;
  var last = sorted.last;
  if (through != null) {
    final t = wk(day(through));
    if (t.isAfter(last)) last = t;
  }

  final out = <WilksWeek>[];
  final lifts = <String, double>{}; // carried lift values
  double? bw;
  for (var m = first;
      !m.isAfter(last);
      m = DateTime(m.year, m.month, m.day + 7)) {
    final trained = bestByWeek[m] ?? const <String, double>{};
    lifts.addAll(trained);
    final n = bwN[m];
    if (n != null) bw = bwSum[m]! / n;
    if (bw == null || wilksLifts.any((l) => !lifts.containsKey(l))) {
      continue; // not computable yet — never guess
    }
    final totalLbs =
        wilksLifts.fold<double>(0, (sum, l) => sum + lifts[l]!);
    out.add(
      WilksWeek(
        weekStart: m,
        wilks: totalLbs * kgPerLb * wilks2020MaleCoeff(bw * kgPerLb),
        totalLbs: totalLbs,
        bodyweightLbs: bw,
        carried: [
          for (final l in wilksLifts)
            if (!trained.containsKey(l)) l,
        ],
      ),
    );
  }
  return out;
}

/// One monthly Wilks point.
class WilksMonth {
  /// First day of the calendar month.
  final DateTime monthStart;
  final double wilks;

  /// SBD total in lbs (best-of-month per-lift values on the series'
  /// [WilksBasis], carries included).
  final double totalLbs;

  /// The month's bodyweight reference in lbs — mean of the month's
  /// weigh-ins, possibly carried from an earlier month ([bwCarried]).
  final double bodyweightLbs;

  /// Lifts whose value this month is carried forward (no qualifying
  /// set on the series' basis this month).
  final List<String> carried;

  /// True when the month had no weigh-in and [bodyweightLbs] is the
  /// last known monthly mean carried forward.
  final bool bwCarried;

  const WilksMonth({
    required this.monthStart,
    required this.wilks,
    required this.totalLbs,
    required this.bodyweightLbs,
    this.carried = const [],
    this.bwCarried = false,
  });
}

/// Monthly Wilks series per the library-doc semantics (see "Monthly
/// cadence" above). Points start at the first calendar month where all
/// three lifts AND a bodyweight are known and run contiguously through
/// the last month with any input — or through [through]'s month when
/// that is later (so the current, not-yet-trained month still gets a
/// carried point). Empty when the inputs never cover all three lifts
/// plus a weigh-in.
List<WilksMonth> monthlyWilksSeries(
  List<StrengthRow> strengthRows,
  List<WeightRow> weighIns, {
  DateTime? through,
  WilksBasis basis = WilksBasis.actualMax,
}) {
  DateTime monthOf(DateTime d) => DateTime(d.year, d.month);

  // Best qualifying value per (month, lift).
  final bestByMonth = <DateTime, Map<String, double>>{};
  for (final r in strengthRows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || !wilksLifts.contains(lift)) continue;
    final e = _basisValue(r, basis);
    if (e == null) continue;
    final mo = monthOf(r.date);
    final m = bestByMonth[mo] ??= {};
    if ((m[lift] ?? 0) < e) m[lift] = e;
  }

  // Monthly bodyweight: mean of the month's weigh-ins.
  final bwSum = <DateTime, double>{};
  final bwN = <DateTime, int>{};
  for (final w in weighIns) {
    final mo = monthOf(w.date);
    bwSum[mo] = (bwSum[mo] ?? 0) + w.weightLbs;
    bwN[mo] = (bwN[mo] ?? 0) + 1;
  }

  final months = <DateTime>{...bestByMonth.keys, ...bwSum.keys};
  if (months.isEmpty) return const [];
  final sorted = months.toList()..sort();
  final first = sorted.first;
  var last = sorted.last;
  if (through != null) {
    final t = monthOf(through);
    if (t.isAfter(last)) last = t;
  }

  final out = <WilksMonth>[];
  final lifts = <String, double>{}; // carried lift values
  double? bw;
  for (var m = first; !m.isAfter(last); m = DateTime(m.year, m.month + 1)) {
    final trained = bestByMonth[m] ?? const <String, double>{};
    lifts.addAll(trained);
    final n = bwN[m];
    if (n != null) bw = bwSum[m]! / n;
    if (bw == null || wilksLifts.any((l) => !lifts.containsKey(l))) {
      continue; // not computable yet — never guess
    }
    final totalLbs =
        wilksLifts.fold<double>(0, (sum, l) => sum + lifts[l]!);
    out.add(
      WilksMonth(
        monthStart: m,
        wilks: totalLbs * kgPerLb * wilks2020MaleCoeff(bw * kgPerLb),
        totalLbs: totalLbs,
        bodyweightLbs: bw,
        carried: [
          for (final l in wilksLifts)
            if (!trained.containsKey(l)) l,
        ],
        bwCarried: n == null,
      ),
    );
  }
  return out;
}

/// The all-time best point of a monthly Wilks series — the BENCHMARK
/// the current score is tracked against (user 2026-09-22: "my wilks
/// should be tracked against my absolute max score for wilks ever").
/// Meaningful on the actual-max basis: best-ever done against actually
/// lifted numbers. Ties keep the EARLIEST month (that's when the mark
/// was first hit). Null for an empty series.
WilksMonth? wilksBenchmark(List<WilksMonth> series) {
  WilksMonth? best;
  for (final m in series) {
    if (best == null || m.wilks > best.wilks) best = m;
  }
  return best;
}
