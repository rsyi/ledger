import 'package:airledger/services/integrations/whoop_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('whoopSleepToRecovery', () {
    test('maps a full night to the richer recovery fields on the wake date',
        () {
      // 8h in bed, 30m awake → 7.5h asleep; ends the morning of the 20th.
      final recs = whoopSleepToRecovery([
        {
          'id': 's1',
          'nap': false,
          'start': '2026-09-19T23:00:00.000Z',
          'end': '2026-09-20T07:00:00.000Z',
          'score': {
            'sleep_performance_percentage': 90,
            'sleep_efficiency_percentage': 94.5,
            'sleep_consistency_percentage': 71,
            'respiratory_rate': 15.2,
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
      // Raw %/scores stored (no 1-5 bucketing).
      expect((r['sleep_performance_pct'] as Map)['value'], 90);
      expect((r['sleep_efficiency_pct'] as Map)['value'], 94.5);
      expect((r['sleep_consistency_pct'] as Map)['value'], 71);
      expect((r['respiratory_rate'] as Map)['value'], 15.2);
      // No 1-5 sleep_quality field anymore.
      expect(r.containsKey('sleep_quality'), isFalse);
    });

    test('missing optional score fields are omitted (omit-don\'t-clear)', () {
      final recs = whoopSleepToRecovery([
        {
          'id': 's1',
          'nap': false,
          'start': '2026-09-19T23:00:00.000Z',
          'end': '2026-09-20T07:00:00.000Z',
          'score': {
            'sleep_performance_percentage': 80,
            'stage_summary': {
              'total_in_bed_time_milli': 7 * 3600 * 1000,
              'total_awake_time_milli': 0,
            },
          },
        },
      ]);
      final r = recs.single;
      expect((r['sleep_performance_pct'] as Map)['value'], 80);
      expect(r.containsKey('sleep_efficiency_pct'), isFalse);
      expect(r.containsKey('sleep_consistency_pct'), isFalse);
      expect(r.containsKey('respiratory_rate'), isFalse);
    });

    test('naps are skipped', () {
      final recs = whoopSleepToRecovery([
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
      final recs = whoopSleepToRecovery([
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
      final recs = whoopSleepToRecovery([
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
      expect((recs.first['sleep_performance_pct'] as Map)['value'], 95);
    });
  });

  group('whoopRecoveryFields', () {
    test('recovery record maps to score/hrv/resting_hr by cycle date', () {
      final map = whoopRecoveryFields([
        {
          'cycle_id': 1,
          'created_at': '2026-09-20T08:00:00.000Z',
          'updated_at': '2026-09-20T08:00:00.000Z',
          'score': {
            'recovery_score': 82,
            'hrv_rmssd_milli': 61.3,
            'resting_heart_rate': 48,
          },
        },
      ]);
      final fields = map['2026-09-20']!;
      expect((fields['recovery_score'] as Map)['value'], 82);
      expect((fields['hrv_ms'] as Map)['value'], 61.3);
      expect((fields['resting_hr'] as Map)['value'], 48);
    });

    test('records without a recovery_score are skipped', () {
      final map = whoopRecoveryFields([
        {
          'cycle_id': 2,
          'created_at': '2026-09-21T08:00:00.000Z',
          'score': {'hrv_rmssd_milli': 50},
        },
      ]);
      expect(map, isEmpty);
    });

    test('later created_at wins a same-day collision', () {
      final map = whoopRecoveryFields([
        {
          'created_at': '2026-09-20T06:00:00.000Z',
          'score': {'recovery_score': 40},
        },
        {
          'created_at': '2026-09-20T09:00:00.000Z',
          'score': {'recovery_score': 70},
        },
      ]);
      expect((map['2026-09-20']!['recovery_score'] as Map)['value'], 70);
    });
  });

  group('merge sleep + recovery', () {
    test('recovery fields are folded into the matching sleep date', () {
      final recs = whoopMergeRecovery(
        sleep: whoopSleepToRecovery([
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
        recovery: whoopRecoveryFields([
          {
            'created_at': '2026-09-20T08:00:00.000Z',
            'score': {
              'recovery_score': 66,
              'hrv_rmssd_milli': 55,
              'resting_heart_rate': 50,
            },
          },
        ]),
      );
      expect(recs, hasLength(1));
      final r = recs.first;
      expect((r['date'] as Map)['value'], '2026-09-20');
      expect((r['sleep_hours'] as Map)['value'], 8.0);
      expect((r['sleep_performance_pct'] as Map)['value'], 70);
      expect((r['recovery_score'] as Map)['value'], 66);
      expect((r['hrv_ms'] as Map)['value'], 55);
      expect((r['resting_hr'] as Map)['value'], 50);
    });

    test('recovery with no matching sleep still produces a row', () {
      final recs = whoopMergeRecovery(
        sleep: const [],
        recovery: {
          '2026-09-22': {
            'recovery_score': {'kind': 'float', 'value': 33.0},
          },
        },
      );
      expect(recs, hasLength(1));
      expect((recs.first['date'] as Map)['value'], '2026-09-22');
      expect((recs.first['recovery_score'] as Map)['value'], 33.0);
      expect(recs.first.containsKey('sleep_hours'), isFalse);
    });
  });
}
