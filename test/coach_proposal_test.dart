import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/coach_proposal.dart';

void main() {
  test('encode/parse round-trip', () {
    final p = CoachProposal(
      view: 'strength',
      date: DateTime(2026, 9, 14),
      template: 'cut_press_heavy',
      summary: 'Combined press day',
      entries: [
        {'exercise': 'Bench Press', 'weight': 185, 'reps': 5},
        {'exercise': 'Overhead Press', 'weight': 115, 'reps': 5},
      ],
    );
    final parsed = CoachProposal.tryParse(p.encode());
    expect(parsed, isNotNull);
    expect(parsed!.view, 'strength');
    expect(parsed.date, DateTime(2026, 9, 14));
    expect(parsed.template, 'cut_press_heavy');
    expect(parsed.summary, 'Combined press day');
    expect(parsed.entries, hasLength(2));
    expect(parsed.entries.first['weight'], 185);
  });

  test('optional template/summary survive as null/empty', () {
    final p = CoachProposal(
      view: 'cardio',
      date: DateTime(2026, 9, 15),
      summary: '',
      entries: [
        {'type': '4x4'},
      ],
    );
    final parsed = CoachProposal.tryParse(p.encode())!;
    expect(parsed.template, isNull);
    expect(parsed.summary, '');
  });

  test('tryParse rejects malformed payloads', () {
    expect(CoachProposal.tryParse('plain chat text'), isNull);
    expect(CoachProposal.tryParse('{"v":1}'), isNull); // missing keys
    expect(CoachProposal.tryParse('{"v":2,"view":"strength","date":"2026-09-14","entries":[{}]}'),
        isNull); // wrong version
    expect(CoachProposal.tryParse('{"v":1,"view":"strength","date":"not-a-date","entries":[{}]}'),
        isNull);
    expect(CoachProposal.tryParse('{"v":1,"view":"strength","date":"2026-09-14","entries":[]}'),
        isNull); // empty entries
    expect(CoachProposal.tryParse('[]'), isNull);
  });

  group('MovesProposal', () {
    final p = MovesProposal(
      summary: 'Missed Wed bench — Fri has room',
      moves: [
        ProposedMove(
          item: 'Bench heavy',
          from: DateTime(2026, 9, 30),
          to: DateTime(2026, 10, 2),
          period: 'PM',
          note: 'missed Wed — late meeting',
        ),
        ProposedMove(
          item: 'Pull-ups',
          from: DateTime(2026, 9, 30),
          to: DateTime(2026, 10, 3),
        ),
      ],
    );

    test('encode shape is the documented wire format', () {
      final m = jsonDecode(p.encode()) as Map;
      expect(m['v'], 1);
      expect(m['type'], 'moves');
      expect(m['summary'], 'Missed Wed bench — Fri has room');
      expect(m['moves'], [
        {
          'item': 'Bench heavy',
          'from_date': '2026-09-30',
          'to_date': '2026-10-02',
          'period': 'PM',
          'note': 'missed Wed — late meeting',
        },
        {
          'item': 'Pull-ups',
          'from_date': '2026-09-30',
          'to_date': '2026-10-03',
          'period': '',
          'note': '',
        },
      ]);
    });

    test('round-trip', () {
      final q = MovesProposal.tryParse(p.encode())!;
      expect(q.summary, p.summary);
      expect(q.moves, hasLength(2));
      expect(q.moves.first.item, 'Bench heavy');
      expect(q.moves.first.from, DateTime(2026, 9, 30));
      expect(q.moves.first.to, DateTime(2026, 10, 2));
      expect(q.moves.first.period, 'PM');
      expect(q.moves.first.note, 'missed Wed — late meeting');
      expect(q.moves.last.period, '');
    });

    test('tolerates missing v / optional keys and drops invalid moves', () {
      final q = MovesProposal.tryParse(jsonEncode({
        'type': 'moves',
        'moves': [
          {'item': 'Squat', 'from_date': '2026-09-28', 'to_date': '2026-09-29T00:00:00'},
          {'item': '', 'from_date': '2026-09-28', 'to_date': '2026-09-29'},
          {'item': 'X', 'from_date': 'nope', 'to_date': '2026-09-29'},
          {'item': 'Same', 'from_date': '2026-09-28', 'to_date': '2026-09-28'},
          'junk',
        ],
      }))!;
      expect(q.summary, '');
      expect(q.moves.map((m) => m.item), ['Squat']);
      expect(q.moves.single.to, DateTime(2026, 9, 29));
    });

    test('rejects garbage', () {
      expect(MovesProposal.tryParse('plain text'), isNull);
      expect(MovesProposal.tryParse('[]'), isNull);
      expect(MovesProposal.tryParse('{"type":"moves","moves":[]}'), isNull);
      expect(MovesProposal.tryParse('{"type":"moves"}'), isNull);
      expect(
          MovesProposal.tryParse(
              '{"type":"moves","moves":[{"item":"","from_date":"x"}]}'),
          isNull);
      expect(
          MovesProposal.tryParse('{"v":2,"type":"moves","moves":'
              '[{"item":"A","from_date":"2026-09-28","to_date":"2026-09-29"}]}'),
          isNull);
      // A legacy v1 proposal is not a moves proposal.
      expect(
          MovesProposal.tryParse(CoachProposal(
            view: 'strength',
            date: DateTime(2026, 9, 14),
            summary: 's',
            entries: [
              {'exercise': 'Bench Press'}
            ],
          ).encode()),
          isNull);
    });

    test('CoachProposal.tryParse returns null for moves payloads', () {
      expect(CoachProposal.tryParse(p.encode()), isNull);
      // Even one that also happens to carry legacy keys.
      expect(
          CoachProposal.tryParse('{"v":1,"type":"moves","view":"strength",'
              '"date":"2026-09-14","entries":[{"a":1}]}'),
          isNull);
    });
  });
}
