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
///  - [acceptProposal] / [declineProposal] resolve a pending automatic
///    TM proposal (HITL gating 2026-10-16 — automatic changes never
///    apply on their own).
/// Rows are written at an explicit computed range (never `values.append`
/// at A1 — that eats the header row when A1 is empty).
library;

import 'package:googleapis/sheets/v4.dart' as sheets;

import 'google_auth/sheets_auth.dart';
import 'swr_cache.dart';

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

  /// Caches the RAW tab cells + the parsed snapshot: the raw cells are
  /// what persists to disk (perf batch 3 — a cold start prices the plan
  /// from the last-good TMs instead of waiting ~2 s on Sheets).
  late final SwrCache<WmTabsRaw> _cache = SwrCache(
    name: 'wm_store',
    ttl: cacheTtl,
    persist: SwrPersist(
      key: 'wm_store|$spreadsheetId',
      encode: (v) => {'wm': v.wm, 'readings': v.readings},
      decode: (j) {
        final m = j as Map;
        return WmTabsRaw(_cells(m['wm']), _cells(m['readings']));
      },
    ),
  );

  static List<List<Object?>> _cells(Object? v) => [
        for (final r in (v as List? ?? const []))
          (r as List).cast<Object?>(),
      ];

  Future<T> _withApi<T>(
      Future<T> Function(sheets.SheetsApi api) fn) =>
      auth.withApi(fn);

  /// Both tabs, parsed. Null only when the fetch fails AND nothing is
  /// cached; tabs that don't exist yet read as empty lists (the nightly
  /// seeds them). STALE-WHILE-REVALIDATE (perf #8): inside [cacheTtl]
  /// the cached copy; past it the last-good copy immediately + one
  /// background refresh; [force] (and the first read after a write)
  /// awaits fresh data. The two tabs are read in PARALLEL.
  Future<WmSnapshot?> snapshot({bool force = false}) async =>
      (await _cache.get(_fetch, force: force))?.snapshot;

  Future<WmTabsRaw> _fetch() => _withApi((api) async {
        final tabs = await Future.wait(
            [_tab(api, wmTabName), _tab(api, readingsTabName)]);
        return WmTabsRaw(tabs[0], tabs[1]);
      });

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

  /// Accepts the lift's PENDING proposal (HITL gating, 2026-10-16):
  /// appends a confirmed `auto_accepted` row with the proposed value —
  /// from then on it prices the program. [expectedId] (the card's
  /// [tmProposalIdOf]) guards against a proposal superseded since the
  /// card rendered. Returns false (nothing appended) when no matching
  /// proposal is pending.
  Future<bool> acceptProposal(String lift, {String? expectedId}) async {
    final snap = await snapshot(force: true);
    final p = snap == null ? null : pendingTmProposal(snap.workingMax, lift);
    if (p == null ||
        (expectedId != null && tmProposalIdOf(p) != expectedId)) {
      return false;
    }
    await _appendWorkingMax(tmAcceptRow(p, DateTime.now()));
    return true;
  }

  /// Keeps the current TM instead of the lift's pending proposal:
  /// appends a confirmed `declined` row (value = the accepted TM,
  /// reading_id = the proposal key) so the nightly doesn't re-propose
  /// the same number. Returns false when no matching proposal is
  /// pending.
  Future<bool> declineProposal(String lift, {String? expectedId}) async {
    final snap = await snapshot(force: true);
    final p = snap == null ? null : pendingTmProposal(snap.workingMax, lift);
    final current =
        snap == null ? null : currentWorkingMax(snap.workingMax, lift);
    if (p == null ||
        current == null ||
        (expectedId != null && tmProposalIdOf(p) != expectedId)) {
      return false;
    }
    await _appendWorkingMax(tmDeclineRow(p, current.valueLb, DateTime.now()));
    return true;
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
    _cache.invalidate(); // next snapshot() awaits a refetch
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

  static Map<String, int> headerIndex(List<List<Object?>> tab) =>
      tab.isEmpty
          ? const {}
          : {
              for (var i = 0; i < tab.first.length; i++)
                tab.first[i].toString(): i,
            };

  static String _fmt(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();
}

/// The two WM tabs' raw cells (what persists) + the parsed snapshot
/// (computed once per value).
class WmTabsRaw {
  WmTabsRaw(this.wm, this.readings);
  final List<List<Object?>> wm;
  final List<List<Object?>> readings;

  late final WmSnapshot snapshot = () {
    final wmHead = WmStore.headerIndex(wm);
    final rdHead = WmStore.headerIndex(readings);
    return (
      workingMax: <WorkingMaxRow>[
        for (final r in wm.skip(1)) ?WorkingMaxRow.fromCells(wmHead, r),
      ],
      readings: <ReadingRow>[
        for (final r in readings.skip(1)) ?ReadingRow.fromCells(rdHead, r),
      ],
    );
  }();
}
