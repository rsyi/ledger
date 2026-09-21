import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/home_synthesis.dart';
import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/wm_tabs.dart';

WorkingMaxRow wm(
  String lift,
  double value,
  String from, {
  String source = 'seed',
  String reason = '',
}) =>
    WorkingMaxRow(
      lift: lift,
      variant: 'default',
      valueLb: value,
      effectiveFrom: DateTime.parse(from),
      source: source,
      reason: reason,
    );

void main() {
  final today = DateTime(2026, 9, 23); // Wednesday; week Monday = Sep 21

  group('trendDirection', () {
    test('up when current exceeds past by more than the threshold', () {
      expect(trendDirection(320, 310), TrendDirection.up);
    });
    test('down when current is below past by more than the threshold', () {
      expect(trendDirection(300, 310), TrendDirection.down);
    });
    test('flat within the threshold', () {
      expect(trendDirection(320, 318), TrendDirection.flat);
      expect(trendDirection(318, 320), TrendDirection.flat);
    });
    test('unknown when either side is missing', () {
      expect(trendDirection(null, 310), TrendDirection.unknown);
      expect(trendDirection(320, null), TrendDirection.unknown);
    });
  });

  group('liftTrends', () {
    test('null snapshot yields all four lifts as unknown placeholders', () {
      final trends = liftTrends(null, today);
      expect(trends.map((t) => t.lift).toList(),
          ['squat', 'bench', 'deadlift', 'press']);
      for (final t in trends) {
        expect(t.valueLb, isNull);
        expect(t.direction, TrendDirection.unknown);
        expect(t.painCap, isFalse);
      }
    });

    test('current value + 4-week direction from tab history', () {
      final snap = (
        workingMax: [
          wm('squat', 300, '2026-07-01'),
          wm('squat', 320, '2026-09-16', source: 'rule'),
          wm('bench', 240, '2026-08-14'),
        ],
        readings: <ReadingRow>[],
      );
      final trends = liftTrends(snap, today);
      final squat = trends.firstWhere((t) => t.lift == 'squat');
      // 28 days before Sep 23 = Aug 26 → squat was 300 → up.
      expect(squat.valueLb, 320);
      expect(squat.direction, TrendDirection.up);
      final bench = trends.firstWhere((t) => t.lift == 'bench');
      expect(bench.valueLb, 240);
      expect(bench.direction, TrendDirection.flat);
      final press = trends.firstWhere((t) => t.lift == 'press');
      expect(press.valueLb, isNull);
      expect(press.direction, TrendDirection.unknown);
    });

    test('seed newer than the 4-week window is unknown, not flat', () {
      final snap = (
        workingMax: [wm('press', 140, '2026-09-21')],
        readings: <ReadingRow>[],
      );
      final press =
          liftTrends(snap, today).firstWhere((t) => t.lift == 'press');
      expect(press.valueLb, 140);
      expect(press.direction, TrendDirection.unknown);
    });

    test('pain cap marker sets painCap until lifted', () {
      final capped = (
        workingMax: [
          wm('deadlift', 330, '2026-09-21'),
          wm('deadlift', 330, '2026-09-21', source: 'pain_cap'),
        ],
        readings: <ReadingRow>[],
      );
      expect(
        liftTrends(capped, today)
            .firstWhere((t) => t.lift == 'deadlift')
            .painCap,
        isTrue,
      );
      final lifted = (
        workingMax: [
          ...capped.workingMax,
          wm('deadlift', 330, '2026-09-22',
              source: 'rule', reason: 'pain cap lifted — clean sessions'),
        ],
        readings: <ReadingRow>[],
      );
      expect(
        liftTrends(lifted, today)
            .firstWhere((t) => t.lift == 'deadlift')
            .painCap,
        isFalse,
      );
    });
  });

  group('fmtLb', () {
    test('whole numbers drop the decimal', () {
      expect(fmtLb(240.0), '240');
      expect(fmtLb(242.5), '242.5');
    });
  });

  group('asDay / asNum', () {
    test('asDay parses DateTime and ISO strings to a UTC day', () {
      expect(asDay(DateTime(2026, 9, 21, 13, 5)), DateTime.utc(2026, 9, 21));
      expect(asDay('2026-09-21'), DateTime.utc(2026, 9, 21));
      expect(asDay('2026-09-21T00:00:00'), DateTime.utc(2026, 9, 21));
      expect(asDay('nope'), isNull);
      expect(asDay(null), isNull);
    });
    test('asNum parses nums and numeric strings', () {
      expect(asNum(28), 28.0);
      expect(asNum('171.9'), 171.9);
      expect(asNum(''), isNull);
      expect(asNum(null), isNull);
    });
  });

  group('latestStatusWeek', () {
    final rows = [
      {'week_monday': DateTime(2026, 9, 14), 'working_sets': 22},
      {'week_monday': '2026-09-21', 'working_sets': 8},
    ];

    test('prefers the row for the week containing today', () {
      final w = latestStatusWeek(rows, today);
      expect(w, isNotNull);
      expect(w!.isCurrentWeek, isTrue);
      expect(w.row['working_sets'], 8);
      expect(w.weekMonday, DateTime.utc(2026, 9, 21));
    });

    test('falls back to the newest prior week', () {
      final w = latestStatusWeek([rows.first], today);
      expect(w!.isCurrentWeek, isFalse);
      expect(w.weekMonday, DateTime.utc(2026, 9, 14));
    });

    test('ignores future weeks and handles empty input', () {
      final w = latestStatusWeek(
        [
          {'week_monday': '2026-09-28', 'working_sets': 0},
        ],
        today,
      );
      expect(w, isNull);
      expect(latestStatusWeek(const [], today), isNull);
    });
  });

  group('flagCount', () {
    test('counts comma-separated ids, tolerating blanks', () {
      expect(flagCount('NEAR_MAX_LOW,WORKING_LOW'), 2);
      expect(flagCount(' NEAR_MAX_LOW , WORKING_LOW ,'), 2);
      expect(flagCount('BENCH_ONCE'), 1);
      expect(flagCount(''), 0);
      expect(flagCount(null), 0);
    });
  });

  group('targetNumber / targetText / weekFraction', () {
    test('plain numbers and numeric strings', () {
      expect(targetNumber(28), 28.0);
      expect(targetNumber('6'), 6.0);
      expect(targetText(28), '28');
    });
    test('ranges use the upper bound as the number, en-dash as text', () {
      expect(targetNumber([0.2, 0.5]), 0.5);
      expect(targetText([2, 3]), '2–3');
    });
    test('missing targets', () {
      expect(targetNumber(null), isNull);
      expect(targetText(null), '—');
    });
    test('weekFraction clamps to 0..1 and nulls out bad input', () {
      expect(weekFraction(14, 28), 0.5);
      expect(weekFraction(30, 28), 1.0);
      expect(weekFraction(0, 28), 0.0);
      expect(weekFraction(null, 28), isNull);
      expect(weekFraction(3, null), isNull);
      expect(weekFraction(3, 0), isNull);
    });
  });

  group('verdictChipText', () {
    test('keeps short labels, strips the em-dash tail', () {
      expect(verdictChipText('cutting, on pace'), 'cutting, on pace');
      expect(verdictChipText('gaining — PHASE_MISMATCH would fire'),
          'gaining');
      expect(verdictChipText('stalled — scale is flat'), 'stalled');
    });
  });

  group('lastBike4x4', () {
    test('newest week at or before today with a measured session', () {
      final rows = [
        {
          'week_monday': '2026-09-21',
          'bike_4x4_count': 0,
          'bike_4x4_max_hr': '',
        },
        {
          'week_monday': '2026-09-14',
          'bike_4x4_count': 1,
          'bike_4x4_max_hr': 174,
        },
        {
          'week_monday': '2026-09-07',
          'bike_4x4_count': 1,
          'bike_4x4_max_hr': 171,
        },
      ];
      final last = lastBike4x4(rows, today);
      expect(last, isNotNull);
      expect(last!.maxHr, 174);
      expect(last.weekMonday, DateTime.utc(2026, 9, 14));
    });

    test('null when nothing measured', () {
      expect(lastBike4x4(const [], today), isNull);
      expect(
        lastBike4x4([
          {'week_monday': '2026-09-14', 'bike_4x4_count': 1},
        ], today),
        isNull,
      );
    });
  });

  group('templateOneLiner', () {
    ProgramSlice slice({String? morning, String? afternoon}) => ProgramSlice(
          id: 'x',
          version: 1,
          block: const {},
          weekInBlock: 1,
          weekType: 'normal',
          todayTemplate: {'morning': morning, 'afternoon': afternoon},
          targetsInForce: const {},
          rulesInForce: const [],
        );

    test('prefers morning, truncates long text', () {
      final line = templateOneLiner(
        slice(
            morning: 'Squat heavy: top set of 1-3 at RPE 8.5-9, then 4x3 '
                'at 82%; hanging leg raise; muscle-ups and more and more'),
        maxLen: 40,
      );
      expect(line, isNotNull);
      expect(line!.length, lessThanOrEqualTo(41)); // 40 + ellipsis char
      expect(line, startsWith('Squat heavy'));
      expect(line, endsWith('…'));
    });

    test('falls back to the afternoon session with a PM prefix', () {
      expect(templateOneLiner(slice(afternoon: 'Climb 1, limit')),
          'PM: Climb 1, limit');
    });

    test('null when the day is empty or slice missing', () {
      expect(templateOneLiner(slice()), isNull);
      expect(templateOneLiner(null), isNull);
    });
  });
}
