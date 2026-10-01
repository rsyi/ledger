import 'package:airledger/services/integrations/whoop_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('whoopWorkoutsToRows', () {
    test('maps a full workout to objective ingest fields', () {
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w-abc',
          'start': '2026-09-20T17:00:00.000Z',
          'end': '2026-09-20T18:00:00.000Z',
          'sport_id': 45, // weightlifting
          'score': {
            'strain': 14.236,
            'average_heart_rate': 128,
            'max_heart_rate': 171,
            'kilojoule': 2500.0, // → 597.5 kcal
          },
        },
      ]);
      expect(rows, hasLength(1));
      final r = rows.single;
      expect((r['workout_id'] as Map)['value'], 'w-abc');
      expect((r['date'] as Map)['value'], '2026-09-20');
      // start/end carried as datetime strings (seconds precision). The
      // engine serde tag is `date_time` (NOT `datetime`).
      expect((r['start_time'] as Map)['kind'], 'date_time');
      expect((r['start_time'] as Map)['value'], '2026-09-20T17:00:00');
      expect((r['end_time'] as Map)['value'], '2026-09-20T18:00:00');
      expect((r['sport'] as Map)['value'], 'weightlifting');
      // strain rounded to 1dp.
      expect((r['strain'] as Map)['value'], 14.2);
      expect((r['avg_hr'] as Map)['value'], 128);
      expect((r['max_hr'] as Map)['value'], 171);
      // kcal = kj / 4.184, 1dp: 2500 / 4.184 = 597.5.
      expect((r['kcal'] as Map)['value'], 597.5);
      // duration 60 min exactly.
      expect((r['duration_min'] as Map)['value'], 60.0);
    });

    test('prefers sport_name over sport_id when present', () {
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w1',
          'start': '2026-09-20T06:00:00.000Z',
          'end': '2026-09-20T06:30:00.000Z',
          'sport_name': 'trail running',
          'sport_id': 1,
          'score': {'strain': 8.0},
        },
      ]);
      expect((rows.single['sport'] as Map)['value'], 'trail running');
    });

    test('unknown sport_id falls back to the raw id string', () {
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w1',
          'start': '2026-09-20T06:00:00.000Z',
          'end': '2026-09-20T06:30:00.000Z',
          'sport_id': 99999,
          'score': {'strain': 8.0},
        },
      ]);
      expect((rows.single['sport'] as Map)['value'], '99999');
    });

    test('maps common sport ids', () {
      String sportOf(int id) {
        final rows = whoopWorkoutsToRows([
          {
            'id': 'w$id',
            'start': '2026-09-20T06:00:00.000Z',
            'end': '2026-09-20T06:30:00.000Z',
            'sport_id': id,
            'score': {'strain': 1.0},
          },
        ]);
        return (rows.single['sport'] as Map)['value'] as String;
      }

      expect(sportOf(0), 'running');
      expect(sportOf(1), 'cycling');
      expect(sportOf(45), 'weightlifting');
      expect(sportOf(-1), 'activity'); // generic -1
    });

    test('score-less (in-progress) workouts are skipped', () {
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w1',
          'start': '2026-09-20T06:00:00.000Z',
          'end': '2026-09-20T06:30:00.000Z',
          'sport_id': 0,
          // no score → pending
        },
      ]);
      expect(rows, isEmpty);
    });

    test('omit-dont-clear: absent objective fields are omitted', () {
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w1',
          'start': '2026-09-20T06:00:00.000Z',
          'end': '2026-09-20T06:30:00.000Z',
          'sport_id': 0,
          'score': {'strain': 9.1}, // no hr / kilojoule
        },
      ]);
      final r = rows.single;
      expect((r['strain'] as Map)['value'], 9.1);
      expect(r.containsKey('avg_hr'), isFalse);
      expect(r.containsKey('max_hr'), isFalse);
      expect(r.containsKey('kcal'), isFalse);
      // duration still derivable from start/end.
      expect((r['duration_min'] as Map)['value'], 30.0);
    });

    test('multiple workouts on one day each produce a row (row-grained)', () {
      final rows = whoopWorkoutsToRows([
        {
          'id': 'w-morning',
          'start': '2026-09-20T06:00:00.000Z',
          'end': '2026-09-20T06:30:00.000Z',
          'sport_id': 0,
          'score': {'strain': 6.0},
        },
        {
          'id': 'w-evening',
          'start': '2026-09-20T17:00:00.000Z',
          'end': '2026-09-20T18:30:00.000Z',
          'sport_id': 45,
          'score': {'strain': 13.0},
        },
      ]);
      expect(rows, hasLength(2));
      expect(rows.map((r) => (r['workout_id'] as Map)['value']),
          containsAll(['w-morning', 'w-evening']));
      // Sorted by start_time ascending.
      expect((rows.first['workout_id'] as Map)['value'], 'w-morning');
    });

    test('skips records with no id, no start, or no end', () {
      final rows = whoopWorkoutsToRows([
        {'start': '2026-09-20T06:00:00.000Z', 'end': '2026-09-20T06:30:00.000Z', 'score': {'strain': 1}},
        {'id': 'w1', 'end': '2026-09-20T06:30:00.000Z', 'score': {'strain': 1}},
        {'id': 'w2', 'start': '2026-09-20T06:00:00.000Z', 'score': {'strain': 1}},
      ]);
      expect(rows, isEmpty);
    });

    test('duplicate workout id keeps the first (ingest is idempotent)', () {
      final rows = whoopWorkoutsToRows([
        {'id': 'w1', 'start': '2026-09-20T06:00:00.000Z', 'end': '2026-09-20T06:30:00.000Z', 'score': {'strain': 6.0}},
        {'id': 'w1', 'start': '2026-09-20T06:00:00.000Z', 'end': '2026-09-20T06:30:00.000Z', 'score': {'strain': 9.0}},
      ]);
      expect(rows, hasLength(1));
      expect((rows.single['strain'] as Map)['value'], 6.0);
    });
  });
}
