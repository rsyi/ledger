/// Groups the Log timeline's planned entries (one per SET) into display
/// slots — ONE ROW PER EXERCISE+SLOT (UI redesign phase 2, 2026-10-02).
///
/// Within a planned group (PlannedEntry.templateName, e.g. `program:
/// week plan`), sets with the same exercise, same set type and same
/// load×reps collapse into one slot; an exercise's warm-up ramp collapses
/// into one warm-up slot regardless of load. A top set and its back-offs
/// differ in load, so they stay separate slots. Slot order = program
/// order (first appearance); an identical set appearing later in the
/// group (e.g. a reverted entry re-appended by PlanStore) rejoins its
/// slot instead of spawning a duplicate row.
///
/// Sets already logged from the plan today ([done], from the undo-
/// logging mappings) count toward their slot ("3×6" stays 3 while the
/// row shows only the remaining chips) and toward the group's n/N.
/// A done set whose slot has nothing left forms a done-only slot, placed
/// before the pending slots (logged sets precede what's left — the
/// workout runs in order).
///
/// Entries without a group are never merged: each is its own block of
/// one slot. Pure (no Flutter) — unit-tested in planned_slots_test.dart.
library;

import 'bodyweight_cache.dart' show isBodyweightExercise;
import 'routine_display.dart' show formatNum, setChipLabel, setsRepsLoad;

/// A pending planned set: [ref] is the caller's handle (the timeline's
/// item), [values] its planned field values, [group] its templateName.
class PlannedSetIn<T> {
  final T ref;
  final Map<String, Object?> values;
  final String? group;
  const PlannedSetIn(this.ref, this.values, this.group);
}

/// One display row.
class PlannedSlot<T> {
  /// Stable-ish key within the day (group + exercise + set type + load);
  /// used for UI state like warm-up expansion.
  final String key;
  final String? exercise;
  final bool warmup;
  final num? weight;
  final num? reps;

  /// Still-planned sets, in program order.
  final List<PlannedSetIn<T>> pending = [];

  /// Values of sets already logged from this slot.
  final List<Map<String, Object?>> done = [];

  PlannedSlot._(this.key, this.exercise, this.warmup, this.weight, this.reps);

  int get total => pending.length + done.length;

  bool get isDone => pending.isEmpty;

  bool get isPartial => pending.isNotEmpty && done.isNotEmpty;

  bool get bodyweight =>
      exercise != null && isBodyweightExercise(exercise!);

  /// `3×6 · 105 lb` / `3×8 · BW`; warm-ups list their ramp loads
  /// ascending: `45·50·70·95`.
  String get meta {
    if (warmup) {
      final loads = <num>[
        for (final v in [...done, for (final p in pending) p.values])
          ?_num(v['weight']),
      ]..sort();
      return loads.map(formatNum).join('·');
    }
    return setsRepsLoad(
      sets: total,
      reps: reps,
      weight: weight,
      bodyweight: bodyweight,
    );
  }

  /// Chip label for one pending set of this slot.
  String chipLabel(PlannedSetIn<T> s) => setChipLabel(
    reps: _num(s.values['reps']),
    weight: _num(s.values['weight']),
    bodyweight: bodyweight,
  );
}

/// A run of slots under one group header ([name] null = an ungrouped
/// single entry, rendered without a header).
class PlannedBlock<T> {
  final String? name;
  final List<PlannedSlot<T>> slots;
  const PlannedBlock(this.name, this.slots);

  int get doneCount => slots.fold(0, (a, s) => a + s.done.length);
  int get totalCount => slots.fold(0, (a, s) => a + s.total);
  int get pendingCount => slots.fold(0, (a, s) => a + s.pending.length);
}

num? _num(Object? v) => v is num ? v : num.tryParse(v?.toString() ?? '');

bool isWarmupValues(Map<String, Object?> v) =>
    v['set_type']?.toString().trim().toLowerCase() == 'warmup';

String? _exercise(Map<String, Object?> v) {
  final s = v['exercise']?.toString().trim();
  return s == null || s.isEmpty ? null : s;
}

/// Groups [pending] (in display order) plus [done] sets (values + group,
/// in log order) into blocks. Groups appear at their first pending set;
/// a group with no pending sets left still yields a block (all slots
/// done) at the end, so the header can show N / N. [done] sets with a
/// null group are ignored (ungrouped entries vanish once logged).
List<PlannedBlock<T>> groupPlannedSlots<T>({
  required List<PlannedSetIn<T>> pending,
  List<(Map<String, Object?>, String?)> done = const [],
}) {
  final blocks = <PlannedBlock<T>>[];
  final byGroup = <String, _GroupBuild<T>>{};
  var anon = 0;
  for (final p in pending) {
    final g = p.group;
    if (g == null) {
      final ex = _exercise(p.values);
      final slot = PlannedSlot<T>._(
        '~${anon++}',
        ex,
        isWarmupValues(p.values),
        _num(p.values['weight']),
        _num(p.values['reps']),
      )..pending.add(p);
      blocks.add(PlannedBlock<T>(null, [slot]));
      continue;
    }
    var gb = byGroup[g];
    if (gb == null) {
      gb = byGroup[g] = _GroupBuild<T>(g);
      blocks.add(PlannedBlock<T>(g, gb.pendingSlots));
    }
    gb.addPending(p);
  }
  for (final (values, g) in done) {
    if (g == null) continue;
    final gb = byGroup[g] ??= () {
      final nb = _GroupBuild<T>(g);
      blocks.add(PlannedBlock<T>(g, nb.pendingSlots));
      return nb;
    }();
    gb.addDone(values);
  }
  // Done-only slots go ahead of the pending ones inside each group.
  return [
    for (final b in blocks)
      if (b.name == null)
        b
      else
        PlannedBlock<T>(b.name, [
          ...byGroup[b.name]!.doneOnlySlots,
          ...byGroup[b.name]!.pendingSlots,
        ]),
  ];
}

class _GroupBuild<T> {
  final String group;
  final List<PlannedSlot<T>> pendingSlots = [];
  final List<PlannedSlot<T>> doneOnlySlots = [];
  final Map<String, PlannedSlot<T>> _byKey = {};
  int _unkeyed = 0;

  _GroupBuild(this.group);

  /// Merge key — null exercise (non-strength views) never merges.
  String _key(Map<String, Object?> v) {
    final ex = _exercise(v);
    if (ex == null) return '$group|~${_unkeyed++}';
    final exK = ex.toLowerCase();
    if (isWarmupValues(v)) return '$group|$exK|warmup';
    return '$group|$exK|${_num(v['weight']) ?? ''}x${_num(v['reps']) ?? ''}';
  }

  PlannedSlot<T> _newSlot(String key, Map<String, Object?> v) =>
      PlannedSlot<T>._(
        key,
        _exercise(v),
        isWarmupValues(v),
        _num(v['weight']),
        _num(v['reps']),
      );

  void addPending(PlannedSetIn<T> p) {
    final k = _key(p.values);
    final slot = _byKey[k] ??= () {
      final s = _newSlot(k, p.values);
      pendingSlots.add(s);
      return s;
    }();
    slot.pending.add(p);
  }

  void addDone(Map<String, Object?> v) {
    final k = _key(v);
    final slot = _byKey[k] ??= () {
      final s = _newSlot(k, v);
      doneOnlySlots.add(s);
      return s;
    }();
    slot.done.add(v);
  }
}
