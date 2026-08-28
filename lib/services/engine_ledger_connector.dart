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
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'engine.dart';
import 'engine_schema_adapter.dart';
import 'sheets_repository.dart' show Record;
import 'sync_scheduler.dart';
import 'warehouse_connector.dart';

class EngineLedgerConnector implements WarehouseConnector {
  @override
  final SheetsConfig config;
  final String defaultSpreadsheetId;
  final EngineLedgerRepository repo;

  EngineLedgerConnector._(this.config, this.defaultSpreadsheetId, this.repo);

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
    return recordFromEngineJson(raw);
  }

  @override
  Future<void> update(ViewSchema view, Record record) async {
    await repo.update(
      viewSchemaToEngineJson(view),
      recordToEngineJson(record),
    );
    SyncScheduler.instance?.onLocalWrite();
  }

  @override
  Future<void> delete(ViewSchema view, Record record) async {
    await repo.delete(
      viewSchemaToEngineJson(view),
      recordToEngineJson(record),
    );
    SyncScheduler.instance?.onLocalWrite();
  }
}
