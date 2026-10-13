// Perf batch 3 (2026-10-12): the week planner's bootstrap sync used to
// list the FULL 33k-row strength history (~2 s on device, right after
// Today paints). It now reads a bounded window: plannerHistoryDays
// before today, open-ended after (planned/logged days in the horizon).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/services/week_planner.dart';
import 'package:airledger/services/week_state_loader.dart'
    show strengthHistoryDays;

class _RangeRepo implements WarehouseConnector, RangeListable {
  _RangeRepo(this.rows);
  final List<Record> rows;
  int fullLists = 0;
  final ranges = <({DateTime? from, DateTime? to})>[];
  @override
  final DatabaseConfig config = SheetsConfig(name: 'g', spreadsheetId: 's');
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    fullLists++;
    return rows;
  }

  @override
  Future<List<Record>> listRange(ViewSchema view,
      {DateTime? from, DateTime? to}) async {
    ranges.add((from: from, to: to));
    return filterRecordsToRange(view, rows, from: from, to: to);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _strength = ViewSchema(
  name: 'strength',
  datasource: 'gsheets',
  table: 'strength',
  entities: const [],
  measures: const [],
  dimensions: const [],
  dateField: 'date',
);

void main() {
  test('planner strength read is bounded: plannerHistoryDays back, '
      'open-ended forward — never the full history', () async {
    final repo = _RangeRepo([
      {'date': '2019-01-01', 'exercise': 'Barbell Squat'},
      {'date': '2026-06-01', 'exercise': 'Barbell Squat'},
      {'date': '2026-10-14', 'exercise': 'Barbell Squat'}, // horizon day
    ]);
    final rows = await WeekPlanner.plannerStrengthRows(
        repo, _strength, DateTime(2026, 10, 12, 9));
    expect(repo.fullLists, 0);
    expect(repo.ranges.single.from,
        DateTime(2026, 10, 12 - WeekPlanner.plannerHistoryDays));
    expect(repo.ranges.single.to, isNull);
    expect([for (final r in rows) r['date']], ['2026-06-01', '2026-10-14']);
  });

  test('lookback matches the Today card (WeekState) window, so both '
      'price accessories/references off the same history', () {
    expect(WeekPlanner.plannerHistoryDays, strengthHistoryDays);
    expect(WeekPlanner.plannerHistoryDays, greaterThanOrEqualTo(42));
  });
}
