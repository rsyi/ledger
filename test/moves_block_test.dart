import 'package:airledger/models/coach_proposal.dart';
import 'package:airledger/services/moves_block.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no block → text unchanged (trimmed), no proposal', () {
    final r = extractMovesBlock('  Good night.\n\nTomorrow: squat.\n');
    expect(r.text, 'Good night.\n\nTomorrow: squat.');
    expect(r.proposal, isNull);
  });

  test('valid block → proposal built, block stripped', () {
    const out = '''Briefing line one.
Missed bench Wed → moving it to Fri (no squat that day).

```moves
{"summary": "Bench to Fri", "moves": [
  {"item": "Bench top set", "from_date": "2026-09-30",
   "to_date": "2026-10-02", "period": "PM", "note": "missed Wed"}
]}
```


Sleep well.''';
    final r = extractMovesBlock(out);
    expect(r.text, 'Briefing line one.\n'
        'Missed bench Wed → moving it to Fri (no squat that day).\n\n'
        'Sleep well.');
    final p = r.proposal!;
    expect(p.summary, 'Bench to Fri');
    expect(p.moves, hasLength(1));
    expect(p.moves.single.item, 'Bench top set');
    expect(p.moves.single.from, DateTime(2026, 9, 30));
    expect(p.moves.single.to, DateTime(2026, 10, 2));
    expect(p.moves.single.period, 'PM');
    expect(p.moves.single.note, 'missed Wed');
    // Encodes to the canonical wire format.
    expect(p.encode(), contains('"type":"moves"'));
  });

  test('fence opener is case-insensitive; full payload with type/v ok', () {
    const out = 'Hi.\n```MOVES\n{"v":1,"type":"moves","summary":"s",'
        '"moves":[{"item":"RDL","from_date":"2026-10-02",'
        '"to_date":"2026-10-03","period":"AM","note":""}]}\n```';
    final r = extractMovesBlock(out);
    expect(r.text, 'Hi.');
    expect(r.proposal!.moves.single.item, 'RDL');
  });

  test('malformed JSON → text still stripped, proposal null', () {
    const out = 'Text.\n\n```moves\n{"summary": "x", moves: [}\n```\nEnd.';
    final r = extractMovesBlock(out);
    expect(r.text, 'Text.\n\nEnd.');
    expect(r.proposal, isNull);
  });

  test('only invalid moves → proposal null', () {
    const out = 'A\n```moves\n{"summary":"x","moves":['
        '{"item":"","from_date":"2026-10-01","to_date":"2026-10-02"},'
        '{"item":"Squat","from_date":"2026-10-01","to_date":"2026-10-01"}'
        ']}\n```';
    final r = extractMovesBlock(out);
    expect(r.text, 'A');
    expect(r.proposal, isNull);
  });

  test('other fenced blocks are left alone', () {
    const out = 'A\n```\ncode\n```\nB';
    final r = extractMovesBlock(out);
    expect(r.text, out);
    expect(r.proposal, isNull);
  });

  group('postSplitBriefing', () {
    const raw = 'Plan for Fri.\n\n```moves\n'
        '{"summary": "s", "moves": [{"item": "Bench heavy", '
        '"from_date": "2026-09-30", "to_date": "2026-10-02"}, '
        '{"item": "Nope", "from_date": "2026-09-30", '
        '"to_date": "2026-10-02"}]}\n```\n';

    test('briefing FIRST, then the validated proposal; invalid moves '
        'dropped with a warning', () async {
      final order = <String>[];
      final warns = <String>[];
      MovesProposal? posted;
      await postSplitBriefing(
        raw,
        postBriefing: (t) async => order.add('briefing:$t'),
        postProposal: (p) async {
          order.add('proposal');
          posted = p;
        },
        validate: (p) => (
          proposal: MovesProposal(
              summary: p.summary, moves: [p.moves.first]),
          warnings: ['moves[1] bad'],
        ),
        warn: warns.add,
      );
      expect(order, ['briefing:Plan for Fri.', 'proposal']);
      expect(posted!.moves.single.item, 'Bench heavy');
      expect(warns.single, contains('moves[1] bad'));
    });

    test('briefing post fails → throws, proposal never posted', () async {
      var proposals = 0;
      await expectLater(
        postSplitBriefing(
          raw,
          postBriefing: (_) async => throw StateError('sheets down'),
          postProposal: (_) async => proposals++,
          validate: (p) => (proposal: p, warnings: const <String>[]),
          warn: (_) {},
        ),
        throwsA(isA<StateError>()),
      );
      expect(proposals, 0);
    });

    test('proposal post fails → warn only (briefing already posted)',
        () async {
      final warns = <String>[];
      await postSplitBriefing(
        raw,
        postBriefing: (_) async {},
        postProposal: (_) async => throw StateError('quota'),
        validate: (p) => (proposal: p, warnings: const <String>[]),
        warn: warns.add,
      );
      expect(warns.single, contains('quota'));
    });

    test('no valid move left → no proposal posted', () async {
      var proposals = 0;
      await postSplitBriefing(
        raw,
        postBriefing: (_) async {},
        postProposal: (_) async => proposals++,
        validate: (p) => (proposal: null, warnings: const ['all bad']),
        warn: (_) {},
      );
      expect(proposals, 0);
    });

    test('empty briefing after stripping → throws before posting anything',
        () async {
      var posts = 0;
      await expectLater(
        postSplitBriefing(
          '```moves\n{"summary":"s","moves":[]}\n```',
          postBriefing: (_) async => posts++,
          postProposal: (_) async => posts++,
          validate: (p) => (proposal: p, warnings: const <String>[]),
          warn: (_) {},
        ),
        throwsA(isA<StateError>()),
      );
      expect(posts, 0);
    });
  });
}
