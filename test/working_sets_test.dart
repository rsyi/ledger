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
}
