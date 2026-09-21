// ignore_for_file: avoid_print

import 'dart:io';

import 'package:airledger/services/kaya_csv.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

/// Import a Kaya "Export Logbook via Email" CSV into the `kaya_ascents`
/// tab of the main workbook. That tab is deliberately NOT a ledger view
/// for writes (only the read-only climbing view renders it), so the
/// sync never touches it — it exists so ledger-mcp's `climbing` view
/// can serve the data to Claude. Re-running replaces the whole tab: the
/// export is a full snapshot, so replace-all is the idempotent
/// operation.
///
/// Parsing/normalization lives in `lib/services/kaya_csv.dart`, shared
/// with the in-app Gmail import (integrations/kaya_gmail.dart) — this
/// tool is the manual/offline path over the same code.
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
  final KayaCsvSnapshot snap;
  try {
    snap = parseKayaExportCsv(raw);
  } on FormatException catch (e) {
    print(e.message);
    exit(1);
  }

  print('parsed ${snap.count} ascents '
      '(${snap.headers.length} columns, ${snap.badDates} unparseable '
      'date(s) kept verbatim)');
  print('columns: ${snap.headers}');
  print('range: ${snap.count == 0 ? '-' : '${snap.oldestDay} … ${snap.latestDay}'}');
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
    print('writing ${snap.count + 1} rows ...');
    await api.spreadsheets.values.update(
      sheets.ValueRange(values: snap.tabRows),
      spreadsheetId,
      "'$tab'!A1",
      valueInputOption: 'RAW',
    );
    print('done: $tab now holds ${snap.count} ascents');
  } finally {
    client.close();
  }
}
