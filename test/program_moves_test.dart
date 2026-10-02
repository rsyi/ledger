// program_moves.dart — the pure move resolver over a Mon–Sun week.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_moves.dart';

final mon = DateTime(2026, 9, 28);
DateTime d(int i) => DateTime(2026, 9, 28 + i);

PrescribedItem item(String name, {String period = 'AM'}) =>
    PrescribedItem(name: name, scheme: '3x8', period: period, targetSets: 3);

ProgramMove mv(
  String item, {
  required DateTime from,
  required DateTime to,
  String id = 'm',
  DateTime? at,
  String source = 'manual',
}) =>
    ProgramMove(
      id: id,
      to: to,
      from: from,
      item: item,
      period: 'AM',
      source: source,
      createdAt: at,
      note: '',
    );

Map<DateTime, List<PrescribedItem>> week() => {
      d(0): [item('Squat'), item('Bench')],
      d(1): [item('Climb', period: 'PM')],
      d(2): [item('Bench'), item('Pull-ups')],
      d(3): [],
      d(4): [item('Deadlift'), item('RDL')],
      d(5): [item('Press')],
      d(6): [],
    };

void main() {
  group('ProgramMove', () {
    test('key = from date + lowercased trimmed item', () {
      final m = mv('  Bench Heavy ', from: d(2), to: d(4));
      expect(m.key, '2026-09-30|bench heavy');
    });

    test('fromRecord parses Sheets-shaped strings', () {
      final m = ProgramMove.fromRecord({
        'id': 'abc',
        'date': '2026-10-02',
        'from_date': '2026-09-30',
        'item': 'Bench',
        'period': 'AM',
        'source': 'coach',
        'created_at': '2026-10-02 08:00:00',
        'note': 'missed Wed',
      })!;
      expect(m.id, 'abc');
      expect(m.to, DateTime(2026, 10, 2));
      expect(m.from, DateTime(2026, 9, 30));
      expect(m.item, 'Bench');
      expect(m.period, 'AM');
      expect(m.source, 'coach');
      expect(m.createdAt, DateTime(2026, 10, 2, 8));
      expect(m.note, 'missed Wed');
    });

    test('fromRecord accepts DateTime values + ISO strings, normalises to '
        'local midnight', () {
      final m = ProgramMove.fromRecord({
        'id': 'x',
        'date': DateTime(2026, 10, 2, 13, 5),
        'from_date': '2026-09-30T00:00:00.000',
        'item': 'RDL',
        'created_at': DateTime(2026, 10, 1, 7),
      })!;
      expect(m.to, DateTime(2026, 10, 2));
      expect(m.from, DateTime(2026, 9, 30));
      expect(m.period, '');
      expect(m.source, '');
      expect(m.note, '');
      expect(m.createdAt, DateTime(2026, 10, 1, 7));
    });

    test('fromRecord → null when a required field is missing/blank', () {
      final base = {
        'id': 'x',
        'date': '2026-10-02',
        'from_date': '2026-09-30',
        'item': 'Bench',
      };
      expect(ProgramMove.fromRecord(base), isNotNull);
      for (final k in base.keys) {
        expect(ProgramMove.fromRecord({...base}..remove(k)), isNull,
            reason: 'missing $k');
        expect(ProgramMove.fromRecord({...base, k: ''}), isNull,
            reason: 'blank $k');
      }
      expect(ProgramMove.fromRecord({...base, 'date': 'garbage'}), isNull);
    });

    test('toRecord round-trips through fromRecord', () {
      final m = ProgramMove(
        id: 'r1',
        to: d(4),
        from: d(2),
        item: 'Bench',
        period: 'AM',
        source: 'manual',
        createdAt: DateTime(2026, 9, 30, 21, 15),
        note: 'late meeting',
      );
      final r = m.toRecord();
      expect(r['date'], d(4));
      expect(r['from_date'], d(2));
      final back = ProgramMove.fromRecord(r)!;
      expect(back.id, m.id);
      expect(back.to, m.to);
      expect(back.from, m.from);
      expect(back.item, m.item);
      expect(back.period, m.period);
      expect(back.source, m.source);
      expect(back.createdAt, m.createdAt);
      expect(back.note, m.note);
    });
  });

  group('activeMoves', () {
    test('single in-week move is active under its key', () {
      final a = activeMoves([mv('Bench', from: d(2), to: d(4))], mon);
      expect(a.keys, ['2026-09-30|bench']);
      expect(a.values.single.to, d(4));
    });

    test('re-move: later createdAt wins regardless of list order', () {
      final later = mv('Bench',
          id: 'b', from: d(2), to: d(5), at: DateTime(2026, 9, 30, 20));
      final earlier = mv('Bench',
          id: 'a', from: d(2), to: d(4), at: DateTime(2026, 9, 30, 9));
      expect(activeMoves([later, earlier], mon).values.single.id, 'b');
      expect(activeMoves([earlier, later], mon).values.single.id, 'b');
    });

    test('equal / missing createdAt → later in list wins', () {
      final a = mv('Bench', id: 'a', from: d(2), to: d(4));
      final b = mv('bench', id: 'b', from: d(2), to: d(5));
      expect(activeMoves([a, b], mon).values.single.id, 'b');
      expect(activeMoves([b, a], mon).values.single.id, 'a');
    });

    test('moves outside the week are ignored (either end)', () {
      expect(
          activeMoves([
            mv('Bench', from: d(2), to: d(7)), // to next Monday
            mv('Bench', from: d(-1), to: d(1)), // from previous Sunday
            mv('Press', from: d(12), to: d(13)), // a different week
          ], mon),
          isEmpty);
    });

    test('to == from is never an active move', () {
      expect(activeMoves([mv('Bench', from: d(2), to: d(2))], mon), isEmpty);
    });

    test('a later to == from row puts the item back home', () {
      final out = mv('Bench',
          id: 'a', from: d(2), to: d(4), at: DateTime(2026, 9, 30, 9));
      final back = mv('Bench',
          id: 'b', from: d(2), to: d(2), at: DateTime(2026, 9, 30, 10));
      expect(activeMoves([out, back], mon), isEmpty);
    });

    test('monday argument is normalised (any time on Monday works)', () {
      final a = activeMoves(
          [mv('Bench', from: d(2), to: d(4))], DateTime(2026, 9, 28, 15));
      expect(a, hasLength(1));
    });
  });

  group('effectiveWeek', () {
    test('no moves → every item at home, nothing ghosted', () {
      final e = effectiveWeek(week(), const {});
      expect(e.keys.toList(), week().keys.toList());
      for (final entry in e.entries) {
        for (final it in entry.value) {
          expect(it.home, entry.key);
          expect(it.isGhost, isFalse);
          expect(it.movedFrom, isNull);
          expect(it.move, isNull);
        }
      }
      expect([for (final x in e[d(2)]!) x.item.name], ['Bench', 'Pull-ups']);
    });

    test('move Wed → Fri: Wed keeps a ghost in place, Fri gains the item',
        () {
      final m = mv('bench', from: d(2), to: d(4));
      final e = effectiveWeek(week(), activeMoves([m], mon));

      final wed = e[d(2)]!;
      expect([for (final x in wed) x.item.name], ['Bench', 'Pull-ups']);
      expect(wed[0].isGhost, isTrue);
      expect(wed[0].movedTo, d(4));
      expect(wed[0].move!.id, m.id);
      expect(wed[1].isGhost, isFalse);

      final fri = e[d(4)]!;
      expect([for (final x in fri) x.item.name], ['Deadlift', 'RDL', 'Bench']);
      final moved = fri.last;
      expect(moved.movedFrom, d(2));
      expect(moved.home, d(2));
      expect(moved.isGhost, isFalse);
      expect(moved.move!.id, m.id);
    });

    test('only the moved day\'s instance moves (Mon Bench stays)', () {
      final e = effectiveWeek(
          week(), activeMoves([mv('Bench', from: d(2), to: d(4))], mon));
      expect(e[d(0)]!.every((x) => !x.isGhost && x.movedFrom == null),
          isTrue);
    });

    test('re-move latest wins end-to-end', () {
      final e = effectiveWeek(
          week(),
          activeMoves([
            mv('Bench', id: 'a', from: d(2), to: d(4), at: DateTime(2026, 9, 30, 9)),
            mv('Bench', id: 'b', from: d(2), to: d(5), at: DateTime(2026, 9, 30, 10)),
          ], mon));
      expect(e[d(2)]!.first.movedTo, d(5));
      expect(e[d(4)]!.any((x) => x.movedFrom != null), isFalse);
      expect(e[d(5)]!.last.item.name, 'Bench');
      expect(e[d(5)]!.last.movedFrom, d(2));
    });

    test('undo (move row deleted) restores the prescription', () {
      final e = effectiveWeek(week(), activeMoves(const [], mon));
      expect(e[d(2)]!.first.isGhost, isFalse);
      expect(e[d(4)], hasLength(2));
    });

    test('unknown item name is ignored (no crash, nothing moves)', () {
      final e = effectiveWeek(
          week(), activeMoves([mv('Snatch', from: d(2), to: d(4))], mon));
      expect(e[d(2)]!.any((x) => x.isGhost), isFalse);
      expect(e[d(4)], hasLength(2));
    });

    test('two same-named items on a day: only the first moves', () {
      final w = week()
        ..[d(5)] = [item('Pull-ups'), item('Press'), item('Pull-ups')];
      final e = effectiveWeek(
          w, activeMoves([mv('PULL-UPS ', from: d(5), to: d(6))], mon));
      final sat = e[d(5)]!;
      expect([for (final x in sat) x.isGhost], [true, false, false]);
      expect(e[d(6)]!.single.item.name, 'Pull-ups');
    });

    test('move onto a day with no prescription (Sun) appends there', () {
      final e = effectiveWeek(
          week(), activeMoves([mv('Press', from: d(5), to: d(6))], mon));
      expect(e[d(6)]!.single.movedFrom, d(5));
      expect(e[d(5)]!.single.isGhost, isTrue);
    });

    test('moved-in items append in origin-day order', () {
      final e = effectiveWeek(
          week(),
          activeMoves([
            mv('Press', from: d(5), to: d(3)),
            mv('Squat', from: d(0), to: d(3)),
          ], mon));
      expect([for (final x in e[d(3)]!) x.item.name], ['Squat', 'Press']);
    });
  });
}
