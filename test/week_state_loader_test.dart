// WeekStateLoader — the Kaya climbing-tab session cache (30-min TTL).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/ledger_data_version.dart';
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

/// A version-tracked connector (EngineLedgerConnector's contract): its
/// writes bump [LedgerDataVersion], so a WeekState over it can be
/// memoized per data version.
class _VersionedRepo extends _CountingRepo implements DataVersioned {
  _VersionedRepo(super.rows);
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
    WeekStateLoader.clearMemo();
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

  test('strength is read as a bounded window: strengthHistoryDays before '
      'the week onward, not all-time (perf batch 2)', () async {
    if (!hasFitness) return;
    final strengthView = ViewSchema(
      name: 'strength',
      datasource: 'gsheets',
      table: 'strength',
      entities: const [],
      measures: const [],
      dateField: 'date',
      dimensions: [
        for (final d in ['id', 'date', 'exercise'])
          Dimension(name: d, type: DimensionType.string, expr: d),
      ],
    );
    final repo = _CountingRepo([
      {'id': 'old', 'date': '2019-03-01', 'exercise': 'Barbell Squat'},
      {'id': 'recent', 'date': '2026-08-01', 'exercise': 'Barbell Squat'},
      {'id': 'today', 'date': '2026-10-02', 'exercise': 'Barbell Squat'},
    ]);
    final state = await WeekStateLoader(
      loadDocs: ProgramProvider((p) async => read(p)).load,
      strengthView: strengthView,
      strengthRepo: repo,
      now: () => DateTime(2026, 10, 2, 9),
    ).load(DateTime(2026, 10, 2));
    expect(state, isNotNull);
    expect([for (final r in state!.strengthRows!) r['id']],
        ['recent', 'today']);
    expect(state.loggedOnDate, ['Barbell Squat']);
  });

  group('coalescing + memo (perf batch 3, audit #4)', () {
    test('identical CONCURRENT loads share one in-flight load', () async {
      if (!hasFitness) return;
      final strength = _CountingRepo(const []);
      final cardio = _CountingRepo(const []);
      final provider = ProgramProvider((p) async => read(p));
      WeekStateLoader loader() => WeekStateLoader(
            loadDocs: provider.load,
            strengthView: _view('strength'),
            strengthRepo: strength,
            cardioView: _view('cardio'),
            cardioRepo: cardio,
          );
      final day = DateTime(2026, 10, 2);
      final both = await Future.wait([
        loader().load(day, withMissed: true),
        loader().load(day, withMissed: true),
      ]);
      expect(identical(both[0], both[1]), isTrue);
      expect(strength.lists, 1);
      expect(cardio.lists, 1);

      // Unversioned repos (fakes / Sheets) are never memoized once done.
      await loader().load(day, withMissed: true);
      expect(strength.lists, 2);
      // Different shape → its own load.
      await Future.wait([
        loader().load(day),
        loader().load(day, withMissed: true),
      ]);
      expect(strength.lists, 4);
    });

    test('version-tracked sources: the result is memoized per data '
        'version; a ledger bump re-reads', () async {
      if (!hasFitness) return;
      final strength = _VersionedRepo(const []);
      final provider = ProgramProvider((p) async => read(p));
      WeekStateLoader loader() => WeekStateLoader(
            loadDocs: provider.load,
            strengthView: _view('strength'),
            strengthRepo: strength,
          );
      final day = DateTime(2026, 10, 2);
      final a = await loader().load(day, withMissed: true);
      final b = await loader().load(day, withMissed: true);
      expect(identical(a, b), isTrue);
      expect(strength.lists, 1);

      LedgerDataVersion.instance.bump('strength');
      final c = await loader().load(day, withMissed: true);
      expect(identical(a, c), isFalse);
      expect(strength.lists, 2);

      // Another day is another entry.
      await loader().load(DateTime(2026, 10, 3), withMissed: true);
      expect(strength.lists, 3);
    });
  });
}
