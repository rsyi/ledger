// WarehouseRangeList.listRange on a connector WITHOUT a native range
// read: list + filterRecordsToRange, with the engine's semantics
// (calendar-date inclusive bounds, dateless rows excluded when bounded,
// no date_field → everything, order preserved).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';

class _Repo implements WarehouseConnector {
  _Repo(this.rows);
  final List<Record> rows;
  @override
  DatabaseConfig get config =>
      SheetsConfig(name: 'gsheets', spreadsheetId: 't');
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async => rows;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ViewSchema _view({String? dateField}) => ViewSchema(
      name: 'v',
      datasource: 'gsheets',
      table: 'v',
      entities: const [],
      measures: const [],
      dateField: dateField,
      dimensions: [Dimension(name: 'date', type: DimensionType.date, expr: 'date')],
    );

void main() {
  final rows = <Record>[
    {'id': 1, 'date': DateTime(2026, 10, 4, 23, 30)},
    {'id': 2, 'date': '2026-10-05'},
    {'id': 3, 'date': DateTime(2026, 10, 11)},
    {'id': 4},
    {'id': 5, 'date': DateTime(2026, 10, 12)},
  ];

  test('bounded window: inclusive calendar days, order kept', () async {
    final got = await _Repo(rows).listRange(_view(dateField: 'date'),
        from: DateTime(2026, 10, 4, 12), to: DateTime(2026, 10, 11));
    expect([for (final r in got) r['id']], [1, 2, 3]);
  });

  test('open-ended bounds', () async {
    final repo = _Repo(rows);
    final v = _view(dateField: 'date');
    expect([for (final r in await repo.listRange(v, from: DateTime(2026, 10, 11))) r['id']],
        [3, 5]);
    expect([for (final r in await repo.listRange(v, to: DateTime(2026, 10, 4))) r['id']],
        [1]);
    expect(await repo.listRange(v), hasLength(5));
  });

  test('no date_field → every row', () async {
    final got = await _Repo(rows)
        .listRange(_view(), from: DateTime(2030), to: DateTime(2031));
    expect(got, hasLength(5));
  });
}
