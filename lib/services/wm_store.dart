/// App-side store for the working-max controller tabs (WM-2).
///
/// Reads the append-only `working_max` + `readings` tabs straight from
/// the workbook (direct Sheets API, same service-account auth the
/// read-only Kaya snapshot card uses — these tabs have no ViewSchema and
/// live entirely outside the engine ledger), with a short cache so the
/// week-plan screen and the planner don't refetch on every build.
///
/// Writes are APPEND-ONLY, matching the nightly tool:
///  - [confirmSeed] appends a duplicate value row with `confirmed=true`
///    (append-only-honest seed confirmation — the pending seed row stays
///    in history; readers take the LAST confirm-bearing row per lift).
///  - [setWorkingMax] appends a `source=manual` row (spec §2 MANUAL:
///    applies immediately — the nightly picks it up as the current wm).
/// Rows are written at an explicit computed range (never `values.append`
/// at A1 — that eats the header row when A1 is empty).
library;

import 'package:googleapis/sheets/v4.dart' as sheets;

import 'google_auth/sheets_auth.dart';

import 'wm_tabs.dart';
import 'working_max.dart' show defaultVariantByLift;

class WmStore {
  WmStore({
    required this.spreadsheetId,
    required this.auth,
  });

  final String spreadsheetId;

  /// Service account (owner build) or the user's Google token.
  final SheetsAuth auth;

  /// Short cache — prescriptions don't need to be fresher than this.
  static const cacheTtl = Duration(minutes: 3);

  WmSnapshot? _cached;
  DateTime? _cachedAt;

  Future<T> _withApi<T>(
      Future<T> Function(sheets.SheetsApi api) fn) =>
      auth.withApi(fn);

  /// Both tabs, parsed. Null only when the fetch fails AND nothing is
  /// cached; tabs that don't exist yet read as empty lists (the nightly
  /// seeds them). Serves the cached copy inside [cacheTtl].
  Future<WmSnapshot?> snapshot({bool force = false}) async {
    final at = _cachedAt;
    if (!force &&
        _cached != null &&
        at != null &&
        DateTime.now().difference(at) < cacheTtl) {
      return _cached;
    }
    try {
      final snap = await _withApi((api) async {
        final wmValues = await _tab(api, wmTabName);
        final readingValues = await _tab(api, readingsTabName);
        final wmHead = _headerIndex(wmValues);
        final rdHead = _headerIndex(readingValues);
        return (
          workingMax: <WorkingMaxRow>[
            for (final r in wmValues.skip(1))
              ?WorkingMaxRow.fromCells(wmHead, r),
          ],
          readings: <ReadingRow>[
            for (final r in readingValues.skip(1))
              ?ReadingRow.fromCells(rdHead, r),
          ],
        );
      });
      _cached = snap;
      _cachedAt = DateTime.now();
      return snap;
    } catch (_) {
      return _cached; // stale-if-error; null before first success
    }
  }

  /// Confirms a pending seed by appending a duplicate row with
  /// `confirmed=true`. No-op when the lift has no current value.
  Future<void> confirmSeed(String lift) async {
    final snap = await snapshot(force: true);
    final current =
        snap == null ? null : currentWorkingMax(snap.workingMax, lift);
    if (current == null) return;
    await _appendWorkingMax(WorkingMaxRow(
      lift: lift,
      variant: current.variant,
      valueLb: current.valueLb,
      effectiveFrom: DateTime.now(),
      source: 'seed',
      reason: 'user confirmed seed (${_fmt(current.valueLb)} lb) in app',
      confirmed: true,
    ));
  }

  /// Manual override (spec §2 MANUAL — applies immediately).
  Future<void> setWorkingMax({
    required String lift,
    required double valueLb,
    required String reason,
  }) async {
    await _appendWorkingMax(WorkingMaxRow(
      lift: lift,
      variant: defaultVariantByLift[lift] ?? 'default',
      valueLb: valueLb,
      effectiveFrom: DateTime.now(),
      source: 'manual',
      reason: reason.trim().isEmpty ? 'manual override in app' : reason,
      confirmed: true,
    ));
  }

  Future<void> _appendWorkingMax(WorkingMaxRow row) async {
    await _withApi((api) async {
      // Ensure the tab + header exist (first manual set can predate the
      // nightly's seeding).
      final meta = await api.spreadsheets.get(spreadsheetId);
      final exists = (meta.sheets ?? [])
          .any((s) => s.properties?.title == wmTabName);
      if (!exists) {
        await api.spreadsheets.batchUpdate(
          sheets.BatchUpdateSpreadsheetRequest(requests: [
            sheets.Request(
              addSheet: sheets.AddSheetRequest(
                properties: sheets.SheetProperties(title: wmTabName),
              ),
            ),
          ]),
          spreadsheetId,
        );
      }
      final values = await _tab(api, wmTabName);
      var startRow = values.length + 1;
      if (values.isEmpty) {
        await api.spreadsheets.values.update(
          sheets.ValueRange(values: [wmTabHeaders]),
          spreadsheetId,
          "'$wmTabName'!A1",
          valueInputOption: 'RAW',
        );
        startRow = 2;
      }
      await api.spreadsheets.values.update(
        sheets.ValueRange(values: [row.toSheetRow()]),
        spreadsheetId,
        "'$wmTabName'!A$startRow",
        valueInputOption: 'RAW',
      );
    });
    _cachedAt = null; // next snapshot() refetches
  }

  Future<List<List<Object?>>> _tab(
      sheets.SheetsApi api, String name) async {
    try {
      final resp =
          await api.spreadsheets.values.get(spreadsheetId, "'$name'");
      return (resp.values ?? const [])
          .map((r) => r.cast<Object?>())
          .toList();
    } on sheets.DetailedApiRequestError catch (e) {
      if (e.status == 400) return const []; // tab doesn't exist yet
      rethrow;
    }
  }

  static Map<String, int> _headerIndex(List<List<Object?>> tab) =>
      tab.isEmpty
          ? const {}
          : {
              for (var i = 0; i < tab.first.length; i++)
                tab.first[i].toString(): i,
            };

  static String _fmt(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();
}
