// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/week_plan.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _fitnessRepo = '../airledger-fitness/coach';

Map<Object?, Object?> _loadYamlMap(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
        'Missing $path — is the airledger-fitness checkout present?');
  }
  final y = loadYaml(file.readAsStringSync());
  return y is Map ? Map<Object?, Object?>.from(y) : {};
}

// ---------------------------------------------------------------------------
// defaultWeekStart tests (pure, no fixtures needed)
// ---------------------------------------------------------------------------

void main() {
  // Minimal stand-in program with a single multi-year block so every date
  // in the tests falls inside the program.
  final program = <Object?, Object?>{
    'versions': [
      {
        'version': 1,
        'pending': false,
        'id': 'test-program',
        'blocks': [
          {
            'n': 1,
            'emphasis': 'lifting',
            'dates': ['2020-01-01', '2030-12-31'],
            'weight': [150, 160],
          },
        ],
        'week_types': {
          'applies_to_blocks': [1],
          'normal': <Object?, Object?>{},
          'light': {'week_in_block': 4},
          'test': {'week_in_block': 8},
        },
        'weekly_template': {
          'mon': {'morning': 'Squat heavy', 'afternoon': null},
          'tue': {'morning': 'Bench', 'afternoon': 'Climb'},
          'wed': {'morning': 'Bike', 'afternoon': null},
          'thu': {'morning': 'Deadlift', 'afternoon': null},
          'fri': {'morning': null, 'afternoon': 'Climb board'},
          'sat': {'morning': 'Volume day', 'afternoon': null},
          'sun': {'morning': null, 'afternoon': null},
        },
        'targets': <Object?, Object?>{},
        'rules': <Object?>[],
      },
    ],
  };

  group('defaultWeekStart', () {
    test('returns Monday of the current week on a Thursday', () {
      // 2026-09-17 is a Thursday; Monday of that week is 2026-09-14.
      final result = defaultWeekStart(DateTime(2026, 9, 17));
      expect(result, DateTime.utc(2026, 9, 14));
    });

    test('returns the SAME Monday when today IS Monday', () {
      final monday = DateTime(2026, 9, 14); // a Monday
      expect(defaultWeekStart(monday), DateTime.utc(2026, 9, 14));
    });

    test('returns the SAME Monday when today is Saturday', () {
      // 2026-09-19 is Saturday; Monday of that week is 2026-09-14.
      final result = defaultWeekStart(DateTime(2026, 9, 19));
      expect(result, DateTime.utc(2026, 9, 14));
    });

    test('returns NEXT Monday when today is Sunday (check-ahead rule)', () {
      // 2026-09-20 is Sunday; next Monday is 2026-09-21.
      final result = defaultWeekStart(DateTime(2026, 9, 20));
      expect(result, DateTime.utc(2026, 9, 21));
    });
  });

  // ---------------------------------------------------------------------------
  // buildWeekPlan tests against the minimal stand-in program
  // ---------------------------------------------------------------------------

  group('buildWeekPlan (stand-in program)', () {
    test('always returns exactly 7 days', () {
      final week = buildWeekPlan(program, null, DateTime(2026, 9, 16));
      expect(week.length, 7);
    });

    test('first entry is Monday regardless of input day', () {
      for (final offset in [0, 2, 5, 6]) {
        final week = buildWeekPlan(
            program, null, DateTime(2026, 9, 14).add(Duration(days: offset)));
        expect(week.first.date.weekday, DateTime.monday,
            reason: 'offset $offset should still start on Monday');
      }
    });

    test('days are consecutive Mon–Sun', () {
      final week = buildWeekPlan(program, null, DateTime(2026, 9, 16));
      for (var i = 0; i < 7; i++) {
        expect(week[i].date.weekday, i + 1); // Mon=1 … Sun=7
        if (i > 0) {
          expect(
              week[i].date.difference(week[i - 1].date).inDays, 1);
        }
      }
    });

    test('Sunday is isOff (no morning/afternoon in template)', () {
      // In our stand-in, sunday has null/null → isOff = true.
      final week = buildWeekPlan(program, null, DateTime(2026, 9, 14));
      final sunday = week[6];
      expect(sunday.date.weekday, DateTime.sunday);
      expect(sunday.isOff, isTrue);
    });

    test('Monday has morning content, not isOff', () {
      final week = buildWeekPlan(program, null, DateTime(2026, 9, 14));
      final monday = week[0];
      expect(monday.slice, isNotNull);
      expect(monday.slice!.todayTemplate['morning'], contains('Squat'));
      expect(monday.isOff, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Off-day and pre-program cases
  // ---------------------------------------------------------------------------

  group('buildWeekPlan (edge cases)', () {
    test('pre-program dates (before any block) get null slice', () {
      // 2019-01-01 is before the stand-in block start 2020-01-01.
      final week = buildWeekPlan(program, null, DateTime(2019, 1, 7));
      for (final day in week) {
        expect(day.slice, isNull,
            reason: 'date ${day.date} is pre-program; slice should be null');
        expect(day.isOff, isTrue);
      }
    });

    test('buildWeekPlan anchors to the correct Monday for mid-week input', () {
      // 2026-09-16 (Wed) → week should start 2026-09-14 (Mon)
      final week = buildWeekPlan(program, null, DateTime(2026, 9, 16));
      expect(week.first.date, DateTime.utc(2026, 9, 14));
      expect(week.last.date, DateTime.utc(2026, 9, 20));
    });
  });

  // ---------------------------------------------------------------------------
  // Integration test against real airledger-fitness fixtures
  // ---------------------------------------------------------------------------

  group('buildWeekPlan (real program.yaml)', () {
    late Map<Object?, Object?> realProgram;
    late Map<Object?, Object?> realPhase;

    setUpAll(() {
      realProgram = _loadYamlMap('$_fitnessRepo/program.yaml');
      realPhase = _loadYamlMap('$_fitnessRepo/phase.yaml');
    });

    test('block-0 week: slice is non-null and emphasis=cut', () {
      // 2026-09-21 is the first day of block 0 (cut).
      final week = buildWeekPlan(realProgram, realPhase, DateTime(2026, 9, 21));
      expect(week.length, 7);
      // Monday 2026-09-21 should be in block 0.
      final monday = week[0];
      expect(monday.slice, isNotNull);
      expect(monday.slice!.block['number'], 0);
      expect(monday.slice!.block['emphasis'], 'cut');
    });

    test('pre-program date gives all-null slices', () {
      // 2026-09-14 is before block 0 (starts 2026-09-21).
      final week = buildWeekPlan(realProgram, realPhase, DateTime(2026, 9, 14));
      for (final day in week) {
        expect(day.slice, isNull,
            reason: '${day.date} should be pre-program');
      }
    });

    test('block-1 (reverse) week in lifting block has no light/test type', () {
      // block 1 is 2026-12-14..2027-01-03 (applies_to_blocks: [2..7] only).
      final week = buildWeekPlan(realProgram, realPhase, DateTime(2026, 12, 22));
      for (final day in week) {
        if (day.slice != null) {
          expect(day.slice!.weekType, 'normal',
              reason: 'block 1 has no light/test cadence');
        }
      }
    });

    test('block 0 uses weekly_template_block_0 for Monday morning', () {
      final week = buildWeekPlan(realProgram, realPhase, DateTime(2026, 9, 21));
      final monday = week[0];
      // block_0 Monday should use the block-0 template (one hard single).
      expect(monday.slice!.todayTemplate['morning'],
          contains('one hard single at RPE 8'));
    });
  });

  group('defaultWeekStart — saturday-start accounting weeks (v7)', () {
    test('a Saturday starts its own week', () {
      expect(
        defaultWeekStart(DateTime(2026, 9, 19),
            weekStartDay: DateTime.saturday),
        DateTime.utc(2026, 9, 19),
      );
    });

    test('Sunday through Thursday stay in the week begun the prior '
        'Saturday', () {
      for (final day in [
        DateTime(2026, 9, 20), // Sunday
        DateTime(2026, 9, 22), // Tuesday
        DateTime(2026, 9, 24), // Thursday
      ]) {
        expect(
          defaultWeekStart(day, weekStartDay: DateTime.saturday),
          DateTime.utc(2026, 9, 19),
        );
      }
    });

    test('the closing Friday plans the UPCOMING week (the Sunday '
        'convention, shifted)', () {
      expect(
        defaultWeekStart(DateTime(2026, 9, 25),
            weekStartDay: DateTime.saturday),
        DateTime.utc(2026, 9, 26),
      );
    });
  });
}
