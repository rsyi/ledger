/// Post-cut recomp weekly review + daily adherence deriveds
/// (coach/recomp-tracking-spec.md in airledger-fitness, 2026-09-27).
///
/// The spec's split: DAILY INPUTS are logged rows (adherence); the
/// WEEKLY REVIEW is generated (adaptation outcomes + the 10-question
/// coaching decision). This lib is the generator's brain — pure Dart,
/// no Flutter, no IO. Callers (tool/program_status_update.dart weekly
/// job, the home dashboard's recomp rows) map rows into the input
/// types and render the outputs.
///
/// Counting rules (documented here, referenced by the schemas):
///   • RIR convention: RIR = 10 − RPE. There is deliberately NO second
///     field — dashboards state the convention instead.
///   • Productive hypertrophy sets: set_type warmup/skill/rehab are
///     EXCLUDED; heavy/hypertrophy are counted. UNTAGGED legacy rows
///     (blank set_type — everything before 2026-09-27) fall back to
///     effort-based inference: excluded when RPE is present and < 6
///     (a logged warmup), counted otherwise (benefit of the doubt —
///     matches week_drivers' hypertrophy_volume, which counts all
///     mapped sets).
///   • Overlap: per-muscle counts price strength/calisthenics rows via
///     the program's exercise_muscle_map credits and add the per-
///     session climbing credits (spec: count the overlap, don't stack
///     rowing on climbing).
///   • 4x4 workload index = speed × incline when incline > 0, else
///     speed alone (the spec's own formula: "more EXTERNAL workload at
///     comparable physiological response"). The trend compares this
///     week's session against the most recent PRIOR session whose max
///     HR is within ±5 bpm (comparable response); no comparable prior
///     → trend is honestly null.
///   • Pain OUTRANKS numeric targets: any pain text in the week turns
///     the recovery verdict red regardless of the averages.
///   • Review week is Mon→Sun (the default weekly schedule's shape) —
///     the Sunday-night job reviews the week just finishing. This is
///     deliberately NOT the Saturday accounting week the driver strip
///     uses; the two answer different questions.
library;

import 'week_drivers.dart' show MuscleMap, TopSetReading;

// ---------------------------------------------------------------------------
// Input row types
// ---------------------------------------------------------------------------

/// One meals row.
class MealRow {
  final DateTime eatenAt;
  final double? calories;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;

  const MealRow({
    required this.eatenAt,
    this.calories,
    this.proteinG,
    this.carbsG,
    this.fatG,
  });
}

/// One strength row, with the recomp-layer extras the older LoggedSet
/// (week_drivers) doesn't carry: rpe + set_type.
class ReviewSet {
  final DateTime date;
  final String exercise;
  final int reps;
  final double weight;
  final double? rpe;

  /// warmup | heavy | hypertrophy | skill | rehab | null (untagged).
  final String? setType;

  const ReviewSet({
    required this.date,
    required this.exercise,
    required this.reps,
    required this.weight,
    this.rpe,
    this.setType,
  });
}

/// One calisthenics row (skill quality log).
class CalisthenicsRow {
  final DateTime date;
  final String skill;
  final String? variation;
  final int? sets;
  final int? reps;
  final double? holdSeconds;
  final bool? clean;
  final double? rpe;

  const CalisthenicsRow({
    required this.date,
    required this.skill,
    this.variation,
    this.sets,
    this.reps,
    this.holdSeconds,
    this.clean,
    this.rpe,
  });
}

/// One kaya_ascents row.
class ClimbRow {
  final DateTime date;

  /// Kaya grade string verbatim ("v5", "5.12a").
  final String grade;

  /// Flash / Onsight / Redpoint / Repeat.
  final String ascentType;

  const ClimbRow({
    required this.date,
    required this.grade,
    required this.ascentType,
  });
}

/// One 4x4 cardio row.
class Cardio4x4Row {
  final DateTime date;
  final double? speed;
  final double? incline;
  final double? maxHr;
  final double? completedIntervals;

  const Cardio4x4Row({
    required this.date,
    this.speed,
    this.incline,
    this.maxHr,
    this.completedIntervals,
  });
}

/// One daily_notes row's recovery subjectives.
class RecoveryRow {
  final DateTime date;
  final double? sleepHours;
  final double? sleepQuality;
  final double? fatigue;
  final double? soreness;
  final double? readiness;
  final String? pain;
  final String? note;

  const RecoveryRow({
    required this.date,
    this.sleepHours,
    this.sleepQuality,
    this.fatigue,
    this.soreness,
    this.readiness,
    this.pain,
    this.note,
  });
}

/// One weight row (weigh-in + optional weekly waist).
class BodyRow {
  final DateTime date;
  final double? weightLbs;
  final double? waistIn;

  const BodyRow({required this.date, this.weightLbs, this.waistIn});
}

/// Full-history inputs; the builder filters to the review week (and
/// looks back where trends need it). All optional — absent sources
/// yield honest "no data" answers, never zeros dressed as facts.
class RecompInputs {
  final List<MealRow> meals;
  final List<ReviewSet> strengthSets;

  /// Working-max controller readings — heavy-exposure ground truth.
  final List<TopSetReading> readings;
  final List<ClimbRow> climbs;
  final List<CalisthenicsRow> calisthenics;
  final List<Cardio4x4Row> cardio;
  final List<RecoveryRow> recovery;
  final List<BodyRow> body;

  const RecompInputs({
    this.meals = const [],
    this.strengthSets = const [],
    this.readings = const [],
    this.climbs = const [],
    this.calisthenics = const [],
    this.cardio = const [],
    this.recovery = const [],
    this.body = const [],
  });
}

/// Targets-in-force (program.yaml recomp variant). Nullable fields are
/// honestly absent (e.g. maintenanceKcal until block 1 records it —
/// read from the program version's `nutrition.maintenance_kcal` when
/// declared).
class RecompTargets {
  final List<double>? proteinGDay; // [160, 175]
  final double? fatGDayMin; // 55
  final List<double>? carbsGDay; // [225, 300]
  final double? maintenanceKcal;
  final List<double> hypBand; // [8, 12]
  final List<String> muscleGroups;
  final MuscleMap? muscleMap;
  final double? climbingWk;
  final double? calisthenicsWk;
  final double? bike4x4Wk;

  const RecompTargets({
    this.proteinGDay,
    this.fatGDayMin,
    this.carbsGDay,
    this.maintenanceKcal,
    this.hypBand = const [8, 12],
    this.muscleGroups = const [],
    this.muscleMap,
    this.climbingWk,
    this.calisthenicsWk,
    this.bike4x4Wk,
  });
}

// ---------------------------------------------------------------------------
// Daily nutrition adherence
// ---------------------------------------------------------------------------

/// One calendar day's nutrition rollup + adherence gates. Gates are
/// null when the corresponding target is undeclared.
class DayNutrition {
  final DateTime day;
  final double kcal;
  final double proteinG;
  final double carbsG;
  final double fatG;
  final bool? proteinMet;
  final bool? fatMet;
  final bool? carbsMet;

  /// kcal − maintenance (negative = under); null without a maintenance
  /// estimate.
  final double? kcalVsMaintenance;

  const DayNutrition({
    required this.day,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    this.proteinMet,
    this.fatMet,
    this.carbsMet,
    this.kcalVsMaintenance,
  });
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Groups meals by calendar day and applies the targets. Days sorted
/// ascending; days with no meals simply don't appear (unlogged ≠ zero).
List<DayNutrition> dailyNutrition(
  List<MealRow> meals,
  RecompTargets targets,
) {
  final byDay = <DateTime, List<MealRow>>{};
  for (final m in meals) {
    byDay.putIfAbsent(_day(m.eatenAt), () => []).add(m);
  }
  final days = byDay.keys.toList()..sort();
  return [
    for (final day in days)
      () {
        double sum(double? Function(MealRow) f) =>
            byDay[day]!.fold(0.0, (acc, m) => acc + (f(m) ?? 0));
        final kcal = sum((m) => m.calories);
        final protein = sum((m) => m.proteinG);
        final carbs = sum((m) => m.carbsG);
        final fat = sum((m) => m.fatG);
        final p = targets.proteinGDay;
        final c = targets.carbsGDay;
        return DayNutrition(
          day: day,
          kcal: kcal,
          proteinG: protein,
          carbsG: carbs,
          fatG: fat,
          proteinMet: p == null ? null : protein >= p[0],
          fatMet: targets.fatGDayMin == null
              ? null
              : fat >= targets.fatGDayMin!,
          carbsMet: c == null ? null : carbs >= c[0] && carbs <= c[1],
          kcalVsMaintenance: targets.maintenanceKcal == null
              ? null
              : kcal - targets.maintenanceKcal!,
        );
      }(),
  ];
}

// ---------------------------------------------------------------------------
// Productive set counting (set_type-aware)
// ---------------------------------------------------------------------------

/// The documented rule (header): warmup/skill/rehab excluded; heavy/
/// hypertrophy counted; untagged rows effort-inferred (RPE < 6 =
/// warmup, otherwise counted).
bool countsAsProductive(ReviewSet s) {
  switch (s.setType) {
    case 'warmup':
    case 'skill':
    case 'rehab':
      return false;
    case 'heavy':
    case 'hypertrophy':
      return true;
    default:
      final rpe = s.rpe;
      return rpe == null || rpe >= 6;
  }
}

/// Weekly productive sets per muscle group: productive strength rows ×
/// their map credits + climbing sessions × the per-session credits.
/// Only [groups] are returned (the band's groups).
Map<String, double> productiveSetsByMuscle({
  required List<ReviewSet> sets,
  required MuscleMap map,
  required int climbingSessionCount,
  required List<String> groups,
}) {
  final counts = {for (final g in groups) g: 0.0};
  for (final s in sets) {
    if (!countsAsProductive(s)) continue;
    final credits = map.creditsFor(s.exercise);
    if (credits == null) continue;
    for (final e in credits.entries) {
      if (counts.containsKey(e.key)) {
        counts[e.key] = counts[e.key]! + e.value;
      }
    }
  }
  for (final e in map.climbingSession.entries) {
    if (counts.containsKey(e.key)) {
      counts[e.key] = counts[e.key]! + climbingSessionCount * e.value;
    }
  }
  return counts;
}

/// Mean RIR (10 − RPE) over PRODUCTIVE sets that carry an RPE. Null
/// when none do.
double? avgRirOfProductiveSets(List<ReviewSet> sets) {
  var sum = 0.0;
  var n = 0;
  for (final s in sets) {
    if (!countsAsProductive(s) || s.rpe == null) continue;
    sum += 10 - s.rpe!;
    n++;
  }
  return n == 0 ? null : sum / n;
}

// ---------------------------------------------------------------------------
// Per-domain weekly rollups
// ---------------------------------------------------------------------------

bool _inWeek(DateTime d, DateTime weekStart) {
  final day = _day(d);
  return !day.isBefore(weekStart) &&
      day.isBefore(weekStart.add(const Duration(days: 7)));
}

/// Boulder V-grade from a kaya grade string ("v5" → 5); null for rope
/// grades ("5.12a") and unparsable strings.
int? vGradeOf(String grade) {
  final m = RegExp(r'^[vV](\d+)').firstMatch(grade.trim());
  return m == null ? null : int.parse(m.group(1)!);
}

class ClimbingWeek {
  final int sessions;

  /// V5+ sends that are NOT repeats (Flash/Onsight/Redpoint).
  final int newV5PlusSends;

  /// V5+ onsights + flashes.
  final int v5PlusOnsightFlash;

  /// Highest V-grade sent this week (null: none / rope only).
  final int? highestSentV;

  const ClimbingWeek({
    required this.sessions,
    required this.newV5PlusSends,
    required this.v5PlusOnsightFlash,
    this.highestSentV,
  });
}

ClimbingWeek climbingWeekOf({
  required List<ClimbRow> climbs,
  required DateTime weekStart,
}) {
  final week = [for (final c in climbs) if (_inWeek(c.date, weekStart)) c];
  final days = {for (final c in week) _day(c.date)};
  var newV5 = 0, onsightFlash = 0;
  int? highest;
  for (final c in week) {
    final v = vGradeOf(c.grade);
    if (v == null) continue;
    final type = c.ascentType.toLowerCase();
    if (highest == null || v > highest) highest = v;
    if (v >= 5 && type != 'repeat') newV5++;
    if (v >= 5 && (type == 'onsight' || type == 'flash')) onsightFlash++;
  }
  return ClimbingWeek(
    sessions: days.length,
    newV5PlusSends: newV5,
    v5PlusOnsightFlash: onsightFlash,
    highestSentV: highest,
  );
}

/// Per-skill weekly bests.
class SkillBest {
  final int? bestReps;
  final int? bestCleanReps;
  final double? bestHoldSeconds;
  final String? variation; // of the best-reps/hold row

  const SkillBest({
    this.bestReps,
    this.bestCleanReps,
    this.bestHoldSeconds,
    this.variation,
  });
}

class CalisthenicsWeek {
  final int sessions;
  final Map<String, SkillBest> bests;

  const CalisthenicsWeek({required this.sessions, required this.bests});
}

CalisthenicsWeek calisthenicsWeekOf({
  required List<CalisthenicsRow> rows,
  required DateTime weekStart,
}) {
  final week = [for (final r in rows) if (_inWeek(r.date, weekStart)) r];
  final days = {for (final r in week) _day(r.date)};
  final bySkill = <String, List<CalisthenicsRow>>{};
  for (final r in week) {
    bySkill.putIfAbsent(r.skill, () => []).add(r);
  }
  final bests = <String, SkillBest>{};
  bySkill.forEach((skill, rows) {
    int? bestReps, bestClean;
    double? bestHold;
    String? variation;
    for (final r in rows) {
      if (r.reps != null && (bestReps == null || r.reps! > bestReps)) {
        bestReps = r.reps;
        variation = r.variation ?? variation;
      }
      if (r.reps != null &&
          r.clean == true &&
          (bestClean == null || r.reps! > bestClean)) {
        bestClean = r.reps;
      }
      if (r.holdSeconds != null &&
          (bestHold == null || r.holdSeconds! > bestHold)) {
        bestHold = r.holdSeconds;
        variation ??= r.variation;
      }
    }
    bests[skill] = SkillBest(
      bestReps: bestReps,
      bestCleanReps: bestClean,
      bestHoldSeconds: bestHold,
      variation: variation,
    );
  });
  return CalisthenicsWeek(sessions: days.length, bests: bests);
}

class CardioWeek {
  final int sessions;

  /// true/false from completed_intervals (≥4 = full); null unrecorded.
  final bool? completedAllFour;

  /// This week's best workload index (speed × incline, or speed).
  final double? workload;
  final double? maxHr;

  /// % change vs the most recent PRIOR comparable-HR session (±5 bpm);
  /// null when no comparable prior exists.
  final double? workloadTrendPct;

  const CardioWeek({
    required this.sessions,
    this.completedAllFour,
    this.workload,
    this.maxHr,
    this.workloadTrendPct,
  });
}

double? _workloadIndex(Cardio4x4Row r) {
  if (r.speed == null) return null;
  final incline = r.incline ?? 0;
  return incline > 0 ? r.speed! * incline : r.speed;
}

CardioWeek cardioWeekOf({
  required List<Cardio4x4Row> rows,
  required DateTime weekStart,
}) {
  final week = [for (final r in rows) if (_inWeek(r.date, weekStart)) r]
    ..sort((a, b) => a.date.compareTo(b.date));
  final prior = [
    for (final r in rows) if (_day(r.date).isBefore(weekStart)) r,
  ]..sort((a, b) => a.date.compareTo(b.date));

  final days = {for (final r in week) _day(r.date)};
  bool? allFour;
  double? workload, maxHr;
  for (final r in week) {
    final w = _workloadIndex(r);
    if (w != null && (workload == null || w > workload)) {
      workload = w;
      maxHr = r.maxHr;
    }
    if (r.completedIntervals != null) {
      allFour = r.completedIntervals! >= 4;
    }
  }

  double? trend;
  if (workload != null && maxHr != null) {
    for (final r in prior.reversed) {
      final w = _workloadIndex(r);
      if (w == null || r.maxHr == null) continue;
      if ((r.maxHr! - maxHr).abs() <= 5) {
        trend = 100 * (workload - w) / w;
        break;
      }
    }
  }
  return CardioWeek(
    sessions: days.length,
    completedAllFour: allFour,
    workload: workload,
    maxHr: maxHr,
    workloadTrendPct: trend,
  );
}

class PainDay {
  final DateTime date;
  final String text;

  const PainDay({required this.date, required this.text});
}

class RecoveryWeek {
  final int daysReported;
  final double? avgSleepHours;
  final double? avgSleepQuality;
  final double? avgFatigue;
  final double? avgSoreness;
  final double? avgReadiness;

  /// Pain OUTRANKS the averages as a coaching signal.
  final List<PainDay> painDays;

  const RecoveryWeek({
    required this.daysReported,
    this.avgSleepHours,
    this.avgSleepQuality,
    this.avgFatigue,
    this.avgSoreness,
    this.avgReadiness,
    this.painDays = const [],
  });
}

RecoveryWeek recoveryWeekOf({
  required List<RecoveryRow> rows,
  required DateTime weekStart,
}) {
  final week = [for (final r in rows) if (_inWeek(r.date, weekStart)) r];
  double? avg(double? Function(RecoveryRow) f) {
    var sum = 0.0;
    var n = 0;
    for (final r in week) {
      final v = f(r);
      if (v == null) continue;
      sum += v;
      n++;
    }
    return n == 0 ? null : sum / n;
  }

  final reported = week
      .where((r) =>
          r.sleepHours != null ||
          r.sleepQuality != null ||
          r.fatigue != null ||
          r.soreness != null ||
          r.readiness != null ||
          (r.pain ?? '').isNotEmpty)
      .length;
  return RecoveryWeek(
    daysReported: reported,
    avgSleepHours: avg((r) => r.sleepHours),
    avgSleepQuality: avg((r) => r.sleepQuality),
    avgFatigue: avg((r) => r.fatigue),
    avgSoreness: avg((r) => r.soreness),
    avgReadiness: avg((r) => r.readiness),
    painDays: [
      for (final r in week)
        if ((r.pain ?? '').trim().isNotEmpty)
          PainDay(date: _day(r.date), text: r.pain!.trim()),
    ],
  );
}

class BodyWeek {
  /// Trailing 7-day average weight as of week end.
  final double? avg7d;

  /// The 7 days before that.
  final double? prev7d;

  /// avg7d − the average four weeks earlier (multi-week trend).
  final double? change4wk;

  /// Latest waist measurement in the week (weekly cadence).
  final double? waistIn;

  /// The previous waist reading before this week, for the delta.
  final double? prevWaistIn;

  const BodyWeek({
    this.avg7d,
    this.prev7d,
    this.change4wk,
    this.waistIn,
    this.prevWaistIn,
  });

  double? get change7d =>
      avg7d == null || prev7d == null ? null : avg7d! - prev7d!;
}

BodyWeek bodyWeekOf({
  required List<BodyRow> rows,
  required DateTime weekStart,
}) {
  final weekEnd = weekStart.add(const Duration(days: 6));
  double? avgIn(DateTime from, DateTime to) {
    var sum = 0.0;
    var n = 0;
    for (final r in rows) {
      final day = _day(r.date);
      if (r.weightLbs == null || day.isBefore(from) || day.isAfter(to)) {
        continue;
      }
      sum += r.weightLbs!;
      n++;
    }
    return n == 0 ? null : sum / n;
  }

  final avg7 = avgIn(weekEnd.subtract(const Duration(days: 6)), weekEnd);
  final prev7 = avgIn(
    weekEnd.subtract(const Duration(days: 13)),
    weekEnd.subtract(const Duration(days: 7)),
  );
  final fourAgo = avgIn(
    weekEnd.subtract(const Duration(days: 34)),
    weekEnd.subtract(const Duration(days: 28)),
  );

  double? waist, prevWaist;
  final sorted = [...rows]..sort((a, b) => a.date.compareTo(b.date));
  for (final r in sorted) {
    if (r.waistIn == null) continue;
    if (_inWeek(r.date, weekStart)) {
      waist = r.waistIn;
    } else if (_day(r.date).isBefore(weekStart)) {
      prevWaist = r.waistIn;
    }
  }
  return BodyWeek(
    avg7d: avg7,
    prev7d: prev7,
    change4wk: avg7 == null || fourAgo == null ? null : avg7 - fourAgo,
    waistIn: waist,
    prevWaistIn: prevWaist,
  );
}

// ---------------------------------------------------------------------------
// Weekly review
// ---------------------------------------------------------------------------

class NutritionWeek {
  final int daysLogged;
  final double avgKcal;
  final double avgProteinG;
  final double avgCarbsG;
  final double avgFatG;

  /// Null when the corresponding target is not in force (block 0 nulls
  /// the absolute nutrition keys) — "no target", not "0 days met".
  final int? proteinDaysMet;
  final int? fatDaysMet;
  final int? carbDaysMet;
  final double? avgKcalVsMaintenance;

  const NutritionWeek({
    required this.daysLogged,
    required this.avgKcal,
    required this.avgProteinG,
    required this.avgCarbsG,
    required this.avgFatG,
    required this.proteinDaysMet,
    required this.fatDaysMet,
    required this.carbDaysMet,
    this.avgKcalVsMaintenance,
  });
}

enum ReviewVerdict { yes, no, mixed, noData }

/// One of the spec's ten ordered coaching-decision answers.
class CoachAnswer {
  final int n;
  final String question;
  final ReviewVerdict verdict;
  final String answer;

  const CoachAnswer({
    required this.n,
    required this.question,
    required this.verdict,
    required this.answer,
  });
}

class WeeklyReview {
  final DateTime weekStart;
  final DateTime weekEnd;

  /// Null when NO meals were logged in the week (vs zeros).
  final NutritionWeek? nutrition;
  final Map<String, double> muscleSets;
  final List<double> hypBand;
  final double? avgRir;

  /// Heavy top-set exposures per main lift (readings-based).
  final Map<String, int> heavyExposures;
  final ClimbingWeek climbing;
  final CalisthenicsWeek calisthenics;
  final CardioWeek cardio;
  final RecoveryWeek recovery;
  final BodyWeek body;
  final List<CoachAnswer> decision;

  const WeeklyReview({
    required this.weekStart,
    required this.weekEnd,
    required this.nutrition,
    required this.muscleSets,
    required this.hypBand,
    required this.avgRir,
    required this.heavyExposures,
    required this.climbing,
    required this.calisthenics,
    required this.cardio,
    required this.recovery,
    required this.body,
    required this.decision,
  });
}

const List<String> _mainLifts = ['squat', 'bench', 'deadlift', 'press'];

WeeklyReview buildWeeklyReview({
  required DateTime weekStart,
  required RecompInputs inputs,
  required RecompTargets targets,
}) {
  final ws = _day(weekStart);
  final weekEnd = ws.add(const Duration(days: 6));

  // Nutrition.
  final weekMeals = [
    for (final m in inputs.meals) if (_inWeek(m.eatenAt, ws)) m,
  ];
  final days = dailyNutrition(weekMeals, targets);
  NutritionWeek? nutrition;
  if (days.isNotEmpty) {
    double avg(double Function(DayNutrition) f) =>
        days.fold(0.0, (acc, d) => acc + f(d)) / days.length;
    final vsMaint = [
      for (final d in days)
        if (d.kcalVsMaintenance != null) d.kcalVsMaintenance!,
    ];
    nutrition = NutritionWeek(
      daysLogged: days.length,
      avgKcal: avg((d) => d.kcal),
      avgProteinG: avg((d) => d.proteinG),
      avgCarbsG: avg((d) => d.carbsG),
      avgFatG: avg((d) => d.fatG),
      proteinDaysMet: targets.proteinGDay == null
          ? null
          : days.where((d) => d.proteinMet == true).length,
      fatDaysMet: targets.fatGDayMin == null
          ? null
          : days.where((d) => d.fatMet == true).length,
      carbDaysMet: targets.carbsGDay == null
          ? null
          : days.where((d) => d.carbsMet == true).length,
      avgKcalVsMaintenance: vsMaint.isEmpty
          ? null
          : vsMaint.reduce((a, b) => a + b) / vsMaint.length,
    );
  }

  // Hypertrophy.
  final weekSets = [
    for (final s in inputs.strengthSets) if (_inWeek(s.date, ws)) s,
  ];
  final climbing = climbingWeekOf(climbs: inputs.climbs, weekStart: ws);
  final map = targets.muscleMap;
  final muscleSets = map == null
      ? <String, double>{}
      : productiveSetsByMuscle(
          sets: weekSets,
          map: map,
          climbingSessionCount: climbing.sessions,
          groups: targets.muscleGroups.isNotEmpty
              ? targets.muscleGroups
              : {for (final m in map.exercises.values) ...m.keys}.toList(),
        );
  final avgRir = avgRirOfProductiveSets(weekSets);

  // Strength (heavy exposures — readings kind != light_week).
  final heavy = {for (final l in _mainLifts) l: 0};
  for (final r in inputs.readings) {
    if (!_inWeek(r.date, ws) || r.kind == 'light_week') continue;
    if (heavy.containsKey(r.lift)) heavy[r.lift] = heavy[r.lift]! + 1;
  }

  final cal =
      calisthenicsWeekOf(rows: inputs.calisthenics, weekStart: ws);
  final cardio = cardioWeekOf(rows: inputs.cardio, weekStart: ws);
  final recovery = recoveryWeekOf(rows: inputs.recovery, weekStart: ws);
  final body = bodyWeekOf(rows: inputs.body, weekStart: ws);

  final decision = _decide(
    targets: targets,
    nutrition: nutrition,
    muscleSets: muscleSets,
    avgRir: avgRir,
    heavy: heavy,
    climbing: climbing,
    cal: cal,
    cardio: cardio,
    recovery: recovery,
    body: body,
  );

  return WeeklyReview(
    weekStart: ws,
    weekEnd: weekEnd,
    nutrition: nutrition,
    muscleSets: muscleSets,
    hypBand: targets.hypBand,
    avgRir: avgRir,
    heavyExposures: heavy,
    climbing: climbing,
    calisthenics: cal,
    cardio: cardio,
    recovery: recovery,
    body: body,
    decision: decision,
  );
}

String _f1(double v) => v.toStringAsFixed(1);

String _f0(double v) => v.round().toString();

List<CoachAnswer> _decide({
  required RecompTargets targets,
  required NutritionWeek? nutrition,
  required Map<String, double> muscleSets,
  required double? avgRir,
  required Map<String, int> heavy,
  required ClimbingWeek climbing,
  required CalisthenicsWeek cal,
  required CardioWeek cardio,
  required RecoveryWeek recovery,
  required BodyWeek body,
}) {
  final answers = <CoachAnswer>[];

  // 1. Protein adequate?
  if (nutrition == null || targets.proteinGDay == null) {
    answers.add(CoachAnswer(
      n: 1,
      question: 'Protein adequate?',
      verdict: ReviewVerdict.noData,
      answer: nutrition == null
          ? 'No data — no meals logged this week.'
          : 'No data — no protein target declared.',
    ));
  } else {
    final t = targets.proteinGDay!;
    final ok = (nutrition.proteinDaysMet ?? 0) >= nutrition.daysLogged - 1 &&
        nutrition.avgProteinG >= t[0];
    answers.add(CoachAnswer(
      n: 1,
      question: 'Protein adequate?',
      verdict: ok ? ReviewVerdict.yes : ReviewVerdict.no,
      answer:
          'Avg ${_f0(nutrition.avgProteinG)} g/day; target met '
          '${nutrition.proteinDaysMet}/${nutrition.daysLogged} logged days '
          '(target ${_f0(t[0])}-${_f0(t[1])} g).',
    ));
  }

  // 2. Calories ~maintenance?
  if (nutrition == null || nutrition.avgKcalVsMaintenance == null) {
    answers.add(CoachAnswer(
      n: 2,
      question: 'Calories ~maintenance?',
      verdict: ReviewVerdict.noData,
      answer: nutrition == null
          ? 'No data — no meals logged this week.'
          : 'No data — maintenance estimate not yet recorded '
              '(block 1 calibration writes nutrition.maintenance_kcal).',
    ));
  } else {
    final vs = nutrition.avgKcalVsMaintenance!;
    final ok = vs.abs() <= 150;
    answers.add(CoachAnswer(
      n: 2,
      question: 'Calories ~maintenance?',
      verdict: ok ? ReviewVerdict.yes : ReviewVerdict.mixed,
      answer: 'Avg ${_f0(nutrition.avgKcal)} kcal — '
          '${vs >= 0 ? '+' : ''}${_f0(vs)} vs maintenance '
          '${_f0(targets.maintenanceKcal!)}.',
    ));
  }

  // 3. Carbs sufficient for performance?
  if (nutrition == null || targets.carbsGDay == null) {
    answers.add(CoachAnswer(
      n: 3,
      question: 'Carbs sufficient for performance?',
      verdict: ReviewVerdict.noData,
      answer: nutrition == null
          ? 'No data — no meals logged this week.'
          : 'No data — no carb target in force this week.',
    ));
  } else {
    final c = targets.carbsGDay!;
    final ok = nutrition.avgCarbsG >= c[0];
    answers.add(CoachAnswer(
      n: 3,
      question: 'Carbs sufficient for performance?',
      verdict: ok ? ReviewVerdict.yes : ReviewVerdict.no,
      answer: 'Avg ${_f0(nutrition.avgCarbsG)} g/day; in-range '
          '${nutrition.carbDaysMet}/${nutrition.daysLogged} days '
          '(range ${_f0(c[0])}-${_f0(c[1])} g).',
    ));
  }

  // 4. Each muscle sufficient productive volume?
  if (muscleSets.isEmpty) {
    answers.add(const CoachAnswer(
      n: 4,
      question: 'Each muscle sufficient productive volume?',
      verdict: ReviewVerdict.noData,
      answer: 'No data — no exercise_muscle_map in the program.',
    ));
  } else {
    final lo = targets.hypBand[0];
    final hi = targets.hypBand[1];
    final under = [
      for (final e in muscleSets.entries) if (e.value < lo) e.key,
    ];
    final over = [
      for (final e in muscleSets.entries) if (e.value > hi) e.key,
    ];
    answers.add(CoachAnswer(
      n: 4,
      question: 'Each muscle sufficient productive volume?',
      verdict: under.isEmpty && over.isEmpty
          ? ReviewVerdict.yes
          : ReviewVerdict.no,
      answer: under.isEmpty && over.isEmpty
          ? 'All groups inside the ${_f0(lo)}-${_f0(hi)} set band.'
          : [
              if (under.isNotEmpty) 'Under band: ${under.join(', ')}.',
              if (over.isNotEmpty)
                'OVER band (excess-overlap caution): ${over.join(', ')}.',
            ].join(' '),
    ));
  }

  // 5. Hypertrophy sets close enough to failure?
  if (avgRir == null) {
    answers.add(const CoachAnswer(
      n: 5,
      question: 'Hypertrophy sets close enough to failure?',
      verdict: ReviewVerdict.noData,
      answer: 'No data — no RPE logged on productive sets '
          '(RIR = 10 - RPE).',
    ));
  } else {
    final ok = avgRir <= 3.5;
    answers.add(CoachAnswer(
      n: 5,
      question: 'Hypertrophy sets close enough to failure?',
      verdict: ok ? ReviewVerdict.yes : ReviewVerdict.no,
      answer: 'Avg ~${_f1(avgRir)} RIR on productive sets '
          '(spec: most work ~1-3 RIR).',
    ));
  }

  // 6. Strength progressing / on plan?
  final missing = [
    for (final l in _mainLifts) if ((heavy[l] ?? 0) == 0) l,
  ];
  answers.add(CoachAnswer(
    n: 6,
    question: 'Strength progressing / on plan?',
    verdict: missing.isEmpty ? ReviewVerdict.yes : ReviewVerdict.mixed,
    answer: missing.isEmpty
        ? 'Heavy exposure recorded for all four lifts.'
        : 'Heavy exposure missing: ${missing.join(', ')} '
            '(one bad/missing session != strength loss — check the '
            'working-max tab for trend).',
  ));

  // 7. Climbing / calisthenics / VO2 targets completed?
  final parts = <String>[];
  var q7Ok = true;
  var q7Data = false;
  if (targets.climbingWk != null) {
    q7Data = true;
    final ok = climbing.sessions >= targets.climbingWk!;
    q7Ok = q7Ok && ok;
    parts.add('climb ${climbing.sessions}/${_f0(targets.climbingWk!)}');
  }
  if (targets.calisthenicsWk != null) {
    q7Data = true;
    final ok = cal.sessions >= targets.calisthenicsWk!;
    q7Ok = q7Ok && ok;
    parts.add('calisthenics ${cal.sessions}/${_f0(targets.calisthenicsWk!)}');
  }
  if (targets.bike4x4Wk != null) {
    q7Data = true;
    final ok = cardio.sessions >= targets.bike4x4Wk!;
    q7Ok = q7Ok && ok;
    parts.add('4x4 ${cardio.sessions}/${_f0(targets.bike4x4Wk!)}');
  }
  answers.add(CoachAnswer(
    n: 7,
    question: 'Climbing / calisthenics / VO2 targets completed?',
    verdict: !q7Data
        ? ReviewVerdict.noData
        : q7Ok
            ? ReviewVerdict.yes
            : ReviewVerdict.mixed,
    answer: q7Data ? parts.join(' · ') : 'No session targets declared.',
  ));

  // 8. Recovery adequate? Pain outranks the numbers.
  if (recovery.painDays.isNotEmpty) {
    answers.add(CoachAnswer(
      n: 8,
      question: 'Recovery adequate?',
      verdict: ReviewVerdict.no,
      answer: 'PAIN flagged (outranks all numeric targets): '
          '${recovery.painDays.map((p) => p.text).join('; ')}.',
    ));
  } else if (recovery.daysReported == 0) {
    answers.add(const CoachAnswer(
      n: 8,
      question: 'Recovery adequate?',
      verdict: ReviewVerdict.noData,
      answer: 'No data — no recovery subjectives logged '
          '(daily_notes sleep/fatigue/soreness fields).',
    ));
  } else {
    final fatigueHigh =
        recovery.avgFatigue != null && recovery.avgFatigue! >= 3.5;
    final sleepLow =
        recovery.avgSleepHours != null && recovery.avgSleepHours! < 6.5;
    answers.add(CoachAnswer(
      n: 8,
      question: 'Recovery adequate?',
      verdict:
          fatigueHigh || sleepLow ? ReviewVerdict.no : ReviewVerdict.yes,
      answer: [
        if (recovery.avgSleepHours != null)
          'sleep ${_f1(recovery.avgSleepHours!)} h',
        if (recovery.avgFatigue != null)
          'fatigue ${_f1(recovery.avgFatigue!)}/5',
        if (recovery.avgSoreness != null)
          'soreness ${_f1(recovery.avgSoreness!)}/5',
        if (recovery.avgReadiness != null)
          'readiness ${_f1(recovery.avgReadiness!)}/5',
        'no pain flagged',
      ].join(' · '),
    ));
  }

  // 9. Body fat / waist ~stable?
  if (body.avg7d == null) {
    answers.add(const CoachAnswer(
      n: 9,
      question: 'Body fat / waist ~stable?',
      verdict: ReviewVerdict.noData,
      answer: 'No data — no weigh-ins this week.',
    ));
  } else {
    final d7 = body.change7d;
    final waistDelta = body.waistIn != null && body.prevWaistIn != null
        ? body.waistIn! - body.prevWaistIn!
        : null;
    final drifting = (d7 != null && d7 > 0.5) &&
        (waistDelta == null || waistDelta > 0.1);
    answers.add(CoachAnswer(
      n: 9,
      question: 'Body fat / waist ~stable?',
      verdict: drifting ? ReviewVerdict.mixed : ReviewVerdict.yes,
      answer: [
        '7d avg ${_f1(body.avg7d!)} lb',
        if (d7 != null) '${d7 >= 0 ? '+' : ''}${_f1(d7)} vs prior week',
        if (body.change4wk != null)
          '${body.change4wk! >= 0 ? '+' : ''}${_f1(body.change4wk!)} vs 4 wk ago',
        body.waistIn != null
            ? 'waist ${_f1(body.waistIn!)} in'
                '${waistDelta != null ? ' (${waistDelta >= 0 ? '+' : ''}${_f1(waistDelta)})' : ''}'
            : 'waist: no measurement this week',
      ].join(' · '),
    ));
  }

  // 10. Should anything actually change next week?
  final issues = <String>[];
  for (final a in answers) {
    if (a.verdict == ReviewVerdict.no) {
      issues.add('Q${a.n} ${a.question.replaceAll('?', '')}'.trim());
    }
  }
  final painFirst = recovery.painDays.isNotEmpty;
  answers.add(CoachAnswer(
    n: 10,
    question: 'Should anything actually change next week?',
    verdict: issues.isEmpty ? ReviewVerdict.yes : ReviewVerdict.mixed,
    answer: painFirst
        ? 'YES — address the pain flag first (pain outranks every '
            'numeric target); adjust training around it before touching '
            'anything else.'
        : issues.isEmpty
            ? 'No — inputs delivered; hold the plan. Never add calories '
                'just because weight is flat.'
            : 'Review: ${issues.join('; ')}. Prefer changing training/'
                'recovery over calories when the problem is training/'
                'recovery; never add calories just because weight is flat.',
  ));

  return answers;
}

// ---------------------------------------------------------------------------
// Markdown renderer (the WEEKLY sections of the tracking spec)
// ---------------------------------------------------------------------------

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String renderWeeklyReviewMarkdown(WeeklyReview r) {
  final b = StringBuffer();
  b.writeln('# Weekly recomp review — ${_ymd(r.weekStart)} '
      'to ${_ymd(r.weekEnd)}');
  b.writeln();

  b.writeln('## Nutrition');
  final n = r.nutrition;
  if (n == null) {
    b.writeln('No data — no meals logged this week.');
  } else {
    b.writeln('- Avg: ${_f0(n.avgKcal)} kcal · ${_f0(n.avgProteinG)} g '
        'protein · ${_f0(n.avgCarbsG)} g carbs · ${_f0(n.avgFatG)} g fat '
        '(${n.daysLogged} days logged)');
    String met(String label, int? v) =>
        v == null ? '$label: no target in force' : '$label $v/${n.daysLogged}';
    b.writeln('- ${met('Protein target met', n.proteinDaysMet)}; '
        '${met('fat minimum met', n.fatDaysMet)}; '
        '${met('carbs in range', n.carbDaysMet)}');
    b.writeln(n.avgKcalVsMaintenance == null
        ? '- vs maintenance: no data (maintenance not yet recorded)'
        : '- vs maintenance: ${n.avgKcalVsMaintenance! >= 0 ? '+' : ''}'
            '${_f0(n.avgKcalVsMaintenance!)} kcal/day');
  }
  b.writeln();

  b.writeln('## Hypertrophy');
  if (r.muscleSets.isEmpty) {
    b.writeln('No data — no exercise_muscle_map declared.');
  } else {
    b.writeln('Productive sets per muscle (band '
        '${_f0(r.hypBand[0])}-${_f0(r.hypBand[1])}; warmup/skill/rehab '
        'excluded; untagged legacy rows effort-inferred; climbing '
        'overlap credited):');
    for (final e in r.muscleSets.entries) {
      final flag = e.value < r.hypBand[0]
          ? ' — UNDER'
          : e.value > r.hypBand[1]
              ? ' — OVER (excess-overlap caution)'
              : '';
      b.writeln('- ${e.key}: ${_f1(e.value)}$flag');
    }
    b.writeln(r.avgRir == null
        ? '- Avg RIR: no data (RIR = 10 - RPE; no RPE on productive sets)'
        : '- Avg proximity to failure: ~${_f1(r.avgRir!)} RIR '
            '(RIR = 10 - RPE)');
  }
  b.writeln();

  b.writeln('## Strength');
  b.writeln('Heavy top-set exposures (working-max controller readings):');
  for (final e in r.heavyExposures.entries) {
    b.writeln('- ${e.key}: ${e.value}');
  }
  b.writeln();

  b.writeln('## Climbing');
  if (r.climbing.sessions == 0) {
    b.writeln('No sessions in the kaya snapshot this week '
        '(may be a stale import).');
  } else {
    b.writeln('- Sessions: ${r.climbing.sessions}');
    b.writeln('- New V5+ sends: ${r.climbing.newV5PlusSends} '
        '(onsight/flash: ${r.climbing.v5PlusOnsightFlash})');
    if (r.climbing.highestSentV != null) {
      b.writeln('- Highest sent: V${r.climbing.highestSentV}');
    }
  }
  b.writeln();

  b.writeln('## Calisthenics');
  if (r.calisthenics.sessions == 0) {
    b.writeln('No data — no calisthenics rows this week.');
  } else {
    b.writeln('- Sessions: ${r.calisthenics.sessions}');
    r.calisthenics.bests.forEach((skill, best) {
      final bits = <String>[
        if (best.bestReps != null)
          'best ${best.bestReps} reps'
              '${best.bestCleanReps != null ? ' (${best.bestCleanReps} clean)' : ''}',
        if (best.bestHoldSeconds != null)
          'best hold ${_f0(best.bestHoldSeconds!)}s',
        if (best.variation != null) '(${best.variation})',
      ];
      b.writeln('- $skill: ${bits.join(' · ')}');
    });
  }
  b.writeln();

  b.writeln('## VO2 (4x4)');
  if (r.cardio.sessions == 0) {
    b.writeln('No 4x4 session this week.');
  } else {
    b.writeln('- Sessions: ${r.cardio.sessions}'
        '${r.cardio.completedAllFour == null ? '' : r.cardio.completedAllFour! ? ' · all four intervals completed' : ' · NOT all four intervals completed'}');
    if (r.cardio.workload != null) {
      b.writeln('- Workload index ${_f1(r.cardio.workload!)} '
          '(speed × incline)'
          '${r.cardio.maxHr != null ? ' at max HR ${_f0(r.cardio.maxHr!)}' : ''}');
    }
    b.writeln(r.cardio.workloadTrendPct == null
        ? '- Workload trend: no comparable-HR prior session (±5 bpm)'
        : '- Workload vs last comparable-HR session: '
            '${r.cardio.workloadTrendPct! >= 0 ? '+' : ''}'
            '${_f1(r.cardio.workloadTrendPct!)}%');
  }
  b.writeln();

  b.writeln('## Recovery');
  if (r.recovery.daysReported == 0 && r.recovery.painDays.isEmpty) {
    b.writeln('No data — recovery subjectives not logged this week.');
  } else {
    final rec = r.recovery;
    b.writeln([
      if (rec.avgSleepHours != null) 'sleep ${_f1(rec.avgSleepHours!)} h',
      if (rec.avgSleepQuality != null)
        'quality ${_f1(rec.avgSleepQuality!)}/5',
      if (rec.avgFatigue != null) 'fatigue ${_f1(rec.avgFatigue!)}/5',
      if (rec.avgSoreness != null) 'soreness ${_f1(rec.avgSoreness!)}/5',
      if (rec.avgReadiness != null)
        'readiness ${_f1(rec.avgReadiness!)}/5',
    ].map((s) => '- $s').join('\n'));
    if (r.recovery.painDays.isNotEmpty) {
      b.writeln('- PAIN (outranks all numeric targets):');
      for (final p in r.recovery.painDays) {
        b.writeln('  - ${_ymd(p.date)}: ${p.text}');
      }
    }
  }
  b.writeln();

  b.writeln('## Body comp');
  if (r.body.avg7d == null) {
    b.writeln('No data — no weigh-ins this week.');
  } else {
    b.writeln('- 7d avg ${_f1(r.body.avg7d!)} lb'
        '${r.body.change7d != null ? ' (${r.body.change7d! >= 0 ? '+' : ''}${_f1(r.body.change7d!)} vs prior week)' : ''}'
        '${r.body.change4wk != null ? ' · ${r.body.change4wk! >= 0 ? '+' : ''}${_f1(r.body.change4wk!)} vs 4 wk ago' : ''}');
    b.writeln(r.body.waistIn == null
        ? '- Waist: no measurement this week (weekly navel measurement)'
        : '- Waist ${_f1(r.body.waistIn!)} in'
            '${r.body.prevWaistIn != null ? ' (prev ${_f1(r.body.prevWaistIn!)})' : ''}');
    b.writeln('- Do NOT react to daily weight — 7d averages only.');
  }
  b.writeln();

  b.writeln('## Coaching decision');
  for (final a in r.decision) {
    final tag = switch (a.verdict) {
      ReviewVerdict.yes => 'YES',
      ReviewVerdict.no => 'NO',
      ReviewVerdict.mixed => 'MIXED',
      ReviewVerdict.noData => 'NO DATA',
    };
    b.writeln('${a.n}. ${a.question} **$tag** — ${a.answer}');
  }
  b.writeln();
  b.writeln('_The dashboard question: am I consistently providing the '
      'stimulus, nutrition, and recovery required to gain muscle and '
      'strength while remaining ~13% body fat?_');
  return b.toString();
}

// ---------------------------------------------------------------------------
// Program-yaml targets extraction
// ---------------------------------------------------------------------------

/// Builds [RecompTargets] from a program VERSION map (the recomp
/// variant's `targets` + `hypertrophy_targets` + `exercise_muscle_map`
/// + optional `nutrition.maintenance_kcal`) and a MuscleMap parsed by
/// week_drivers.parseExerciseMuscleMap. Absent keys stay null (honest
/// no-data downstream — e.g. block 0's targets_block_0 nulls the
/// absolute nutrition keys, so cut-week reviews honestly say "no
/// target in force"). Pass [targetsInForce] (a resolved ProgramSlice's
/// merged targets) to price the week's ACTUAL targets instead of the
/// version's base `targets:` map.
RecompTargets recompTargetsFromProgram(
  Map<Object?, Object?>? version,
  MuscleMap? muscleMap, {
  Map<Object?, Object?>? targetsInForce,
}) {
  if (version == null) return RecompTargets(muscleMap: muscleMap);
  final targets = targetsInForce ?? version['targets'];
  final hyp = version['hypertrophy_targets'];
  final nutrition = version['nutrition'];

  List<double>? pair(Object? v) =>
      v is List && v.length == 2 && v.every((e) => e is num)
          ? [(v[0] as num).toDouble(), (v[1] as num).toDouble()]
          : null;
  double? num0(Object? v) =>
      v is List && v.isNotEmpty && v[0] is num
          ? (v[0] as num).toDouble()
          : v is num
              ? v.toDouble()
              : null;

  // Session-target keys come in two spellings: raw program `targets:`
  // (climbing_wk / bike_4x4_wk / muscle_up_sessions_wk) vs a resolved
  // slice's normalized targets_in_force (climbing_sessions / bike_4x4 /
  // muscle_up_sessions). Read both.
  Object? key(Object? a, Object? b) => a ?? b;
  double? climbingWk;
  if (targets is Map) {
    final c = key(targets['climbing_sessions'], targets['climbing_wk']);
    // Scalar or {lifting_block: 2, climbing_block: 3} — the review
    // can't know the block emphasis here; take the lifting_block
    // default (callers can override via the returned object).
    climbingWk = c is num
        ? c.toDouble()
        : c is Map
            ? (c['lifting_block'] as num?)?.toDouble()
            : null;
  }

  return RecompTargets(
    proteinGDay: targets is Map ? pair(targets['protein_g_day']) : null,
    fatGDayMin: targets is Map ? num0(targets['fat_g_day_min']) : null,
    carbsGDay: targets is Map ? pair(targets['carbs_g_day']) : null,
    maintenanceKcal:
        nutrition is Map ? num0(nutrition['maintenance_kcal']) : null,
    hypBand: (hyp is Map ? pair(hyp['sets_per_muscle_wk']) : null) ??
        const [8, 12],
    muscleGroups: hyp is Map && hyp['muscle_groups'] is List
        ? [for (final g in hyp['muscle_groups'] as List) g.toString()]
        : const [],
    muscleMap: muscleMap,
    climbingWk: climbingWk,
    calisthenicsWk: targets is Map
        ? (key(targets['muscle_up_sessions'], targets['muscle_up_sessions_wk'])
                as num?)
            ?.toDouble()
        : null,
    bike4x4Wk: targets is Map
        ? (key(targets['bike_4x4'], targets['bike_4x4_wk']) as num?)
            ?.toDouble()
        : null,
  );
}
