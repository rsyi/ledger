/// Local-first [WarehouseConnector]: every CRUD call hits the Rust
/// engine's SQLite store (instant, zero network); a background
/// [SyncScheduler] reconciles with Google Sheets when connectivity
/// and the wifi-only setting allow.
///
/// Mirrors [EngineSheetsConnector]'s shape so the registry and every
/// screen swap over without changes (behind `useLocalFirst` in
/// `engine.dart`).
library;

import 'dart:async';
import 'dart:collection' show UnmodifiableMapView;

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'engine.dart';
import 'engine_schema_adapter.dart';
import 'google_auth/sheets_auth.dart';
import 'ledger_data_version.dart';
import 'log_event_bus.dart';
import 'perf.dart';
import 'sheets_repository.dart' show Record;
import 'sync_scheduler.dart';
import 'warehouse_connector.dart';

class EngineLedgerConnector
    implements WarehouseConnector, RangeListable, DataVersioned {
  @override
  final SheetsConfig config;
  final String defaultSpreadsheetId;
  final EngineLedgerRepository repo;

  /// Bearer mode (multi-user, no baked key): the user's Google token
  /// source, pushed into the engine before every sync. Null = service
  /// account (owner build).
  final AccessTokenSource? tokens;

  EngineLedgerConnector._(this.config, this.defaultSpreadsheetId, this.repo,
      [this.tokens]);

  /// Test seam: wraps a fake engine [repo] (no dylib, no sheets).
  @visibleForTesting
  EngineLedgerConnector.forTesting(this.repo)
      : config = SheetsConfig(name: 'gsheets', spreadsheetId: 'test'),
        defaultSpreadsheetId = 'test',
        tokens = null;

  /// Open (creating if needed) the on-device ledger DB and prepare
  /// the sync-side sheets credentials. Works fully offline — the
  /// credentials are parsed, not exercised, until a sync runs.
  static Future<EngineLedgerConnector> connectFromKey({
    required String defaultSpreadsheetId,
    required String serviceAccountKeyJson,
    SheetsConfig? config,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final repo = getEngine().openLedger(
      dbPath: p.join(dir.path, 'engine_ledger.db'),
      defaultSpreadsheetId: defaultSpreadsheetId,
      serviceAccountJson: serviceAccountKeyJson,
    );
    return EngineLedgerConnector._(
      config ??
          SheetsConfig(name: 'gsheets', spreadsheetId: defaultSpreadsheetId),
      defaultSpreadsheetId,
      repo,
    );
  }

  /// Bearer-mode twin of [connectFromKey]: the engine authenticates with
  /// the user's Google access token (pushed in by [sync]). The DB file is
  /// PER SPREADSHEET — switching spreadsheets must never push one
  /// sheet's local rows (and row bookkeeping) into another.
  static Future<EngineLedgerConnector> connectBearer({
    required String defaultSpreadsheetId,
    required AccessTokenSource tokens,
    SheetsConfig? config,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final repo = getEngine().openLedgerBearer(
      dbPath: p.join(dir.path, bearerDbFileName(defaultSpreadsheetId)),
      defaultSpreadsheetId: defaultSpreadsheetId,
      accessToken: '',
    );
    return EngineLedgerConnector._(
      config ??
          SheetsConfig(name: 'gsheets', spreadsheetId: defaultSpreadsheetId),
      defaultSpreadsheetId,
      repo,
      tokens,
    );
  }

  /// Local DB file for a bearer-mode ledger (the owner's stays
  /// `engine_ledger.db`).
  static String bearerDbFileName(String spreadsheetId) =>
      'engine_ledger_${spreadsheetId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.db';

  /// Full sync. Bearer mode pushes a fresh token first and refreshes +
  /// re-syncs once on an `unauthorized (401)` result. Every view whose
  /// result reports a change (pulled / pushed / deleted / conflicts) or an
  /// error (phase-B commits may still have landed) gets its
  /// [LedgerDataVersion] bumped, so cached reads of it refresh.
  Future<List<Map<String, dynamic>>> sync(
      List<Map<String, dynamic>> views) async {
    final t = tokens;
    final results = await Perf.span(
      'engine.sync',
      () => t == null
          ? repo.sync(views)
          : syncWithTokenRefresh(
              tokens: t,
              setToken: repo.setAccessToken,
              runSync: () => repo.sync(views),
            ),
      meta: {'views': views.length},
    );
    for (final r in results) {
      if (syncResultChanged(r)) {
        LedgerDataVersion.instance.bump(r['view']?.toString());
      }
    }
    return results;
  }

  /// Whether one per-view sync result may have changed local rows.
  @visibleForTesting
  static bool syncResultChanged(Map<String, dynamic> r) {
    if (r['error'] != null) return true;
    for (final k in const [
      'pulled',
      'pushed',
      'deleted_local',
      'deleted_remote',
      'conflicts',
    ]) {
      final v = r[k];
      if (v is num && v != 0) return true;
    }
    return false;
  }

  // ------------------------------------------------ snapshot cache
  //
  // Perf batch 2 (on-device: strength = 33.5k rows, 1.2–3 s per full
  // list, listed 6+ times during startup/Today/Week). Every read is cached
  // per (view, date_field, read shape) and tagged with the view's
  // LedgerDataVersion; a bump (local write, sync change, ingest) makes the
  // next read go back to the engine. Identical in-flight reads share one
  // future. Results are UNMODIFIABLE (list + record maps) because they
  // are shared — copy before mutating. Failed reads are never cached.

  static const _maxEntries = 64;
  final _cache = <String, _Snapshot>{};

  /// Drops every cached read (tests; a DB swap).
  void clearCache() => _cache.clear();

  Future<List<Record>> _cached(
    ViewSchema view,
    String shape,
    Future<List<Map<String, Object?>>> Function() fetch,
    Map<String, Object?> meta,
  ) {
    final version = LedgerDataVersion.instance.of(view.name);
    final key = '${view.name}|${view.dateField ?? ''}|$shape';
    final hit = _cache.remove(key);
    if (hit != null && hit.version == version) {
      _cache[key] = hit; // most recently used
      Perf.count('engine.list.hit', meta: meta);
      return hit.rows;
    }
    final rows = Perf.span(
      'engine.list',
      () async => _freeze(await fetch()),
      meta: meta,
      metaOf: (rows) => {'rows': rows.length},
    );
    final snap = _Snapshot(version, rows);
    _cache[key] = snap;
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    rows.then<void>((_) {}, onError: (Object _) {
      if (identical(_cache[key], snap)) _cache.remove(key);
    });
    return rows;
  }

  static List<Record> _freeze(List<Map<String, Object?>> rows) =>
      List<Record>.unmodifiable(
          [for (final r in rows) UnmodifiableMapView<String, Object?>(r)]);

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  void close() => repo.close();

  /// Local store needs no table setup, and the *sheet* tab is
  /// ensured during sync — so startup becomes zero-network.
  @override
  Future<void> ensureTable(ViewSchema view) async {}

  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) {
    // listRecords converts tagged → native INSIDE the worker isolate
    // (perf #3) — the UI isolate gets ready records. Cached (see above).
    return _cached(
      view,
      onDate == null ? 'all' : 'day:${_iso(onDate)}',
      () => repo.listRecords(viewSchemaToEngineJson(view), onDate: onDate),
      {'view': view.name, if (onDate != null) 'onDate': true},
    );
  }

  /// Date-window read through the engine's indexed `date_key` (only the
  /// window's rows are parsed, serialized and converted). Calendar-date
  /// bounds, inclusive; no bounds = the (cached) full [list].
  @override
  Future<List<Record>> listRange(ViewSchema view,
      {DateTime? from, DateTime? to}) {
    if (from == null && to == null) return list(view);
    return _cached(
      view,
      'range:${from == null ? '' : _iso(from)}..${to == null ? '' : _iso(to)}',
      () => repo.listRecordsRange(viewSchemaToEngineJson(view),
          from: from, to: to),
      {'view': view.name, 'range': true},
    );
  }

  @override
  Future<Record> create(ViewSchema view, Record record) async {
    final raw = await Perf.span(
      'engine.create',
      () => repo.create(
        viewSchemaToEngineJson(view),
        recordToEngineJson(record),
      ),
      meta: {'view': view.name},
    );
    LedgerDataVersion.instance.bump(view.name);
    SyncScheduler.instance?.onLocalWrite();
    final created = recordFromEngineJson(raw);
    // Fire-and-forget: post-log features (notifications, the day
    // synthesis refresh) listen on the bus rather than editing the form.
    LogEventBus.instance.publish(LogEvent(view.name, created));
    return created;
  }

  @override
  Future<void> update(ViewSchema view, Record record) async {
    await repo.update(
      viewSchemaToEngineJson(view),
      recordToEngineJson(record),
    );
    LedgerDataVersion.instance.bump(view.name);
    SyncScheduler.instance?.onLocalWrite();
    // An edit changes what the day achieved: refresh the program card,
    // Week goals, synthesis (no post-log notification — kind filters).
    LogEventBus.instance.publish(
        LogEvent(view.name, record, kind: LogEventKind.updated));
  }

  @override
  Future<void> delete(ViewSchema view, Record record) async {
    await repo.delete(
      viewSchemaToEngineJson(view),
      recordToEngineJson(record),
    );
    LedgerDataVersion.instance.bump(view.name);
    SyncScheduler.instance?.onLocalWrite();
    // Every delete refreshes the surfaces that show logged work (a
    // program_moves delete — proposal Undo / Schedule rollback — changes
    // the effective week; a deleted set changes the day). Kind `deleted`
    // keeps PostLogNotifier quiet.
    LogEventBus.instance.publish(
        LogEvent(view.name, record, kind: LogEventKind.deleted));
  }
}

class _Snapshot {
  _Snapshot(this.version, this.rows);
  final int version;
  final Future<List<Record>> rows;
}
