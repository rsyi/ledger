/// The synced `app_settings` tab (2026-10-03) — a tiny key/value store
/// in the main workbook that the app, the nightly Mac tools (service
/// account) and the ledger-mcp worker all read, so one setting means the
/// same thing everywhere. First key: `week_start` (week_start.dart).
///
/// Shape: header row `key | value | updated_at`, one row per key
/// (upserted in place — the LAST row for a key wins if duplicates ever
/// appear). Direct Sheets, NOT an engine view: it's a single mutable
/// config row, not a dated ledger of events (an engine view would need a
/// date dimension, append-only history semantics and a schema rollout
/// gated on an APK install — trap #2), and every reader already has
/// service-account Sheets access.
///
/// HEADER GUARD: writes never use `values.append` (which, at an empty
/// A1, writes data INTO the header row — how the `program_moves` tab
/// once lost its header). [writeAppSetting] first ensures row 1 IS the
/// header — creating the tab, writing A1, or inserting a header row
/// above stray data — then updates the key's row at an explicit range.
///
/// No Flutter imports (tools use it too).
library;

import 'package:googleapis/sheets/v4.dart' as sheets;

import 'week_start.dart';

const appSettingsTabName = 'app_settings';
const appSettingsHeaders = ['key', 'value', 'updated_at'];

String _cell(List<Object?> row, int i) =>
    i >= 0 && i < row.length ? (row[i]?.toString().trim() ?? '') : '';

/// key → value from the tab's raw values (header row first). Rows with
/// a blank key are skipped; the last row per key wins. A tab whose first
/// row isn't the header reads as empty (never guesses columns).
Map<String, String> parseAppSettings(List<List<Object?>> values) {
  if (values.isEmpty) return const {};
  final head = [for (final c in values.first) c?.toString().trim() ?? ''];
  final k = head.indexOf('key');
  final v = head.indexOf('value');
  if (k < 0 || v < 0) return const {};
  final out = <String, String>{};
  for (final r in values.skip(1)) {
    final key = _cell(r, k);
    if (key.isEmpty) continue;
    out[key] = _cell(r, v);
  }
  return out;
}

/// Whether row 1 of [values] is the header.
bool hasAppSettingsHeader(List<List<Object?>> values) =>
    values.isNotEmpty &&
    [for (final c in values.first) c?.toString().trim() ?? '']
        .take(appSettingsHeaders.length)
        .join('|') ==
        appSettingsHeaders.join('|');

Future<List<List<Object?>>> _tab(
    sheets.SheetsApi api, String spreadsheetId) async {
  try {
    final resp = await api.spreadsheets.values
        .get(spreadsheetId, "'$appSettingsTabName'");
    return (resp.values ?? const []).map((r) => r.cast<Object?>()).toList();
  } on sheets.DetailedApiRequestError catch (e) {
    if (e.status == 400) return const []; // tab doesn't exist yet
    rethrow;
  }
}

/// Every setting (empty when the tab doesn't exist yet).
Future<Map<String, String>> readAppSettings(
        sheets.SheetsApi api, String spreadsheetId) async =>
    parseAppSettings(await _tab(api, spreadsheetId));

/// Upserts [key] = [value] (stamped [now]): creates the tab and/or its
/// header first when missing (see the library doc), then updates the
/// key's existing row in place or writes the next free row — always at
/// an explicit range.
Future<void> writeAppSetting(
  sheets.SheetsApi api,
  String spreadsheetId,
  String key,
  String value, {
  DateTime? now,
}) async {
  final meta = await api.spreadsheets.get(spreadsheetId);
  final sheet = (meta.sheets ?? const <sheets.Sheet>[])
      .where((s) => s.properties?.title == appSettingsTabName)
      .firstOrNull;
  int? sheetId = sheet?.properties?.sheetId;
  if (sheet == null) {
    final resp = await api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: [
        sheets.Request(
          addSheet: sheets.AddSheetRequest(
            properties: sheets.SheetProperties(title: appSettingsTabName),
          ),
        ),
      ]),
      spreadsheetId,
    );
    sheetId = resp.replies?.firstOrNull?.addSheet?.properties?.sheetId;
  }
  var values = await _tab(api, spreadsheetId);
  if (!hasAppSettingsHeader(values)) {
    final firstRowBlank = values.isEmpty ||
        values.first.every((c) => (c?.toString().trim() ?? '').isEmpty);
    if (!firstRowBlank && sheetId != null) {
      // Stray data in row 1: push it down, never overwrite it.
      await api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(requests: [
          sheets.Request(
            insertDimension: sheets.InsertDimensionRequest(
              range: sheets.DimensionRange(
                sheetId: sheetId,
                dimension: 'ROWS',
                startIndex: 0,
                endIndex: 1,
              ),
              inheritFromBefore: false,
            ),
          ),
        ]),
        spreadsheetId,
      );
    }
    await api.spreadsheets.values.update(
      sheets.ValueRange(values: [appSettingsHeaders]),
      spreadsheetId,
      "'$appSettingsTabName'!A1",
      valueInputOption: 'RAW',
    );
    values = await _tab(api, spreadsheetId);
  }
  final head = [for (final c in values.first) c?.toString().trim() ?? ''];
  final k = head.indexOf('key');
  var row = -1; // 0-based index into values
  for (var i = values.length - 1; i >= 1; i--) {
    if (_cell(values[i], k) == key) {
      row = i;
      break;
    }
  }
  final sheetRow = row >= 1 ? row + 1 : values.length + 1;
  await api.spreadsheets.values.update(
    sheets.ValueRange(values: [
      [key, value, (now ?? DateTime.now()).toUtc().toIso8601String()],
    ]),
    spreadsheetId,
    "'$appSettingsTabName'!A$sheetRow",
    valueInputOption: 'RAW',
  );
}

/// THE week start for a tool / nightly run: the synced `week_start` row
/// (read here) resolved against [programVersion]'s default
/// (week_start.dart's precedence). A failed/missing tab read falls back
/// to the program default — never throws.
Future<({int day, WeekStartSource source})> readWeekStart(
  sheets.SheetsApi api,
  String spreadsheetId, {
  Map<Object?, Object?>? programVersion,
}) async {
  String? setting;
  try {
    setting = (await readAppSettings(api, spreadsheetId))[weekStartSettingKey];
  } catch (_) {/* offline / no tab: program default */}
  return resolveWeekStart(setting: setting, programVersion: programVersion);
}
