/// Derived training metrics for the coach outcome layer (spec §2.5/§2.6,
/// docs/superpowers/specs/2026-09-20-coach-intent-layers-spec.md in the
/// airledger repo).
///
/// Pure Dart — no Flutter, no IO. Callers (backtest tool, nightly job)
/// map sheet rows into the input types and render the outputs.
library;

// ---------------------------------------------------------------------------
// Input types
// ---------------------------------------------------------------------------

/// One logged strength set (one sheet row).
class StrengthRow {
  final DateTime date;
  final String exercise;
  final double weight;
  final int reps;
  final double? rpe;

  const StrengthRow({
    required this.date,
    required this.exercise,
    required this.weight,
    required this.reps,
    this.rpe,
  });
}

/// One body-weight measurement.
class WeightRow {
  final DateTime date;
  final double weightLbs;

  const WeightRow({required this.date, required this.weightLbs});
}

/// One 4x4 interval row (caller identifies which cardio rows are 4x4s).
class FourByFourRow {
  final DateTime date;
  final double? maxHr;
  final double? workRateOrSpeed;

  const FourByFourRow({required this.date, this.maxHr, this.workRateOrSpeed});
}

/// One daily note (only `cause` matters to flags).
class DailyNoteRow {
  final DateTime date;
  final String? cause;

  const DailyNoteRow({required this.date, this.cause});
}

// ---------------------------------------------------------------------------
// Main-lift mapping (§2.5 — EXACT logged exercise names)
// ---------------------------------------------------------------------------

const Map<String, String> mainLiftByExercise = {
  'Barbell Squat': 'squat',
  'Flat Barbell Bench Press': 'bench',
  'Barbell Deadlift': 'deadlift',
  'Overhead Press': 'press',
  'Barbell Standing Military Press': 'press',
};

// ---------------------------------------------------------------------------
// Graded sets (§2.5 per-set)
// ---------------------------------------------------------------------------

enum SetTier { warmUp, moderate, hard }

class GradedSet {
  final DateTime date;

  /// squat | bench | deadlift | press.
  final String lift;
  final double weight;
  final int reps;
  final double e1rm;

  /// Null (with effort/pctMax/tier) when the set predates any qualifying
  /// reference for its lift — such sets are ungraded and never count as
  /// working / near-max.
  final double? reference;
  final double? effort;
  final double? pctMax;
  final SetTier? tier;
  final bool working;
  final bool nearMax;
  final bool longFailureSet;
  final double? rpe;

  const GradedSet({
    required this.date,
    required this.lift,
    required this.weight,
    required this.reps,
    required this.e1rm,
    required this.reference,
    required this.effort,
    required this.pctMax,
    required this.tier,
    required this.working,
    required this.nearMax,
    required this.longFailureSet,
    this.rpe,
  });
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

/// set_e1rm = weight * (1 + min(reps, 12) / 30) — Epley, reps capped at 12.
double epleyE1rm(double weight, int reps) =>
    weight * (1 + (reps > 12 ? 12 : reps) / 30);

/// Grades main-lift sets per §2.5. Non-main-lift rows are dropped.
///
/// reference = max set_e1rm over the same lift, sets with reps <= 8, in the
/// 42 days ending on and including the set's date (same-day sets included);
/// carried forward when the window is empty; sets before any qualifying
/// reference exists are ungraded.
List<GradedSet> gradeSets(List<StrengthRow> rows) {
  final mains = <StrengthRow>[
    for (final r in rows)
      if (mainLiftByExercise.containsKey(r.exercise)) r,
  ]..sort((a, b) => a.date.compareTo(b.date));

  // Per lift: chronological qualifying (reps <= 8) sets for the window scan.
  final qualifying = <String, List<(DateTime, double)>>{};
  for (final r in mains) {
    if (r.reps <= 8) {
      final lift = mainLiftByExercise[r.exercise]!;
      (qualifying[lift] ??= []).add((_day(r.date), epleyE1rm(r.weight, r.reps)));
    }
  }

  // Reference per (lift, day), computed once per distinct day with a
  // two-pointer sweep; carry-forward held per lift.
  final refCache = <String, Map<DateTime, double?>>{};
  final lo = <String, int>{};
  final hi = <String, int>{};
  final lastRef = <String, double?>{};

  final out = <GradedSet>[];
  for (final r in mains) {
    final lift = mainLiftByExercise[r.exercise]!;
    final day = _day(r.date);
    final cache = refCache[lift] ??= {};
    double? reference;
    if (cache.containsKey(day)) {
      reference = cache[day];
    } else {
      final q = qualifying[lift] ?? const <(DateTime, double)>[];
      var i = lo[lift] ?? 0;
      var j = hi[lift] ?? 0;
      // Advance j to include every qualifying set on or before `day`
      // (mains is date-sorted, so days only move forward per lift).
      while (j < q.length && _daysBetween(q[j].$1, day) >= 0) {
        j++;
      }
      // Advance i past sets older than 41 days before `day`.
      while (i < j && _daysBetween(q[i].$1, day) > 41) {
        i++;
      }
      lo[lift] = i;
      hi[lift] = j;
      double? windowMax;
      for (var k = i; k < j; k++) {
        if (windowMax == null || q[k].$2 > windowMax) windowMax = q[k].$2;
      }
      reference = windowMax ?? lastRef[lift];
      if (reference != null) lastRef[lift] = reference;
      cache[day] = reference;
    }

    final e1rm = epleyE1rm(r.weight, r.reps);
    final effort = reference == null ? null : e1rm / reference;
    final pctMax = reference == null ? null : r.weight / reference;
    final tier = effort == null
        ? null
        : effort < 0.80
            ? SetTier.warmUp
            : effort < 0.90
                ? SetTier.moderate
                : SetTier.hard;
    final working = effort != null && effort >= 0.80;
    final nearMax = effort != null && effort >= 0.95;
    out.add(
      GradedSet(
        date: day,
        lift: lift,
        weight: r.weight,
        reps: r.reps,
        e1rm: e1rm,
        reference: reference,
        effort: effort,
        pctMax: pctMax,
        tier: tier,
        working: working,
        nearMax: nearMax,
        longFailureSet: r.reps >= 8 && nearMax,
        rpe: r.rpe,
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// Weekly rollup (§2.5 per ISO week, Mon–Sun keyed by Monday)
// ---------------------------------------------------------------------------

class LiftWeek {
  final int days;
  final int workingSets;
  final int nearMaxSets;

  /// Best raw e1rm this week among sets with reps <= 5 (null when none).
  final double? bestE1rmFromSetsLe5;

  const LiftWeek({
    required this.days,
    required this.workingSets,
    required this.nearMaxSets,
    required this.bestE1rmFromSetsLe5,
  });
}

/// One 4x4 session (all interval rows of one date collapsed).
class Bike4x4Session {
  final DateTime date;
  final double? maxHr;
  final double? workRateOrSpeed;

  const Bike4x4Session({required this.date, this.maxHr, this.workRateOrSpeed});
}

/// A lift session's top set (highest e1rm of the day), for TOP_SET_HEAVY.
class TopSetInfo {
  final DateTime date;
  final double e1rm;
  final double? rpe;

  const TopSetInfo({required this.date, required this.e1rm, this.rpe});
}

class WeeklyMetrics {
  /// The ISO week's Monday.
  final DateTime weekStart;
  final int sessions;
  final int setsTotal;
  final int workingSets;
  final int hardSets;
  final int nearMaxSets;
  final int longFailureSets;
  final double? avgRepsWorking;
  final Map<String, LiftWeek> perLift;
  final int benchDays;
  final int climbingSessions;
  final List<Bike4x4Session> bike4x4Sessions;
  final double? bw7dAvg;
  final double? bwRateLbWk;
  final double? bw3wkChange;

  /// normal | light | test — null when no program covers this week
  /// (backtest of pre-program history).
  final String? weekType;

  /// Squat/deadlift sets with effort >= 0.85 logged on a Tuesday.
  final int tuesdayLowerSets;

  /// Per lift: this week's session top sets (for TOP_SET_HEAVY).
  final Map<String, List<TopSetInfo>> topSets;

  /// Daily notes with cause=pain this week.
  final int painNotes;

  const WeeklyMetrics({
    required this.weekStart,
    required this.sessions,
    required this.setsTotal,
    required this.workingSets,
    required this.hardSets,
    required this.nearMaxSets,
    required this.longFailureSets,
    required this.avgRepsWorking,
    required this.perLift,
    required this.benchDays,
    required this.climbingSessions,
    required this.bike4x4Sessions,
    required this.bw7dAvg,
    required this.bwRateLbWk,
    required this.bw3wkChange,
    required this.weekType,
    required this.tuesdayLowerSets,
    required this.topSets,
    required this.painNotes,
  });

  DateTime get weekSunday => weekStart.add(const Duration(days: 6));
  int get bike4x4Count => bike4x4Sessions.length;
  double? get bike4x4MaxHr => _maxOf([
        for (final s in bike4x4Sessions)
          if (s.maxHr != null) s.maxHr!,
      ]);
  double? get bike4x4WorkRateOrSpeed => _maxOf([
        for (final s in bike4x4Sessions)
          if (s.workRateOrSpeed != null) s.workRateOrSpeed!,
      ]);
}

double? _maxOf(List<double> xs) =>
    xs.isEmpty ? null : xs.reduce((a, b) => a > b ? a : b);

/// Monday of the ISO week containing [d].
DateTime mondayOf(DateTime d) {
  final day = _day(d);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

/// Rolls graded sets + weigh-ins + 4x4 rows + climbing dates + notes into
/// per-ISO-week metrics. Emits a contiguous run of weeks from the first to
/// the last week containing any input row.
List<WeeklyMetrics> weeklyRollup(
  List<GradedSet> sets, {
  List<WeightRow> weights = const [],
  List<FourByFourRow> fourByFours = const [],
  List<DateTime> climbingDates = const [],
  List<DailyNoteRow> notes = const [],
  String? Function(DateTime weekMonday)? weekTypeOf,
}) {
  final mondays = <DateTime>{
    for (final s in sets) mondayOf(s.date),
    for (final w in weights) mondayOf(w.date),
    for (final c in fourByFours) mondayOf(c.date),
    for (final c in climbingDates) mondayOf(c),
    for (final n in notes) mondayOf(n.date),
  };
  if (mondays.isEmpty) return const [];
  final sorted = mondays.toList()..sort();
  final first = sorted.first;
  final last = sorted.last;

  // Sorted weigh-ins for the as-of-Sunday window scans.
  final weighIns = [...weights]..sort((a, b) => a.date.compareTo(b.date));

  final setsByWeek = <DateTime, List<GradedSet>>{};
  for (final s in sets) {
    (setsByWeek[mondayOf(s.date)] ??= []).add(s);
  }
  final climbsByWeek = <DateTime, Set<DateTime>>{};
  for (final c in climbingDates) {
    (climbsByWeek[mondayOf(c)] ??= {}).add(_day(c));
  }
  final ffByWeek = <DateTime, List<FourByFourRow>>{};
  for (final c in fourByFours) {
    (ffByWeek[mondayOf(c.date)] ??= []).add(c);
  }
  final painByWeek = <DateTime, int>{};
  for (final n in notes) {
    if (n.cause == 'pain') {
      final k = mondayOf(n.date);
      painByWeek[k] = (painByWeek[k] ?? 0) + 1;
    }
  }

  double? bw7dAvgAsOf(DateTime sunday) {
    final from = sunday.subtract(const Duration(days: 6));
    var sum = 0.0;
    var n = 0;
    for (final w in weighIns) {
      final d = _day(w.date);
      if (d.isBefore(from)) continue;
      if (d.isAfter(sunday)) break;
      sum += w.weightLbs;
      n++;
    }
    return n == 0 ? null : sum / n;
  }

  final out = <WeeklyMetrics>[];
  final bwByIndex = <double?>[];
  for (var m = first; !m.isAfter(last); m = m.add(const Duration(days: 7))) {
    final weekSets = setsByWeek[m] ?? const <GradedSet>[];
    final graded = [for (final s in weekSets) if (s.effort != null) s];
    final working = [for (final s in graded) if (s.working) s];

    final perLift = <String, LiftWeek>{};
    final topSets = <String, List<TopSetInfo>>{};
    for (final lift in {for (final s in weekSets) s.lift}) {
      final liftSets = [for (final s in weekSets) if (s.lift == lift) s];
      final le5 = [for (final s in liftSets) if (s.reps <= 5) s.e1rm];
      perLift[lift] = LiftWeek(
        days: {for (final s in liftSets) s.date}.length,
        workingSets: liftSets.where((s) => s.working).length,
        nearMaxSets: liftSets.where((s) => s.nearMax).length,
        bestE1rmFromSetsLe5: _maxOf(le5),
      );
      // Session top set per date: highest e1rm that day.
      final byDate = <DateTime, GradedSet>{};
      for (final s in liftSets) {
        final cur = byDate[s.date];
        if (cur == null || s.e1rm > cur.e1rm) byDate[s.date] = s;
      }
      topSets[lift] = [
        for (final d in byDate.keys.toList()..sort())
          TopSetInfo(date: d, e1rm: byDate[d]!.e1rm, rpe: byDate[d]!.rpe),
      ];
    }

    // 4x4 sessions: collapse interval rows per date.
    final ffSessions = <Bike4x4Session>[];
    final ffRows = ffByWeek[m] ?? const <FourByFourRow>[];
    final ffDates = {for (final r in ffRows) _day(r.date)}.toList()..sort();
    for (final d in ffDates) {
      final rows = [for (final r in ffRows) if (_day(r.date) == d) r];
      ffSessions.add(
        Bike4x4Session(
          date: d,
          maxHr: _maxOf([
            for (final r in rows)
              if (r.maxHr != null) r.maxHr!,
          ]),
          workRateOrSpeed: _maxOf([
            for (final r in rows)
              if (r.workRateOrSpeed != null) r.workRateOrSpeed!,
          ]),
        ),
      );
    }

    final sunday = m.add(const Duration(days: 6));
    final bw = bw7dAvgAsOf(sunday);
    bwByIndex.add(bw);
    final i = bwByIndex.length - 1;
    final prev = i >= 1 ? bwByIndex[i - 1] : null;
    final threeAgo = i >= 3 ? bwByIndex[i - 3] : null;

    out.add(
      WeeklyMetrics(
        weekStart: m,
        sessions: {for (final s in weekSets) s.date}.length,
        setsTotal: weekSets.length,
        workingSets: working.length,
        hardSets: graded.where((s) => s.tier == SetTier.hard).length,
        nearMaxSets: graded.where((s) => s.nearMax).length,
        longFailureSets: graded.where((s) => s.longFailureSet).length,
        avgRepsWorking: working.isEmpty
            ? null
            : working.map((s) => s.reps).reduce((a, b) => a + b) /
                working.length,
        perLift: perLift,
        benchDays: {
          for (final s in weekSets)
            if (s.lift == 'bench') s.date,
        }.length,
        climbingSessions: (climbsByWeek[m] ?? const {}).length,
        bike4x4Sessions: ffSessions,
        bw7dAvg: bw,
        bwRateLbWk: bw != null && prev != null ? bw - prev : null,
        bw3wkChange: bw != null && threeAgo != null ? bw - threeAgo : null,
        weekType: weekTypeOf?.call(m),
        tuesdayLowerSets: weekSets
            .where(
              (s) =>
                  (s.lift == 'squat' || s.lift == 'deadlift') &&
                  s.date.weekday == DateTime.tuesday &&
                  (s.effort ?? 0) >= 0.85,
            )
            .length,
        topSets: topSets,
        painNotes: painByWeek[m] ?? 0,
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// Flags (§2.6 — weekly)
// ---------------------------------------------------------------------------

class FlagHit {
  final String id;

  /// The Sunday of the week the flag belongs to.
  final DateTime firedOn;
  final Map<String, Object?> evidence;
  final String action;

  const FlagHit({
    required this.id,
    required this.firedOn,
    required this.evidence,
    required this.action,
  });
}

/// Evaluates §2.6 flags per week. Weeks must be the contiguous, sorted
/// output of [weeklyRollup].
///
/// Backtest semantics: a null weekType is treated as `normal` for the
/// normal-scoped rules (NEAR_MAX_LOW / WORKING_LOW / BENCH_ONCE) — the §6
/// backtest expects them to fire on pre-program history. Rules whose inputs
/// don't exist here never fire: WEIGHT_FLAT / PHASE_MISMATCH need [phaseOf];
/// WEIGHT_DRIFT / CLIMB_OVER / BLOCK_END need program data (block target
/// line, climbing allowance, test-week comparisons) and are no-ops until the
/// intent layer supplies them.
Map<DateTime, List<FlagHit>> evaluateFlags(
  List<WeeklyMetrics> weeks, {
  String? Function(DateTime weekMonday)? phaseOf,
}) {
  final out = <DateTime, List<FlagHit>>{};
  bool normalScope(WeeklyMetrics w) =>
      w.weekType == null || w.weekType == 'normal';

  // TOP_SET_HEAVY: per-lift chronological session top sets across all weeks.
  final topByLift = <String, List<TopSetInfo>>{};
  for (final w in weeks) {
    for (final e in w.topSets.entries) {
      (topByLift[e.key] ??= []).addAll(e.value);
    }
  }
  for (final l in topByLift.values) {
    l.sort((a, b) => a.date.compareTo(b.date));
  }
  // Dates (per lift) where the session top set and its predecessor are both
  // RPE >= 9.5.
  final heavyTopDates = <String, Set<DateTime>>{};
  for (final e in topByLift.entries) {
    final l = e.value;
    for (var i = 1; i < l.length; i++) {
      final a = l[i - 1].rpe;
      final b = l[i].rpe;
      if (a != null && a >= 9.5 && b != null && b >= 9.5) {
        (heavyTopDates[e.key] ??= {}).add(l[i].date);
      }
    }
  }

  // BIKE_DROP: chronological 4x4 sessions; a session "drops" when its
  // max_hr or work rate is below the median of the previous four sessions.
  final ffAll = <Bike4x4Session>[
    for (final w in weeks) ...w.bike4x4Sessions,
  ]..sort((a, b) => a.date.compareTo(b.date));
  final dropDates = <DateTime>{};
  double? median(List<double> xs) {
    if (xs.length < 4) return null; // need all four predecessors measured
    final s = [...xs]..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }

  for (var i = 4; i < ffAll.length; i++) {
    final prev4 = ffAll.sublist(i - 4, i);
    final hrMed = median([
      for (final s in prev4)
        if (s.maxHr != null) s.maxHr!,
    ]);
    final wrMed = median([
      for (final s in prev4)
        if (s.workRateOrSpeed != null) s.workRateOrSpeed!,
    ]);
    final s = ffAll[i];
    final hrDrop = hrMed != null && s.maxHr != null && s.maxHr! < hrMed;
    final wrDrop = wrMed != null &&
        s.workRateOrSpeed != null &&
        s.workRateOrSpeed! < wrMed;
    if (hrDrop || wrDrop) dropDates.add(s.date);
  }

  for (var i = 0; i < weeks.length; i++) {
    final w = weeks[i];
    final hits = <FlagHit>[];
    final sunday = w.weekSunday;
    void fire(String id, Map<String, Object?> evidence, String action) =>
        hits.add(
          FlagHit(id: id, firedOn: sunday, evidence: evidence, action: action),
        );

    final prev = i >= 1 ? weeks[i - 1] : null;
    final prev2 = i >= 2 ? weeks[i - 2] : null;

    // WEIGHT_FAST — rate > 0.6 two consecutive weeks.
    if (w.bwRateLbWk != null &&
        w.bwRateLbWk! > 0.6 &&
        prev?.bwRateLbWk != null &&
        prev!.bwRateLbWk! > 0.6) {
      fire(
        'WEIGHT_FAST',
        {'bw_rate_lb_wk': w.bwRateLbWk, 'prev_rate': prev.bwRateLbWk},
        "Take 100 kcal/day out now; don't wait for the three-week check.",
      );
    }

    final phase = phaseOf?.call(w.weekStart);

    // WEIGHT_FLAT — bulk and abs(3wk change) < 0.3.
    if (phase == 'bulk' &&
        w.bw3wkChange != null &&
        w.bw3wkChange!.abs() < 0.3) {
      fire(
        'WEIGHT_FLAT',
        {'bw_3wk_change': w.bw3wkChange},
        'Add 100 kcal/day.',
      );
    }

    // WEIGHT_CAP — bw_7d_avg > 172.
    if (w.bw7dAvg != null && w.bw7dAvg! > 172) {
      fire(
        'WEIGHT_CAP',
        {'bw_7d_avg': w.bw7dAvg},
        'Hold at maintenance until the next block starts, whatever the '
            'block was for.',
      );
    }

    // WEIGHT_DRIFT — needs the block target line (program); no-op here.

    // PHASE_MISMATCH — three consecutive weeks of scale disagreement.
    if (phase != null) {
      bool mismatch(WeeklyMetrics? m) {
        if (m == null) return false;
        final rate = m.bwRateLbWk;
        final chg3 = m.bw3wkChange;
        switch (phase) {
          case 'bulk':
            return rate != null && rate <= -0.2;
          case 'cut':
            return rate != null && rate >= 0.2;
          case 'maintain':
            return chg3 != null && chg3.abs() > 1.5;
        }
        return false;
      }

      if (mismatch(w) && mismatch(prev) && mismatch(prev2)) {
        fire(
          'PHASE_MISMATCH',
          {
            'phase': phase,
            'rates': [prev2?.bwRateLbWk, prev?.bwRateLbWk, w.bwRateLbWk],
            'bw_3wk_change': w.bw3wkChange,
          },
          'Declared $phase; scale says otherwise for three weeks. Food or '
              'declaration is wrong.',
        );
      }
    }

    // NEAR_MAX_LOW — normal weeks, near_max_sets < 5.
    if (normalScope(w) && w.nearMaxSets < 5) {
      fire(
        'NEAR_MAX_LOW',
        {'near_max_sets': w.nearMaxSets},
        'Heavy work is missing. Every productive stretch had 6+ near-max '
            'sets a week; every failed one had 4 or fewer.',
      );
    }

    // WORKING_LOW — normal weeks, working_sets < 20.
    if (normalScope(w) && w.workingSets < 20) {
      fire(
        'WORKING_LOW',
        {'working_sets': w.workingSets},
        'Working volume under 20. Target ~28.',
      );
    }

    // LONG_SETS — long_failure_sets >= 2, any week type.
    if (w.longFailureSets >= 2) {
      fire(
        'LONG_SETS',
        {'long_failure_sets': w.longFailureSets},
        'Two or more long sets to failure. This is the 2025 pattern; they '
            'replace heavy sets, they don\'t add to them.',
      );
    }

    // BENCH_ONCE — normal weeks, bench_days < 2.
    if (normalScope(w) && w.benchDays < 2) {
      fire(
        'BENCH_ONCE',
        {'bench_days': w.benchDays},
        'Bench once this week. Twice is the rule in every phase.',
      );
    }

    // TUESDAY_LOWER — any squat/deadlift set effort >= 0.85 on a Tuesday.
    if (w.tuesdayLowerSets > 0) {
      fire(
        'TUESDAY_LOWER',
        {'sets': w.tuesdayLowerSets},
        'Heavy lower on a climbing day. Never.',
      );
    }

    // CLIMB_OVER — needs the block's climbing allowance; no-op here.

    // BIKE_DROP — a dropping 4x4 this week and last week.
    bool weekDrops(WeeklyMetrics m) =>
        m.bike4x4Sessions.any((s) => dropDates.contains(s.date));
    if (weekDrops(w) && prev != null && weekDrops(prev)) {
      fire(
        'BIKE_DROP',
        {
          'dates': [
            for (final s in w.bike4x4Sessions)
              if (dropDates.contains(s.date)) s.date.toIso8601String(),
          ],
        },
        'Take the light week early.',
      );
    }

    // TOP_SET_HEAVY — two consecutive top sets on one lift at RPE >= 9.5.
    for (final e in heavyTopDates.entries) {
      final inWeek = [
        for (final d in e.value)
          if (mondayOf(d) == w.weekStart) d,
      ];
      if (inWeek.isNotEmpty) {
        fire(
          'TOP_SET_HEAVY',
          {
            'lift': e.key,
            'dates': [for (final d in inWeek..sort()) d.toIso8601String()],
          },
          'Next week: RPE 8 on that lift, no top-set attempts.',
        );
      }
    }

    // PAIN_NOTE — a daily note with cause=pain this week.
    if (w.painNotes > 0) {
      fire(
        'PAIN_NOTE',
        {'notes': w.painNotes},
        'Check the finger / elbow / back gates in the program.',
      );
    }

    // BLOCK_END — needs test-week single comparisons (program); no-op here.

    // TWO_SIGNALS — two or more OTHER flags fired this week.
    if (hits.length >= 2) {
      fire(
        'TWO_SIGNALS',
        {'fired': [for (final h in hits) h.id]},
        'This week becomes a light week.',
      );
    }

    if (hits.isNotEmpty) out[w.weekStart] = hits;
  }
  return out;
}
