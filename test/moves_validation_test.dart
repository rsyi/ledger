// moves_validation.dart — the shared propose_moves / nightly ```moves
// validation (week bounds + the item must exist on from_date).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/services/moves_validation.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_moves.dart';

PrescribedItem _i(String name, {String period = 'PM'}) =>
    PrescribedItem(name: name, scheme: '', period: period);

void main() {
  final mon = DateTime(2026, 9, 28);
  final wed = DateTime(2026, 9, 30);
  final thu = DateTime(2026, 10, 1);
  final fri = DateTime(2026, 10, 2);
  final sat = DateTime(2026, 10, 3);
  final today = thu;

  Map<DateTime, List<PrescribedItem>> prescribed() => {
        for (var i = 0; i < 7; i++)
          DateTime(2026, 9, 28 + i): switch (i) {
            0 => [_i('Squat heavy', period: 'AM'), _i('RDL')],
            2 => [_i('Bench heavy'), _i('Pull-ups')],
            4 => [_i('Deadlift heavy')],
            _ => <PrescribedItem>[],
          },
      };

  Map<DateTime, List<EffectiveItem>> week({List<ProgramMove> moves = const []}) =>
      effectiveWeek(prescribed(), activeMoves(moves, mon));

  ProposedMove mv(String item, DateTime from, DateTime to) =>
      ProposedMove(item: item, from: from, to: to);

  group('checkProposedMove', () {
    test('a prescribed item on from_date passes, canonical name', () {
      final m = checkProposedMove(mv('bench HEAVY ', wed, fri),
          today: today, week: week());
      expect(m.item, 'Bench heavy');
      expect(m.from, wed);
      expect(m.to, fri);
    });

    test('an item not on from_date throws, listing the valid names', () {
      expect(
        () => checkProposedMove(mv('Bench top set', wed, fri),
            today: today, week: week(), label: 'moves[0]'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('moves[0]'), contains('Bench top set'),
              contains('Bench heavy'), contains('Pull-ups')),
        )),
      );
    });

    test('a rest day says nothing is prescribed', () {
      expect(
        () => checkProposedMove(mv('Bench heavy', DateTime(2026, 9, 29), fri),
            today: today, week: week()),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('nothing is prescribed'))),
      );
    });

    test('an already-moved item: re-moving from its HOME day passes', () {
      final w = week(moves: [
        ProgramMove(id: 'm', to: fri, from: wed, item: 'Bench heavy'),
      ]);
      final m = checkProposedMove(mv('Bench heavy', wed, sat),
          today: today, week: w);
      expect(m.from, wed);
    });

    test('an item currently LIVING on from_date (moved in) is accepted and '
        're-keyed to its home day', () {
      final w = week(moves: [
        ProgramMove(id: 'm', to: fri, from: wed, item: 'Bench heavy'),
      ]);
      final m = checkProposedMove(mv('Bench heavy', fri, sat),
          today: today, week: w);
      expect(m.from, wed, reason: 'program_moves keys on the home day');
      expect(m.to, sat);
    });

    test('date rules: outside week / past / to == from', () {
      for (final (from, to, msg) in [
        (wed, DateTime(2026, 10, 5), 'outside this week'),
        (DateTime(2026, 9, 27), fri, 'outside this week'),
        (mon, DateTime(2026, 9, 29), 'in the past'),
        (fri, fri, 'equals from_date'),
      ]) {
        expect(
          () => checkProposedMove(mv('X', from, to), today: today),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains(msg))),
        );
      }
    });

    test('week null → item check skipped (dates still checked)', () {
      expect(
        checkProposedMove(mv('Anything', wed, fri), today: today).item,
        'Anything',
      );
    });
  });

  group('filterValidMoves', () {
    test('drops invalid moves with warnings, keeps the valid ones', () {
      final r = filterValidMoves(
        MovesProposal(summary: 's', moves: [
          mv('Bench heavy', wed, fri),
          mv('Bench top set', wed, fri),
          mv('Squat heavy', mon, DateTime(2026, 10, 5)),
        ]),
        today: today,
        week: week(),
      );
      expect(r.proposal!.moves.map((m) => m.item), ['Bench heavy']);
      expect(r.proposal!.summary, 's');
      expect(r.warnings, hasLength(2));
      expect(r.warnings.first, contains('Bench top set'));
    });

    test('none valid → null proposal', () {
      final r = filterValidMoves(
        MovesProposal(summary: 's', moves: [mv('Nope', wed, fri)]),
        today: today,
        week: week(),
      );
      expect(r.proposal, isNull);
      expect(r.warnings, hasLength(1));
    });
  });
}
