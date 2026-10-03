// week_start.dart — THE week-start resolver (2026-10-03): synced setting
// > program.yaml `week_start` > Monday, plus the pure week helpers.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/app_settings_tab.dart';
import 'package:airledger/services/week_start.dart';

void main() {
  group('resolveWeekStart precedence', () {
    test('synced setting wins over the program default', () {
      final r = resolveWeekStart(
        setting: 'monday',
        programVersion: {'week_start': 'saturday'},
      );
      expect(r.day, DateTime.monday);
      expect(r.source, WeekStartSource.setting);
    });

    test('no setting → program.yaml week_start', () {
      final r = resolveWeekStart(programVersion: {'week_start': 'saturday'});
      expect(r.day, DateTime.saturday);
      expect(r.source, WeekStartSource.program);
    });

    test('blank / unparseable setting falls through to the program', () {
      for (final s in ['', '  ', 'someday', 'null', 9]) {
        expect(
          resolveWeekStartDay(
            setting: s,
            programVersion: {'week_start': 'saturday'},
          ),
          DateTime.saturday,
          reason: '$s',
        );
      }
    });

    test('neither → Monday', () {
      final r = resolveWeekStart();
      expect(r.day, DateTime.monday);
      expect(r.source, WeekStartSource.fallback);
      expect(
        resolveWeekStartDay(programVersion: {'week_start': 'bogus'}),
        DateTime.monday,
      );
    });
  });

  test('parseWeekday: names, abbreviations, numbers, case/space', () {
    expect(parseWeekday('saturday'), DateTime.saturday);
    expect(parseWeekday(' Saturday '), DateTime.saturday);
    expect(parseWeekday('SAT'), DateTime.saturday);
    expect(parseWeekday('sun'), DateTime.sunday);
    expect(parseWeekday(1), DateTime.monday);
    expect(parseWeekday('7'), DateTime.sunday);
    expect(parseWeekday('s'), isNull);
    expect(parseWeekday(0), isNull);
    expect(parseWeekday(null), isNull);
    expect(weekdayKey(DateTime.saturday), 'saturday');
    expect(weekdayName(DateTime.saturday), 'Saturday');
    expect(weekdayShortName(DateTime.friday), 'Fri');
  });

  group('weekStartOf / weekEndOf / weekDaysOf for every start day', () {
    // Tue 2026-10-06 sits in a different week per start day.
    final tue = DateTime(2026, 10, 6, 18, 30);
    final expected = {
      DateTime.monday: DateTime(2026, 10, 5),
      DateTime.tuesday: DateTime(2026, 10, 6),
      DateTime.wednesday: DateTime(2026, 9, 30),
      DateTime.thursday: DateTime(2026, 10, 1),
      DateTime.friday: DateTime(2026, 10, 2),
      DateTime.saturday: DateTime(2026, 10, 3),
      DateTime.sunday: DateTime(2026, 10, 4),
    };
    for (final e in expected.entries) {
      test(weekdayName(e.key), () {
        final start = weekStartOf(tue, e.key);
        expect(start, e.value);
        expect(start.weekday, e.key);
        final days = weekDaysOf(tue, e.key);
        expect(days, hasLength(7));
        expect(days.first, start);
        expect(days.last, weekEndOf(tue, e.key));
        expect(days.last.weekday, weekEndDay(e.key));
        expect(days, contains(DateTime(2026, 10, 6)));
        // Every day of the week maps back to the same start.
        for (final d in days) {
          expect(weekStartOf(d, e.key), start);
        }
      });
    }

    test('Saturday weeks: Sat 10/3 – Fri 10/9; Sat 10/10 is next week', () {
      expect(
        weekStartOf(DateTime(2026, 10, 9), DateTime.saturday),
        DateTime(2026, 10, 3),
      );
      expect(
        weekStartOf(DateTime(2026, 10, 10), DateTime.saturday),
        DateTime(2026, 10, 10),
      );
      expect(
        sameWeek(
          DateTime(2026, 10, 3),
          DateTime(2026, 10, 9),
          DateTime.saturday,
        ),
        isTrue,
      );
      expect(
        sameWeek(
          DateTime(2026, 10, 9),
          DateTime(2026, 10, 10),
          DateTime.saturday,
        ),
        isFalse,
      );
      expect(weekEndDay(DateTime.saturday), DateTime.friday);
      expect(weekEndDay(DateTime.monday), DateTime.sunday);
    });

    test('UTC input keeps its calendar date', () {
      expect(
        weekStartOf(DateTime.utc(2026, 10, 9), DateTime.saturday),
        DateTime(2026, 10, 3),
      );
    });
  });

  group('app_settings tab codec', () {
    test(
      'parses key/value rows; last row per key wins; blank keys skipped',
      () {
        final m = parseAppSettings([
          ['key', 'value', 'updated_at'],
          ['week_start', 'monday', '2026-10-01'],
          ['', 'x'],
          ['week_start', 'saturday', '2026-10-03'],
          ['other'],
        ]);
        expect(m, {'week_start': 'saturday', 'other': ''});
      },
    );

    test('a tab whose row 1 is not the header reads as empty (the '
        'program_moves header-loss shape)', () {
      final values = [
        ['week_start', 'saturday', '2026-10-03'],
      ];
      expect(parseAppSettings(values), isEmpty);
      expect(hasAppSettingsHeader(values), isFalse);
      expect(hasAppSettingsHeader([appSettingsHeaders]), isTrue);
      expect(hasAppSettingsHeader(const []), isFalse);
    });
  });
}
