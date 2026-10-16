// ignore_for_file: avoid_print

import 'dart:io';

import 'package:airledger/services/wm_tabs.dart';
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:googleapis_auth/auth_io.dart';

/// HITL TM gating rollout (2026-10-16): converts automatic TM changes
/// that were already APPLIED (source=rule/test, dated on/after --since)
/// into PENDING proposals — APPEND-ONLY, via [hitlConversionRows]:
///   1. a `revert_to_pending` row restoring the previously accepted value
///      (same effective date, confirmed=true), then
///   2. a pending `auto` proposal (confirmed=false) of the applied value
///      with its evidence, for the user to Accept / Keep in the app.
///
///   dart run tool/wm_hitl_convert.dart [--since=2026-10-15]   # dry run
///   dart run tool/wm_hitl_convert.dart --confirm              # append
///
/// Idempotent: after a conversion the lift's newest value row is the
/// revert, so a re-run finds nothing.
Future<void> main(List<String> args) async {
  final confirm = args.contains('--confirm');
  var since = DateTime.utc(2026, 10, 15);
  for (final a in args) {
    if (a.startsWith('--since=')) {
      since = DateTime.parse('${a.substring(8)}T00:00:00Z');
    }
  }
  final home = Platform.environment['HOME']!;
  final cfg = File('$home/.config/airledger/config.yaml').readAsLinesSync();
  String? pick(String key) {
    for (final l in cfg) {
      if (l.startsWith('$key:')) return l.substring(key.length + 1).trim();
    }
    return null;
  }

  final spreadsheetId = pick('spreadsheet_id')!;
  final keyPath =
      pick('service_account_key_path') ??
      '$home/.config/airledger/service-account.json';
  final client = await clientViaServiceAccount(
    ServiceAccountCredentials.fromJson(await File(keyPath).readAsString()),
    [gsheets.SheetsApi.spreadsheetsScope],
  );
  final api = gsheets.SheetsApi(client);

  Future<List<List<Object?>>> tab(String name) async =>
      (await api.spreadsheets.values.get(spreadsheetId, "'$name'")).values ??
      [];
  Map<String, int> head(List<List<Object?>> t) => t.isEmpty
      ? {}
      : {for (var i = 0; i < t.first.length; i++) t.first[i].toString(): i};

  final wmValues = await tab(wmTabName);
  final rdValues = await tab(readingsTabName);
  final wmHead = head(wmValues);
  final rdHead = head(rdValues);
  final snap = (
    workingMax: <WorkingMaxRow>[
      for (final r in wmValues.skip(1)) ?WorkingMaxRow.fromCells(wmHead, r),
    ],
    readings: <ReadingRow>[
      for (final r in rdValues.skip(1)) ?ReadingRow.fromCells(rdHead, r),
    ],
  );
  final rows = hitlConversionRows(snap, since: since);
  print(
    'working_max: ${wmValues.length - 1} rows; converting applied auto '
    'changes dated on/after ${since.toIso8601String().substring(0, 10)}',
  );
  if (rows.isEmpty) {
    print('nothing to convert');
    client.close();
    return;
  }
  for (final r in rows) {
    print('  ${confirm ? 'APPEND' : 'would append'}: ${r.toSheetRow()}');
  }
  final after = [...snap.workingMax, ...rows];
  for (final lift in {for (final r in rows) r.lift}) {
    print(
      '  → $lift accepted ${currentWorkingMax(after, lift)!.valueLb}, '
      'pending ${pendingTmProposal(after, lift)?.valueLb}',
    );
  }
  if (!confirm) {
    print('dry run — pass --confirm to append');
    client.close();
    return;
  }
  await api.spreadsheets.values.update(
    gsheets.ValueRange(values: [for (final r in rows) r.toSheetRow()]),
    spreadsheetId,
    "'$wmTabName'!A${wmValues.length + 1}",
    valueInputOption: 'RAW',
  );
  print(
    'appended ${rows.length} working_max rows at row '
    '${wmValues.length + 1}',
  );
  client.close();
}
