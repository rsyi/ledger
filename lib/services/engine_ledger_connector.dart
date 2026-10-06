/// Local-first [WarehouseConnector]: every CRUD call hits the Rust
/// engine's SQLite store (instant, zero network); a background
/// [SyncScheduler] reconciles with Google Sheets when connectivity
/// and the wifi-only setting allow.
///
/// Mirrors [EngineSheetsConnector]'s shape so the registry and every
/// screen swap over without changes (behind `useLocalFirst` in
/// `engine.dart`).
library;

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'engine.dart';
import 'engine_schema_adapter.dart';
import 'google_auth/sheets_auth.dart';
import 'log_event_bus.dart';
import 'sheets_repository.dart' show Record;
import 'sync_scheduler.dart';
import 'warehouse_connector.dart';

class EngineLedgerConnector implements WarehouseConnector {
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
  /// re-syncs once on an `unauthorized (401)` result.
  Future<List<Map<String, dynamic>>> sync(List<Map<String, dynamic>> views) {
    final t = tokens;
    if (t == null) return repo.sync(views);
    return syncWithTokenRefresh(
      tokens: t,
      setToken: repo.setAccessToken,
      runSync: () => repo.sync(views),
    );
  }

  void close() => repo.close();

  /// Local store needs no table setup, and the *sheet* tab is
  /// ensured during sync — so startup becomes zero-network.
  @override
  Future<void> ensureTable(ViewSchema view) async {}

  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    final raw = await repo.list(
      viewSchemaToEngineJson(view),
      onDate: onDate,
    );
    return raw.map(recordFromEngineJson).toList();
  }

  @override
  Future<Record> create(ViewSchema view, Record record) async {
    final raw = await repo.create(
      viewSchemaToEngineJson(view),
      recordToEngineJson(record),
    );
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
    SyncScheduler.instance?.onLocalWrite();
    // Every delete refreshes the surfaces that show logged work (a
    // program_moves delete — proposal Undo / Schedule rollback — changes
    // the effective week; a deleted set changes the day). Kind `deleted`
    // keeps PostLogNotifier quiet.
    LogEventBus.instance.publish(
        LogEvent(view.name, record, kind: LogEventKind.deleted));
  }
}
