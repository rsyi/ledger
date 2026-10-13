// Perf #9 (2026-10-12): the read-only repo connects on FIRST USE — no
// token exchange before first paint; a failed connect retries next call.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/lazy_connector.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';

class _Repo implements WarehouseConnector {
  @override
  final DatabaseConfig config = SheetsConfig(name: 'g', spreadsheetId: 's');
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      [
        {'id': 'x'},
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _view = ViewSchema(
  name: 'climbing',
  datasource: 'gsheets',
  table: 'climbing',
  entities: const [],
  measures: const [],
  dimensions: const [],
);

void main() {
  test('connects once, on first use; failures retry', () async {
    var connects = 0;
    var fail = true;
    final c = LazyConnector(SheetsConfig(name: 'g', spreadsheetId: 's'),
        () async {
      connects++;
      if (fail) throw Exception('offline');
      return _Repo();
    });
    expect(connects, 0, reason: 'nothing at construction');
    await expectLater(c.list(_view), throwsException);
    fail = false;
    expect(await c.list(_view), [
      {'id': 'x'},
    ]);
    await c.list(_view);
    expect(connects, 2);
  });
}
