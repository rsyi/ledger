import 'package:airledger/services/integrations/withings.dart';
import 'package:flutter_test/flutter_test.dart';

int epochOf(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void main() {
  test('kg converts to lbs at 1dp, fat passes through, earliest of day wins',
      () {
    final grps = [
      {
        'grpid': 2,
        'date': epochOf(DateTime(2026, 8, 28, 18, 5)), // later weigh-in
        'measures': [
          {'value': 83000, 'unit': -3, 'type': 1},
        ],
      },
      {
        'grpid': 1,
        'date': epochOf(DateTime(2026, 8, 28, 7, 31)), // earliest
        'measures': [
          {'value': 82045, 'unit': -3, 'type': 1}, // 82.045 kg
          {'value': 182, 'unit': -1, 'type': 6}, // 18.2 %
        ],
      },
    ];
    final recs = withingsGroupsToRecords(grps);
    expect(recs, hasLength(1), reason: 'one record per day');
    final r = recs.first;
    // 82.045 kg * 2.20462 = 180.88… → 180.9
    expect(r['weight_lbs'], {'kind': 'float', 'value': 180.9});
    expect(r['body_fat_withing'], {'kind': 'float', 'value': 18.2});
    expect(r['date'], {'kind': 'date', 'value': '2026-08-28'});
    expect(r['time'], {'kind': 'string', 'value': '07:31'});
  });

  test('groups without weight or fat measures are dropped', () {
    final grps = [
      {
        'grpid': 1,
        'date': epochOf(DateTime(2026, 8, 27, 9, 0)),
        'measures': [
          {'value': 60, 'unit': 0, 'type': 11}, // heart rate — ignored
        ],
      },
    ];
    expect(withingsGroupsToRecords(grps), isEmpty);
  });

  test('records come out date-sorted across days', () {
    final grps = [
      {
        'grpid': 1,
        'date': epochOf(DateTime(2026, 8, 28, 8, 0)),
        'measures': [
          {'value': 82000, 'unit': -3, 'type': 1},
        ],
      },
      {
        'grpid': 2,
        'date': epochOf(DateTime(2026, 8, 26, 8, 0)),
        'measures': [
          {'value': 81000, 'unit': -3, 'type': 1},
        ],
      },
    ];
    final recs = withingsGroupsToRecords(grps);
    expect(recs, hasLength(2));
    expect((recs[0]['date'] as Map)['value'], '2026-08-26');
    expect((recs[1]['date'] as Map)['value'], '2026-08-28');
  });

  test('deletion set = provenance days minus current days, sorted', () {
    final deleted = withingsDeletedDates(
      windowDaysWithData: {'2026-08-28'},
      provenanceDays: {'2026-08-28', '2026-08-20', '2026-08-01'},
    );
    expect(deleted, ['2026-08-01', '2026-08-20']);
  });
}
