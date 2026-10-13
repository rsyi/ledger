/// A [WarehouseConnector] that connects on FIRST USE (perf #9,
/// 2026-10-12). The read-only Sheets repo used to be connected inside
/// the startup bootstrap — a service-account token exchange awaited
/// (with transient retries) before first paint. Wrapping it keeps ONE
/// stable connector identity (the Kaya rows cache keys on it) while the
/// exchange happens only when a read-only view is actually read.
/// A failed connect is not memoized — the next call retries.
library;

import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'sheets_repository.dart' show Record;
import 'warehouse_connector.dart';

class LazyConnector implements WarehouseConnector {
  LazyConnector(this.config, this._connect);

  @override
  final DatabaseConfig config;

  final Future<WarehouseConnector> Function() _connect;
  Future<WarehouseConnector>? _inner;

  /// Whether the underlying connection has been requested (test hook).
  bool get connected => _inner != null;

  Future<WarehouseConnector> _get() {
    final f = _inner ??= _connect();
    f.catchError((Object _) {
      if (identical(_inner, f)) _inner = null;
      return this;
    }).ignore();
    return f;
  }

  @override
  Future<void> ensureTable(ViewSchema view) async =>
      (await _get()).ensureTable(view);

  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      (await _get()).list(view, onDate: onDate);

  @override
  Future<Record> create(ViewSchema view, Record record) async =>
      (await _get()).create(view, record);

  @override
  Future<void> update(ViewSchema view, Record record) async =>
      (await _get()).update(view, record);

  @override
  Future<void> delete(ViewSchema view, Record record) async =>
      (await _get()).delete(view, record);
}
