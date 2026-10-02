// WeekStateLoader — the Kaya climbing-tab session cache (30-min TTL).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/week_state_loader.dart';

const _fitness = '../airledger-fitness';

class _CountingRepo implements WarehouseConnector {
  final List<Record> rows;
  int lists = 0;
  _CountingRepo(this.rows);
  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    lists++;
    return rows;
  }

  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {}
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

ViewSchema _view(String name) => ViewSchema(
      name: name,
      datasource: 'gsheets',
      table: name,
      entities: const [],
      measures: const [],
      dimensions: [
        for (final d in ['id', 'date', 'exercise'])
          Dimension(name: d, type: DimensionType.string, expr: d),
      ],
    );

void main() {
  final hasFitness = File('$_fitness/coach/program.yaml').existsSync();
  String? read(String path) {
    final f = File('$_fitness/$path');
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  setUp(() {
    ProgramProvider.clearCache();
    WeekStateLoader.clearKayaCache();
  });

  test('Kaya climbing tab is read once per TTL, re-read after it / a '
      'clear / for another repo', () async {
    if (!hasFitness) return;
    var clock = DateTime(2026, 10, 2, 9);
    final climbing = _CountingRepo([
      {'id': 'c1', 'date': '2026-09-29'},
    ]);
    WeekStateLoader loader(WarehouseConnector repo) => WeekStateLoader(
          loadDocs: ProgramProvider((p) async => read(p)).load,
          strengthView: _view('strength'),
          strengthRepo: _CountingRepo(const []),
          climbingView: _view('climbing'),
          climbingRepo: repo,
          now: () => clock,
        );
    final day = DateTime(2026, 10, 2);

    final a = await loader(climbing).load(day, withMissed: true);
    await loader(climbing).load(day, withMissed: true);
    expect(climbing.lists, 1);
    // The cached climb still credits Tuesday's climb.
    expect(
      a!.missed!.missed.where((m) => m.kind == 'climb'),
      isEmpty,
    );

    clock = clock.add(const Duration(minutes: 31));
    await loader(climbing).load(day, withMissed: true);
    expect(climbing.lists, 2, reason: 'TTL expired');

    WeekStateLoader.clearKayaCache();
    await loader(climbing).load(day, withMissed: true);
    expect(climbing.lists, 3, reason: 'cleared (Kaya import)');

    final other = _CountingRepo(const []);
    await loader(other).load(day, withMissed: true);
    expect(other.lists, 1, reason: 'keyed by repo identity');

    // Without withMissed the climbing tab is never read.
    await loader(climbing).load(day);
    expect(climbing.lists, 3);
  });
}
