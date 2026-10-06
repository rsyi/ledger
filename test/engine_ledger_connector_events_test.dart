// Bug (2026-10-05): after the user cleaned up an accidental log-all by
// deleting/editing rows, the Today program card (and Week goals) kept the
// stale sets — the connector published a LogEvent only for creates (and
// program_moves deletes). Every create / update / delete now publishes,
// with a kind so the post-log "Nice work" notification stays create-only.
import 'package:airledger_engine/airledger_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/engine_ledger_connector.dart';
import 'package:airledger/services/log_event_bus.dart';
import 'package:airledger/services/post_log_notifier.dart';

class _FakeEngine implements EngineLedgerRepository {
  @override
  Future<Map<String, dynamic>> create(
          Map<String, dynamic> viewJson, Map<String, dynamic> recordJson) async =>
      recordJson;
  @override
  Future<void> update(
      Map<String, dynamic> viewJson, Map<String, dynamic> recordJson) async {}
  @override
  Future<void> delete(
      Map<String, dynamic> viewJson, Map<String, dynamic> recordJson) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Dimension _d(String name, DimensionType t) =>
    Dimension(name: name, type: t, expr: name);

final _strength = ViewSchema(
  name: 'strength',
  datasource: 'gsheets',
  table: 'strength',
  entities: const [],
  measures: const [],
  dateField: 'date',
  dimensions: [
    _d('id', DimensionType.string),
    _d('date', DimensionType.date),
    _d('exercise', DimensionType.string),
    _d('weight', DimensionType.number),
    _d('reps', DimensionType.number),
  ],
);

void main() {
  test('create / update / delete each publish, with their kind', () async {
    final events = <LogEvent>[];
    final sub = LogEventBus.instance.stream.listen(events.add);
    addTearDown(sub.cancel);
    final c = EngineLedgerConnector.forTesting(_FakeEngine());
    final row = <String, Object?>{
      'id': 'r1',
      'date': DateTime(2026, 10, 5),
      'exercise': 'Barbell Squat',
      'weight': 235,
      'reps': 6,
    };
    await c.create(_strength, row);
    await c.update(_strength, {...row, 'reps': 5});
    await c.delete(_strength, row);
    await Future<void>.delayed(Duration.zero);
    expect([for (final e in events) e.kind], [
      LogEventKind.created,
      LogEventKind.updated,
      LogEventKind.deleted,
    ]);
    expect([for (final e in events) e.view], everyElement('strength'));
    expect(events[1].record['reps'], 5);
    // Only the create is a "Nice work" notification.
    expect([for (final e in events) PostLogNotifier.notifies(e)],
        [true, false, false]);
  });
}
