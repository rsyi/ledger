// Perf #5 (2026-10-12): the read-only Kaya climbing tab is fetched ONCE
// per 30 min for every caller (Goals, dashboard, Plan data, coach,
// WeekStateLoader) through ReadOnlyRowsCache; ledger views bypass it.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/read_only_rows_cache.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/week_state_loader.dart';

class _Counting implements WarehouseConnector {
  int lists = 0;
  bool fail = false;
  @override
  final DatabaseConfig config = SheetsConfig(name: 'g', spreadsheetId: 's');
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    lists++;
    await Future<void>.delayed(Duration.zero);
    if (fail) throw Exception('offline');
    return [
      {'id': 'c1', 'date': DateTime(2026, 10, 6)},
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ViewSchema _view(String name, {bool readOnly = false}) => ViewSchema(
      name: name,
      datasource: 'gsheets',
      table: name,
      entities: const [],
      measures: const [],
      dimensions: const [],
      readOnly: readOnly,
    );

void main() {
  setUp(ReadOnlyRowsCache.clear);

  test('read-only view: concurrent + repeated callers share one fetch',
      () async {
    final repo = _Counting();
    final climbing = _view('climbing', readOnly: true);
    final r = await Future.wait([
      ReadOnlyRowsCache.listIfReadOnly(climbing, repo),
      ReadOnlyRowsCache.listIfReadOnly(climbing, repo),
    ]);
    await ReadOnlyRowsCache.list(climbing, repo);
    expect(r[0], hasLength(1));
    expect(repo.lists, 1);

    // WeekStateLoader's clear is the same cache (Kaya import bust).
    WeekStateLoader.clearKayaCache();
    await ReadOnlyRowsCache.list(climbing, repo);
    expect(repo.lists, 2);

    // TTL.
    var clock = DateTime.now();
    await ReadOnlyRowsCache.list(climbing, repo, now: () => clock);
    clock = clock.add(const Duration(minutes: 31));
    await ReadOnlyRowsCache.list(climbing, repo, now: () => clock);
    expect(repo.lists, 3);
  });

  test('ledger views bypass the cache; failures are not cached', () async {
    final repo = _Counting();
    final strength = _view('strength');
    await ReadOnlyRowsCache.listIfReadOnly(strength, repo);
    await ReadOnlyRowsCache.listIfReadOnly(strength, repo);
    expect(repo.lists, 2);

    final climbing = _view('climbing', readOnly: true);
    repo.fail = true;
    await expectLater(
        ReadOnlyRowsCache.list(climbing, repo), throwsException);
    repo.fail = false;
    expect(await ReadOnlyRowsCache.list(climbing, repo), hasLength(1));
  });
}
