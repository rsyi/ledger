/// Kaya "Export Logbook via Email" CSV parsing — shared by the in-app
/// Gmail import (`integrations/kaya_gmail.dart`) and the CLI
/// (`tool/kaya_import.dart`). Pure Dart on purpose: no Flutter imports,
/// so `dart run tool/kaya_import.dart` keeps working on the host VM.
///
/// The only transformation applied is date normalization (Kaya exports
/// JS Date.toString() strings; the MCP's recency filter and any human
/// reader want yyyy-mm-dd) plus newest-first ordering. All other
/// columns pass through verbatim — the export schema has drifted before
/// (2022 sample: date, stiffness, rating, ascent_type, grade, color,
/// climb_name, gym, location, country, attempts) and passthrough means
/// drift lands as new columns, not import failures.
library;

/// A parsed, normalized Kaya export ready to replace the sheet tab.
class KayaCsvSnapshot {
  KayaCsvSnapshot({
    required this.headers,
    required this.rows,
    required this.badDates,
    required this.dateCol,
  });

  /// Trimmed header cells, verbatim order from the export.
  final List<String> headers;

  /// Data rows, padded to [headers] length, dates normalized to
  /// yyyy-mm-dd where parseable, sorted newest-first by the date column.
  final List<List<String>> rows;

  /// Count of rows whose date cell couldn't be parsed (kept verbatim so
  /// no data is silently lost).
  final int badDates;

  /// Index of the `date` column within [headers].
  final int dateCol;

  int get count => rows.length;
  String? get latestDay => rows.isEmpty ? null : rows.first[dateCol];
  String? get oldestDay => rows.isEmpty ? null : rows.last[dateCol];

  /// Header + data rows — exactly what replace-all writes to the tab.
  List<List<String>> get tabRows => [headers, ...rows];
}

/// Parses a raw Kaya export CSV. Throws [FormatException] when the CSV
/// has no data rows or no `date` column — both mean "this is not a Kaya
/// logbook export" and the caller should surface that, not import it.
KayaCsvSnapshot parseKayaExportCsv(String raw) {
  final parsed = parseCsv(raw);
  if (parsed.length < 2) {
    throw FormatException(
        'CSV has no data rows (parsed ${parsed.length} row(s))');
  }
  final headers = parsed.first.map((c) => c.trim()).toList();
  final dateCol = headers.indexWhere((h) => h.toLowerCase() == 'date');
  if (dateCol < 0) {
    throw FormatException('no "date" column in CSV headers: $headers');
  }
  final data = <List<String>>[];
  var badDates = 0;
  for (final r in parsed.sublist(1)) {
    if (r.every((c) => c.trim().isEmpty)) continue;
    final row = List<String>.from(r);
    while (row.length < headers.length) {
      row.add(''); // API-trimmed trailing blanks
    }
    final day = normalizeDay(row[dateCol]);
    if (day == null) {
      badDates++;
    } else {
      row[dateCol] = day;
    }
    data.add(row);
  }
  // Newest first — canonical ledger tab order.
  data.sort((a, b) => b[dateCol].compareTo(a[dateCol]));
  return KayaCsvSnapshot(
    headers: headers,
    rows: data,
    badDates: badDates,
    dateCol: dateCol,
  );
}

/// Kaya export dates are JS Date.toString() ("Sun May 23 2021 14:15:39
/// GMT+0000 (GMT)"); ISO strings are accepted too in case the export
/// format ever modernizes. Returns yyyy-mm-dd, or null when unparseable
/// (caller keeps the original cell so no data is silently lost).
String? normalizeDay(String v) {
  final s = v.trim();
  if (s.isEmpty) return null;
  final iso = DateTime.tryParse(s);
  if (iso != null) return _fmt(iso);
  const months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6, //
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };
  final parts = s.split(' ');
  if (parts.length >= 4) {
    final m = months[parts[1]];
    final d = int.tryParse(parts[2]);
    final y = int.tryParse(parts[3]);
    if (m != null && d != null && y != null) return _fmt(DateTime(y, m, d));
  }
  return null;
}

String _fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Minimal RFC 4180 parser (quoted fields, embedded commas/newlines,
/// doubled quotes). The repo has no csv dependency and the export is
/// simple enough that adding one isn't warranted.
List<List<String>> parseCsv(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.length > 1 || row.first.isNotEmpty) rows.add(row);
      row = <String>[];
    } else {
      cell.write(c);
    }
  }
  row.add(cell.toString());
  if (row.length > 1 || row.first.isNotEmpty) rows.add(row);
  return rows;
}
