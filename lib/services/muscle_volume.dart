/// Per-muscle-group weekly set counting — ONE implementation shared by
/// the THIS WEEK `hypertrophy_volume` driver (week_drivers.dart), the
/// weekly review (recomp_review.dart) and the Week tab's
/// `muscle_stimulus` goal (goals_service.dart).
///
/// Credits come from the program's declared `exercise_muscle_map`
/// (program.yaml v9+): every logged SET credits its exercise's
/// fractional per-group credits (v16: "Flat Barbell Bench Press" →
/// chest 1, triceps 0.5), and every climbing SESSION credits the map's
/// `climbing_session` block (v16: lats 1.5, biceps 0.5, forearms 2,
/// core 0.5). Callers
/// decide WHICH sets count (window, warm-up rule) — this file only
/// credits them.
///
/// Pure: no Flutter/IO imports.
library;

/// The v9 exercise → muscle-group credit map (program.yaml
/// `exercise_muscle_map`): per-SET fractional credits per group, plus
/// the per-SESSION climbing credits. Parsed by [parseExerciseMuscleMap].
class MuscleMap {
  /// Exact logged exercise name → {group: credit}. Lookup is exact
  /// first, then longest declared PREFIX ("Muscle Up Purple Band"
  /// counts under "Muscle Up"), then the same two case/hyphen-blind
  /// (calisthenics logs "muscle-up green band"), then the calisthenics
  /// skill aliases ([calisthenicsSkillAliases]).
  final Map<String, Map<String, double>> exercises;

  /// One climbing session's credits ({lats: 1.5, forearms: 2, ...}).
  final Map<String, double> climbingSession;

  const MuscleMap({
    required this.exercises,
    this.climbingSession = const {},
  });

  /// Credits for a logged [exercise] name, or null when unmapped.
  Map<String, double>? creditsFor(String exercise) {
    final exact = exercises[exercise];
    if (exact != null) return exact;
    final prefix = _longestPrefix(exercise, (k) => k);
    if (prefix != null) return exercises[prefix];
    // Case/hyphen-blind retry (calisthenics skill names are lowercase
    // with hyphens: "muscle-up green band", "front lever tuck").
    final n = _normName(exercise);
    final loose = _longestPrefix(n, _normName);
    if (loose != null) return exercises[loose];
    final alias = calisthenicsSkillAliases[n.split(' ').first];
    return alias == null ? null : exercises[alias];
  }

  String? _longestPrefix(String name, String Function(String) key) {
    String? best;
    for (final k in exercises.keys) {
      final kk = key(k);
      if (kk.isEmpty) continue;
      if (name.startsWith(kk) && (best == null || k.length > best.length)) {
        best = k;
      }
    }
    return best;
  }
}

String _normName(String s) => s
    .toLowerCase()
    .replaceAll('-', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Calisthenics skill dropdown values whose name doesn't prefix a map
/// key → the map exercise they credit as (calisthenics.input.yml
/// `skill:` options). `core` stays unmapped (no group in the band).
const calisthenicsSkillAliases = <String, String>{
  'handstand': 'Handstand Hold',
  'hspu': 'Handstand Push Up',
};

/// Parses a program VERSION map's `exercise_muscle_map` (v9). Null when
/// absent/malformed — the counters then report pending / no data.
MuscleMap? parseExerciseMuscleMap(Map<Object?, Object?>? version) {
  final raw = version?['exercise_muscle_map'];
  if (raw is! Map) return null;
  Map<String, double> credits(Object? m) => m is Map
      ? {
          for (final e in m.entries)
            if (e.value is num) e.key.toString(): (e.value as num).toDouble(),
        }
      : const {};
  final exercises = raw['exercises'];
  if (exercises is! Map) return null;
  return MuscleMap(
    exercises: {
      for (final e in exercises.entries)
        e.key.toString(): credits(e.value),
    },
    climbingSession: credits(raw['climbing_session']),
  );
}

/// The program version's declared hypertrophy muscle groups
/// (`hypertrophy_targets.muscle_groups`), or empty.
List<String> hypertrophyMuscleGroups(Map<Object?, Object?>? version) {
  final t = version?['hypertrophy_targets'];
  final g = t is Map ? t['muscle_groups'] : null;
  return g is List ? [for (final x in g) x.toString()] : const [];
}

/// The program version's TRACKED-ONLY groups
/// (`hypertrophy_targets.tracked_groups`, v16: lower_back, front_delts,
/// forearms, core) — counted and shown, never held to the band. Empty
/// for older versions (they declare none).
List<String> hypertrophyTrackedGroups(Map<Object?, Object?>? version) {
  final t = version?['hypertrophy_targets'];
  final g = t is Map ? t['tracked_groups'] : null;
  return g is List ? [for (final x in g) x.toString()] : const [];
}

/// One muscle group's weekly volume.
class MuscleVolume {
  final String group;

  /// Fractional sets credited (e.g. 9.25).
  final double sets;

  /// Contributor → sets it credited to this group, in first-seen order.
  /// Logged exercise names as logged; climbing under [climbingLabel].
  final Map<String, double> byExercise;

  const MuscleVolume({
    required this.group,
    required this.sets,
    this.byExercise = const {},
  });
}

/// Contributor key for the per-session climbing credit.
const climbingLabel = 'Climbing sessions';

/// Credits [setNames] (one entry per counted set — the caller already
/// applied its window and warm-up rule) plus [climbSessions] climbing
/// sessions to [groups] via [map]. Every group in [groups] is present
/// in the result (0 when nothing credits it); credits to other groups
/// (forearms, core, calves...) are dropped. Unmapped names credit
/// nothing.
Map<String, MuscleVolume> weeklyMuscleVolume({
  required MuscleMap map,
  required List<String> groups,
  required Iterable<String> setNames,
  int climbSessions = 0,
}) {
  final sets = {for (final g in groups) g: 0.0};
  final by = {for (final g in groups) g: <String, double>{}};
  void credit(String group, String who, double v) {
    if (!sets.containsKey(group) || v == 0) return;
    sets[group] = sets[group]! + v;
    by[group]![who] = (by[group]![who] ?? 0) + v;
  }

  for (final name in setNames) {
    final credits = map.creditsFor(name);
    if (credits == null) continue;
    credits.forEach((g, v) => credit(g, name, v));
  }
  if (climbSessions > 0) {
    map.climbingSession
        .forEach((g, v) => credit(g, climbingLabel, climbSessions * v));
  }
  return {
    for (final g in groups)
      g: MuscleVolume(group: g, sets: sets[g]!, byExercise: by[g]!),
  };
}
