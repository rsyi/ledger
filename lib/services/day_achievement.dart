/// What a day's logged work ACHIEVED against its program items — the
/// Today card's accomplishment-forward meta ("top 275×6", "2×4 · 255 lb")
/// plus where each attached clip belongs and what was logged outside the
/// program ("Also logged").
///
/// Built on [allocateDayOwners] (the same exclusive allocation the card's
/// done marks + the missed-work detector use) with two display-only
/// refinements that never change any item's credited count:
///   * FOLD — a surplus working set of an exercise an item already
///     claimed (a 4th back-off, an extra deadlift single) belongs to that
///     item (the last one in program order that claimed it), not to
///     "Also logged".
///   * TOP SWAP — a top-set item shows the heaviest set of its exercise:
///     allocation is name/order based, so a top item could otherwise be
///     credited with a lighter set logged first.
///
/// Pure: no Flutter/IO imports.
library;

import 'missed_work.dart' show allocateDayOwners, programItemKind;
import 'prescribed_exercises.dart';

/// One logged working set (a strength record, or a bare calisthenics
/// set when [weight]/[reps] are unknown).
class AchievedSet {
  final String exercise;
  final double? weight;
  final int? reps;

  /// The record behind it (identity-matched against clips); null for
  /// calisthenics sets.
  final Map<String, Object?>? record;

  const AchievedSet({
    required this.exercise,
    this.weight,
    this.reps,
    this.record,
  });

  factory AchievedSet.fromRecord(String exercise, Map<String, Object?>? r) =>
      AchievedSet(
        exercise: exercise,
        weight: r == null ? null : _num(r['weight']),
        reps: r == null ? null : _num(r['reps'])?.round(),
        record: r,
      );

  bool get weighted => (weight ?? 0) > 0;
}

/// A clip attached to one of the day's strength rows.
class DayClip {
  final String url;
  final String? mediaId;
  final String exercise;
  final Map<String, Object?> record;

  const DayClip({
    required this.url,
    required this.mediaId,
    required this.exercise,
    required this.record,
  });
}

/// An "Also logged" exercise: working sets (and/or clips) that matched
/// no program item.
class ExtraWork {
  final String exercise;
  final List<AchievedSet> sets;
  final List<DayClip> clips;

  ExtraWork(this.exercise) : sets = [], clips = [];
}

class DayAchievement {
  /// The items with `loggedSets` from the allocation (same order as in).
  final List<PrescribedItem> items;

  /// Per item: the sets shown as its achievement (claimed + folded).
  final List<List<AchievedSet>> sets;

  /// Per item: clips of its sets.
  final List<List<DayClip>> clips;

  /// Logged work that matched no item, first-logged order.
  final List<ExtraWork> extra;

  const DayAchievement({
    required this.items,
    required this.sets,
    required this.clips,
    required this.extra,
  });
}

String _key(String s) => s.trim().toLowerCase();

/// Assigns [logged] (the day's WORKING sets, program-allocation order)
/// and [clips] (every clip on the day's strength rows, warm-ups
/// included) to [items]. [isTop] flags top-set items (all priced lines
/// are top sets) for the top swap; shorter lists read as false.
DayAchievement achieveDay({
  required List<PrescribedItem> items,
  required List<AchievedSet> logged,
  List<DayClip> clips = const [],
  List<bool> isTop = const [],
}) {
  final alloc = allocateDayOwners(items, [for (final s in logged) s.exercise]);
  final owner = [...alloc.owner];

  // FOLD: surplus sets of an exercise an item claimed → the last such item.
  final lastClaimer = <String, int>{};
  for (var j = 0; j < logged.length; j++) {
    if (owner[j] >= 0) {
      final k = _key(logged[j].exercise);
      final prev = lastClaimer[k];
      if (prev == null || owner[j] > prev) lastClaimer[k] = owner[j];
    }
  }
  for (var j = 0; j < logged.length; j++) {
    if (owner[j] >= 0) continue;
    final i = lastClaimer[_key(logged[j].exercise)];
    if (i != null && programItemKind(items[i]) == 'lift') owner[j] = i;
  }

  // TOP SWAP: a top item takes the heaviest set of its exercise.
  double w(int j) => logged[j].weight ?? 0;
  for (var i = 0; i < items.length; i++) {
    if (i >= isTop.length || !isTop[i]) continue;
    final mine = [for (var j = 0; j < logged.length; j++) if (owner[j] == i) j];
    if (mine.isEmpty) continue;
    final ex = {for (final j in mine) _key(logged[j].exercise)};
    var heaviest = -1;
    for (var j = 0; j < logged.length; j++) {
      if (owner[j] < 0 || !ex.contains(_key(logged[j].exercise))) continue;
      if (heaviest < 0 || w(j) > w(heaviest)) heaviest = j;
    }
    if (heaviest < 0 || owner[heaviest] == i) continue;
    var lightest = mine.first;
    for (final j in mine) {
      if (w(j) < w(lightest)) lightest = j;
    }
    if (w(heaviest) <= w(lightest)) continue;
    owner[lightest] = owner[heaviest];
    owner[heaviest] = i;
  }

  final sets = [for (var i = 0; i < items.length; i++) <AchievedSet>[]];
  final extraByKey = <String, ExtraWork>{};
  final extra = <ExtraWork>[];
  ExtraWork extraFor(String exercise) => extraByKey.putIfAbsent(
        _key(exercise),
        () {
          final e = ExtraWork(exercise.trim());
          extra.add(e);
          return e;
        },
      );
  for (var j = 0; j < logged.length; j++) {
    if (owner[j] >= 0) {
      sets[owner[j]].add(logged[j]);
    } else {
      extraFor(logged[j].exercise).sets.add(logged[j]);
    }
  }

  // Clips: the set's own item; else (a warm-up / unclaimed set) the item
  // that claimed that exercise; else Also logged.
  final itemClips = [for (var i = 0; i < items.length; i++) <DayClip>[]];
  final byExercise = <String, int>{};
  for (var i = 0; i < items.length; i++) {
    for (final s in sets[i]) {
      byExercise.putIfAbsent(_key(s.exercise), () => i);
    }
  }
  for (final c in clips) {
    var target = -1;
    for (var i = 0; i < items.length && target < 0; i++) {
      if (sets[i].any((s) => identical(s.record, c.record))) target = i;
    }
    if (target < 0) target = byExercise[_key(c.exercise)] ?? -1;
    if (target >= 0) {
      itemClips[target].add(c);
    } else {
      extraFor(c.exercise).clips.add(c);
    }
  }

  return DayAchievement(
    items: alloc.items,
    sets: sets,
    clips: itemClips,
    extra: extra,
  );
}

String _fmtW(double w) =>
    w == w.roundToDouble() ? w.round().toString() : w.toStringAsFixed(1);

/// One set as `275×6` / `BW×8` / `275 lb` / null (nothing recorded).
String? setLabel(AchievedSet s) {
  if (s.weighted) {
    return s.reps == null ? '${_fmtW(s.weight!)} lb' : '${_fmtW(s.weight!)}×${s.reps}';
  }
  return s.reps == null ? null : 'BW×${s.reps}';
}

/// The heaviest set (ties → more reps); for unweighted work, most reps.
AchievedSet? bestSet(List<AchievedSet> sets) {
  AchievedSet? best;
  for (final s in sets) {
    if (setLabel(s) == null) continue;
    if (best == null) {
      best = s;
      continue;
    }
    final bw = best.weight ?? 0, sw = s.weight ?? 0;
    if (sw > bw || (sw == bw && (s.reps ?? 0) > (best.reps ?? 0))) best = s;
  }
  return best;
}

/// The achievement meta for one item's [sets]:
///   * top-set item: `top 275×6`, plus the rest when more than one
///     (`· +3 sets 235×6` when uniform, else `· +3 sets`);
///   * uniform sets: `2×4 · 255 lb` / `3×8 · BW`;
///   * mixed: `3 sets · best 160×10`;
///   * not yet complete ([target] > sets): `1 of 3 sets · best 160×8`.
/// Null when [sets] is empty.
String? achievedMeta(
  List<AchievedSet> sets, {
  required int target,
  bool top = false,
}) {
  final n = sets.length;
  if (n == 0) return null;
  final best = bestSet(sets);
  final bestText = best == null ? null : setLabel(best);
  final count = '$n set${n == 1 ? '' : 's'}';
  if (n < target) {
    final of = '$n of $target sets';
    return bestText == null ? of : '$of · ${top ? 'top' : 'best'} $bestText';
  }
  if (top && bestText != null) {
    if (n == 1) return 'top $bestText';
    // The rest (back-offs folded in): `+3 sets 235×6` when uniform.
    final rest = [...sets]..remove(best);
    final k = rest.length;
    final r0 = setLabel(rest.first);
    final more = '+$k set${k == 1 ? '' : 's'}';
    final same = r0 != null && rest.every((x) => setLabel(x) == r0);
    return 'top $bestText · ${same ? '$more $r0' : more}';
  }
  if (bestText == null) return count;
  if (n == 1) return bestText;
  final reps = sets.first.reps;
  final weight = sets.first.weight ?? 0;
  final uniform = reps != null &&
      sets.every((s) => s.reps == reps && (s.weight ?? 0) == weight);
  if (uniform) {
    return weight > 0 ? '$n×$reps · ${_fmtW(weight)} lb' : '$n×$reps · BW';
  }
  return '$count · best $bestText';
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}
