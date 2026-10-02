/// Goals evaluator — the GOALS tab's brain (bottom-nav split 2026-09-29).
///
/// The home page split into two output/input surfaces (user directive):
///   PROGRESS  outputs only — weight trajectory + strength (the hero
///             weight row + the STRENGTH card).
///   GOALS     the phase's INPUT eigenvectors — the few causal drivers
///             the user controls day to day, each a plain-language row
///             with a met / partial / unmet state.
///
/// This library is the GOALS surface's pure evaluation (no Flutter, no
/// IO — every verdict is unit-tested; the screen stays layout-only). It
/// mirrors the week_drivers contract (declared in app/dashboards.yaml,
/// phase-selected, back-compat by construction) but with the specific
/// goal set the directive names:
///
///   1. macros        protein g/lb in the phase band + carbs at/above a
///                    floor (Macrofactor meals, 7-day logged average).
///   2. calorie_band  actual 7-day-avg intake vs the phase-correct band:
///                    cut → below maintenance (a deficit); bulk /
///                    maintenance → maintenance .. +band_kcal. Maintenance
///                    is the adaptive estimate (nutrition_model); no
///                    estimate yet → honest "no data".
///   3. hard_sets     PROGRAM PROGRESS per main lift (2026-10-02): working
///                    sets logged / sets this week's EFFECTIVE program
///                    prescribes for the lift (top sets + back-offs + %TM
///                    volume slots; program_moves applied, skips
///                    excluded), over the program's MON–SUN week — the
///                    same exclusive allocation as the program day card
///                    and the missed-work detector (weekLiftCredits), so
///                    the Week tab and the Today card agree. RPE-blind;
///                    the RPE ≥ 7 hard-set count rides along as secondary
///                    info. `hard_set_targets` is an override only. With
///                    no program week supplied it falls back to the
///                    legacy hard-sets-vs-~10 count over the accounting
///                    week. Plus a per-lift "accessories done" check.
///   3b. muscle_stimulus  per-muscle-group working sets this Mon–Sun week
///                    vs a band (8–12) via the program's
///                    exercise_muscle_map (muscle_volume.dart — the same
///                    counter as the hypertrophy_volume driver), climbing
///                    sessions credited per session. Pacing-aware.
///                    v16 `tracked_groups` (lower back, front delts,
///                    forearms, core) are counted + listed in the
///                    detail, never banded or judged.
///   4. climbing      distinct climb-session days (Whoop ∪ Kaya, counted
///                    once) vs a weekly target.
///   5. cardio_4x4    distinct 4x4 cardio days vs a weekly target.
///   6. zone2_run     easy runs (Whoop) vs a weekly target — usually optional.
///
/// Declared under app/dashboards.yaml `phases:` → `<phase>:` → `goals:`;
/// absent → [parseGoals] returns null and the GOALS screen shows a
/// "no goals declared" placeholder (never crashes).
library;

import 'package:yaml/yaml.dart';

import 'missed_work.dart' show ItemCredit, weekLiftCredits;
import 'muscle_volume.dart';
import 'program_item_pricing.dart' show itemLiftKey, mainLiftOfItemName;
import 'program_metrics.dart'
    show GradedSet, mainLiftByExercise, weekStartOf;
import 'program_moves.dart' show EffectiveItem;
import 'program_week.dart' show mondayOf;
import 'whoop_activity.dart';

// ---------------------------------------------------------------------------
// Config (dashboards.yaml phases.<phase>.goals)
// ---------------------------------------------------------------------------

/// One declared goal. Only the fields its `id` needs are read.
class GoalConfig {
  final String id;

  /// Row title. Absent → a per-id default.
  final String? label;

  /// One-line plain-language description shown under the title.
  final String? description;

  // --- macros ---
  /// protein g-per-lb-of-bodyweight band ([0.8, 1.0]).
  final List<double>? proteinGPerLb;

  /// ABSOLUTE protein band in grams ([160, 175]) — wins over
  /// [proteinGPerLb] when declared (post-cut recomp).
  final List<double>? proteinGDay;

  /// carbs sufficiency floor in grams/day (soft — "enough").
  final double? carbsFloorGDay;

  // --- calorie_band ---
  /// 'deficit' (cut: below maintenance) or 'surplus' (bulk/maintain:
  /// maintenance .. maintenance + [bandKcal]).
  final String? calorieMode;

  /// surplus mode: kcal above maintenance the band tops out at (≈200).
  final double? bandKcal;

  // --- hard_sets ---
  /// The main lifts each getting a hard-set count (default the four).
  final List<String> lifts;

  /// Hard-set target per lift (~10 — the hypertrophy landmark).
  final int? hardSetTarget;

  /// Per-lift overrides of [hardSetTarget] (`hard_set_targets:` map,
  /// e.g. `{deadlift: 3}` — the routine trains deadlift once a week with
  /// deliberately low supplemental volume, so 10 is unreachable by
  /// design). A separate key so older apps (which cast
  /// `hard_set_target` as num) keep parsing.
  final Map<String, int> hardSetTargetByLift;

  /// The minimum RPE that counts as a "hard set" (default 7 — RPE 7 and
  /// above). Declared as a single number (`hard_rpe_min: 7`); a legacy
  /// `[lo, hi]` band is still accepted and only its lo is read (the
  /// threshold is open-ended above — an RPE 9 set still counts).
  final double? hardRpeMin;

  /// Per-lift associated accessory exercise names (from the routine).
  /// lift → [exercise names]. A lift's accessory check is met when EVERY
  /// listed accessory has ≥ 1 logged set this week.
  final Map<String, List<String>> accessories;

  // --- muscle_stimulus ---
  /// Weekly working-set band per muscle group ([8, 12]).
  final List<double>? band;

  /// Groups evaluated. Empty → the program's
  /// hypertrophy_targets.muscle_groups (GoalInputs.muscleGroups).
  final List<String> muscleGroups;

  /// Tracked-only groups (v16 `tracked_groups`): counted and shown in
  /// the detail sheet, never banded or judged. Empty → the program's
  /// hypertrophy_targets.tracked_groups (GoalInputs.trackedGroups).
  final List<String> trackedGroups;

  // --- climbing / cardio_4x4 / zone2_run ---
  final double? target;

  /// A "nice to have" goal: unmet renders [GoalStatus.optional] (neutral),
  /// never the red unmet state.
  final bool optional;

  // --- zone2_run ---
  /// Minimum run length in minutes (default 20).
  final double? minMinutes;

  /// Max average HR as a fraction of the user's max HR (default 0.75).
  final double? maxAvgHrPct;

  const GoalConfig({
    required this.id,
    this.label,
    this.description,
    this.proteinGPerLb,
    this.proteinGDay,
    this.carbsFloorGDay,
    this.calorieMode,
    this.bandKcal,
    this.lifts = const [],
    this.hardSetTarget,
    this.hardSetTargetByLift = const {},
    this.hardRpeMin,
    this.accessories = const {},
    this.band,
    this.muscleGroups = const [],
    this.trackedGroups = const [],
    this.target,
    this.optional = false,
    this.minMinutes,
    this.maxAvgHrPct,
  });
}

List<double>? _numPair(Object? v) =>
    v is List && v.length == 2 && v.every((e) => e is num)
        ? [(v[0] as num).toDouble(), (v[1] as num).toDouble()]
        : null;

/// Parses `phases:` → phase value → its `goals:` list. Null when nothing
/// declares goals (or the yaml is missing/malformed) — the screen shows a
/// placeholder. Entries without an id are skipped, never fatal.
Map<String, List<GoalConfig>>? parseGoals(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  Object? doc;
  try {
    doc = loadYaml(raw);
  } catch (_) {
    return null;
  }
  if (doc is! Map) return null;
  final phases = doc['phases'];
  if (phases is! Map) return null;
  final out = <String, List<GoalConfig>>{};
  for (final entry in phases.entries) {
    final name = entry.key?.toString().trim() ?? '';
    final body = entry.value;
    if (name.isEmpty || body is! Map) continue;
    final goals = body['goals'];
    if (goals is! List) continue;
    final parsed = <GoalConfig>[];
    for (final gg in goals) {
      if (gg is! Map) continue;
      final id = gg['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final lifts = gg['lifts'];
      final acc = gg['accessories'];
      final perLift = gg['hard_set_targets'];
      final groups = gg['muscle_groups'];
      final tracked = gg['tracked_groups'];
      parsed.add(
        GoalConfig(
          id: id,
          label: gg['label']?.toString(),
          description: gg['description']?.toString(),
          proteinGPerLb: _numPair(gg['protein_g_per_lb']),
          proteinGDay: _numPair(gg['protein_g_day']),
          carbsFloorGDay: (gg['carbs_floor_g_day'] as num?)?.toDouble(),
          calorieMode: gg['calorie_mode']?.toString(),
          bandKcal: (gg['band_kcal'] as num?)?.toDouble(),
          lifts: lifts is List
              ? [for (final l in lifts) l.toString()]
              : const [],
          hardSetTarget: (gg['hard_set_target'] as num?)?.toInt(),
          hardSetTargetByLift: perLift is Map
              ? {
                  for (final e in perLift.entries)
                    if (e.value is num)
                      e.key.toString(): (e.value as num).toInt(),
                }
              : const {},
          hardRpeMin: (gg['hard_rpe_min'] as num?)?.toDouble() ??
              _numPair(gg['hard_rpe'])?.first,
          accessories: acc is Map
              ? {
                  for (final e in acc.entries)
                    if (e.value is List)
                      e.key.toString(): [
                        for (final x in (e.value as List)) x.toString(),
                      ],
                }
              : const {},
          band: _numPair(gg['band']),
          muscleGroups: groups is List
              ? [for (final g in groups) g.toString()]
              : const [],
          trackedGroups: tracked is List
              ? [for (final g in tracked) g.toString()]
              : const [],
          target: (gg['target'] as num?)?.toDouble(),
          optional: gg['optional'] == true,
          minMinutes: (gg['min_minutes'] as num?)?.toDouble(),
          maxAvgHrPct: (gg['max_avg_hr_pct'] as num?)?.toDouble(),
        ),
      );
    }
    if (parsed.isNotEmpty) out[name] = parsed;
  }
  return out.isEmpty ? null : out;
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

/// met      the goal is satisfied.
/// partial  progress made but not there yet — the amber "on the way"
///          state (also the calorie band's "close but not quite").
/// unmet    no progress / a floor breached — the red state.
/// unknown  can't be evaluated (no data, no target in force).
/// optional  a nice-to-have goal not (yet) met — neutral, never red.
enum GoalStatus { met, partial, unmet, unknown, optional }

/// One per-lift tick (hard_sets). Program mode: [done] = working sets
/// credited to the lift's prescribed items this Mon–Sun week, [target] =
/// the sets the effective week prescribes (or the declared override);
/// legacy mode: [done] = [hardSets], [target] = the flat ~10.
class GoalLiftTick {
  final String lift;

  /// Sets RPE ≥ the declared minimum (default 7) this week — the
  /// primary number in legacy mode, secondary info in program mode.
  final int hardSets;

  /// The per-lift target (program prescription, override, or ~10).
  final int target;

  /// The chip's primary count (program sets done; legacy = [hardSets]).
  final int done;

  /// True when [target] comes from the program (not typed / legacy).
  final bool fromProgram;

  /// A prescribed item for this lift due BEFORE today is short — the
  /// same condition the missed-work detector reports.
  final bool behind;

  /// Whether this lift's associated accessories were all hit (null when
  /// none are declared for the lift).
  final bool? accessoriesDone;

  /// Weekdays (DateTime.monday..sunday) this week trains the lift, in
  /// week order. Empty → unknown (no routine/program supplied).
  final List<int> scheduledDays;

  /// Weekdays from today on that still carry unfinished work for the
  /// lift (program mode), or the scheduled days still ahead (legacy).
  /// Drives the "· Fri" not-yet-due hint — deadlift is Friday-only, so
  /// it reads 0 most of the week without being missed.
  final List<int> remainingDays;

  const GoalLiftTick({
    required this.lift,
    required this.hardSets,
    required this.target,
    int? done,
    this.fromProgram = false,
    this.behind = false,
    this.accessoriesDone,
    this.scheduledDays = const [],
    this.remainingDays = const [],
  }) : done = done ?? hardSets;

  bool get complete => done >= target;

  /// True when nothing is logged yet but the lift's day hasn't passed —
  /// the chip should say when it's due rather than read as missed.
  bool get pending => done == 0 && remainingDays.isNotEmpty;

  /// Short of target with work still scheduled ahead — the chip appends
  /// the remaining days ("bench 4/11 · Fri").
  bool get dueAhead => !complete && remainingDays.isNotEmpty;
}

/// One muscle group's row (muscle_stimulus).
class GoalMuscleRow {
  final String group;

  /// Working sets credited this Mon–Sun week (fractional).
  final double sets;

  /// The band.
  final double lo;
  final double hi;

  /// Expected sets by today at an even pace: lo × (days elapsed / 7).
  final double pace;

  /// Contributor → sets it credited (logged exercise names; climbing as
  /// "Climbing sessions"), largest first.
  final List<MapEntry<String, double>> contributors;

  /// A tracked-only group (v16 `tracked_groups`: lower back, front
  /// delts, forearms, core): sets are shown, but it has no band — never
  /// over / in range / under, never behind pace, never red.
  final bool tracked;

  const GoalMuscleRow({
    required this.group,
    required this.sets,
    required this.lo,
    required this.hi,
    required this.pace,
    this.contributors = const [],
    this.tracked = false,
  });

  bool get over => !tracked && sets > hi + 1e-9;
  bool get inBand => !tracked && !over && sets >= lo - 1e-9;
  bool get under => !tracked && sets < lo - 1e-9;

  /// Under the band AND under the even-pace line.
  bool get behindPace => under && sets < pace - 1e-9;

  /// 'under' | 'in range' | 'over' | 'tracked'.
  String get state => tracked
      ? 'tracked'
      : over
          ? 'over'
          : inBand
              ? 'in range'
              : 'under';
}

/// One evaluated goal, preformatted for the row.
class GoalEval {
  final GoalConfig config;
  final GoalStatus status;

  /// The headline value ("0.94 g/lb", "in a deficit", "3/4 lifts").
  final String value;

  /// A short secondary line (e.g. "carbs 240 g" or "1,850 kcal · maint
  /// 2,100"). Empty → none.
  final String detail;

  /// Per-lift ticks (hard_sets only; empty otherwise).
  final List<GoalLiftTick> ticks;

  /// Per-muscle rows (muscle_stimulus only; empty otherwise) — the
  /// BANDED groups only; these alone decide status and counts.
  final List<GoalMuscleRow> muscles;

  /// Tracked-only muscle rows (muscle_stimulus; [GoalMuscleRow.tracked])
  /// — shown in the detail sheet, never counted toward status.
  final List<GoalMuscleRow> trackedMuscles;

  const GoalEval({
    required this.config,
    required this.status,
    required this.value,
    this.detail = '',
    this.ticks = const [],
    this.muscles = const [],
    this.trackedMuscles = const [],
  });

  static const _defaultLabels = {
    'macros': 'Macros',
    'calorie_band': 'Calories',
    'hard_sets': 'Program sets per lift',
    'muscle_stimulus': 'Sets per muscle group',
    'climbing': 'Climbing',
    'cardio_4x4': 'Cardio',
    'zone2_run': 'Zone-2 run',
  };

  String get label => config.label ?? _defaultLabels[config.id] ?? config.id;
}

/// Inputs the evaluators read — already fetched by the screen, same
/// shape philosophy as WeekDriverInputs.
class GoalInputs {
  /// §2.5 graded main-lift sets over full history (RPE carried); the
  /// hard-set counter filters to the accounting week and the RPE floor.
  final List<GradedSet> graded;

  /// ALL logged strength rows (exercise name + date) — the accessory
  /// completion check reads exact names.
  final List<({DateTime date, String exercise})> strengthRows;

  /// Calendar day → total protein grams (meals summed per day).
  final Map<DateTime, double> proteinByDay;

  /// Calendar day → total carbs grams.
  final Map<DateTime, double> carbsByDay;

  /// Calendar day → total calories (logged days only clear the floor
  /// upstream — here we just average what's present in the week).
  final Map<DateTime, double> kcalByDay;

  /// Current bodyweight (lb) — prices the protein g/lb band.
  final double? bodyweightLb;

  /// 7-day-average intake (kcal) for the calorie band — from
  /// nutrition_model's NutritionAvg (logged days only). Null → no data.
  final double? intakeKcal7d;

  /// The adaptive maintenance estimate (kcal). Null → the calorie band
  /// can't be judged.
  final double? maintenanceKcal;

  /// Distinct climb-session dates.
  final List<DateTime> climbingDates;

  /// Distinct 4x4 cardio dates (caller applies the type filter).
  final List<DateTime> cardioDates;

  /// Whoop activities (whoop_activity.dart) — climbing credit + zone-2.
  final List<WhoopActivity> activities;

  /// The user's max HR (meta `user_max_hr`). Null → zone-2 can't judge.
  final double? maxHr;

  /// Main lift → weekdays the routine trains it ([mainLiftWeekdays]).
  /// Empty → the hard-set ticks carry no schedule. (Legacy mode only —
  /// program mode reads the days off [programWeek].)
  final Map<String, Set<int>> liftDays;

  /// The EFFECTIVE Mon–Sun program week (program_moves applied) —
  /// WeekStateLoader.week. Non-null switches hard_sets to program
  /// progress.
  final Map<DateTime, List<EffectiveItem>>? programWeek;

  /// The week's intentional skips (program_moves skip keys).
  final Set<String> programSkips;

  /// Main lift per prescribed item, keyed by itemLiftKey(home, name)
  /// (program_item_pricing.mainLiftByItem). Items absent here fall back
  /// to the name ([mainLiftOfItemName]).
  final Map<String, String> itemLifts;

  /// WORKING sets (warm-ups excluded — working_sets.dart) logged this
  /// Mon–Sun week, strength + calisthenics, one entry per set — the
  /// program-credit and muscle-stimulus source.
  final List<({DateTime date, String exercise})> weekWorkingSets;

  /// The program's exercise → muscle credit map. Null → muscle_stimulus
  /// reports no data.
  final MuscleMap? muscleMap;

  /// The program's hypertrophy muscle groups (hypertrophy_targets).
  final List<String> muscleGroups;

  /// The program's tracked-only groups (hypertrophy_targets
  /// .tracked_groups, v16) — counted + shown, never banded.
  final List<String> trackedGroups;

  const GoalInputs({
    this.graded = const [],
    this.strengthRows = const [],
    this.proteinByDay = const {},
    this.carbsByDay = const {},
    this.kcalByDay = const {},
    this.bodyweightLb,
    this.intakeKcal7d,
    this.maintenanceKcal,
    this.climbingDates = const [],
    this.cardioDates = const [],
    this.activities = const [],
    this.maxHr,
    this.liftDays = const {},
    this.programWeek,
    this.programSkips = const {},
    this.itemLifts = const {},
    this.weekWorkingSets = const [],
    this.muscleMap,
    this.muscleGroups = const [],
    this.trackedGroups = const [],
  });
}

const _weekdayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// Main lift → the weekdays (DateTime.monday..sunday) a resolved routine
/// week (program_current.routineWeekFor) plans it. Reads each day's
/// `planned` list (an alternation map contributes every variant); only
/// exact main-lift exercise names count. Malformed → empty.
Map<String, Set<int>> mainLiftWeekdays(Map<Object?, Object?>? week) {
  final out = <String, Set<int>>{};
  if (week == null) return out;
  for (var i = 0; i < 7; i++) {
    final day = week[_weekdayKeys[i]];
    if (day is! Map) continue;
    final planned = day['planned'];
    final lists = planned is List
        ? [planned]
        : planned is Map
            ? planned.values.whereType<List>().toList()
            : const <List>[];
    for (final list in lists) {
      for (final item in list) {
        if (item is! Map) continue;
        final lift = mainLiftByExercise[item['exercise']?.toString()];
        if (lift != null) (out[lift] ??= <int>{}).add(i + 1);
      }
    }
  }
  return out;
}

/// Short weekday label (DateTime.monday → 'Mon').
String weekdayShort(int weekday) =>
    const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][weekday - 1];

const List<String> _defaultLifts = ['squat', 'bench', 'deadlift', 'press'];

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

int _daysBetween(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day)
    .difference(DateTime.utc(a.year, a.month, a.day))
    .inDays;

/// Averages the grams/kcal maps over the days IN this accounting week
/// that carry a value (never fabricates zero days).
double? _weekAvg(Map<DateTime, double> byDay, bool Function(DateTime) inWeek) {
  double sum = 0;
  var n = 0;
  byDay.forEach((d, v) {
    if (!inWeek(d)) return;
    sum += v;
    n++;
  });
  return n == 0 ? null : sum / n;
}

/// Evaluates [configs] against the CURRENT accounting week (the week of
/// [today] keyed by [weekStartDay]). Future rows never count. Unknown
/// ids are skipped so a newer config never breaks an older app.
List<GoalEval> evaluateGoals({
  required List<GoalConfig> configs,
  required GoalInputs inputs,
  required DateTime today,
  int weekStartDay = DateTime.monday,
}) {
  final weekStart = weekStartOf(_day(today), weekStartDay);
  bool inWeek(DateTime d) =>
      _daysBetween(d, today) >= 0 &&
      weekStartOf(_day(d), weekStartDay) == weekStart;
  // The program's Mon–Sun week (to date) — program progress + muscle
  // stimulus, consistent with the program card. The other goals keep
  // the accounting week.
  final monday = mondayOf(_day(today));
  bool inProgramWeek(DateTime d) =>
      _daysBetween(d, today) >= 0 && !_day(d).isBefore(monday);

  final out = <GoalEval>[];
  for (final c in configs) {
    switch (c.id) {
      case 'macros':
        final protein = _weekAvg(inputs.proteinByDay, inWeek);
        final carbs = _weekAvg(inputs.carbsByDay, inWeek);
        // Protein is the gate; carbs "enough" is a secondary check.
        GoalStatus proteinStatus;
        String proteinValue;
        if (c.proteinGDay != null) {
          // Absolute band (post-cut recomp).
          final lo = c.proteinGDay![0];
          if (protein == null) {
            proteinStatus = GoalStatus.unknown;
            proteinValue = 'protein — g';
          } else {
            proteinStatus =
                protein >= lo ? GoalStatus.met : GoalStatus.unmet;
            proteinValue = 'protein ${protein.round()} g';
          }
        } else if (c.proteinGPerLb != null && inputs.bodyweightLb != null &&
            inputs.bodyweightLb! > 0) {
          final lo = c.proteinGPerLb![0];
          if (protein == null) {
            proteinStatus = GoalStatus.unknown;
            proteinValue = 'protein — g/lb';
          } else {
            final gPerLb = protein / inputs.bodyweightLb!;
            proteinStatus =
                gPerLb >= lo ? GoalStatus.met : GoalStatus.unmet;
            proteinValue = 'protein ${gPerLb.toStringAsFixed(2)} g/lb';
          }
        } else {
          proteinStatus = GoalStatus.unknown;
          proteinValue = 'protein — ';
        }
        // Carbs sufficiency: at/above the floor is met; below is partial
        // (a soft "eat a bit more", never the hard red).
        String carbsDetail;
        var carbsShort = false;
        if (c.carbsFloorGDay == null || carbs == null) {
          carbsDetail = carbs == null ? 'carbs — g' : 'carbs ${carbs.round()} g';
        } else {
          carbsShort = carbs < c.carbsFloorGDay!;
          carbsDetail = 'carbs ${carbs.round()} g'
              '${carbsShort ? ' (aim ≥ ${c.carbsFloorGDay!.round()})' : ''}';
        }
        // Combined: protein missed → unmet; protein met but carbs short
        // → partial; both good → met.
        final status = proteinStatus == GoalStatus.unknown
            ? GoalStatus.unknown
            : proteinStatus == GoalStatus.unmet
                ? GoalStatus.unmet
                : carbsShort
                    ? GoalStatus.partial
                    : GoalStatus.met;
        out.add(GoalEval(
          config: c,
          status: status,
          value: proteinValue,
          detail: carbsDetail,
        ));

      case 'calorie_band':
        final intake = inputs.intakeKcal7d;
        final maint = inputs.maintenanceKcal;
        if (intake == null || maint == null) {
          out.add(GoalEval(
            config: c,
            status: GoalStatus.unknown,
            value: 'no data',
            detail: intake == null
                ? 'need Macrofactor logging'
                : 'need a maintenance estimate',
          ));
          break;
        }
        final delta = intake - maint;
        final detail = '${_kcal(intake)} · maintenance ${_kcal(maint)}';
        if (c.calorieMode == 'surplus') {
          // maintenance .. maintenance + band (bulk / reverse / gaining).
          final band = c.bandKcal ?? 200;
          final GoalStatus status;
          final String value;
          if (delta >= 0 && delta <= band) {
            status = GoalStatus.met;
            value = 'in the band (+${delta.round()} kcal)';
          } else if (delta < 0) {
            status = GoalStatus.partial;
            value = 'under maintenance (${delta.round()} kcal)';
          } else {
            status = GoalStatus.unmet;
            value = 'over the band (+${delta.round()} kcal)';
          }
          out.add(GoalEval(
            config: c,
            status: status,
            value: value,
            detail: detail,
          ));
        } else {
          // deficit (cut): below maintenance is the goal.
          final GoalStatus status;
          final String value;
          if (delta < 0) {
            status = GoalStatus.met;
            value = 'in a deficit (${delta.round()} kcal)';
          } else if (delta == 0) {
            status = GoalStatus.partial;
            value = 'at maintenance';
          } else {
            status = GoalStatus.unmet;
            value = 'over maintenance (+${delta.round()} kcal)';
          }
          out.add(GoalEval(
            config: c,
            status: status,
            value: value,
            detail: detail,
          ));
        }

      case 'hard_sets' when inputs.programWeek != null:
        out.add(_programSets(c, inputs, today, inProgramWeek));

      case 'muscle_stimulus':
        out.add(_muscleStimulus(c, inputs, today, inProgramWeek));

      case 'hard_sets':
        final lifts = c.lifts.isEmpty ? _defaultLifts : c.lifts;
        final target = c.hardSetTarget ?? 10;
        int targetFor(String lift) => c.hardSetTargetByLift[lift] ?? target;
        // Weekdays in accounting-week order; which are still ahead.
        int pos(int weekday) => (weekday - weekStartDay + 7) % 7;
        final todayPos = pos(_day(today).weekday);
        List<int> ordered(String lift) =>
            (inputs.liftDays[lift] ?? const <int>{}).toList()
              ..sort((a, b) => pos(a).compareTo(pos(b)));
        final rpeMin = c.hardRpeMin ?? 7.0;
        int hardSets(String lift) => inputs.graded
            .where((s) =>
                s.lift == lift &&
                inWeek(s.date) &&
                s.rpe != null &&
                s.rpe! >= rpeMin)
            .length;
        // Per-lift accessory completion: every declared accessory needs
        // ≥ 1 logged set this week. No accessories declared → null.
        bool? accessoriesDone(String lift) {
          final names = c.accessories[lift];
          if (names == null || names.isEmpty) return null;
          for (final name in names) {
            final hit = inputs.strengthRows.any(
              (r) => r.exercise == name && inWeek(r.date),
            );
            if (!hit) return false;
          }
          return true;
        }

        final ticks = <GoalLiftTick>[
          for (final lift in lifts)
            GoalLiftTick(
              lift: lift,
              hardSets: hardSets(lift),
              target: targetFor(lift),
              accessoriesDone: accessoriesDone(lift),
              scheduledDays: ordered(lift),
              remainingDays: [
                for (final d in ordered(lift))
                  if (pos(d) >= todayPos) d,
              ],
            ),
        ];
        final atTarget = ticks.where((t) => t.hardSets >= t.target).length;
        final anyProgress = ticks.any((t) => t.hardSets > 0);
        final status = atTarget == lifts.length
            ? GoalStatus.met
            : anyProgress
                ? GoalStatus.partial
                : GoalStatus.unmet;
        final uniform = ticks.every((t) => t.target == target);
        out.add(GoalEval(
          config: c,
          status: status,
          value: uniform
              ? '$atTarget/${lifts.length} lifts at $target'
              : '$atTarget/${lifts.length} lifts at target',
          ticks: ticks,
        ));

      case 'climbing':
        // Whoop says a climb happened even when Kaya hasn't exported
        // yet; climbDaysUnion (I1) also folds a Kaya D+1 export into a
        // Whoop climb on D — Kaya's export date can be the UTC date, so
        // an evening session would otherwise count twice. Filter to the
        // accounting week AFTER the fold.
        final sessions = climbDaysUnion(
          inputs.climbingDates,
          whoopClimbDays(inputs.activities),
        ).where(inWeek).length;
        final t = (c.target ?? 2).round();
        out.add(GoalEval(
          config: c,
          status: sessions >= t
              ? GoalStatus.met
              : sessions > 0
                  ? GoalStatus.partial
                  : GoalStatus.unmet,
          value: '$sessions/$t sessions',
        ));

      case 'cardio_4x4':
        final sessions = <DateTime>{
          for (final d in inputs.cardioDates)
            if (inWeek(d)) _day(d),
        }.length;
        final t = (c.target ?? 1).round();
        out.add(GoalEval(
          config: c,
          status: sessions >= t ? GoalStatus.met : GoalStatus.unmet,
          value: '$sessions/$t session${t == 1 ? '' : 's'}',
        ));

      case 'zone2_run':
        final maxHr = inputs.maxHr;
        if (maxHr == null || maxHr <= 0) {
          out.add(GoalEval(
            config: c,
            status: GoalStatus.unknown,
            value: 'set max HR',
            detail: 'Integrations → Whoop live heart rate',
          ));
          break;
        }
        final runs = [
          for (final a in inputs.activities)
            if (inWeek(a.date) &&
                isZone2Run(a,
                    maxHr: maxHr,
                    minMinutes: c.minMinutes ?? 20,
                    maxAvgPct: c.maxAvgHrPct ?? 0.75))
              a,
        ];
        final days = {for (final a in runs) a.date}.length;
        final t = (c.target ?? 1).round();
        final last = runs.isEmpty ? null : runs.last;
        out.add(GoalEval(
          config: c,
          status: days >= t
              ? GoalStatus.met
              : days > 0
                  ? GoalStatus.partial
                  : GoalStatus.unmet,
          value: '$days/$t run${t == 1 ? '' : 's'}',
          detail: last == null
              ? ''
              : '${last.durationMin!.round()} min · avg HR ${last.avgHr!.round()}',
        ));

      default:
        // Unknown id — newer config, older app. Skip, never error.
        break;
    }
  }
  // Optional goals never go red: unmet → the neutral "nice to have".
  return [
    for (final e in out)
      e.config.optional && e.status == GoalStatus.unmet
          ? GoalEval(
              config: e.config,
              status: GoalStatus.optional,
              value: e.value,
              detail: e.detail.isEmpty ? 'nice to have' : e.detail,
              ticks: e.ticks,
              muscles: e.muscles,
            )
          : e,
  ];
}

/// hard_sets in PROGRAM mode (see the library doc, goal 3).
GoalEval _programSets(
  GoalConfig c,
  GoalInputs inputs,
  DateTime today,
  bool Function(DateTime) inWeek,
) {
  final t = _day(today);
  final lifts = c.lifts.isEmpty ? _defaultLifts : c.lifts;
  final credits = weekLiftCredits(
    week: inputs.programWeek!,
    strengthRows: inputs.weekWorkingSets,
    today: t,
    skipped: inputs.programSkips,
  );
  String? liftOf(ItemCredit ic) =>
      inputs.itemLifts[itemLiftKey(ic.home, ic.item.name)] ??
      mainLiftOfItemName(ic.item.name);
  final rpeMin = c.hardRpeMin ?? 7.0;
  int hardSets(String lift) => inputs.graded
      .where((s) =>
          s.lift == lift && inWeek(s.date) && s.rpe != null && s.rpe! >= rpeMin)
      .length;
  bool? accessoriesDone(String lift) {
    final names = c.accessories[lift];
    if (names == null || names.isEmpty) return null;
    for (final name in names) {
      final hit = inputs.weekWorkingSets
              .any((r) => r.exercise == name && inWeek(r.date)) ||
          inputs.strengthRows.any((r) => r.exercise == name && inWeek(r.date));
      if (!hit) return false;
    }
    return true;
  }

  List<int> days(Iterable<ItemCredit> items) =>
      ({for (final i in items) i.day.weekday}.toList()..sort());

  final ticks = <GoalLiftTick>[];
  for (final lift in lifts) {
    final items = [for (final ic in credits) if (liftOf(ic) == lift) ic];
    final prescribed = items.fold<int>(0, (n, i) => n + i.target);
    final override = c.hardSetTargetByLift[lift];
    // A typed override isn't program-shaped, so it counts every working
    // set of the lift this week (uncapped); the program target counts
    // the allocation (each set credits one item, at most its sets).
    final done = override != null
        ? inputs.weekWorkingSets
            .where((r) =>
                inWeek(r.date) && mainLiftByExercise[r.exercise] == lift)
            .length
        : items.fold<int>(0, (n, i) => n + i.credited);
    ticks.add(GoalLiftTick(
      lift: lift,
      hardSets: hardSets(lift),
      target: override ?? prescribed,
      done: done,
      fromProgram: override == null,
      behind: override == null &&
          items.any((i) => i.day.isBefore(t) && i.short),
      accessoriesDone: accessoriesDone(lift),
      scheduledDays: days(items),
      remainingDays: days([
        for (final i in items)
          if (!i.day.isBefore(t) && i.short) i,
      ]),
    ));
  }
  final complete = ticks.where((k) => k.complete).length;
  final behind = [for (final k in ticks) if (k.behind) k];
  final doneSum = ticks.fold<int>(0, (n, k) => n + k.done.clamp(0, k.target));
  final targetSum = ticks.fold<int>(0, (n, k) => n + k.target);
  // Status: every lift done → met; prescribed work from an EARLIER day
  // still short (what the Today card lists as missed) → unmet; anything
  // else is still on schedule → partial. Never red for work not yet due.
  final status = complete == ticks.length
      ? GoalStatus.met
      : behind.isNotEmpty
          ? GoalStatus.unmet
          : GoalStatus.partial;
  final detail = complete == ticks.length
      ? 'all program sets done · Mon–Sun program week'
      : behind.isNotEmpty
          ? 'behind on ${behind.map((k) => liftDisplayName(k.lift)).join(', ')}'
              ' · Mon–Sun program week'
          : 'on schedule · Mon–Sun program week';
  return GoalEval(
    config: c,
    status: status,
    value: '$doneSum of $targetSum program sets · '
        '$complete/${ticks.length} lifts done',
    detail: detail,
    ticks: ticks,
  );
}

/// muscle_stimulus (see the library doc, goal 3b).
///
/// Status (decided 2026-10-02): every group in the band → met; otherwise
/// partial — the row is NEVER red. Under the band mid-week is simply not
/// done yet (and on a cut under-dosing isn't failure); the detail says
/// how many groups trail an even pace (lo × days elapsed / 7). OVER the
/// band is the program's declared caution (excess overlapping volume) —
/// flagged per group (red chip + "N over the range"), but the live cut
/// week itself prescribes back/biceps/triceps above 12 once climbing is
/// credited, so a red row would fire every week and mean nothing.
GoalEval _muscleStimulus(
  GoalConfig c,
  GoalInputs inputs,
  DateTime today,
  bool Function(DateTime) inWeek,
) {
  final map = inputs.muscleMap;
  if (map == null) {
    return GoalEval(
      config: c,
      status: GoalStatus.unknown,
      value: 'no data',
      detail: 'the program declares no exercise-to-muscle map',
    );
  }
  final band = c.band ?? const [8.0, 12.0];
  final lo = band[0] <= band[1] ? band[0] : band[1];
  final hi = band[0] <= band[1] ? band[1] : band[0];
  final trackedDeclared =
      c.trackedGroups.isNotEmpty ? c.trackedGroups : inputs.trackedGroups;
  final groups = c.muscleGroups.isNotEmpty
      ? c.muscleGroups
      : inputs.muscleGroups.isNotEmpty
          ? inputs.muscleGroups
          : {for (final m in map.exercises.values) ...m.keys}
              .where((g) => !trackedDeclared.contains(g))
              .toList();
  // A group declared both ways stays banded.
  final tracked = [
    for (final g in trackedDeclared)
      if (!groups.contains(g)) g,
  ];
  final climbSessions = climbDaysUnion(
    inputs.climbingDates,
    whoopClimbDays(inputs.activities),
  ).where(inWeek).length;
  final volume = weeklyMuscleVolume(
    map: map,
    groups: [...groups, ...tracked],
    setNames: [
      for (final s in inputs.weekWorkingSets)
        if (inWeek(s.date)) s.exercise,
    ],
    climbSessions: climbSessions,
  );
  final pace = lo * _day(today).weekday / 7;
  final rows = <GoalMuscleRow>[
    for (final g in groups)
      GoalMuscleRow(
        group: g,
        sets: volume[g]!.sets,
        lo: lo,
        hi: hi,
        pace: pace,
        contributors: volume[g]!.byExercise.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)),
      ),
  ];
  final trackedRows = <GoalMuscleRow>[
    for (final g in tracked)
      GoalMuscleRow(
        group: g,
        sets: volume[g]!.sets,
        lo: lo,
        hi: hi,
        pace: pace,
        tracked: true,
        contributors: volume[g]!.byExercise.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)),
      ),
  ];
  final inBand = rows.where((r) => r.inBand).length;
  final over = rows.where((r) => r.over).length;
  final behind = rows.where((r) => r.behindPace).length;
  final under = rows.where((r) => r.under).length;
  final status =
      inBand == rows.length ? GoalStatus.met : GoalStatus.partial;
  final parts = <String>[
    if (over > 0) '$over over the range',
    if (behind > 0)
      '$behind behind pace'
    else if (under > 0)
      '${over > 0 ? 'the rest' : 'all'} on pace',
    'Mon–Sun',
  ];
  return GoalEval(
    config: c,
    status: status,
    value: '$inBand of ${rows.length} groups in ${_fmtNum(lo)}–${_fmtNum(hi)}',
    detail: parts.join(' · '),
    muscles: rows,
    trackedMuscles: trackedRows,
  );
}

String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// Plain lift name for UI copy ('press' → 'overhead press').
String liftDisplayName(String key) => switch (key) {
      'press' => 'overhead press',
      _ => key,
    };

/// Plain sentence-case muscle-group name ('hamstrings_glutes' →
/// 'Hamstrings and glutes', 'upper_back' → 'Upper back', 'side_delts' →
/// 'Side delts') — no abbreviations on the Week tab.
String muscleDisplayName(String key) {
  final s = switch (key) {
    'hamstrings_glutes' => 'hamstrings and glutes',
    _ => key.replaceAll('_', ' ').trim(),
  };
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// "1,850 kcal" with a thousands separator.
String _kcal(double v) {
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '$b kcal';
}
