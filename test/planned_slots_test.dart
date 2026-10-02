import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/planned_slots.dart';
import 'package:airledger/services/routine_display.dart';

const _g = 'program: week plan';

PlannedSetIn<String> _p(
  String id,
  String ex,
  num reps, {
  num? weight,
  bool warmup = false,
  String? group = _g,
}) => PlannedSetIn(id, {
  'exercise': ex,
  'reps': reps,
  'weight': ?weight,
  if (warmup) 'set_type': 'warmup',
}, group);

/// Saturday 2026-10-03 as planned on device (21 sets).
List<PlannedSetIn<String>> _saturday() {
  var i = 0;
  String id() => 's${i++}';
  return [
    _p(id(), 'Overhead Press', 10, weight: 45, warmup: true),
    _p(id(), 'Overhead Press', 5, weight: 50, warmup: true),
    _p(id(), 'Overhead Press', 3, weight: 70, warmup: true),
    _p(id(), 'Overhead Press', 1, weight: 95, warmup: true),
    _p(id(), 'Overhead Press', 5, weight: 120),
    for (var k = 0; k < 3; k++) _p(id(), 'Overhead Press', 6, weight: 105),
    for (var k = 0; k < 3; k++) _p(id(), 'Seated Cable Row', 8, weight: 110),
    for (var k = 0; k < 3; k++) _p(id(), 'Pull Up', 6, weight: 161.5),
    for (var k = 0; k < 3; k++)
      _p(id(), 'Lateral Dumbbell Raise', 12, weight: 20),
    for (var k = 0; k < 2; k++) _p(id(), 'Cable Face Pull', 12, weight: 17.5),
    for (var k = 0; k < 2; k++)
      _p(id(), 'Cable External Rotation', 12, weight: 7.5),
  ];
}

void main() {
  test('Saturday: 21 sets collapse to 8 rows in program order', () {
    final blocks = groupPlannedSlots(pending: _saturday());
    expect(blocks, hasLength(1));
    final b = blocks.single;
    expect(b.name, _g);
    expect(b.totalCount, 21);
    expect(b.doneCount, 0);
    expect(
      [for (final s in b.slots) '${s.exercise}${s.warmup ? ' (w)' : ''}'],
      [
        'Overhead Press (w)',
        'Overhead Press',
        'Overhead Press',
        'Seated Cable Row',
        'Pull Up',
        'Lateral Dumbbell Raise',
        'Cable Face Pull',
        'Cable External Rotation',
      ],
    );
    final metas = [for (final s in b.slots) s.meta];
    expect(metas, [
      '45·50·70·95',
      '1×5 · 120 lb',
      '3×6 · 105 lb',
      '3×8 · 110 lb',
      '3×6 · BW',
      '3×12 · 20 lb',
      '2×12 · 17.5 lb',
      '2×12 · 7.5 lb',
    ]);
    final top = b.slots[1];
    expect(top.chipLabel(top.pending.single), '120×5');
    final pull = b.slots[4];
    expect(pull.bodyweight, isTrue);
    expect(pull.chipLabel(pull.pending.first), 'BW×6');
    // Warm-up chips keep their own loads.
    final w = b.slots.first;
    expect([for (final s in w.pending) w.chipLabel(s)], [
      '45×10',
      '50×5',
      '70×3',
      '95×1',
    ]);
  });

  test('done sets count toward the slot + group, chips shrink', () {
    final sat = _saturday();
    // Logged: all 4 warm-ups, the top set, one back-off.
    final done = [
      for (final s in sat.take(6)) (s.values, s.group),
    ];
    final blocks = groupPlannedSlots(pending: sat.skip(6).toList(), done: done);
    final b = blocks.single;
    expect(b.doneCount, 6);
    expect(b.totalCount, 21);
    expect(b.pendingCount, 15);
    // Done-only slots (warm-up, top) lead, then the partial back-off row.
    expect(b.slots[0].warmup && b.slots[0].isDone, isTrue);
    expect(b.slots[0].meta, '45·50·70·95');
    expect(b.slots[1].meta, '1×5 · 120 lb');
    expect(b.slots[1].isDone, isTrue);
    final back = b.slots[2];
    expect(back.meta, '3×6 · 105 lb');
    expect(back.pending, hasLength(2));
    expect(back.isPartial, isTrue);
  });

  test('fully-done group still yields its block (N / N)', () {
    final sat = _saturday();
    final blocks = groupPlannedSlots<String>(
      pending: const [],
      done: [for (final s in sat) (s.values, s.group)],
    );
    expect(blocks.single.doneCount, 21);
    expect(blocks.single.pendingCount, 0);
  });

  test('a re-appended identical set rejoins its slot', () {
    final blocks = groupPlannedSlots(
      pending: [
        _p('a', 'Bench Press', 6, weight: 175),
        _p('b', 'Squat', 8, weight: 210),
        _p('c', 'Bench Press', 6, weight: 175), // reverted, appended
      ],
    );
    final slots = blocks.single.slots;
    expect(slots, hasLength(2));
    expect([for (final s in slots.first.pending) s.ref], ['a', 'c']);
  });

  test('ungrouped entries never merge; done ungrouped ignored', () {
    final blocks = groupPlannedSlots(
      pending: [
        _p('a', 'Curl', 10, weight: 30, group: null),
        _p('b', 'Curl', 10, weight: 30, group: null),
        _p('c', 'Dip', 8, group: 'Coach: Thu'),
      ],
      done: [
        ({'exercise': 'Curl', 'reps': 10}, null),
      ],
    );
    expect([for (final b in blocks) b.name], [null, null, 'Coach: Thu']);
    expect(blocks.first.slots.single.meta, '1×10 · 30 lb');
    expect(blocks.last.slots.single.meta, '1×8 · BW');
  });

  test('entries without an exercise (non-strength views) stay separate', () {
    final blocks = groupPlannedSlots(
      pending: [
        PlannedSetIn('a', const {'type': 'bike'}, 'g'),
        PlannedSetIn('b', const {'type': 'bike'}, 'g'),
      ],
    );
    expect(blocks.single.slots, hasLength(2));
    final s = blocks.single.slots.first;
    expect(s.chipLabel(s.pending.single), 'Log');
  });

  test('formatters', () {
    expect(setsRepsLoad(sets: 3, reps: 8), '3×8');
    expect(setsRepsLoad(sets: 3, reps: 8, weight: 161.5), '3×8 · 161.5 lb');
    expect(setsRepsLoad(sets: 3, reps: 8, weight: 161.5, bodyweight: true),
        '3×8 · BW');
    expect(setChipLabel(reps: 6, weight: 105.0), '105×6');
    expect(setChipLabel(reps: 8), '8 reps');
    expect(formatNum(105.0), '105');
  });
}
