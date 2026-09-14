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
}
