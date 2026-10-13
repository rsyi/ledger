/// Per-view LOCAL DATA VERSION for the engine ledger (perf batch 2,
/// 2026-10-12). Bumped whenever rows of a view may have changed in the
/// on-device store: a local create/update/delete (EngineLedgerConnector),
/// a sync that pulled/pushed/merged/deleted rows for the view, and an
/// integration ingest (Withings, Whoop, Kaya, Macrofactor write through
/// `EngineLedgerRepository.ingest` directly — each call site bumps).
///
/// The connector's snapshot cache keys every cached read on [of]; a bump
/// makes the next read go back to the engine. Pure Dart, process-global.
library;

class LedgerDataVersion {
  LedgerDataVersion._();
  static final LedgerDataVersion instance = LedgerDataVersion._();

  final _views = <String, int>{};
  int _epoch = 0;
  int _total = 0;

  /// The version of [view]'s rows — strictly increases on every bump
  /// that can affect the view ([bump] of it, or [bumpAll]).
  int of(String view) => _epoch + (_views[view] ?? 0);

  /// Monotonic count of every bump (any view) — a cheap "anything in the
  /// ledger changed" key.
  int get total => _total;

  /// Rows of [view] changed (or may have).
  void bump(String? view) {
    _total++;
    if (view == null || view.isEmpty) {
      _epoch++;
      return;
    }
    _views[view] = (_views[view] ?? 0) + 1;
  }

  /// Rows of any view may have changed (unknown-scope writes).
  void bumpAll() {
    _total++;
    _epoch++;
  }
}

/// Marker: a connector whose every row change bumps [LedgerDataVersion]
/// (EngineLedgerConnector). Results derived from such reads may be
/// memoized per `LedgerDataVersion.instance.total` (WeekStateLoader).
abstract interface class DataVersioned {}
