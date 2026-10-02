import 'package:airledger/services/integrations/whoop_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('whoopOffset', () {
    test('parses signed offsets', () {
      expect(whoopOffset('-07:00'), const Duration(hours: -7));
      expect(whoopOffset('+05:30'), const Duration(hours: 5, minutes: 30));
      expect(whoopOffset('Z'), Duration.zero);
    });
    test('null on absent / malformed', () {
      expect(whoopOffset(null), isNull);
      expect(whoopOffset('pacific'), isNull);
      expect(whoopOffset(7), isNull);
    });
  });

  group('workouts use the local day', () {
    test('evening Pacific session stays on its local day', () {
      // 02:30Z on the 23rd = 19:30 PDT on the 22nd.
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w1',
          'start': '2026-09-23T02:30:00.000Z',
          'end': '2026-09-23T02:55:59.000Z',
          'timezone_offset': '-07:00',
          'sport_name': 'walking',
          'score': {'strain': 5.1},
        },
      ]);
      final r = rows.single;
      expect((r['date'] as Map)['value'], '2026-09-22');
      expect((r['start_time'] as Map)['value'], '2026-09-22T19:30:00');
      expect((r['end_time'] as Map)['value'], '2026-09-22T19:55:59');
    });
    test('no offset → UTC (legacy behaviour)', () {
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w2',
          'start': '2026-09-23T02:30:00.000Z',
          'end': '2026-09-23T02:55:00.000Z',
          'sport_name': 'walking',
          'score': {'strain': 5.1},
        },
      ]);
      expect((rows.single['date'] as Map)['value'], '2026-09-23');
    });
  });

  group('sleep wake day is local', () {
    test('wake shortly before local midnight stays on that local day', () {
      // end 06:30Z on the 2nd = 23:30 PDT on the 1st → wake day is the 1st.
      final recs = whoopSleepToRecovery([
        {
          'id': 's1',
          'nap': false,
          'start': '2026-10-01T23:00:00.000Z',
          'end': '2026-10-02T06:30:00.000Z',
          'timezone_offset': '-07:00',
          'score': {'sleep_performance_percentage': 90},
        },
      ]);
      expect((recs.single['date'] as Map)['value'], '2026-10-01');
    });
  });
}
