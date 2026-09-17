// ignore_for_file: avoid_print

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

/// Import a Kaya "Export Logbook via Email" CSV into the `kaya_ascents`
/// tab of the main workbook. That tab is deliberately NOT a ledger view
/// (no views/*.view.yml targets it), so the app and sync never touch it
/// — it exists purely so ledger-mcp's `climbing` view can serve the
/// data to Claude. Re-running replaces the whole tab: the export is a
/// full snapshot, so replace-all is the idempotent operation.
///
/// The only transformation applied is date normalization (Kaya exports
/// JS Date.toString() strings; the MCP's recency filter and any human
/// reader want yyyy-mm-dd) plus newest-first ordering. All other
/// columns pass through verbatim — the export schema has drifted before
/// (2022 sample: date, stiffness, rating, ascent_type, grade, color,
/// climb_name, gym, location, country, attempts) and passthrough means
/// drift lands as new columns, not import failures.
///
/// Usage:
///   dart run tool/kaya_import.dart `<csv-path>` [--confirm]
///   dart run tool/kaya_import.dart ~/Downloads/export.csv --confirm
Future<void> main(List<String> args) async {
  final paths = args.where((a) => !a.startsWith('--')).toList();
  if (paths.length != 1) {
    print('usage: dart run tool/kaya_import.dart <csv-path> [--confirm]');
    exit(1);
  }
  final confirmed = args.contains('--confirm');
  const spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
  const tab = 'kaya_ascents';

  final raw = await File(paths.first).readAsString();
  final rows = parseCsv(raw);
  if (rows.length < 2) {
    print('CSV has no data rows (parsed ${rows.length} row(s))');
    exit(1);
  }
  final headers = rows.first.map((c) => c.trim()).toList();
  final dateCol = headers.indexWhere((h) => h.toLowerCase() == 'date');
  if (dateCol < 0) {
    print('no "date" column in CSV headers: $headers');
    exit(1);
  }

  final data = <List<String>>[];
  var badDates = 0;
  for (final r in rows.sublist(1)) {
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

  print('parsed ${data.length} ascents '
      '(${headers.length} columns, $badDates unparseable date(s) kept verbatim)');
  print('columns: $headers');
  print('range: ${data.isEmpty ? '-' : '${data.last[dateCol]} … ${data.first[dateCol]}'}');
  if (!confirmed) {
    print('\ndry run — pass --confirm to replace "$tab" in $spreadsheetId');
    exit(0);
  }

  final home = Platform.environment['HOME']!;
  final keyJson =
      await File('$home/.config/airledger/service-account.json').readAsString();
  final client = await clientViaServiceAccount(
    ServiceAccountCredentials.fromJson(keyJson),
    [sheets.SheetsApi.spreadsheetsScope],
  );
  try {
    final api = sheets.SheetsApi(client);

    final meta = await api.spreadsheets.get(spreadsheetId);
    final exists = (meta.sheets ?? [])
        .any((s) => s.properties?.title == tab);
    if (!exists) {
      print('creating tab "$tab" ...');
      await api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(requests: [
          sheets.Request(
            addSheet: sheets.AddSheetRequest(
              properties: sheets.SheetProperties(title: tab),
            ),
          ),
        ]),
        spreadsheetId,
      );
    }

    print('clearing "$tab" ...');
    await api.spreadsheets.values
        .clear(sheets.ClearValuesRequest(), spreadsheetId, "'$tab'");
    print('writing ${data.length + 1} rows ...');
    await api.spreadsheets.values.update(
      sheets.ValueRange(values: [headers, ...data]),
      spreadsheetId,
      "'$tab'!A1",
      valueInputOption: 'RAW',
    );
    print('done: $tab now holds ${data.length} ascents');
  } finally {
    client.close();
  }
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
