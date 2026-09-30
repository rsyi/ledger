import 'package:airledger/services/integrations/whoop_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('whoopSleepToNotes', () {
    test('maps a full night to sleep_hours + quality on the wake date', () {
      // 8h in bed, 30m awake → 7.5h asleep; ends the morning of the 20th.
      final recs = whoopSleepToNotes([
        {
          'id': 's1',
          'nap': false,
          'start': '2026-09-19T23:00:00.000Z',
          'end': '2026-09-20T07:00:00.000Z',
          'score': {
            'sleep_performance_percentage': 90,
            'stage_summary': {
              'total_in_bed_time_milli': 8 * 3600 * 1000,
              'total_awake_time_milli': 30 * 60 * 1000,
            },
          },
        },
      ]);
      expect(recs, hasLength(1));
      final r = recs.first;
      expect((r['date'] as Map)['value'], '2026-09-20');
      expect((r['sleep_hours'] as Map)['value'], 7.5);
      // 90% performance → quality 5 (>=90).
      expect((r['sleep_quality'] as Map)['value'], 5);
    });

    test('naps are skipped', () {
      final recs = whoopSleepToNotes([
        {
          'id': 'nap',
          'nap': true,
          'start': '2026-09-20T13:00:00.000Z',
          'end': '2026-09-20T13:45:00.000Z',
          'score': {
            'sleep_performance_percentage': 20,
            'stage_summary': {
              'total_in_bed_time_milli': 45 * 60 * 1000,
              'total_awake_time_milli': 0,
            },
          },
        },
      ]);
      expect(recs, isEmpty);
    });

    test('records without a score are skipped (in-progress / pending)', () {
      final recs = whoopSleepToNotes([
        {
          'id': 's2',
          'nap': false,
          'start': '2026-09-19T23:00:00.000Z',
          'end': '2026-09-20T07:00:00.000Z',
          'score': null,
        },
      ]);
      expect(recs, isEmpty);
    });

    test('one row per wake-date; latest night wins on collision', () {
      final recs = whoopSleepToNotes([
        {
          'id': 'a',
          'nap': false,
          'start': '2026-09-19T22:00:00.000Z',
          'end': '2026-09-20T06:00:00.000Z',
          'score': {
            'sleep_performance_percentage': 50,
            'stage_summary': {
              'total_in_bed_time_milli': 8 * 3600 * 1000,
              'total_awake_time_milli': 0,
            },
          },
        },
        // a second (later end) sleep also waking on the 20th — keep it.
        {
          'id': 'b',
          'nap': false,
          'start': '2026-09-20T07:00:00.000Z',
          'end': '2026-09-20T08:00:00.000Z',
          'score': {
            'sleep_performance_percentage': 95,
            'stage_summary': {
              'total_in_bed_time_milli': 3600 * 1000,
              'total_awake_time_milli': 0,
            },
          },
        },
      ]);
      expect(recs, hasLength(1));
      expect((recs.first['date'] as Map)['value'], '2026-09-20');
      // Latest-ending night wins.
      expect((recs.first['sleep_quality'] as Map)['value'], 5);
    });
  });

  group('whoopRecoveryToReadiness', () {
    test('recovery score maps to readiness 1-5 by cycle date', () {
      final map = whoopRecoveryToReadiness([
        {
          'cycle_id': 1,
          'created_at': '2026-09-20T08:00:00.000Z',
          'updated_at': '2026-09-20T08:00:00.000Z',
          'score': {'recovery_score': 82},
        },
      ]);
      // 82% → readiness 5 (>=80). Keyed by created_at date.
      expect(map['2026-09-20'], 5);
    });

    test('records without a score are skipped', () {
      final map = whoopRecoveryToReadiness([
        {
          'cycle_id': 2,
          'created_at': '2026-09-21T08:00:00.000Z',
          'score': null,
        },
      ]);
      expect(map, isEmpty);
    });
  });

  group('merge sleep + readiness', () {
    test('readiness is folded into the matching sleep date', () {
      final recs = whoopMergeDailyNotes(
        sleep: whoopSleepToNotes([
          {
            'id': 's',
            'nap': false,
            'start': '2026-09-19T23:00:00.000Z',
            'end': '2026-09-20T07:00:00.000Z',
            'score': {
              'sleep_performance_percentage': 70,
              'stage_summary': {
                'total_in_bed_time_milli': 8 * 3600 * 1000,
                'total_awake_time_milli': 0,
              },
            },
          },
        ]),
        readiness: whoopRecoveryToReadiness([
          {
            'cycle_id': 1,
            'created_at': '2026-09-20T08:00:00.000Z',
            'score': {'recovery_score': 40},
          },
        ]),
      );
      expect(recs, hasLength(1));
      final r = recs.first;
      expect((r['date'] as Map)['value'], '2026-09-20');
      expect((r['sleep_hours'] as Map)['value'], 8.0);
      // 40% recovery → readiness 2 (>=40 & <60).
      expect((r['readiness'] as Map)['value'], 2);
    });

    test('readiness with no matching sleep still produces a row', () {
      final recs = whoopMergeDailyNotes(
        sleep: const [],
        readiness: {'2026-09-22': 3},
      );
      expect(recs, hasLength(1));
      expect((recs.first['date'] as Map)['value'], '2026-09-22');
      expect((recs.first['readiness'] as Map)['value'], 3);
      expect(recs.first.containsKey('sleep_hours'), isFalse);
    });
  });
}
