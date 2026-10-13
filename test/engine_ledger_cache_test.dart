// Perf batch 2 (2026-10-12): EngineLedgerConnector's per-view snapshot
// cache — coalesced + cached reads keyed on (view, range) × the view's
// LedgerDataVersion; local writes, syncs that changed a view, and
// external bumps (integration ingest) invalidate. Results are
// unmodifiable. listRange goes to the engine's indexed range read.
import 'dart:async';

import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/engine_ledger_connector.dart';
import 'package:airledger/services/ledger_data_version.dart';
import 'package:airledger/services/log_event_bus.dart';
import 'package:airledger/services/warehouse_connector.dart';

class _FakeEngine implements EngineLedgerRepository {
  final rows = <String, List<Map<String, Object?>>>{};
  final calls = <String>[];
  List<Map<String, dynamic>> syncResults = const [];
  Completer<void>? gate;
  bool failNext = false;

  Future<List<Map<String, Object?>>> _read(String what, String view) async {
    calls.add(what);
    if (gate != null) await gate!.future;
    if (failNext) {
      failNext = false;
      throw StateError('engine down');
    }
    return [for (final r in rows[view] ?? const []) Map.of(r)];
  }

  @override
  Future<List<Map<String, Object?>>> listRecords(Map<String, dynamic> viewJson,
          {DateTime? onDate}) =>
      _read('list:${viewJson['name']}${onDate == null ? '' : '@$onDate'}',
          viewJson['name'] as String);

  @override
  Future<List<Map<String, Object?>>> listRecordsRange(
      Map<String, dynamic> viewJson,
      {DateTime? from,
      DateTime? to}) async {
    final view = viewJson['name'] as String;
    final all = await _read('range:$view:$from:$to', view);
    return [
      for (final r in all)
        if (r['date'] case final DateTime d
            when (from == null || !d.isBefore(from)) &&
                (to == null || !d.isAfter(to)))
          r,
    ];
  }

  @override
  Future<Map<String, dynamic>> create(
      Map<String, dynamic> viewJson, Map<String, dynamic> recordJson) async {
    final rec = recordFromEngineJson(recordJson);
    (rows[viewJson['name'] as String] ??= []).add(rec);
    return recordJson;
  }

  @override
  Future<void> update(
      Map<String, dynamic> viewJson, Map<String, dynamic> recordJson) async {}

  @override
  Future<void> delete(
      Map<String, dynamic> viewJson, Map<String, dynamic> recordJson) async {
    rows[viewJson['name'] as String]?.clear();
  }

  @override
  Future<List<Map<String, dynamic>>> sync(
          List<Map<String, dynamic>> views) async =>
      syncResults;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Dimension _d(String name, DimensionType t) =>
    Dimension(name: name, type: t, expr: name);

ViewSchema _view(String name) => ViewSchema(
      name: name,
      datasource: 'gsheets',
      table: name,
      entities: const [],
      measures: const [],
      dateField: 'date',
      dimensions: [
        _d('id', DimensionType.string),
        _d('date', DimensionType.date),
        _d('reps', DimensionType.number),
      ],
    );

void main() {
  late _FakeEngine engine;
  late EngineLedgerConnector c;
  final strength = _view('strength');
  final weight = _view('weight');

  setUp(() {
    engine = _FakeEngine();
    engine.rows['strength'] = [
      {'id': 'a', 'date': DateTime(2026, 10, 1), 'reps': 5},
      {'id': 'b', 'date': DateTime(2026, 10, 8), 'reps': 3},
    ];
    engine.rows['weight'] = [
      {'id': 'w', 'date': DateTime(2026, 10, 8), 'reps': 0},
    ];
    c = EngineLedgerConnector.forTesting(engine);
  });

  test('concurrent identical reads share one engine call', () async {
    engine.gate = Completer<void>();
    final f1 = c.list(strength);
    final f2 = c.list(strength);
    engine.gate!.complete();
    final r1 = await f1;
    final r2 = await f2;
    expect(engine.calls, ['list:strength']);
    expect(identical(r1, r2), isTrue);
    expect(r1, hasLength(2));
  });

  test('repeat reads hit the cache until the view changes', () async {
    await c.list(strength);
    await c.list(strength);
    expect(engine.calls, hasLength(1));
    await c.create(strength, {'id': 'c', 'date': DateTime(2026, 10, 9)});
    final fresh = await c.list(strength);
    expect(fresh, hasLength(3), reason: 'write bumps → fresh read');
    expect(engine.calls, hasLength(2));
  });

  test('a write is visible to bus listeners that re-read', () async {
    await c.list(strength); // warm
    final seen = Completer<int>();
    final sub = LogEventBus.instance.stream.listen((_) async {
      if (!seen.isCompleted) seen.complete((await c.list(strength)).length);
    });
    addTearDown(sub.cancel);
    await c.create(strength, {'id': 'c', 'date': DateTime(2026, 10, 9)});
    expect(await seen.future, 3);
  });

  test('writes invalidate only their own view', () async {
    await c.list(strength);
    await c.list(weight);
    await c.delete(weight, {'id': 'w'});
    await c.list(strength);
    await c.list(weight);
    expect(engine.calls, ['list:strength', 'list:weight', 'list:weight']);
  });

  test('sync that changed a view invalidates it; a no-op sync does not',
      () async {
    await c.list(strength);
    await c.list(weight);
    engine.syncResults = [
      {'view': 'strength', 'pulled': 0, 'pushed': 0, 'deleted_local': 0,
        'deleted_remote': 0, 'conflicts': 0, 'error': null},
      {'view': 'weight', 'pulled': 0, 'pushed': 0, 'deleted_local': 0,
        'deleted_remote': 0, 'conflicts': 0, 'error': null},
    ];
    await c.sync(const []);
    await c.list(strength);
    await c.list(weight);
    expect(engine.calls, hasLength(2), reason: 'nothing changed → cached');

    engine.rows['strength']!.add({'id': 'p', 'date': DateTime(2026, 10, 10)});
    engine.syncResults = [
      {'view': 'strength', 'pulled': 1, 'pushed': 0, 'deleted_local': 0,
        'deleted_remote': 0, 'conflicts': 0, 'error': null},
      {'view': 'weight', 'pulled': 0, 'pushed': 0, 'deleted_local': 0,
        'deleted_remote': 0, 'conflicts': 0, 'error': null},
    ];
    await c.sync(const []);
    expect(await c.list(strength), hasLength(3), reason: 'pull → fresh');
    await c.list(weight);
    expect(engine.calls, ['list:strength', 'list:weight', 'list:strength']);
  });

  test('a sync error invalidates the view (commits may have landed)',
      () async {
    await c.list(strength);
    engine.syncResults = [
      {'view': 'strength', 'pulled': 0, 'pushed': 0, 'deleted_local': 0,
        'deleted_remote': 0, 'conflicts': 0, 'error': 'push insert: 500'},
    ];
    await c.sync(const []);
    await c.list(strength);
    expect(engine.calls, hasLength(2));
  });

  test('external bump (integration ingest) forces a re-read', () async {
    await c.list(weight);
    LedgerDataVersion.instance.bump('weight');
    await c.list(weight);
    expect(engine.calls, hasLength(2));
  });

  test('listRange: engine range read, cached per window', () async {
    final r = await c.listRange(strength,
        from: DateTime(2026, 10, 5), to: DateTime(2026, 10, 11));
    expect([for (final x in r) x['id']], ['b']);
    await c.listRange(strength,
        from: DateTime(2026, 10, 5), to: DateTime(2026, 10, 11, 18));
    expect(engine.calls, hasLength(1), reason: 'same calendar window');
    await c.listRange(strength, from: DateTime(2026, 9, 1));
    expect(engine.calls, hasLength(2));
    expect(engine.calls.every((x) => x.startsWith('range:')), isTrue);
    // Unbounded = the cached full list.
    await c.listRange(strength);
    expect(engine.calls.last, 'list:strength');
  });

  test('extension dispatch reaches the engine range read', () async {
    final WarehouseConnector w = c;
    await w.listRange(strength, from: DateTime(2026, 10, 5));
    expect(engine.calls.single, startsWith('range:strength'));
  });

  test('results are unmodifiable (lists and records)', () async {
    final rows = await c.list(strength);
    expect(() => rows.add(const {}), throwsUnsupportedError);
    expect(() => rows.first['reps'] = 9, throwsUnsupportedError);
    final ranged = await c.listRange(strength, from: DateTime(2026, 10, 1));
    expect(() => ranged.removeLast(), throwsUnsupportedError);
  });

  test('a failed read is not cached', () async {
    engine.failNext = true;
    await expectLater(c.list(strength), throwsStateError);
    expect(await c.list(strength), hasLength(2));
    expect(engine.calls, hasLength(2));
  });
}
