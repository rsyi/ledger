// Shared Kaya CSV parser (lib/services/kaya_csv.dart) — used by both
// tool/kaya_import.dart and the in-app Gmail import.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/kaya_csv.dart';

void main() {
  group('parseCsv (RFC 4180)', () {
    test('plain rows and columns', () {
      expect(parseCsv('a,b,c\n1,2,3\n'), [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
    });

    test('quoted fields with embedded commas, newlines, doubled quotes', () {
      final rows = parseCsv('name,note\n"Crimpy, slabby","line1\nline2"\n'
          '"say ""hi""",x\n');
      expect(rows, [
        ['name', 'note'],
        ['Crimpy, slabby', 'line1\nline2'],
        ['say "hi"', 'x'],
      ]);
    });

    test('CRLF line endings and missing trailing newline', () {
      expect(parseCsv('a,b\r\n1,2\r\n3,4'), [
        ['a', 'b'],
        ['1', '2'],
        ['3', '4'],
      ]);
    });

    test('skips blank lines', () {
      expect(parseCsv('a,b\n\n1,2\n\n'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });
  });

  group('normalizeDay', () {
    test('JS Date.toString() form', () {
      expect(normalizeDay('Sun May 23 2021 14:15:39 GMT+0000 (GMT)'),
          '2021-05-23');
    });

    test('ISO form passes through normalized', () {
      expect(normalizeDay('2026-09-15T20:11:00Z'), '2026-09-15');
      expect(normalizeDay('2026-09-15'), '2026-09-15');
    });

    test('junk returns null', () {
      expect(normalizeDay(''), isNull);
      expect(normalizeDay('yesterday'), isNull);
      expect(normalizeDay('Foo Bar 12 twenty'), isNull);
    });
  });

  group('parseKayaExportCsv', () {
    const header = 'date,grade,gym';

    test('normalizes dates and sorts newest-first', () {
      final snap = parseKayaExportCsv('$header\n'
          'Sun May 23 2021 14:15:39 GMT+0000 (GMT),v4,Movement\n'
          'Tue Sep 15 2026 09:00:00 GMT+0000 (GMT),v6,Touchstone\n'
          '2024-01-02,v5,Movement\n');
      expect(snap.count, 3);
      expect(snap.rows.map((r) => r[0]).toList(),
          ['2026-09-15', '2024-01-02', '2021-05-23']);
      expect(snap.latestDay, '2026-09-15');
      expect(snap.oldestDay, '2021-05-23');
      expect(snap.badDates, 0);
      expect(snap.tabRows.first, ['date', 'grade', 'gym']);
      expect(snap.tabRows, hasLength(4));
    });

    test('pads API-trimmed short rows and keeps bad dates verbatim', () {
      final snap = parseKayaExportCsv('$header\n'
          'not-a-date,v1\n'
          '2026-01-01,v2,Gym\n');
      expect(snap.badDates, 1);
      // Short row padded to header length.
      expect(snap.rows.every((r) => r.length == 3), isTrue);
      // Unparseable date cell survives untouched.
      expect(snap.rows.map((r) => r[0]), contains('not-a-date'));
    });

    test('skips fully-empty rows', () {
      final snap = parseKayaExportCsv('$header\n2026-01-01,v2,Gym\n,,\n');
      expect(snap.count, 1);
    });

    test('throws on no data rows', () {
      expect(() => parseKayaExportCsv('$header\n'),
          throwsA(isA<FormatException>()));
      expect(() => parseKayaExportCsv(''), throwsA(isA<FormatException>()));
    });

    test('throws when the date column is missing', () {
      expect(() => parseKayaExportCsv('grade,gym\nv5,Movement\n'),
          throwsA(isA<FormatException>()));
    });

    test('trims header cells and matches date case-insensitively', () {
      final snap = parseKayaExportCsv(' Date ,grade\n2026-01-01,v2\n');
      expect(snap.headers, ['Date', 'grade']);
      expect(snap.dateCol, 0);
    });
  });
}
