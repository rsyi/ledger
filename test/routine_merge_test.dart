// v12 `routine:` base-week + phase_overrides merge (routineWeekFor) and
// the planner's accessory double-progression weight fill — synthetic
// programs (no live-YAML dependency).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_metrics.dart' show StrengthRow;
import 'package:airledger/services/week_planner.dart';

Map<Object?, Object?> _program({
  Map<Object?, Object?>? routine,
  Map<Object?, Object?>? legacyBase,
  Map<Object?, Object?>? legacyBlock0,
}) =>
    {
      'versions': [
        {
          'version': 12,
          'id': 'test',
          'blocks': [
            {
              'n': 0,
              'dates': ['2026-09-21', '2026-12-13'],
              'emphasis': 'cut',
              'weight': [163, 154],
            },
            {
              'n': 1,
              'dates': ['2026-12-14', '2027-01-03'],
              'emphasis': 'reverse',
              'weight': [154, 155],
            },
          ],
          'routine': ?routine,
          'weekly_template': ?legacyBase,
          'weekly_template_block_0': ?legacyBlock0,
        },
      ],
    };

void main() {
  group('routineWeekFor', () {
    final routine = <Object?, Object?>{
      'week': {
        'mon': {'morning': 'cut monday', 'planned': []},
        'tue': {'morning': 'cut tuesday'},
      },
      'phase_overrides': {
        'postcut': {
          'applies_to_blocks': [1, 2, 3],
          'week': {
            'mon': {'morning': 'postcut monday'},
          },
        },
        'climbing_emphasis': {
          'applies_to_blocks': [2],
          'note': 'multipliers only — no template change',
        },
      },
    };

    test('base week for a block outside every override', () {
      final week = routineWeekFor({'routine': routine}, 0)!;
      expect((week['mon'] as Map)['morning'], 'cut monday');
      expect((week['tue'] as Map)['morning'], 'cut tuesday');
    });

    test('override replaces only the days it declares', () {
      final week = routineWeekFor({'routine': routine}, 1)!;
      expect((week['mon'] as Map)['morning'], 'postcut monday');
      expect((week['tue'] as Map)['morning'], 'cut tuesday');
    });

    test('week-less overrides (documentation) change nothing', () {
      final week = routineWeekFor({'routine': routine}, 2)!;
      expect((week['mon'] as Map)['morning'], 'postcut monday');
      expect((week['tue'] as Map)['morning'], 'cut tuesday');
    });

    test('null blockN gets the base week', () {
      final week = routineWeekFor({'routine': routine}, null)!;
      expect((week['mon'] as Map)['morning'], 'cut monday');
    });

    test('legacy fallback: block 0 prefers weekly_template_block_0', () {
      final v = {
        'weekly_template': {
          'mon': {'morning': 'base'},
        },
        'weekly_template_block_0': {
          'mon': {'morning': 'block0'},
        },
      };
      expect((routineWeekFor(v, 0)!['mon'] as Map)['morning'], 'block0');
      expect((routineWeekFor(v, 1)!['mon'] as Map)['morning'], 'base');
    });

    test('no templates at all → null', () {
      expect(routineWeekFor({}, 0), isNull);
      expect(routineWeekFor(null, 0), isNull);
    });
  });

  group('programCurrent through the routine merge', () {
    test('block 0 reads the base week; block 1 the override', () {
      final program = _program(routine: {
        'week': {
          'mon': {'morning': 'cut monday', 'afternoon': null},
        },
        'phase_overrides': {
          'postcut': {
            'applies_to_blocks': [1],
            'week': {
              'mon': {'morning': 'postcut monday', 'afternoon': 'climb'},
            },
          },
        },
      });
      final cut = programCurrent(program, null, DateTime.utc(2026, 9, 21))!;
      expect(cut.todayTemplate['morning'], 'cut monday');
      final post = programCurrent(program, null, DateTime.utc(2026, 12, 14))!;
      expect(post.todayTemplate['morning'], 'postcut monday');
      expect(post.todayTemplate['afternoon'], 'climb');
    });
  });

  group('planner accessory double progression', () {
    final program = _program(routine: {
      'week': {
        'mon': {
          'morning': 'accessories',
          'planned': [
            {
              'exercise': 'Seated Cable Row',
              'sets': 2,
              'reps': 8,
              'reps_hi': 12,
            },
            {'exercise': 'Pull Up', 'sets': 2, 'reps': 6, 'reps_hi': 10},
          ],
        },
      },
    });
    // Week containing Mon 2026-10-05 (block 0).
    final monday = DateTime.utc(2026, 10, 5);

    test('suggests +step when the last session topped the range', () {
      final history = [
        StrengthRow(
          date: DateTime.utc(2026, 9, 28),
          exercise: 'Seated Cable Row',
          weight: 100,
          reps: 12,
          rpe: 8,
        ),
        StrengthRow(
          date: DateTime.utc(2026, 9, 28),
          exercise: 'Seated Cable Row',
          weight: 100,
          reps: 12,
          rpe: 8.5,
        ),
      ];
      final entries = buildWeekPlannedEntries(
        program,
        monday,
        accessoryHistory: history,
      );
      final rows = [
        for (final e in entries)
          if (e['exercise'] == 'Seated Cable Row') e,
      ];
      expect(rows, hasLength(2));
      expect(rows.first['weight'], 105);
      expect(rows.first['reps'], 8); // planner still plans the LOW end
      // reps_hi rides along as a DISPLAY marker (routine screen shows
      // the 8-12 range); regenerateWeek never persists it.
      expect(rows.first['reps_hi'], 12);
    });

    test('bodyweight accessories stay weightless (no fabrication)', () {
      final entries = buildWeekPlannedEntries(
        program,
        monday,
        accessoryHistory: [
          StrengthRow(
            date: DateTime.utc(2026, 9, 28),
            exercise: 'Pull Up',
            weight: 0,
            reps: 8,
            rpe: 8,
          ),
        ],
      );
      final rows = [
        for (final e in entries)
          if (e['exercise'] == 'Pull Up') e,
      ];
      expect(rows, hasLength(2));
      expect(rows.first.containsKey('weight'), isFalse);
      // And no warm-up rows were fabricated for accessories.
      expect(entries.every((e) => e['exercise'] != 'Barbell Squat'), isTrue);
    });

    test('no history → unchanged pre-v12 behavior (no weights)', () {
      final entries = buildWeekPlannedEntries(program, monday);
      expect(entries.every((e) => !e.containsKey('weight')), isTrue);
    });

    test('accessories never get a warm-up ramp even with weights', () {
      final withWarmup = _program(routine: {
        'week': {
          'mon': {
            'planned': [
              {
                'exercise': 'Seated Cable Row',
                'sets': 1,
                'reps': 8,
                'reps_hi': 12,
              },
            ],
          },
        },
      });
      // Inject directly into the stored version map (currentVersion
      // returns a defensive copy).
      ((withWarmup['versions'] as List).first as Map)['warmup_protocol'] = {
        'rounding_lb': 5,
        'default': [
          {'weight_lb': 45, 'reps': 10},
        ],
      };
      final entries = buildWeekPlannedEntries(
        withWarmup,
        monday,
        accessoryHistory: [
          StrengthRow(
            date: DateTime.utc(2026, 9, 28),
            exercise: 'Seated Cable Row',
            weight: 100,
            reps: 8,
            rpe: 8,
          ),
        ],
      );
      final rows = [
        for (final e in entries)
          if (e['exercise'] == 'Seated Cable Row') e,
      ];
      expect(rows, hasLength(1)); // no 45-lb bar row spliced in front
      expect(rows.single['weight'], 100); // hold (range not topped)
    });
  });
}
