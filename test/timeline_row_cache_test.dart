// Perf #7 (2026-10-12): the timeline's RowCache (whole-table JSON written
// on every reload / date tap / log) is skipped for the local-first engine
// connector; network-backed connectors keep it.
import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/services/engine_ledger_connector.dart';
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/timeline_screen.dart';

class _FakeEngine implements EngineLedgerRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('engine connector → no RowCache; others keep it', () {
    expect(
        TimelineScreen.usesRowCache(
            EngineLedgerConnector.forTesting(_FakeEngine())),
        isFalse);
    expect(
        TimelineScreen.usesRowCache(UnimplementedConnector(
            SheetsConfig(name: 'g', spreadsheetId: 's'))),
        isTrue);
  });
}
