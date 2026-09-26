import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/home_synthesis.dart';
import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, gradeSets;
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

StrengthRow strengthRow(String date, String ex, double w, int reps) =>
    StrengthRow(
      date: DateTime.parse(date),
      exercise: ex,
      weight: w,
      reps: reps,
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

  group('strengthRowFromRecord', () {
    test('maps date/exercise/weight/reps/rpe, tolerating string cells', () {
      final r = strengthRowFromRecord({
        'date': '2026-09-21',
        'exercise': 'Barbell Squat',
        'weight': '275',
        'reps': 3,
        'rpe': 8.0,
      })!;
      expect(r.exercise, 'Barbell Squat');
      expect(r.weight, 275);
      expect(r.reps, 3);
      expect(r.rpe, 8.0);
      expect(r.date, DateTime(2026, 9, 21));
    });

    test('null on missing date/exercise/weight/reps (planned rows, holds)',
        () {
      expect(strengthRowFromRecord({'exercise': 'Barbell Squat'}), isNull);
      expect(strengthRowFromRecord({'date': '2026-09-21'}), isNull);
      expect(
        strengthRowFromRecord({
          'date': '2026-09-21',
          'exercise': 'Plank',
          'weight': null, // isometric hold — no weight
          'reps': 1,
        }),
        isNull,
      );
    });
  });

  group('allTimeBestE1rms', () {
    StrengthRow s(String ex, double w, int reps) => StrengthRow(
          date: DateTime(2025, 1, 1),
          exercise: ex,
          weight: w,
          reps: reps,
        );

    test('max Epley e1RM per lift over the full history', () {
      final best = allTimeBestE1rms([
        s('Barbell Squat', 300, 1), // e1rm 310
        s('Barbell Squat', 275, 5), // e1rm ~320.8 — rep PR wins
        s('Flat Barbell Bench Press', 225, 1), // 232.5
        s('Overhead Press', 135, 3), // 148.5
      ]);
      expect(best['squat'], closeTo(320.8, 0.1));
      expect(best['bench'], closeTo(232.5, 0.01));
      expect(best['press'], closeTo(148.5, 0.01));
      expect(best.containsKey('deadlift'), isFalse);
    });

    test('reps cap at 12 (max_e1rm_capped expression) and junk is skipped',
        () {
      final best = allTimeBestE1rms([
        s('Barbell Deadlift', 300, 20), // capped: 300 * 1.4 = 420
        s('Barbell Deadlift', 0, 5), // weight <= 0 skipped
        s('Bicep Curl', 500, 1), // not a main lift
      ]);
      expect(best['deadlift'], closeTo(420, 0.01));
      expect(best.length, 1);
    });
  });

  group('fmtAge', () {
    final now = DateTime(2026, 9, 22);
    test('days under two weeks', () {
      expect(fmtAge(DateTime(2026, 9, 22), now), '0d');
      expect(fmtAge(DateTime(2026, 9, 19), now), '3d');
      expect(fmtAge(DateTime(2026, 9, 9), now), '13d');
    });
    test('weeks from 14 days', () {
      expect(fmtAge(DateTime(2026, 9, 8), now), '2w');
      expect(fmtAge(DateTime(2026, 8, 4), now), '7w');
    });
    test('months and years', () {
      expect(fmtAge(DateTime(2026, 4, 22), now), '5mo');
      expect(fmtAge(DateTime(2024, 9, 20), now), '2y');
    });
    test('future dates clamp to 0d', () {
      expect(fmtAge(DateTime(2026, 9, 25), now), '0d');
    });
  });

  group('fmtMonthTag', () {
    test("PR-month tag — the wilks chart benchmark's vocabulary", () {
      expect(fmtMonthTag(DateTime(2025, 4, 12)), "Apr '25");
      expect(fmtMonthTag(DateTime(2024, 12, 31)), "Dec '24");
    });
    test('single-digit years zero-pad', () {
      expect(fmtMonthTag(DateTime(2107, 1, 1)), "Jan '07");
    });
  });

  group('recentBestE1rm', () {
    // gradeSets needs history: seed a reference, then recent work.
    List<StrengthRow> rows() => [
          strengthRow('2026-08-01', 'Barbell Squat', 315, 3), // ref seed
          strengthRow('2026-09-10', 'Barbell Squat', 310, 3),
          strengthRow('2026-09-19', 'Barbell Squat', 300, 3),
          strengthRow('2026-09-19', 'Barbell Squat', 135, 5), // warm-up
        ];
    final today = DateTime(2026, 9, 22);

    test('best capped e1RM in the trailing 14 days, warm-ups excluded',
        () {
      final graded = gradeSets(rows());
      final r = recentBestE1rm(graded, 'squat', today)!;
      // Sep 10 (12d ago) and Sep 19 both inside; Sep 10's 310x3 wins.
      expect(r.value, closeTo(310 * (1 + 3 / 30), 1e-9));
      expect(r.date, DateTime(2026, 9, 10));
      // The 135x5 warm-up (effort « 0.75) never sets the number.
    });

    test('light accounting weeks are excluded', () {
      final graded = gradeSets(rows());
      final r = recentBestE1rm(
        graded,
        'squat',
        today,
        weekTypeOf: (ws) =>
            ws == DateTime(2026, 9, 7) ? 'light' : 'normal',
      )!;
      // Sep 10 falls in the light week (Mon Sep 7) → Sep 19's set wins.
      expect(r.value, closeTo(300 * (1 + 3 / 30), 1e-9));
      expect(r.date, DateTime(2026, 9, 19));
    });

    test('widens when the last 14 days are empty — the age tag tells '
        'the story', () {
      final graded = gradeSets([
        strengthRow('2026-06-01', 'Barbell Squat', 315, 3),
        strengthRow('2026-06-20', 'Barbell Squat', 305, 3),
      ]);
      final r = recentBestE1rm(graded, 'squat', today)!;
      // Nothing in the 14 days ending today → window ends at the newest
      // qualifying set (Jun 20); Jun 1's heavier set is OUTSIDE that
      // 14-day window, so Jun 20 wins despite being lighter.
      expect(r.date, DateTime(2026, 6, 20));
      expect(r.value, closeTo(305 * (1 + 3 / 30), 1e-9));
    });

    test('null when the lift has no qualifying history', () {
      expect(recentBestE1rm(const [], 'squat', today), isNull);
    });

    test('rpeAdjusted: true values sets by RPE-adjusted e1RM — an '
        'RPE-8 double outranks a heavier at-failure set', () {
      final graded = gradeSets([
        strengthRow('2026-08-01', 'Barbell Squat', 315, 3), // ref seed
        // 310x1 no RPE → treated at-failure: e1RM 320.3.
        strengthRow('2026-09-18', 'Barbell Squat', 310, 1),
        // 300x2@8 → 2 RIR → 4 effective reps: 340.0 adjusted (would
        // LOSE on plain Epley: 320.0 < 320.3).
        StrengthRow(
          date: DateTime(2026, 9, 19),
          exercise: 'Barbell Squat',
          weight: 300,
          reps: 2,
          rpe: 8,
        ),
      ]);
      final plain = recentBestE1rm(graded, 'squat', today)!;
      expect(plain.date, DateTime(2026, 9, 18)); // 320.3 > 320.0
      final adj = recentBestE1rm(graded, 'squat', today, rpeAdjusted: true)!;
      expect(adj.date, DateTime(2026, 9, 19));
      expect(adj.value, closeTo(300 * (1 + 4 / 30), 1e-9)); // 340.0
    });

    test('rpeAdjusted: true leaves RPE-less history identical to the '
        'plain metric (at-failure fallback)', () {
      final graded = gradeSets(rows());
      final plain = recentBestE1rm(graded, 'squat', today)!;
      final adj = recentBestE1rm(graded, 'squat', today, rpeAdjusted: true)!;
      expect(adj.value, plain.value);
      expect(adj.date, plain.date);
    });
  });

  group('liveWeekCounts', () {
    final rows = [
      // Reference history so this week's sets grade as working/near-max.
      strengthRow('2026-08-20', 'Flat Barbell Bench Press', 225, 3),
      strengthRow('2026-08-20', 'Barbell Squat', 315, 3),
      // Friday Sep 18 — OLD saturday-week.
      strengthRow('2026-09-18', 'Barbell Squat', 315, 1),
      // Monday Sep 21 — current saturday-week (started Sat Sep 19).
      strengthRow('2026-09-21', 'Flat Barbell Bench Press', 240, 1),
      strengthRow('2026-09-21', 'Flat Barbell Bench Press', 200, 3),
    ];
    final today = DateTime(2026, 9, 22); // Tuesday

    test('saturday-start: Monday bench counts; Friday squat does not',
        () {
      final live = liveWeekCounts(
        strengthRows: rows,
        climbingDates: [
          DateTime(2026, 9, 18), // Friday — old week
          DateTime(2026, 9, 20), // Sunday — current week
          DateTime(2026, 9, 20), // same day, one session
        ],
        today: today,
        weekStartDay: DateTime.saturday,
      );
      expect(live.weekStart, DateTime(2026, 9, 19));
      expect(live.benchDays, 1);
      expect(live.nearMaxSets, 1); // the 240x1 single
      expect(live.workingSets, greaterThanOrEqualTo(1));
      expect(live.climbingSessions, 1);
    });

    test('monday-start keeps the Friday set in the prior week too', () {
      final live = liveWeekCounts(
        strengthRows: rows,
        today: today,
      );
      expect(live.weekStart, DateTime(2026, 9, 21));
      expect(live.benchDays, 1);
    });

    test('future-dated rows never count', () {
      final live = liveWeekCounts(
        strengthRows: [
          ...rows,
          strengthRow('2026-09-24', 'Flat Barbell Bench Press', 225, 1),
        ],
        today: today,
        weekStartDay: DateTime.saturday,
      );
      expect(live.benchDays, 1);
    });
  });

  group('latestStatusWeek — saturday keying', () {
    test('a saturday-keyed current row is current on the weekend', () {
      final rows = [
        {'week_monday': '2026-09-19', 'working_sets': 10},
        {'week_monday': '2026-09-12', 'working_sets': 20},
      ];
      final sat = latestStatusWeek(rows, DateTime(2026, 9, 19),
          weekStartDay: DateTime.saturday)!;
      expect(sat.weekMonday, DateTime.utc(2026, 9, 19));
      expect(sat.isCurrentWeek, isTrue);
      // Under Monday keying the same Saturday sits in the Sep 14 week —
      // the Sep 19 row would read as FUTURE and be skipped.
      final mon = latestStatusWeek(rows, DateTime(2026, 9, 19))!;
      expect(mon.weekMonday, DateTime.utc(2026, 9, 12));
    });
  });
}
