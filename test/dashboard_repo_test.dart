import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/connector_registry.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';

/// Marker fake — identity is all these tests compare.
class _FakeRepo implements WarehouseConnector {
  final String tag;
  _FakeRepo(this.tag);

  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      const [];
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

ViewSchema _view({required bool readOnly}) => ViewSchema(
      name: 'climbing',
      datasource: 'gsheets',
      table: 'kaya_ascents',
      entities: const [],
      measures: const [],
      dimensions: [
        Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
      ],
      readOnly: readOnly,
    );

void main() {
  group('dashboardRepoFor', () {
    final readOnlyRepo = _FakeRepo('direct-sheet');
    final ledgerRepo = _FakeRepo('engine-ledger');

    test('read-only view resolves to the direct-sheet repo, never the '
        'registry (regression: live climb count read an empty ledger '
        'table instead of kaya_ascents)', () {
      final repo = dashboardRepoFor(
        _view(readOnly: true),
        readOnlyRepo: readOnlyRepo,
        forView: (_) => ledgerRepo,
      );
      expect(identical(repo, readOnlyRepo), isTrue);
    });

    test('entry view resolves through the registry', () {
      final repo = dashboardRepoFor(
        _view(readOnly: false),
        readOnlyRepo: readOnlyRepo,
        forView: (_) => ledgerRepo,
      );
      expect(identical(repo, ledgerRepo), isTrue);
    });

    test('read-only view with no direct repo degrades to null '
        '(strip falls back to the nightly status row)', () {
      final repo = dashboardRepoFor(
        _view(readOnly: true),
        readOnlyRepo: null,
        forView: (_) => ledgerRepo,
      );
      expect(repo, isNull);
    });

    test('null view is null', () {
      expect(
        dashboardRepoFor(
          null,
          readOnlyRepo: readOnlyRepo,
          forView: (_) => ledgerRepo,
        ),
        isNull,
      );
    });
  });
}
