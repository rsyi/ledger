import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/domain_config.dart';
import 'package:airledger/services/domain_metrics.dart';
import 'package:airledger/services/program_metrics.dart';
import 'package:airledger/services/wilks.dart';

StrengthRow row(String exercise, double weight, int reps, String date) =>
    StrengthRow(
      date: DateTime.parse(date),
      exercise: exercise,
      weight: weight,
      reps: reps,
    );

final today = DateTime(2026, 9, 21);

// Epley capped: w * (1 + min(reps,12)/30)
double e1rm(double w, int reps) => w * (1 + (reps > 12 ? 12 : reps) / 30);

void main() {
  group('plTotal', () {
    test('sums the four lifts and reports none missing', () {
      final t = plTotal({
        'squat': 300,
        'bench': 200,
        'deadlift': 400,
        'press': 100,
      })!;
      expect(t.total, 1000);
      expect(t.missing, isEmpty);
    });

    test('partial history sums what exists and lists the gaps', () {
      final t = plTotal({'squat': 300, 'bench': 200})!;
      expect(t.total, 500);
      expect(t.missing, ['deadlift', 'press']);
    });

    test('no lifts at all → null', () {
      expect(plTotal({}), isNull);
    });
  });

  group('allTimeBestWeights', () {
    test('max actual weight per main lift; non-mains dropped', () {
      final best = allTimeBestWeights([
        row('Barbell Squat', 315, 3, '2025-01-10'),
        row('Barbell Squat', 335, 1, '2025-06-01'),
        row('Barbell Squat', 225, 8, '2026-01-01'),
        row('Flat Barbell Bench Press', 245, 2, '2026-02-01'),
        row('Overhead Press', 135, 5, '2026-03-01'),
        row('Barbell Standing Military Press', 145, 1, '2026-04-01'),
        row('Lat Pulldown', 999, 1, '2026-04-01'), // not a main lift
      ], today);
      expect(best, {
        'squat': 335,
        'bench': 245,
        'press': 145, // both press names fold into one lift
      });
    });

    test('future-dated and zero/invalid rows are excluded', () {
      final best = allTimeBestWeights([
        row('Barbell Squat', 500, 1, '2027-01-01'), // future
        row('Barbell Squat', 0, 5, '2026-01-01'), // no weight
        row('Barbell Squat', 315, 0, '2026-01-01'), // no reps
        row('Barbell Squat', 300, 5, '2026-01-01'),
      ], today);
      expect(best, {'squat': 300});
    });
  });

  group('bodyFatSeriesFromRecords', () {
    test('coalesces caliper > omron > withings, averages per day', () {
      final series = bodyFatSeriesFromRecords([
        {'date': '2026-09-01', 'body_fat_withing': 22.0},
        {
          'date': '2026-09-02',
          'body_fat_caliper': 18.0,
          'body_fat_withing': 23.0, // caliper wins on the same row
        },
        {'date': '2026-09-02', 'body_fat_omron': 20.0}, // second row same day
        {'date': '2026-09-03'}, // no bf at all → skipped
        {'date': null, 'body_fat_omron': 19.0}, // no date → skipped
      ]);
      expect(series, [
        (day: DateTime.utc(2026, 9, 1), value: 22.0),
        (day: DateTime.utc(2026, 9, 2), value: 19.0), // (18 + 20) / 2
      ]);
    });

    test('noise values and non-numeric strings are skipped', () {
      final series = bodyFatSeriesFromRecords([
        {'date': '2026-09-01', 'body_fat_omron': 0}, // <= 0
        {'date': '2026-09-02', 'body_fat_omron': 90}, // >= 75
        {'date': '2026-09-03', 'body_fat_omron': 'n/a'},
        {'date': '2026-09-04', 'body_fat_omron': '17.5'}, // numeric string ok
      ]);
      expect(series, [(day: DateTime.utc(2026, 9, 4), value: 17.5)]);
    });
  });

  group('dailySumSeries', () {
    test('sums per day off a datetime key, ascending', () {
      final s = dailySumSeries([
        {'eaten_at': '2026-09-20 08:00:00', 'calories': 500},
        {'eaten_at': '2026-09-20 19:30:00', 'calories': '750.5'},
        {'eaten_at': '2026-09-19 12:00:00', 'calories': 1800},
        {'eaten_at': '2026-09-21 09:00:00'}, // no value → day omitted
        {'calories': 400}, // no date → skipped
      ], dateKey: 'eaten_at', valueKey: 'calories');
      expect(s, [
        (day: DateTime.utc(2026, 9, 19), value: 1800.0),
        (day: DateTime.utc(2026, 9, 20), value: 1250.5),
      ]);
    });
  });

  group('gradePyramid', () {
    test('counts boulder grades, numeric-desc; routes filtered + counted', () {
      final p = gradePyramid([
        {'grade': 'v5'},
        {'grade': 'V5'}, // case folds into v5
        {'grade': 'v3'},
        {'grade': 'v10'}, // numeric sort, not lexicographic (v10 > v5)
        {'grade': 'vIntro'}, // non-numeric v-grade → below the numerics
        {'grade': '5.12a'}, // route → excluded
        {'grade': ''}, // blank → ignored entirely
        {},
      ]);
      expect(p.bars, [
        (label: 'v10', count: 1),
        (label: 'v5', count: 2),
        (label: 'v3', count: 1),
        (label: 'vIntro', count: 1),
      ]);
      expect(p.routesExcluded, 1);
    });
  });

  group('sessionsPerWeek', () {
    test('distinct session days per ISO week, zero-filled, last N weeks', () {
      // 2026-09-21 is a Monday.
      final s = sessionsPerWeek([
        {'date': '2026-09-21'},
        {'date': '2026-09-21'}, // same day twice → one session
        {'date': '2026-09-18'},
        {'date': '2026-09-15'},
        {'date': '2026-09-08'},
        {'date': '2020-01-01'}, // far outside the window → ignored
      ], today: DateTime(2026, 9, 21), weeks: 4);
      expect(s, [
        (day: DateTime.utc(2026, 8, 31), value: 0.0),
        (day: DateTime.utc(2026, 9, 7), value: 1.0),
        (day: DateTime.utc(2026, 9, 14), value: 2.0),
        (day: DateTime.utc(2026, 9, 21), value: 1.0),
      ]);
    });

    test('mid-week today buckets into the current ISO week', () {
      final s = sessionsPerWeek(
        [
          {'date': '2026-09-17'}, // Thursday same week as today (Fri 9/18)
        ],
        today: DateTime(2026, 9, 18),
        weeks: 2,
      );
      expect(s, [
        (day: DateTime.utc(2026, 9, 7), value: 0.0),
        (day: DateTime.utc(2026, 9, 14), value: 1.0),
      ]);
    });
  });

  group('maxPerDaySeries', () {
    test('max value per day; blanks, non-numerics, zeros skipped', () {
      final s = maxPerDaySeries([
        {'date': '2026-09-10', 'max_hr': 190},
        {'date': '2026-09-10', 'max_hr': '195'},
        {'date': '2026-09-10', 'max_hr': ''},
        {'date': '2026-09-17', 'max_hr': 0}, // zero → not a reading
        {'date': '2026-09-17', 'max_hr': 191.0},
        {'date': '2026-09-12'}, // no reading that day → omitted
      ], valueKey: 'max_hr');
      expect(s, [
        (day: DateTime.utc(2026, 9, 10), value: 195.0),
        (day: DateTime.utc(2026, 9, 17), value: 191.0),
      ]);
    });
  });

  group('computeMetric', () {
    final strengthRows = [
      row('Barbell Squat', 315, 3, '2026-09-01'),
      row('Barbell Squat', 365, 1, '2024-01-01'), // old all-time weight PR
      row('Flat Barbell Bench Press', 225, 5, '2026-09-10'),
      row('Barbell Deadlift', 405, 2, '2026-09-05'),
      row('Overhead Press', 125, 6, '2026-09-08'),
    ];
    final inputs = DomainMetricInputs(strengthRows: strengthRows, today: today);

    test('pl_total sums all-time best capped e1RMs', () {
      final d =
          computeMetric(const MetricConfig(id: 'pl_total', unit: 'lb'), inputs)
              as MetricStats;
      final expected = e1rm(365, 1) + // squat all-time (old PR)
          e1rm(225, 5) +
          e1rm(405, 2) +
          e1rm(125, 6);
      expect(d.stats.single.label, 'total');
      expect(d.stats.single.value, '${expected.round()} lb');
      expect(d.note, isNull);
    });

    test('e1rm_reference is per-lift, 42-day windowed (old PR excluded)', () {
      final d = computeMetric(
        const MetricConfig(
          id: 'e1rm_reference',
          unit: 'lb',
          lifts: ['squat', 'bench', 'deadlift', 'press'],
        ),
        inputs,
      ) as MetricStats;
      expect(d.stats.map((s) => s.label), ['squat', 'bench', 'deadlift', 'press']);
      // squat ref comes from the recent 315x3, not the 2024 365x1.
      expect(d.stats.first.value, '${e1rm(315, 3).round()} lb');
    });

    test('all_time_best_weight is the actual bar weight', () {
      final d = computeMetric(
        const MetricConfig(id: 'all_time_best_weight', unit: 'lb'),
        inputs,
      ) as MetricStats;
      expect(
        {for (final s in d.stats) s.label: s.value},
        {
          'squat': '365 lb',
          'bench': '225 lb',
          'deadlift': '405 lb',
          'press': '125 lb',
        },
      );
    });

    test('bw_series carries points, 7-day avg, and the goal line', () {
      final daily = [
        for (var i = 0; i < 10; i++)
          WeightRow(
            date: DateTime.utc(2026, 9, 1 + i),
            weightLbs: 165.0 - i * 0.1,
          ),
      ];
      final d = computeMetric(
        const MetricConfig(id: 'bw_series', unit: 'lb', goal: 154),
        DomainMetricInputs(weightDaily: daily, today: today),
      ) as MetricSeries;
      expect(d.points, hasLength(10));
      expect(d.avg, hasLength(10));
      expect(d.goal, 154);
      expect(d.unit, 'lb');
      // Trailing avg of the first point is itself.
      expect(d.avg.first.value, closeTo(165.0, 1e-9));
    });

    test('bf_series reads the body-fat columns', () {
      final d = computeMetric(
        const MetricConfig(id: 'bf_series', unit: '%'),
        DomainMetricInputs(
          records: [
            {'date': '2026-09-01', 'body_fat_omron': 19.5},
          ],
          today: today,
        ),
      ) as MetricSeries;
      expect(d.points.single.value, 19.5);
    });

    test('kcal_series sums calories per day off eaten_at', () {
      final d = computeMetric(
        const MetricConfig(id: 'kcal_series', unit: 'kcal'),
        DomainMetricInputs(
          records: [
            {'eaten_at': '2026-09-20 08:00:00', 'calories': 500},
            {'eaten_at': '2026-09-20 20:00:00', 'calories': 700},
          ],
          today: today,
        ),
      ) as MetricSeries;
      expect(d.points.single, (day: DateTime.utc(2026, 9, 20), value: 1200.0));
      expect(d.unit, 'kcal');
      expect(d.bandLow, isNull);
    });

    test('protein_series carries the g/lb band scaled by current 7d-avg bw',
        () {
      final daily = [
        for (var i = 0; i < 7; i++)
          WeightRow(date: DateTime.utc(2026, 9, 10 + i), weightLbs: 160),
      ];
      final d = computeMetric(
        const MetricConfig(
          id: 'protein_series',
          unit: 'g',
          goalBandPerLb: (low: 0.8, high: 1.0),
        ),
        DomainMetricInputs(
          records: [
            {'eaten_at': '2026-09-20 08:00:00', 'protein_g': 42.5},
          ],
          weightDaily: daily,
          today: today,
        ),
      ) as MetricSeries;
      expect(d.points.single.value, 42.5);
      expect(d.bandLow, closeTo(128, 1e-9)); // 0.8 × 160
      expect(d.bandHigh, closeTo(160, 1e-9)); // 1.0 × 160
    });

    test('protein_series without weigh-ins still plots, just bandless', () {
      final d = computeMetric(
        const MetricConfig(
          id: 'protein_series',
          goalBandPerLb: (low: 0.8, high: 1.0),
        ),
        DomainMetricInputs(
          records: [
            {'eaten_at': '2026-09-20 08:00:00', 'protein_g': 40},
          ],
          today: today,
        ),
      ) as MetricSeries;
      expect(d.points, hasLength(1));
      expect(d.bandLow, isNull);
      expect(d.bandHigh, isNull);
    });

    test('grade_pyramid renders bars with a routes-excluded note', () {
      final d = computeMetric(
        const MetricConfig(id: 'grade_pyramid'),
        DomainMetricInputs(
          records: [
            {'grade': 'v5'},
            {'grade': 'v3'},
            {'grade': 'v3'},
            {'grade': '5.12a'},
          ],
          today: today,
        ),
      ) as MetricBars;
      expect(d.bars, [
        (label: 'v5', count: 1),
        (label: 'v3', count: 2),
      ]);
      expect(d.note, '1 route not shown');
    });

    test('session_frequency is a weekly series with the config goal', () {
      final d = computeMetric(
        const MetricConfig(id: 'session_frequency', goal: 2),
        DomainMetricInputs(
          records: [
            {'date': '2026-09-21'},
            {'date': '2026-09-18'},
          ],
          today: today,
        ),
      ) as MetricSeries;
      expect(d.points, hasLength(12)); // 12 ISO weeks, zero-filled
      expect(d.points.last, (day: DateTime.utc(2026, 9, 21), value: 1.0));
      expect(d.points[10], (day: DateTime.utc(2026, 9, 14), value: 1.0));
      expect(d.goal, 2);
    });

    test('hr_4x4_series is per-session max HR over time', () {
      final d = computeMetric(
        const MetricConfig(id: 'hr_4x4_series', unit: 'bpm'),
        DomainMetricInputs(
          records: [
            {'date': '2026-09-10', 'max_hr': 195},
            {'date': '2026-09-17', 'max_hr': 191},
          ],
          today: today,
        ),
      ) as MetricSeries;
      expect(d.points, hasLength(2));
      expect(d.points.last.value, 191);
    });

    test('wilks stat: SBD-only total at weekly bodyweight', () {
      final daily = [
        WeightRow(date: DateTime(2026, 9, 14), weightLbs: 165),
        WeightRow(date: DateTime(2026, 9, 16), weightLbs: 163),
      ];
      final d = computeMetric(
        const MetricConfig(id: 'wilks'),
        DomainMetricInputs(
          strengthRows: strengthRows,
          weightDaily: daily,
          today: today,
        ),
      ) as MetricStats;
      // All sets fall in weeks of Aug 31 / Sep 7; bw first appears in
      // the week of Sep 14, so that week (all lifts carried) is the
      // first computable point, carried into today's week of Sep 21.
      final total = e1rm(315, 3) + e1rm(225, 5) + e1rm(405, 2);
      final expected =
          total * kgPerLb * wilks2020MaleCoeff(164 * kgPerLb);
      expect(d.stats.single.label, 'Wilks (SBD)');
      expect(d.stats.single.value, expected.toStringAsFixed(1));
      expect(d.note, contains('@ 164.0 lb bw'));
      expect(d.note, contains('carried: squat, bench, deadlift'));
    });

    test('wilks_series clips to `from` and anchors the reference there',
        () {
      final daily = [
        for (var i = 0; i < 21; i++)
          WeightRow(date: DateTime(2026, 9, 1 + i), weightLbs: 164),
      ];
      final d = computeMetric(
        MetricConfig(id: 'wilks_series', from: DateTime(2026, 9, 14)),
        DomainMetricInputs(
          strengthRows: strengthRows,
          weightDaily: daily,
          today: today,
        ),
      ) as MetricSeries;
      // `from` anchors the reference only — the series keeps the full
      // computable history (Wilks is a career-scale trend; the dashed
      // reference marks the cut-start value to compare it against).
      final fromWeeks =
          d.points.where((p) => !p.day.isBefore(DateTime(2026, 9, 14)));
      expect(fromWeeks, hasLength(2));
      expect(d.points.length, greaterThanOrEqualTo(2),
          reason: 'pre-from history must survive');
      final refWeek =
          d.points.lastWhere((p) => !p.day.isAfter(DateTime(2026, 9, 14)));
      expect(d.goal, closeTo(refWeek.value, 1e-9));
    });

    test('wilks without weigh-ins degrades honestly', () {
      expect(
        computeMetric(
          const MetricConfig(id: 'wilks'),
          DomainMetricInputs(strengthRows: strengthRows, today: today),
        ),
        isA<MetricUnavailable>(),
      );
    });

    test('empty inputs degrade to MetricUnavailable', () {
      final empty = DomainMetricInputs(today: today);
      for (final id in [
        'pl_total',
        'wilks',
        'wilks_series',
        'e1rm_reference',
        'all_time_best_weight',
        'bw_series',
        'bf_series',
        'kcal_series',
        'protein_series',
        'grade_pyramid',
        'session_frequency',
        'hr_4x4_series',
      ]) {
        expect(
          computeMetric(MetricConfig(id: id), empty),
          isA<MetricUnavailable>(),
          reason: id,
        );
      }
    });

    test('unknown ids are placeholders, not errors', () {
      expect(
        computeMetric(const MetricConfig(id: 'made_up_metric'), inputs),
        isA<MetricUnavailable>(),
      );
    });
  });
}
