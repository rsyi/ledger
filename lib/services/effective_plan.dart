/// The PRICED week after `program_moves` (moves + skips) — what the
/// Program screen renders and what the week planner plans (2026-10-02
/// "my program view for next week still doesn't take my vacation into
/// account": both priced the raw program week, so moved-out work stayed
/// on its home day, skipped work stayed planned, and moved-in work never
/// appeared on its target day).
///
/// [effectivePlannedEntries] takes one Mon–Sun week of
/// [buildWeekPlannedEntries] output (`snapToWeekStart: false`) and
/// relocates it per [effectiveWeek]: each prose item owns the priced
/// lines [matchItemLines] gives it ON ITS HOME DAY (the Today card's
/// approach — a moved item keeps its home-day pricing), so
///   * moved-out items' sets leave their home day,
///   * moved-in items' sets land on the target day, after the day's own
///     work, tagged with the `moved_from` / `moved_item` display markers,
///   * skipped items' sets (skip keyed on the EFFECTIVE day) disappear,
///   * warm-up ramps are re-spliced per (day, main lift) exactly like the
///     planner's pass 2 — a moved main lift brings its ramp; a day that
///     loses all of a lift's working sets loses its ramp.
/// Days no move/skip touches pass through verbatim.
///
/// [effectiveDayInfo] / [effectiveDaySummary] give the screen the day's
/// moved-out / skipped / moved-in notes and an effective summary.
///
/// Pure: no Flutter/IO imports.
library;

import 'prescribed_exercises.dart';
import 'program_item_pricing.dart' show matchItemLines;
import 'program_metrics.dart' show mainLiftByExercise;
import 'program_moves.dart';
import 'program_week.dart' show dayOnly;
import 'routine_display.dart' show SessionLine, daySummary;
import 'working_max.dart' show warmupRamp;

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The day's working entries grouped into display lines exactly like
/// [sessionLinesByDay] (consecutive identical rows merge), each line with
/// the indices of the entries behind it.
List<(SessionLine, List<int>)> _group(List<Map<String, Object?>> working) {
  final out = <(SessionLine, List<int>)>[];
  for (var i = 0; i < working.length; i++) {
    final e = working[i];
    final exercise = e['exercise'] as String;
    final reps = e['reps'] as num;
    final repsHi = e['reps_hi'] as num?;
    final weight = e['weight'] as num?;
    final pct = e['pct'] as num?;
    final top = e['top'] == true;
    if (out.isNotEmpty) {
      final (l, idx) = out.last;
      if (l.exercise == exercise &&
          l.reps == reps &&
          l.repsHi == repsHi &&
          l.weight == weight &&
          l.pct == pct &&
          l.top == top) {
        out[out.length - 1] = (
          SessionLine(
            exercise: exercise,
            sets: l.sets + 1,
            reps: reps,
            repsHi: repsHi,
            weight: weight,
            pct: pct,
            top: top,
          ),
          [...idx, i],
        );
        continue;
      }
    }
    out.add((
      SessionLine(
        exercise: exercise,
        sets: 1,
        reps: reps,
        repsHi: repsHi,
        weight: weight,
        pct: pct,
        top: top,
      ),
      [i],
    ));
  }
  return out;
}

/// The planner's pass 2: each MAIN lift's warm-up ramp spliced before its
/// first working set, ramping to the day's heaviest filled working
/// weight for that exercise (no filled weight → no ramp).
List<Map<String, Object?>> _withWarmups(
  List<Map<String, Object?>> working,
  Object? warmupProtocol,
) {
  final tops = <String, num>{};
  for (final w in working) {
    final weight = w['weight'];
    if (weight is! num) continue;
    final ex = w['exercise'] as String;
    if (tops[ex] == null || weight > tops[ex]!) tops[ex] = weight;
  }
  final out = <Map<String, Object?>>[];
  final warmedUp = <String>{};
  for (final w in working) {
    final ex = w['exercise'] as String;
    final top = tops[ex];
    if (top != null && mainLiftByExercise[ex] != null && warmedUp.add(ex)) {
      for (final s in warmupRamp(warmupProtocol, mainLiftByExercise[ex], top)) {
        out.add({
          'date': w['date'],
          'exercise': ex,
          'reps': s.reps,
          'weight': s.weight,
          'warmup': true,
        });
      }
    }
    out.add(w);
  }
  return out;
}

/// Relocates one Mon–Sun week of planner [entries] per [moves] / [skips]
/// (see the library doc). [prescribed] = `prescribedWeek` for the same
/// week (local-midnight keys); [warmupProtocol] = the program version's
/// `warmup_protocol`. Entries' `date` stays UTC midnight (the planner's
/// convention). Moved entries carry `moved_from` (home day, local
/// midnight) and `moved_item` (the prose item name) — display markers,
/// never persisted ([plannedValuesOf] ignores them).
List<Map<String, Object?>> effectivePlannedEntries(
  List<Map<String, Object?>> entries,
  Map<DateTime, List<PrescribedItem>> prescribed, {
  Map<String, ProgramMove> moves = const {},
  Map<String, ProgramMove> skips = const {},
  Object? warmupProtocol,
}) {
  if (moves.isEmpty && skips.isEmpty) return entries;
  final week = effectiveWeek(prescribed, moves);
  final itemsByKey = <String, List<PrescribedItem>>{
    for (final e in prescribed.entries) _ymd(e.key): e.value,
  };

  // Entries per day (input order), split working / warm-up.
  final dayOrder = <String>[];
  final dateOf = <String, DateTime>{};
  final workingByKey = <String, List<Map<String, Object?>>>{};
  final allByKey = <String, List<Map<String, Object?>>>{};
  for (final e in entries) {
    final d = e['date'] as DateTime;
    final k = _ymd(d);
    if (!allByKey.containsKey(k)) {
      dayOrder.add(k);
      dateOf[k] = d;
    }
    (allByKey[k] ??= []).add(e);
    if (e['warmup'] != true) (workingByKey[k] ??= []).add(e);
  }

  // Ownership on each HOME day: owner[k][i] = prose item index of
  // working entry i, or -1 (a priced line no prose item claims).
  final owner = <String, List<int>>{};
  workingByKey.forEach((k, working) {
    final items = itemsByKey[k] ?? const <PrescribedItem>[];
    final groups = _group(working);
    final matched =
        matchItemLines(items, [for (final (l, _) in groups) l]);
    final own = List<int>.filled(working.length, -1);
    for (var j = 0; j < groups.length; j++) {
      final (line, idx) = groups[j];
      for (var i = 0; i < items.length; i++) {
        if (matched[i].any((l) => identical(l, line))) {
          for (final x in idx) {
            own[x] = i;
          }
          break;
        }
      }
    }
    owner[k] = own;
  });

  bool skipped(DateTime day, PrescribedItem it) =>
      skips.containsKey(skipKey(day, it.name));

  // Every day to emit: the input's days + any target day the input
  // lacks (an otherwise empty day receiving moved work), in date order.
  final keys = <String>{...dayOrder};
  for (final d in week.keys) {
    final k = _ymd(d);
    if (keys.contains(k)) continue;
    if ((week[d] ?? const []).any((e) => e.movedFrom != null)) {
      keys.add(k);
      dateOf[k] = DateTime.utc(d.year, d.month, d.day);
    }
  }
  final sorted = keys.toList()..sort();

  final out = <Map<String, Object?>>[];
  for (final k in sorted) {
    final date = dateOf[k]!;
    final local = DateTime(date.year, date.month, date.day);
    final eff = week[local] ?? const <EffectiveItem>[];
    final touched = eff.any((e) =>
            e.isGhost || e.movedFrom != null || skipped(local, e.item)) ||
        skips.values.any((s) => dayOnly(s.to) == local);
    if (!touched) {
      out.addAll(allByKey[k] ?? const []);
      continue;
    }
    final items = itemsByKey[k] ?? const <PrescribedItem>[];
    // Home item index → still lives here (not moved out, not skipped).
    final stays = List<bool>.filled(items.length, true);
    for (final e in eff) {
      if (e.movedFrom != null) continue;
      final i = items.indexWhere((it) => identical(it, e.item));
      if (i < 0) continue;
      if (e.isGhost || skipped(local, e.item)) stays[i] = false;
    }
    final anyHomeStays = stays.contains(true);
    final working = <Map<String, Object?>>[];
    final own = owner[k] ?? const <int>[];
    final homeWorking = workingByKey[k] ?? const <Map<String, Object?>>[];
    for (var x = 0; x < homeWorking.length; x++) {
      final i = own[x];
      // Unclaimed lines follow the day: kept while any of its own work
      // stays (a fully moved/skipped day — travel — drops them too).
      if (i < 0 ? anyHomeStays : stays[i]) working.add(homeWorking[x]);
    }
    // Moved-in items, in effectiveWeek order, priced on their home day.
    for (final e in eff) {
      final from = e.movedFrom;
      if (from == null || skipped(local, e.item)) continue;
      final hk = _ymd(from);
      final hItems = itemsByKey[hk] ?? const <PrescribedItem>[];
      final hi = hItems.indexWhere((it) => identical(it, e.item));
      if (hi < 0) continue;
      final hWorking = workingByKey[hk] ?? const <Map<String, Object?>>[];
      final hOwn = owner[hk] ?? const <int>[];
      for (var x = 0; x < hWorking.length; x++) {
        if (hOwn[x] != hi) continue;
        working.add({
          ...hWorking[x],
          'date': date,
          'moved_from': dayOnly(from),
          'moved_item': e.item.name,
        });
      }
    }
    out.addAll(_withWarmups(working, warmupProtocol));
  }
  return out;
}

/// What moves/skips did to one day, for the Program screen's notes.
class EffectiveDayInfo {
  /// Any move in/out or skip on this day.
  final bool touched;

  /// Items still on the day (own + moved-in), skips removed, in order.
  final List<EffectiveItem> remaining;

  /// Moved-out item names grouped by target day (date order).
  final Map<DateTime, List<String>> movedOut;

  /// Skipped item names grouped by reason (the note's first ` — `
  /// segment; '' when none), first-seen order.
  final Map<String, List<String>> skipped;

  const EffectiveDayInfo({
    required this.touched,
    this.remaining = const [],
    this.movedOut = const {},
    this.skipped = const {},
  });

  /// Moved-in items (remaining with a movedFrom).
  List<EffectiveItem> get movedIn =>
      [for (final e in remaining) if (e.movedFrom != null) e];
}

/// [day]'s moves/skips summary over the effective [week].
EffectiveDayInfo effectiveDayInfo(
  DateTime day,
  Map<DateTime, List<EffectiveItem>> week,
  Map<String, ProgramMove> skips,
) {
  final local = dayOnly(day);
  final eff = week[local] ?? const <EffectiveItem>[];
  final remaining = <EffectiveItem>[];
  final movedOut = <DateTime, List<String>>{};
  final skipped = <String, List<String>>{};
  var touched = false;
  for (final e in eff) {
    if (e.isGhost) {
      touched = true;
      (movedOut[dayOnly(e.movedTo!)] ??= []).add(e.item.name);
      continue;
    }
    if (e.movedFrom != null) touched = true;
    final s = skips[skipKey(local, e.item.name)];
    if (s != null) {
      touched = true;
      final reason = s.note.split(' — ').first.trim();
      (skipped[reason] ??= []).add(e.item.name);
      continue;
    }
    remaining.add(e);
  }
  final sortedOut = Map.fromEntries(
      movedOut.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  return EffectiveDayInfo(
    touched: touched,
    remaining: remaining,
    movedOut: sortedOut,
    skipped: skipped,
  );
}

/// The day's summary over its EFFECTIVE contents, or null when nothing
/// touched the day (callers keep the template-prose [daySummary]).
///   * nothing left, skips present → `Skipped — <reason>` (the shared
///     reason when every skip gives the same one, else `Skipped`);
///   * nothing left, only moved out → `Moved to Mon` (first target);
///   * else [daySummary] over [lines] + the remaining items' prose.
String? effectiveDaySummary(
  EffectiveDayInfo info,
  List<SessionLine> lines,
) {
  if (!info.touched) return null;
  if (info.remaining.isEmpty) {
    if (info.skipped.isNotEmpty) {
      final reasons = info.skipped.keys.where((r) => r.isNotEmpty).toSet();
      return reasons.length == 1 && info.skipped.length == 1
          ? 'Skipped — ${reasons.first}'
          : 'Skipped';
    }
    if (info.movedOut.isNotEmpty) {
      return 'Moved to ${_wd[info.movedOut.keys.first.weekday - 1]}';
    }
  }
  // Each item's name + the HEAD of its scheme (before any parenthetical
  // or second sentence): the Tue climb's scheme prose mentions the
  // morning 4x4, which must not survive the 4x4 moving out.
  String head(String scheme) => scheme.split(RegExp(r'\(|\. ')).first.trim();
  String prose(String period) => [
        for (final e in info.remaining)
          if (e.item.period == period) '${e.item.name} ${head(e.item.scheme)}',
      ].join('. ');
  return daySummary(
    lines: lines,
    morning: prose('AM'),
    afternoon: prose('PM'),
  );
}

const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// `Mon`..`Sun` for [d].
String weekdayShort(DateTime d) => _wd[d.weekday - 1];
