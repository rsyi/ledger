import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/day_inputs.dart';

void main() {
  group('summarizeDayInputs', () {
    test('populates AM/PM prose and block note; not a rest day', () {
      final s = summarizeDayInputs(
        label: 'Today',
        weekday: 'Mon',
        template: {
          'morning': 'Squat top single @ RPE 8; BSS 3x8',
          'afternoon': 'Light climb',
          'block_note': 'Wave week 3 (heavy)',
        },
      );
      expect(s.isRest, isFalse);
      expect(s.morning, 'Squat top single @ RPE 8; BSS 3x8');
      expect(s.afternoon, 'Light climb');
      expect(s.blockNote, 'Wave week 3 (heavy)');
      expect(s.label, 'Today');
      expect(s.weekday, 'Mon');
    });

    test('whitespace-only prose counts as absent → rest day', () {
      final s = summarizeDayInputs(
        label: 'Tomorrow',
        weekday: 'Sun',
        template: {'morning': '   ', 'afternoon': ''},
      );
      expect(s.isRest, isTrue);
      expect(s.morning, isNull);
      expect(s.afternoon, isNull);
    });

    test('null template (date outside every block) → rest day', () {
      final s = summarizeDayInputs(
        label: 'Tomorrow',
        weekday: 'Wed',
        template: null,
      );
      expect(s.isRest, isTrue);
      expect(s.morning, isNull);
      expect(s.afternoon, isNull);
      expect(s.blockNote, isNull);
    });

    test('morning only is still an active day', () {
      final s = summarizeDayInputs(
        label: 'Today',
        weekday: 'Fri',
        template: {'morning': 'Deadlift top set'},
      );
      expect(s.isRest, isFalse);
      expect(s.morning, 'Deadlift top set');
      expect(s.afternoon, isNull);
    });
  });

  group('weekdayAbbr', () {
    test('maps weekday to Mon-first abbreviation', () {
      expect(weekdayAbbr(DateTime.utc(2026, 9, 28)), 'Mon'); // 2026-09-28 Mon
      expect(weekdayAbbr(DateTime.utc(2026, 10, 4)), 'Sun'); // Sun
    });
  });
}
