/// Wilks (SBD) strength score — WILKS-2020 male coefficients.
///
/// Classic 3-lift Wilks: total = squat + bench + deadlift ONLY. The
/// app's `pl_total` ("est. total") is the same SBD sum since 2026-10-23
/// (user: "wilks and powerlifting total should be based on squat bench
/// deadlift only, not ohp" — it was a 4-lift sum incl. press before).
/// The strength header's two numbers + their breakdown sheet all read
/// ONE function, [currentStrengthTotal].
///
/// THREE BASES ([WilksBasis]), one shared engine:
///
///   • [WilksBasis.rpeE1rm] — THE DISPLAY STANDARD since 2026-10-12
///     (user: "RPE-adjusted e1RM — same estimate as the Lifts rows
///     (275×5 @ RPE 8.5 → ~332 squat). Reflects strength through 3–5-rep
///     wave weeks; consistent across Progress."). Per set the value is
///     [rpeAdjustedE1rm] — the SAME per-set estimator the Progress
///     Lifts rows ("recent e1RM (RPE-adj)", recentBestE1rm rpeAdjusted)
///     use: Epley over effective reps = reps + RIR (10 − RPE), total
///     capped at 12; no RPE → plain capped Epley. Warm-ups are excluded
///     by the shared working_sets.dart rule ([isWarmupSet]); only the
///     exact main-lift exercise names count (variants never do). Every
///     consumer — weekly stat + decomposition, monthly trend, its
///     benchmark, the phase-start reference/floor — reads the SAME
///     basis, so the verdict can't flip on a basis mismatch. The
///     heaviest set actually lifted rides along per lift
///     ([WilksWeek.liftTopSet]) as the secondary "lifted 275×5" line.
///   • [WilksBasis.actualMax] — the 2026-09-22..10-12 display standard
///     (user 2026-09-22:
///     "my wilks should be tracked against my absolute max score for
///     wilks ever. That should be the benchmark, but done against
///     actually max lift numbers, not e1RM"). Per period per lift the
///     value is the heaviest weight ACTUALLY lifted over sets with any
///     reps >= 1 and weight > 0 — a 405×2 counts as 405: it is a
///     lifted number, not an estimate, so the rep count neither
///     inflates it (no Epley) nor disqualifies it (no reps cap).
///     Retired from display 2026-10-12: the cut wave's 3–5-rep tops at
///     RPE 7–8.5 made "heaviest lifted" understate strength (275×5 @
///     8.5 read as a 275 squat). Kept for the sim_fit calibration
///     series + comparisons.
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
    show
        StrengthRow,
        WeightRow,
        epleyE1rm,
        mainLiftByExercise,
        rpeAdjustedE1rm,
        weekStartOf;
import 'working_sets.dart' show warmupIndices;

/// Exact lb → kg factor (international avoirdupois pound).
const double kgPerLb = 0.45359237;

/// The classic powerlifting three: the lifts a Wilks total sums.
const List<String> wilksLifts = ['squat', 'bench', 'deadlift'];

/// Which per-set number a Wilks series is built from (library docs).
enum WilksBasis {
  /// Best capped e1RM over reps <= 5 sets — the retired estimate basis.
  e1rm,

  /// Heaviest weight actually lifted, any reps >= 1 (405×2 counts as
  /// 405) — the 2026-09-22 display standard, retired 2026-10-12.
  actualMax,

  /// RPE-adjusted capped e1RM ([rpeAdjustedE1rm]) over non-warm-up
  /// sets — the display standard since 2026-10-12, the same estimate
  /// as the Progress Lifts rows.
  rpeE1rm,
}

/// The default basis every display consumer reads.
const WilksBasis defaultWilksBasis = WilksBasis.rpeE1rm;

/// The basis' qualifying value for one set, or null when the set does
/// not qualify. THE one place every series function reads a set.
/// [warmup]: the set is a warm-up per the shared working_sets rule
/// (only the rpeE1rm basis excludes them — a warm-up can never be the
/// heaviest set or a reps<=5 best on the older bases anyway).
double? _basisValue(StrengthRow r, WilksBasis basis, {bool warmup = false}) {
  if (r.weight <= 0 || r.reps <= 0) return null;
  switch (basis) {
    case WilksBasis.e1rm:
      if (r.reps > 5) return null;
      return epleyE1rm(r.weight, r.reps);
    case WilksBasis.actualMax:
      return r.weight;
    case WilksBasis.rpeE1rm:
      if (warmup) return null;
      return rpeAdjustedE1rm(r.weight, r.reps, r.rpe);
  }
}

/// Indices of the warm-up sets among [rows] by the SHARED rule
/// (working_sets.dart [warmupIndices]: tagged `warmup`, or an untagged
/// easy ramp set under 75% of the day's top / lighter than the day's
/// lightest rated set, same exercise). Only main SBD rows are fed — the
/// rule is per (day, exercise), so other exercises never interact.
Set<int> _warmups(List<StrengthRow> rows, WilksBasis basis) {
  if (basis != WilksBasis.rpeE1rm) return const {};
  final idx = <int>[];
  final recs = <Map<String, Object?>>[];
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null) continue;
    idx.add(i);
    recs.add({
      'date': r.date,
      'exercise': r.exercise,
      'weight': r.weight,
      'rpe': r.rpe,
      'set_type': r.setType,
    });
  }
  return {for (final j in warmupIndices(recs)) idx[j]};
}

/// One set's weight × reps — the "heaviest lifted" secondary line.
typedef LiftedSet = ({double weight, int reps});

/// Heaviest-weight tiebreak: more weight wins, then more reps.
bool _heavier(LiftedSet a, LiftedSet? b) =>
    b == null || a.weight > b.weight || (a.weight == b.weight && a.reps > b.reps);

/// Per lift in [lifts], the basis value of the most recent accounting
/// week (≤ [today]) in which the lift has a qualifying set — exactly the
/// per-lift values a [weeklyWilksSeries] week through [today] sums
/// (trained this week, or carried from the last trained week). [date]
/// is that week's start. Used by the strength header's "est. total" so
/// it sits on the same basis + numbers as the Wilks stat.
Map<String, ({double value, DateTime date})> estimatedMaxesAsOf(
  List<StrengthRow> strengthRows,
  DateTime today, {
  int weekStartDay = DateTime.monday,
  List<String> lifts = wilksLifts,
  WilksBasis basis = defaultWilksBasis,
}) => {
  for (final e in _estimatesAsOf(
    strengthRows,
    today,
    weekStartDay: weekStartDay,
    lifts: lifts,
    basis: basis,
  ).entries)
    e.key: (value: e.value.value, date: e.value.date),
};

/// [estimatedMaxesAsOf] plus the index (into the input list) of the set
/// each value comes from — ties keep the earlier set.
Map<String, ({double value, DateTime date, int index})> _estimatesAsOf(
  List<StrengthRow> strengthRows,
  DateTime today, {
  required int weekStartDay,
  required List<String> lifts,
  required WilksBasis basis,
}) {
  final end = DateTime(today.year, today.month, today.day + 1);
  final warm = _warmups(strengthRows, basis);
  final out = <String, ({double value, DateTime date, int index})>{};
  for (var i = 0; i < strengthRows.length; i++) {
    final r = strengthRows[i];
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || !lifts.contains(lift)) continue;
    if (!r.date.isBefore(end)) continue;
    final v = _basisValue(r, basis, warmup: warm.contains(i));
    if (v == null) continue;
    final wk = weekStartOf(r.date, weekStartDay);
    final cur = out[lift];
    if (cur == null ||
        wk.isAfter(cur.date) ||
        (wk == cur.date && v > cur.value)) {
      out[lift] = (value: v, date: wk, index: i);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// The strength header's "Wilks · est. total" (2026-10-23)
// ---------------------------------------------------------------------------

/// One SBD lift's CURRENT estimate inside [StrengthTotalBreakdown].
class LiftEstimate {
  /// squat | bench | deadlift.
  final String lift;

  /// The estimated 1RM (lbs) on the breakdown's basis — RPE-adjusted
  /// e1RM by default.
  final double e1rmLbs;

  /// The set the estimate comes from (its [StrengthRow.id] opens it in
  /// the timeline).
  final StrengthRow source;

  /// The lookback window: the accounting week the source set sits in —
  /// the most recent week (≤ today) with a qualifying set for this lift.
  final DateTime windowStart;
  final DateTime windowEnd; // inclusive

  /// True when [windowStart] is not the current accounting week (the
  /// lift wasn't trained yet this week; its value carries).
  final bool carried;

  const LiftEstimate({
    required this.lift,
    required this.e1rmLbs,
    required this.source,
    required this.windowStart,
    required this.windowEnd,
    required this.carried,
  });
}

/// Everything behind the strength header's "Wilks · est. total" — the
/// header chips AND their breakdown sheet both render THIS object, so
/// they can never diverge.
class StrengthTotalBreakdown {
  /// Present SBD lifts, in [wilksLifts] order.
  final List<LiftEstimate> lifts;

  /// SBD lifts with no qualifying set yet.
  final List<String> missing;

  /// Sum of the present lifts' estimates; null when none is present.
  final double? totalLbs;

  /// The bodyweight the coefficient uses: mean of the weigh-ins in the
  /// most recent accounting week (≤ today) that has any — the weekly
  /// Wilks series' 7-day average. Null without weigh-ins.
  final double? bodyweightLbs;

  /// That week ([bwWeekStart]) + the weigh-ins averaged: count and the
  /// first/last weigh-in dates.
  final DateTime? bwWeekStart;
  final int bwCount;
  final DateTime? bwFirst;
  final DateTime? bwLast;

  /// True when [bwWeekStart] is not the current week (carried).
  final bool bwCarried;

  /// WILKS-2020 male coefficient at [bodyweightLbs]; null without bw.
  final double? coeff;

  /// total_kg × coeff — null unless all three lifts AND a bodyweight.
  final double? wilks;

  const StrengthTotalBreakdown({
    required this.lifts,
    required this.missing,
    required this.totalLbs,
    this.bodyweightLbs,
    this.bwWeekStart,
    this.bwCount = 0,
    this.bwFirst,
    this.bwLast,
    this.bwCarried = false,
    this.coeff,
    this.wilks,
  });
}

/// THE strength-header computation: per SBD lift the current estimate
/// (= [estimatedMaxesAsOf]), their sum, the week's bodyweight
/// ([weeklyWilksSeries]' rule: the most recent week's weigh-in mean,
/// carried) and the Wilks. Rows/weigh-ins dated after [today] are
/// ignored. Matches `weeklyWilksSeries(..., through: today).last` on
/// histories without future-dated rows.
StrengthTotalBreakdown currentStrengthTotal(
  List<StrengthRow> strengthRows,
  List<WeightRow> weighIns,
  DateTime today, {
  int weekStartDay = DateTime.monday,
  WilksBasis basis = defaultWilksBasis,
}) {
  final thisWeek = weekStartOf(
    DateTime(today.year, today.month, today.day),
    weekStartDay,
  );
  final est = _estimatesAsOf(
    strengthRows,
    today,
    weekStartDay: weekStartDay,
    lifts: wilksLifts,
    basis: basis,
  );
  final lifts = [
    for (final l in wilksLifts)
      if (est[l] case final e?)
        LiftEstimate(
          lift: l,
          e1rmLbs: e.value,
          source: strengthRows[e.index],
          windowStart: e.date,
          windowEnd: DateTime(e.date.year, e.date.month, e.date.day + 6),
          carried: e.date != thisWeek,
        ),
  ];
  final total = lifts.isEmpty
      ? null
      : lifts.fold<double>(0, (s, l) => s + l.e1rmLbs);

  // Bodyweight: the latest week (≤ this week) with weigh-ins.
  final end = DateTime(today.year, today.month, today.day + 1);
  DateTime? bwWeek;
  for (final w in weighIns) {
    if (!w.date.isBefore(end)) continue;
    final k = weekStartOf(w.date, weekStartDay);
    if (bwWeek == null || k.isAfter(bwWeek)) bwWeek = k;
  }
  double? bw;
  var n = 0;
  DateTime? first, last;
  if (bwWeek != null) {
    var sum = 0.0;
    for (final w in weighIns) {
      if (!w.date.isBefore(end)) continue;
      if (weekStartOf(w.date, weekStartDay) != bwWeek) continue;
      sum += w.weightLbs;
      n++;
      if (first == null || w.date.isBefore(first)) first = w.date;
      if (last == null || w.date.isAfter(last)) last = w.date;
    }
    bw = sum / n;
  }
  final coeff = bw == null ? null : wilks2020MaleCoeff(bw * kgPerLb);
  return StrengthTotalBreakdown(
    lifts: lifts,
    missing: [
      for (final l in wilksLifts)
        if (!est.containsKey(l)) l,
    ],
    totalLbs: total,
    bodyweightLbs: bw,
    bwWeekStart: bwWeek,
    bwCount: n,
    bwFirst: first,
    bwLast: last,
    bwCarried: bwWeek != null && bwWeek != thisWeek,
    coeff: coeff,
    wilks: coeff == null || lifts.length < wilksLifts.length
        ? null
        : total! * kgPerLb * coeff,
  );
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

  /// Per-lift values (lbs) the week's total sums, carries included —
  /// keys are [wilksLifts]. Empty on hand-rolled weeks that never set
  /// it; series-built weeks always carry all three (2026-09-25, the
  /// hero sheet's decomposition source).
  final Map<String, double> liftLbs;

  /// Per lift, the start of the week its value was ACTUALLY lifted:
  /// [weekStart] itself for lifts trained this week, an earlier week
  /// for carries — what lets the decomposition say "carried from
  /// Sep 14" instead of a bare "carried".
  final Map<String, DateTime> liftTrainedWeek;

  /// Per lift, the heaviest set ACTUALLY lifted (weight × reps, warm-ups
  /// included — it's a lifted number) in the week its [liftLbs] value
  /// comes from (carried with it) — the secondary "lifted 275×5" line
  /// under an estimate-basis value (2026-10-12).
  final Map<String, LiftedSet> liftTopSet;

  const WilksWeek({
    required this.weekStart,
    required this.wilks,
    required this.totalLbs,
    required this.bodyweightLbs,
    this.carried = const [],
    this.liftLbs = const {},
    this.liftTrainedWeek = const {},
    this.liftTopSet = const {},
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
/// the RPE-adjusted e1RM display standard ([defaultWilksBasis]).
List<WilksWeek> weeklyWilksSeries(
  List<StrengthRow> strengthRows,
  List<WeightRow> weighIns, {
  DateTime? through,
  int weekStartDay = DateTime.monday,
  WilksBasis basis = defaultWilksBasis,
}) {
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
  DateTime wk(DateTime d) => weekStartOf(d, weekStartDay);

  // Best qualifying value per (week start, lift) + the heaviest set
  // actually lifted that week (the secondary line).
  final warm = _warmups(strengthRows, basis);
  final bestByWeek = <DateTime, Map<String, double>>{};
  final topByWeek = <DateTime, Map<String, LiftedSet>>{};
  for (var i = 0; i < strengthRows.length; i++) {
    final r = strengthRows[i];
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || !wilksLifts.contains(lift)) continue;
    if (r.weight > 0 && r.reps > 0) {
      final t = topByWeek[wk(r.date)] ??= {};
      final s = (weight: r.weight, reps: r.reps);
      if (_heavier(s, t[lift])) t[lift] = s;
    }
    final e = _basisValue(r, basis, warmup: warm.contains(i));
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
  final trainedWeek = <String, DateTime>{}; // week each value was lifted
  final topSet = <String, LiftedSet>{}; // heaviest lifted, same week
  double? bw;
  for (var m = first;
      !m.isAfter(last);
      m = DateTime(m.year, m.month, m.day + 7)) {
    final trained = bestByWeek[m] ?? const <String, double>{};
    lifts.addAll(trained);
    for (final l in trained.keys) {
      trainedWeek[l] = m;
      final t = topByWeek[m]?[l];
      if (t != null) topSet[l] = t;
    }
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
        liftLbs: Map.unmodifiable(lifts),
        liftTrainedWeek: Map.unmodifiable(trainedWeek),
        liftTopSet: Map.unmodifiable(topSet),
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// Weekly decomposition (2026-09-25 — the hero sheet's legibility fix)
// ---------------------------------------------------------------------------

/// One lift's share of a weekly Wilks total (see [wilksWeekDecomposition]).
class WilksLiftPart {
  /// squat | bench | deadlift, in [wilksLifts] order.
  final String lift;

  /// The value (lbs) the week's total counts for this lift — on the
  /// series' basis (the RPE-adjusted estimate by default).
  final double weightLbs;

  /// The heaviest set actually lifted in the week [weightLbs] comes
  /// from; null on hand-rolled weeks without [WilksWeek.liftTopSet].
  final LiftedSet? lifted;

  /// When the value is a CARRY (the lift wasn't trained in the
  /// decomposed week): the start of the week it was actually lifted.
  /// Null for lifts trained this week.
  final DateTime? carriedFrom;

  /// Exact share: weight_kg × coeff(bw_kg). The three parts sum to
  /// [WilksWeek.wilks] to floating-point precision (the coefficient is
  /// linear in the total).
  final double points;

  /// [points] at one decimal, largest-remainder adjusted across the
  /// parts so the DISPLAYED lines sum to the DISPLAYED 1dp total
  /// exactly — three independently rounded parts can drift ±0.15 off
  /// the stat, which is precisely the "numbers don't add up" complaint
  /// this decomposition exists to kill. Each display value stays within
  /// one tenth-step of its exact share.
  final double displayPoints;

  const WilksLiftPart({
    required this.lift,
    required this.weightLbs,
    this.lifted,
    required this.carriedFrom,
    required this.points,
    required this.displayPoints,
  });
}

/// Decomposes one [WilksWeek] into its three per-lift shares — the
/// constituent lifts of the weekly actual-max Wilks stat, each priced
/// at the week's bodyweight. Total function: weeks without [WilksWeek.
/// liftLbs] (hand-rolled fixtures, pre-2026-09-25 constructors) yield
/// an empty list.
List<WilksLiftPart> wilksWeekDecomposition(WilksWeek week) {
  if (wilksLifts.any((l) => !week.liftLbs.containsKey(l))) return const [];
  final coeff = wilks2020MaleCoeff(week.bodyweightLbs * kgPerLb);
  final exact = [
    for (final l in wilksLifts) week.liftLbs[l]! * kgPerLb * coeff,
  ];
  // Largest-remainder rounding in tenths: round every part, then walk
  // the residual vs the rounded TOTAL into the parts whose rounding
  // remainders point the right way.
  final tenths = [for (final e in exact) (e * 10).round()];
  var diff = (week.wilks * 10).round() - tenths.fold<int>(0, (a, b) => a + b);
  while (diff != 0) {
    final step = diff > 0 ? 1 : -1;
    var best = 0;
    var bestRem = double.negativeInfinity;
    for (var i = 0; i < exact.length; i++) {
      final rem = (exact[i] * 10 - tenths[i]) * step;
      if (rem > bestRem) {
        bestRem = rem;
        best = i;
      }
    }
    tenths[best] += step;
    diff -= step;
  }
  return [
    for (var i = 0; i < wilksLifts.length; i++)
      WilksLiftPart(
        lift: wilksLifts[i],
        weightLbs: week.liftLbs[wilksLifts[i]]!,
        lifted: week.liftTopSet[wilksLifts[i]],
        carriedFrom: week.carried.contains(wilksLifts[i])
            ? week.liftTrainedWeek[wilksLifts[i]]
            : null,
        points: exact[i],
        displayPoints: tenths[i] / 10,
      ),
  ];
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
  WilksBasis basis = defaultWilksBasis,
}) {
  DateTime monthOf(DateTime d) => DateTime(d.year, d.month);

  // Best qualifying value per (month, lift).
  final warm = _warmups(strengthRows, basis);
  final bestByMonth = <DateTime, Map<String, double>>{};
  for (var i = 0; i < strengthRows.length; i++) {
    final r = strengthRows[i];
    final lift = mainLiftByExercise[r.exercise];
    if (lift == null || !wilksLifts.contains(lift)) continue;
    final e = _basisValue(r, basis, warmup: warm.contains(i));
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
/// Same basis as the series it is given (the RPE-adjusted estimate by
/// default since 2026-10-12 — the benchmark and the current stat must
/// never mix bases). Ties keep the EARLIEST month (that's when the mark
/// was first hit). Null for an empty series.
WilksMonth? wilksBenchmark(List<WilksMonth> series) {
  WilksMonth? best;
  for (final m in series) {
    if (best == null || m.wilks > best.wilks) best = m;
  }
  return best;
}
