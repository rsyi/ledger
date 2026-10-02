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
}
