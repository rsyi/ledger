/// Wilks (SBD) strength score — WILKS-2020 male coefficients.
///
/// Classic 3-lift Wilks: total = squat + bench + deadlift ONLY. The
/// app's `pl_total` is a 4-lift sum (it includes press), so it is NOT
/// comparable to powerlifting references — this metric is, and the UI
/// labels it "Wilks (SBD)" to make the distinction explicit.
///
/// Weekly cadence (ISO weeks keyed by Monday, matching the §2.5
/// rollup):
///   • per lift, the week's value = best capped e1RM (Epley, reps
///     capped at 12 — the same [epleyE1rm] expression used everywhere)
///     over sets logged that week with reps <= 5 and weight > 0;
///     when a lift wasn't trained that week the last known weekly
///     value carries forward (the maintenance cut trains each lift
///     weekly, so carries stay short);
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
    show StrengthRow, WeightRow, epleyE1rm, mainLiftByExercise, mondayOf;

/// Exact lb → kg factor (international avoirdupois pound).
const double kgPerLb = 0.45359237;

/// The classic powerlifting three: the lifts a Wilks total sums.
const List<String> wilksLifts = ['squat', 'bench', 'deadlift'];

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

/// One weekly Wilks point.
class WilksWeek {
  /// The ISO week's Monday.
  final DateTime weekStart;
  final double wilks;

  /// SBD total in lbs (best-of-week capped e1RMs, carries included).
  final double totalLbs;

  /// The week's bodyweight reference in lbs (7-day average, possibly
  /// carried from an earlier week).
  final double bodyweightLbs;

  /// Lifts whose value this week is carried forward (not trained with
  /// a qualifying reps<=5 set this week).
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
List<WilksWeek> weeklyWilksSeries(
  List<StrengthRow> strengthRows,
  List<WeightRow> weighIns, {
  DateTime? through,
}) {
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);

  // Best qualifying e1RM per (week Monday, lift).
  final bestByWeek = <DateTime, Map<String, double>>{};
  for (final r in strengthRows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || !wilksLifts.contains(lift)) continue;
    if (r.reps <= 0 || r.reps > 5 || r.weight <= 0) continue;
    final wk = mondayOf(r.date);
    final e = epleyE1rm(r.weight, r.reps);
    final m = bestByWeek[wk] ??= {};
    if ((m[lift] ?? 0) < e) m[lift] = e;
  }

  // Weekly bodyweight: mean of the daily series Mon..Sun.
  final bwSum = <DateTime, double>{};
  final bwN = <DateTime, int>{};
  for (final w in weighIns) {
    final wk = mondayOf(w.date);
    bwSum[wk] = (bwSum[wk] ?? 0) + w.weightLbs;
    bwN[wk] = (bwN[wk] ?? 0) + 1;
  }

  final mondays = <DateTime>{...bestByWeek.keys, ...bwSum.keys};
  if (mondays.isEmpty) return const [];
  final sorted = mondays.toList()..sort();
  final first = sorted.first;
  var last = sorted.last;
  if (through != null) {
    final t = mondayOf(day(through));
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

  /// SBD total in lbs (best-of-month capped e1RMs, carries included).
  final double totalLbs;

  /// The month's bodyweight reference in lbs — mean of the month's
  /// weigh-ins, possibly carried from an earlier month ([bwCarried]).
  final double bodyweightLbs;

  /// Lifts whose value this month is carried forward (no qualifying
  /// reps<=5 set this month).
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
}) {
  DateTime monthOf(DateTime d) => DateTime(d.year, d.month);

  // Best qualifying e1RM per (month, lift).
  final bestByMonth = <DateTime, Map<String, double>>{};
  for (final r in strengthRows) {
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || !wilksLifts.contains(lift)) continue;
    if (r.reps <= 0 || r.reps > 5 || r.weight <= 0) continue;
    final mo = monthOf(r.date);
    final e = epleyE1rm(r.weight, r.reps);
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
