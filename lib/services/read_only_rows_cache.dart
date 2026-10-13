/// One shared, process-wide cache for READ-ONLY view rows (perf #5,
/// 2026-10-12) — the Kaya `climbing` tab is a NETWORK read of ~1.4k rows
/// (direct Sheets; it only changes on a Kaya import), and Goals, the
/// Progress dashboard, the Plan data loader, the coach and
/// WeekStateLoader each used to fetch it separately.
///
/// Keyed by (connector identity, view name); [ttl] 30 min (the former
/// WeekStateLoader Kaya cache, now generalized). Concurrent reads share
/// one request; failed reads are never cached. [clear] after an import.
library;

import '../models/view_schema.dart';
import 'perf.dart';
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';

class ReadOnlyRowsCache {
  ReadOnlyRowsCache._();

  static const ttl = Duration(minutes: 30);

  static final Map<(WarehouseConnector, String),
      ({DateTime at, List<Record> rows})> _cache = {};
  static final Map<(WarehouseConnector, String), Future<List<Record>>>
      _inflight = {};
  static int _gen = 0;

  /// Bumped by every [clear] (a Kaya import) — memo keys over these rows.
  static int get generation => _gen;

  /// Drops every entry (after a Kaya import; tests).
  static void clear() {
    _cache.clear();
    _inflight.clear();
    _gen++;
  }

  /// All rows of [view] via [repo], cached for [ttl]. Throws when the
  /// read fails and nothing fresh is cached (callers degrade as before).
  static Future<List<Record>> list(
    ViewSchema view,
    WarehouseConnector repo, {
    DateTime Function() now = DateTime.now,
  }) {
    final key = (repo, view.name);
    final at = now();
    final c = _cache[key];
    if (c != null && !at.isBefore(c.at) && at.difference(c.at) < ttl) {
      Perf.count('ro_rows.hit', meta: {'view': view.name});
      return Future.value(c.rows);
    }
    final pending = _inflight[key];
    if (pending != null) return pending;
    final gen = _gen;
    final f = Perf.span('ro_rows.load', () async {
      final rows = List<Record>.unmodifiable(await repo.list(view));
      if (gen == _gen) _cache[key] = (at: at, rows: rows);
      return rows;
    }, meta: {'view': view.name});
    _inflight[key] = f;
    f.whenComplete(() {
      if (identical(_inflight[key], f)) _inflight.remove(key);
    }).ignore();
    return f;
  }

  /// [list] when [view] is read-only (network-backed), else a plain
  /// `repo.list` — ledger views are local + change on every log.
  static Future<List<Record>> listIfReadOnly(
          ViewSchema view, WarehouseConnector repo) =>
      view.readOnly ? list(view, repo) : repo.list(view);
}
