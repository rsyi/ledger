// Moves under the CONFIGURED week (2026-10-03): a move may PULL an item
// forward from next week (to earlier than from by ≤ 7 days, across the
// boundary); a later move must stay within from's week. Pinned with the
// user's live travel rows under a Saturday start (Sat 10/3 – Fri 10/9).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/services/missed_work.dart';
import 'package:airledger/services/moves_validation.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/program_week.dart' show dayOnly;

import 'support/travel_week_moves.dart';

const sat = DateTime.saturday;
DateTime d(int day) => DateTime(2026, 10, day);

ProgramMove mv(String item, DateTime from, DateTime to, {int min = 0}) =>
    ProgramMove(
      id: '$item$min',
      to: to,
      from: from,
      item: item,
      period: 'AM',
      source: 'manual',
      createdAt: DateTime(2026, 10, 2, 12, min),
    );

PrescribedItem pi(String name) =>
    PrescribedItem(name: name, scheme: '', period: 'AM', targetSets: 1);

void main() {
  group('isAllowedMove', () {
    test('same week: earlier or later', () {
      expect(isAllowedMove(d(9), d(6), weekStartDay: sat), isTrue);
      expect(isAllowedMove(d(6), d(9), weekStartDay: sat), isTrue);
    });
    test('pull forward across the boundary: ≤ 7 days earlier', () {
      expect(isAllowedMove(d(10), d(6), weekStartDay: sat), isTrue);
      expect(isAllowedMove(d(10), d(3), weekStartDay: sat), isTrue); // 7
      expect(isAllowedMove(d(16), d(9), weekStartDay: sat), isTrue); // 7
      expect(isAllowedMove(d(16), d(8), weekStartDay: sat), isFalse); // 8
    });
    test('push LATER across the boundary: never', () {
      // The live Norwegian row: Tue 10/6 → Sun 10/11 (next week).
      expect(isAllowedMove(d(6), d(11), weekStartDay: sat), isFalse);
      expect(isAllowedMove(d(9), d(10), weekStartDay: sat), isFalse);
      // …but under Monday weeks it was within the week.
      expect(isAllowedMove(d(6), d(11)), isTrue);
    });
  });

  group('activeMoves (Saturday weeks)', () {
    test('a pulled-forward move belongs to BOTH weeks it touches', () {
      final m = mv('OHP heavy', d(10), d(6));
      expect(activeMoves([m], d(4), weekStartDay: sat).keys, [
        m.key,
      ]); // target week (Sat 10/3 – Fri 10/9)
      expect(activeMoves([m], d(12), weekStartDay: sat).keys, [
        m.key,
      ]); // home week (Sat 10/10 – Fri 10/16)
      expect(activeMoves([m], d(20), weekStartDay: sat), isEmpty);
    });

    test('an invalid later row never supersedes a valid earlier one', () {
      final ok = mv('OHP heavy', d(6), d(8), min: 0);
      final bad = mv('OHP heavy', d(6), d(11), min: 1); // later, crosses
      final a = activeMoves([ok, bad], d(6), weekStartDay: sat);
      expect(a.values.single.to, d(8));
    });

    test('back-home row still cancels a pull-forward', () {
      final a = activeMoves(
        [
          mv('OHP heavy', d(10), d(6), min: 0),
          mv('OHP heavy', d(10), d(10), min: 1),
        ],
        d(6),
        weekStartDay: sat,
      );
      expect(a, isEmpty);
    });

    test('pulledInHomeDays lists next-week home days only', () {
      final a = activeMoves(
        [mv('OHP heavy', d(10), d(6)), mv('Deadlift heavy', d(9), d(6))],
        d(6),
        weekStartDay: sat,
      );
      expect(pulledInHomeDays(a, d(6), weekStartDay: sat), {d(10)});
    });
  });

  group('effectiveWeek — pulled-forward items', () {
    test('render on the target day; next week shows the ghost', () {
      final moves = [mv('OHP heavy', d(10), d(6))];
      final prescribed = {
        for (var i = 3; i <= 9; i++) d(i): <PrescribedItem>[],
        d(10): [pi('OHP heavy'), pi('Pull-ups')],
      };
      final thisWeek = effectiveWeek(
        prescribed,
        activeMoves(moves, d(3), weekStartDay: sat),
        weekStart: d(3),
      );
      expect(thisWeek.keys, [for (var i = 3; i <= 9; i++) d(i)]);
      final tue = thisWeek[d(6)]!.single;
      expect(tue.item.name, 'OHP heavy');
      expect(tue.movedFrom, d(10));

      final next = effectiveWeek(
        {
          for (var i = 10; i <= 16; i++)
            d(i): i == 10
                ? [pi('OHP heavy'), pi('Pull-ups')]
                : <PrescribedItem>[],
        },
        activeMoves(moves, d(10), weekStartDay: sat),
        weekStart: d(10),
      );
      expect(next.keys.first, d(10));
      final satItems = next[d(10)]!;
      expect(
        satItems.firstWhere((e) => e.item.name == 'OHP heavy').movedTo,
        d(6),
      );
      expect(
        satItems.firstWhere((e) => e.item.name == 'Pull-ups').isGhost,
        isFalse,
      );
      expect(
        next.containsKey(d(6)),
        isFalse,
        reason: 'the previous-week target is not part of next week',
      );
    });

    test('the LIVE travel rows (incl. the later OHP → Tue rows) under a '
        'Saturday start', () {
      final all = liveTravelMoves();
      final a = activeMoves(all, d(5), weekStartDay: sat);
      String keyOf(String item, int from) =>
          '2026-10-${from.toString().padLeft(2, '0')}|${item.toLowerCase()}';
      // Pulled forward from next Saturday onto Tue (the LATER OHP rows win
      // over the earlier Sat → Mon ones).
      for (final item in [
        'OHP heavy',
        'OHP back-offs',
        'Seated cable row',
        'Face pulls',
      ]) {
        expect(a[keyOf(item, 10)]?.to, d(6), reason: item);
      }
      // In-week moves unchanged.
      expect(a[keyOf('Bench heavy', 7)]?.to, d(5));
      expect(a[keyOf('Deadlift heavy', 9)]?.to, d(6));
      // Norwegian Tue → Sun 10/11 is a LATER move across the boundary:
      // ignored, so the 4x4 stays home on Tue.
      expect(a.containsKey(keyOf('Norwegian', 6)), isFalse);
      // Skips: this week's by date; the Sat 10/10 ones are next week's.
      final skips = activeSkips(all, d(5), weekStartDay: sat);
      expect(skips.keys.any((k) => k.startsWith('2026-10-10')), isFalse);
      expect(skips.keys.where((k) => k.startsWith('2026-10-08')), hasLength(7));
      final nextSkips = activeSkips(all, d(10), weekStartDay: sat);
      expect(nextSkips.keys.map((k) => k.split('|').last).toSet(), {
        'pull-ups',
        'lateral raise',
        'external rotations',
      });
    });
  });

  group('checkProposedMove (Saturday weeks, today Tue 10/6)', () {
    final today = d(6);
    ProposedMove pm(DateTime from, DateTime to) =>
        ProposedMove(item: 'OHP heavy', from: from, to: to);

    test('pull forward from next week → allowed', () {
      final m = checkProposedMove(
        pm(d(10), d(7)),
        today: today,
        weekStartDay: sat,
      );
      expect(m.from, d(10));
      expect(m.to, d(7));
    });

    test('push later into next week → refused', () {
      expect(
        () =>
            checkProposedMove(pm(d(6), d(11)), today: today, weekStartDay: sat),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('outside this week'),
          ),
        ),
      );
    });

    test('pull from two weeks ahead (> 7 days) → refused', () {
      expect(
        () =>
            checkProposedMove(pm(d(17), d(7)), today: today, weekStartDay: sat),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('too far ahead'),
          ),
        ),
      );
    });

    test('item check against this + next week\'s effective days', () {
      final week = {
        d(10): [EffectiveItem(item: pi('OHP heavy'), home: d(10))],
      };
      final m = checkProposedMove(
        ProposedMove(item: 'ohp heavy', from: d(10), to: d(8)),
        today: today,
        week: week,
        weekStartDay: sat,
      );
      expect(m.item, 'OHP heavy');
    });
  });

  group('missed work + expiry (Saturday weeks)', () {
    test('expiry wording keys off the week\'s LAST day (Fri)', () {
      expect(expiryLabel(d(8), d(8), weekStartDay: sat), isNull); // Thu
      expect(
        expiryLabel(d(9), d(8), weekStartDay: sat),
        'expires end of Fri 10/9',
      );
      expect(
        expiryLabel(d(9), d(9), weekStartDay: sat),
        'expires end of Fri 10/9 (tonight)',
      );
      expect(expiryLabel(d(11), d(11), weekStartDay: sat), isNull); // Sun
    });

    test('remaining days run today..Fri; a missed Saturday is still '
        'recoverable within the week', () {
      final week = {
        for (var i = 3; i <= 9; i++)
          d(i): i == 3
              ? [EffectiveItem(item: pi('OHP heavy'), home: d(3))]
              : <EffectiveItem>[],
      };
      final mw = detectMissedWork(
        week: week,
        strengthRows: const [],
        climbDays: const {},
        cardio4x4Days: const {},
        today: d(6),
        weekStartDay: sat,
      );
      expect(mw.remainingDays, [d(6), d(7), d(8), d(9)]);
      expect(mw.missed.single.item.name, 'OHP heavy');
      // Logged on Tue (no move needed): the week's work covers it.
      final done = detectMissedWork(
        week: week,
        strengthRows: [(date: d(6), exercise: 'Overhead Press')],
        climbDays: const {},
        cardio4x4Days: const {},
        today: d(7),
        weekStartDay: sat,
      );
      expect(done.isEmpty, isTrue);
    });

    test('judgeToday counts the closing day itself', () {
      final week = {
        for (var i = 3; i <= 9; i++)
          d(i): i == 9
              ? [EffectiveItem(item: pi('Deadlift heavy'), home: d(9))]
              : <EffectiveItem>[],
      };
      MissedWork run({required bool judge}) => detectMissedWork(
        week: week,
        strengthRows: const [],
        climbDays: const {},
        cardio4x4Days: const {},
        today: d(9),
        weekStartDay: sat,
        judgeToday: judge,
      );
      expect(run(judge: false).isEmpty, isTrue);
      expect(run(judge: true).missed.single.day, dayOnly(d(9)));
    });
  });
}
