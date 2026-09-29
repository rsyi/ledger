/// Today-vs-plan status: a two-line plain-language read on how the day
/// is going against the plan — FOOD (Macrofactor meals vs macro targets)
/// and TRAINING (logged strength sets vs today's planned sets).
///
/// Pure: no Flutter, no IO. The Progress-tab card feeds it today's
/// meals + logged sets + planned sets + the day's macro targets and
/// renders the two lines. Replaced the Coach preview row (the coach
/// stays reachable on its own tab). Design principle: this is a
/// process check — "am I on plan today?" — not a vanity tally.
library;

/// One meal's macros (already summed per record; nulls = not reported).
class TodayMeal {
  final double? calories;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;

  const TodayMeal({this.calories, this.proteinG, this.carbsG, this.fatG});
}

/// One strength set — only the exercise name matters for the count/list.
class TodaySet {
  final String exercise;
  const TodaySet({required this.exercise});
}

/// The macro targets in force today (from the program slice). Any may be
/// null (block-0 nulls → "no target", we still show what was eaten).
class TodayTargets {
  /// [lo, hi] grams/day; the low end is the target we compare against.
  final List<double>? proteinGDay;
  final List<double>? carbsGDay;
  final double? fatGDayMin;

  const TodayTargets({this.proteinGDay, this.carbsGDay, this.fatGDayMin});
}

enum TodayState {
  /// Nothing logged yet (meals empty, or planned work not started).
  none,

  /// Rest day — nothing planned and nothing logged.
  rest,

  /// Progressing, on pace.
  onTrack,

  /// Behind pace with little day left (food) — a nudge.
  behind,

  /// Target met / all planned work done.
  done,
}

class TodayStatus {
  final String foodText;
  final TodayState foodState;
  final String exerciseText;
  final TodayState exerciseState;

  const TodayStatus({
    required this.foodText,
    required this.foodState,
    required this.exerciseText,
    required this.exerciseState,
  });
}

/// After this hour of local time a partial protein tally is judged as
/// "behind" rather than merely "on track" — there's little day left to
/// catch up.
const int _kLateHour = 20;

TodayStatus buildTodayStatus({
  required List<TodayMeal> meals,
  required List<TodaySet> loggedSets,
  required List<TodaySet> plannedSets,
  required TodayTargets targets,
  DateTime? now,
  DateTime? today,
}) {
  final clock = now ?? DateTime.now();
  return TodayStatus(
    foodText: _foodText(meals, targets),
    foodState: _foodState(meals, targets, clock, today),
    exerciseText: _exerciseText(loggedSets, plannedSets),
    exerciseState: _exerciseState(loggedSets, plannedSets),
  );
}

// ------------------------------------------------------------------- food

double _sum(List<TodayMeal> meals, double? Function(TodayMeal) f) {
  var total = 0.0;
  for (final m in meals) {
    total += f(m) ?? 0;
  }
  return total;
}

String _foodText(List<TodayMeal> meals, TodayTargets targets) {
  if (meals.isEmpty) return 'Food: nothing logged yet';
  final protein = _sum(meals, (m) => m.proteinG).round();
  final kcal = _sum(meals, (m) => m.calories).round();
  final target = targets.proteinGDay;
  final proteinPart = target == null
      ? '${protein}g protein'
      : '${protein}g protein of ${target[0].round()}';
  return 'Food: $proteinPart · ${_thousands(kcal)} kcal so far';
}

TodayState _foodState(
  List<TodayMeal> meals,
  TodayTargets targets,
  DateTime now,
  DateTime? today,
) {
  if (meals.isEmpty) return TodayState.none;
  final target = targets.proteinGDay;
  if (target == null) return TodayState.onTrack; // no target to grade
  final protein = _sum(meals, (m) => m.proteinG);
  if (protein >= target[0]) return TodayState.done;
  // Behind only when there's little day left to catch up — before then a
  // partial tally is normal.
  final day = today == null
      ? null
      : DateTime(today.year, today.month, today.day);
  final nowIsToday = day == null ||
      (now.year == day.year && now.month == day.month && now.day == day.day);
  if (nowIsToday && now.hour >= _kLateHour) return TodayState.behind;
  return TodayState.onTrack;
}

// --------------------------------------------------------------- exercise

String _exerciseText(List<TodaySet> logged, List<TodaySet> planned) {
  if (planned.isEmpty && logged.isEmpty) return 'Training: rest day';
  if (planned.isEmpty) {
    // Unplanned but logged — report what was done.
    return 'Training: ${logged.length} sets logged — ${_names(logged)}';
  }
  if (logged.isEmpty) {
    return 'Training: nothing logged yet — ${planned.length} planned';
  }
  return 'Training: ${logged.length} of ${planned.length} planned sets '
      'done — ${_names(logged)}';
}

TodayState _exerciseState(List<TodaySet> logged, List<TodaySet> planned) {
  if (planned.isEmpty && logged.isEmpty) return TodayState.rest;
  if (logged.isEmpty) return TodayState.none;
  if (planned.isEmpty) return TodayState.done; // unplanned work counts
  return logged.length >= planned.length
      ? TodayState.done
      : TodayState.onTrack;
}

/// Distinct exercise names (lower-cased, insertion order), capped at
/// three with a trailing ellipsis.
String _names(List<TodaySet> sets) {
  final seen = <String>[];
  for (final s in sets) {
    final n = s.exercise.trim().toLowerCase();
    if (n.isEmpty) continue;
    if (!seen.contains(n)) seen.add(n);
  }
  if (seen.length <= 3) return seen.join(' · ');
  return '${seen.take(3).join(' · ')}…';
}

// --------------------------------------------------------------- helpers

/// Groups an integer with thousands separators (1240 → "1,240").
String _thousands(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
