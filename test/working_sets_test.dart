// working_sets.dart — warm-up exclusion before sets credit prescribed items.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/working_sets.dart';

void main() {
  group('isWarmupSet', () {
    test('tagged warmup is always a warm-up; other tags never', () {
      expect(isWarmupSet(setType: 'warmup', weight: 225, dayTopWeight: 225),
          isTrue);
      for (final t in ['heavy', 'hypertrophy', 'skill', 'rehab']) {
        expect(isWarmupSet(setType: t, weight: 95, dayTopWeight: 225),
            isFalse, reason: t);
      }
    });

    test('untagged: light (< 75% of the day top) AND easy (rpe null/<6)', () {
      expect(isWarmupSet(weight: 135, dayTopWeight: 225), isTrue);
      expect(isWarmupSet(weight: 135, rpe: 5, dayTopWeight: 225), isTrue);
      // Light but hard → a real (back-off/AMRAP) set.
      expect(isWarmupSet(weight: 135, rpe: 8, dayTopWeight: 225), isFalse);
      // >= 75% → working regardless of rpe.
      expect(isWarmupSet(weight: 170, dayTopWeight: 225), isFalse);
      expect(isWarmupSet(weight: 225, dayTopWeight: 225), isFalse);
    });

    test('bodyweight / no-weight rows are never warm-ups by weight', () {
      expect(isWarmupSet(weight: null, dayTopWeight: null), isFalse);
      expect(isWarmupSet(weight: 0, rpe: 4, dayTopWeight: 0), isFalse);
      expect(isWarmupSet(weight: 0, dayTopWeight: 25), isFalse);
    });
  });

  group('workingSetRecords', () {
    test('live Mon bench: 3 untagged ramp sets + 2 working → 2 remain', () {
      final rows = [
        for (final w in [95, 135, 155])
          {'date': '2026-09-28', 'exercise': 'Bench Press', 'weight': w},
        {'date': '2026-09-28', 'exercise': 'Bench Press', 'weight': 225,
            'rpe': 8},
        {'date': '2026-09-28', 'exercise': 'Bench Press', 'weight': '225'},
        // Same weights on ANOTHER day's group: its own top decides.
        {'date': '2026-09-30', 'exercise': 'Bench Press', 'weight': '155'},
        // Bodyweight + tagged rows.
        {'date': '2026-09-28', 'exercise': 'Pull-up'},
        {'date': '2026-09-28', 'exercise': 'Squat', 'weight': 315,
            'set_type': 'warmup'},
      ];
      final out = workingSetRecords(rows);
      expect([for (final r in out) '${r['exercise']}@${r['weight']}'], [
        'Bench Press@225',
        'Bench Press@225',
        'Bench Press@155',
        'Pull-up@null',
      ]);
    });

    test('REAL Mon 9/28 bench: 175@8, 175@7 + unrated 155/135/95 → only '
        'the two rated sets work', () {
      // 155 and 135 are >= 75% of 175, but lighter than every RPE-rated
      // set that day: an unrated lighter set is a ramp.
      final out = workingSetRecords([
        for (final (w, rpe) in [(175, 8), (175, 7), (155, null), (135, null),
            (95, null)])
          {'date': '2026-09-28', 'exercise': 'Flat Barbell Bench Press',
              'weight': '$w', 'rpe': rpe == null ? null : '$rpe'},
      ]);
      expect([for (final r in out) r['weight']], ['175', '175']);
    });

    test('unrated sets at/above the lightest rated set still work (squat '
        'back-offs without RPE)', () {
      final out = workingSetRecords([
        {'date': '2026-09-28', 'exercise': 'Squat', 'weight': 305, 'rpe': 9},
        {'date': '2026-09-28', 'exercise': 'Squat', 'weight': 255, 'rpe': 8},
        {'date': '2026-09-28', 'exercise': 'Squat', 'weight': 285},
        {'date': '2026-09-28', 'exercise': 'Squat', 'weight': 255},
        {'date': '2026-09-28', 'exercise': 'Squat', 'weight': 225},
      ]);
      expect([for (final r in out) r['weight']], [305, 255, 285, 255]);
    });

    test('DateTime dates + case-insensitive exercise grouping', () {
      final d = DateTime(2026, 9, 28, 18);
      final out = workingSetRecords([
        {'date': d, 'exercise': 'bench press', 'weight': 95.0},
        {'date': DateTime(2026, 9, 28), 'exercise': 'Bench Press',
            'weight': 225.0},
      ]);
      expect(out, hasLength(1));
    });
  });

  group('warmupIndices (timeline best-set + history day-max)', () {
    test('indexes the same sets workingSetRecords drops; nulls skipped', () {
      final rows = <Map<String, Object?>?>[
        {'date': '2026-09-28', 'exercise': 'Bench Press', 'weight': 95},
        null, // e.g. a batch tile with no single row
        {'date': '2026-09-28', 'exercise': 'Bench Press', 'weight': 225,
            'rpe': 8},
        {'date': '2026-09-28', 'exercise': 'Bench Press', 'weight': 135,
            'set_type': 'warmup', 'reps': 1},
        {'date': '2026-09-28', 'exercise': 'Pull-up'},
        {'date': '2026-09-28', 'exercise': 'Squat', 'weight': 100,
            'set_type': 'heavy'},
      ];
      expect(warmupIndices(rows), {0, 3});
      final kept = workingSetRecords([for (final r in rows) ?r]);
      expect(kept, hasLength(3));
    });

    test('a tagged warm-up never sets the ramp baseline', () {
      // A (mis)tagged 315 warm-up must not make the unrated 225 a ramp.
      expect(
        warmupIndices([
          {'date': '2026-09-28', 'exercise': 'Squat', 'weight': 225},
          {'date': '2026-09-28', 'exercise': 'Squat', 'weight': 315,
              'set_type': 'warmup'},
        ]),
        {1},
      );
    });
  });
}
