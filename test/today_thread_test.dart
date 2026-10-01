import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/today_thread.dart';

void main() {
  group('todaySynthesisThreadId', () {
    test('zero-pads to a stable per-day id', () {
      expect(todaySynthesisThreadId(DateTime(2026, 9, 30)),
          'today-2026-09-30');
      expect(todaySynthesisThreadId(DateTime(2026, 1, 5)), 'today-2026-01-05');
    });

    test('same day → same id regardless of time of day', () {
      expect(
        todaySynthesisThreadId(DateTime(2026, 9, 30, 6, 15)),
        todaySynthesisThreadId(DateTime(2026, 9, 30, 23, 45)),
      );
    });
  });

  group('shouldSeedTodayThread', () {
    test('empty thread → seed', () {
      expect(shouldSeedTodayThread(const []), isTrue);
    });

    test('a coach opener already present → do not seed (idempotent)', () {
      expect(
        shouldSeedTodayThread([
          {'role': 'coach', 'text': 'Today is going well.'},
        ]),
        isFalse,
      );
    });

    test('only a user message present → still seed the coach opener', () {
      expect(
        shouldSeedTodayThread([
          {'role': 'user', 'text': 'how am I doing?'},
        ]),
        isTrue,
      );
    });
  });

  group('todayThreadRows', () {
    test('filters to the day thread; blank thread resolves to general', () {
      final rows = [
        {'thread': 'today-2026-09-30', 'text': 'a'},
        {'thread': '', 'text': 'b'}, // general
        {'text': 'c'}, // missing → general
        {'thread': 'today-2026-09-30', 'text': 'd'},
      ];
      final day = todayThreadRows(rows, 'today-2026-09-30');
      expect(day.map((r) => r['text']), ['a', 'd']);
    });
  });

  test('todaySynthesisThreadTitle', () {
    expect(todaySynthesisThreadTitle(DateTime(2026, 9, 30)),
        "Today's read · Sep 30");
  });
}
