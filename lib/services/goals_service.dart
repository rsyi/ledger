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
///   3. hard_sets     per main lift, sets close to failure (RPE in the
///                    declared band, default 8-9) this accounting week
///                    toward ~10 — the common ~10-hard-sets/muscle/week
///                    hypertrophy landmark (Schoenfeld et al.). Plus a
///                    per-lift "accessories done" check: did that lift's
///                    associated accessories (declared in the config,
///                    derived from the routine) get hit this week.
///   4. climbing      distinct climb-session days vs a weekly target.
///   5. cardio_4x4    distinct 4x4 cardio days vs a weekly target.
///
/// Declared under app/dashboards.yaml `phases:` → `<phase>:` → `goals:`;
/// absent → [parseGoals] returns null and the GOALS screen shows a
/// "no goals declared" placeholder (never crashes).
library;

import 'package:yaml/yaml.dart';

import 'program_metrics.dart' show GradedSet, mainLiftByExercise, weekStartOf;

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

  /// The RPE band that counts as "close to failure" ([8, 9]).
  final List<double>? hardRpe;

  /// Per-lift associated accessory exercise names (from the routine).
  /// lift → [exercise names]. A lift's accessory check is met when EVERY
  /// listed accessory has ≥ 1 logged set this week.
  final Map<String, List<String>> accessories;

  // --- climbing / cardio_4x4 ---
  final double? target;

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
    this.hardRpe,
    this.accessories = const {},
    this.target,
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
          hardRpe: _numPair(gg['hard_rpe']),
          accessories: acc is Map
              ? {
                  for (final e in acc.entries)
                    if (e.value is List)
                      e.key.toString(): [
                        for (final x in (e.value as List)) x.toString(),
                      ],
                }
              : const {},
          target: (gg['target'] as num?)?.toDouble(),
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
enum GoalStatus { met, partial, unmet, unknown }

/// One per-lift tick (hard_sets: sets toward the target + accessory done).
class GoalLiftTick {
  final String lift;

  /// Hard sets (RPE-in-band) counted this week.
  final int hardSets;

  /// The per-lift hard-set target (~10).
  final int target;

  /// Whether this lift's associated accessories were all hit (null when
  /// none are declared for the lift).
  final bool? accessoriesDone;

  const GoalLiftTick({
    required this.lift,
    required this.hardSets,
    required this.target,
    this.accessoriesDone,
  });
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

  const GoalEval({
    required this.config,
    required this.status,
    required this.value,
    this.detail = '',
    this.ticks = const [],
  });

  static const _defaultLabels = {
    'macros': 'Macros',
    'calorie_band': 'Calories',
    'hard_sets': 'Hard sets per lift',
    'climbing': 'Climbing',
    'cardio_4x4': 'Cardio',
  };

  String get label => config.label ?? _defaultLabels[config.id] ?? config.id;
}

/// Inputs the evaluators read — already fetched by the screen, same
/// shape philosophy as WeekDriverInputs.
class GoalInputs {
  /// §2.5 graded main-lift sets over full history (RPE carried); the
  /// hard-set counter filters to the accounting week and the RPE band.
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
  });
}

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

      case 'hard_sets':
        final lifts = c.lifts.isEmpty ? _defaultLifts : c.lifts;
        final target = c.hardSetTarget ?? 10;
        final rpeLo = c.hardRpe == null ? 8.0 : c.hardRpe![0];
        final rpeHi = c.hardRpe == null ? 9.0 : c.hardRpe![1];
        int hardSets(String lift) => inputs.graded
            .where((s) =>
                s.lift == lift &&
                inWeek(s.date) &&
                s.rpe != null &&
                s.rpe! >= rpeLo &&
                s.rpe! <= rpeHi)
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
              target: target,
              accessoriesDone: accessoriesDone(lift),
            ),
        ];
        final atTarget = ticks.where((t) => t.hardSets >= t.target).length;
        final anyProgress = ticks.any((t) => t.hardSets > 0);
        final status = atTarget == lifts.length
            ? GoalStatus.met
            : anyProgress
                ? GoalStatus.partial
                : GoalStatus.unmet;
        out.add(GoalEval(
          config: c,
          status: status,
          value: '$atTarget/${lifts.length} lifts at $target',
          ticks: ticks,
        ));

      case 'climbing':
        final sessions = <DateTime>{
          for (final d in inputs.climbingDates)
            if (inWeek(d)) _day(d),
        }.length;
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

      default:
        // Unknown id — newer config, older app. Skip, never error.
        break;
    }
  }
  return out;
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
