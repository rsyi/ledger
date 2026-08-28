/// Singleton + feature-flag hub for the airledger-engine Rust binding.
///
/// The engine is loaded lazily on first use — `AirledgerEngine.load()`
/// opens `libairledger_engine.so` from the app's nativeLibraryDir
/// (the .so files come from `~/repos/airledger/sdk-dart/build/jniLibs/`
/// via the gradle `sourceSets.jniLibs.srcDirs` wiring).
///
/// Flip [`useEngine`] off if a regression slips in and you need to
/// fall back to the pure-Dart parsers/repositories while you debug.
library;

import 'package:airledger_engine/airledger_engine.dart';

import 'engine_ledger_connector.dart';
import 'engine_sheets_connector.dart';
import 'sheets_repository.dart';
import 'warehouse_connector.dart';

/// When true, schema parsing AND sheets ingest route through the
/// Rust engine instead of the pure-Dart code in
/// `services/schema_parser.dart`, `services/input_parser.dart`, and
/// `services/sheets_repository.dart`.
///
/// Reverting to false should require no other changes — both paths
/// stay compiled in.
const useEngine = true;

/// When true (and [useEngine] is true), the bundled gsheets-backed
/// connector becomes local-first: reads/writes hit the engine's
/// on-device SQLite store and a background [SyncScheduler] pushes/
/// pulls the Sheet. Flip off to fall back to direct Sheets I/O.
const useLocalFirst = true;

AirledgerEngine? _engine;

/// Lazily load and cache the engine. Subsequent calls return the
/// same instance (the underlying [`DynamicLibrary.open`] is also
/// process-cached but we keep the wrapper around for the bindings).
AirledgerEngine getEngine() => _engine ??= AirledgerEngine.load();

/// Build a sheets-backed [`WarehouseConnector`] — engine-routed when
/// [`useEngine`] is true, pure-Dart [`SheetsRepository`] otherwise.
/// Both shapes satisfy the same interface, so callers can hold the
/// result as `WarehouseConnector` and not care which path produced it.
Future<WarehouseConnector> connectSheetsConnector({
  required String defaultSpreadsheetId,
  required String serviceAccountKeyJson,
}) async {
  if (useEngine && useLocalFirst) {
    return EngineLedgerConnector.connectFromKey(
      defaultSpreadsheetId: defaultSpreadsheetId,
      serviceAccountKeyJson: serviceAccountKeyJson,
    );
  }
  if (useEngine) {
    return EngineSheetsConnector.connectFromKey(
      defaultSpreadsheetId: defaultSpreadsheetId,
      serviceAccountKeyJson: serviceAccountKeyJson,
    );
  }
  return SheetsRepository.connectFromKey(
    defaultSpreadsheetId: defaultSpreadsheetId,
    serviceAccountKeyJson: serviceAccountKeyJson,
  );
}
