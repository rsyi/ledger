import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/domain_config.dart';
import 'package:airledger/services/domain_metrics.dart';
import 'package:airledger/services/program_metrics.dart';

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
          weightRecords: [
            {'date': '2026-09-01', 'body_fat_omron': 19.5},
          ],
          today: today,
        ),
      ) as MetricSeries;
      expect(d.points.single.value, 19.5);
    });

    test('empty inputs degrade to MetricUnavailable', () {
      final empty = DomainMetricInputs(today: today);
      for (final id in [
        'pl_total',
        'e1rm_reference',
        'all_time_best_weight',
        'bw_series',
        'bf_series',
      ]) {
        expect(
          computeMetric(MetricConfig(id: id), empty),
          isA<MetricUnavailable>(),
          reason: id,
        );
      }
    });

    test('P3 vocabulary and unknown ids are placeholders, not errors', () {
      for (final id in [
        'kcal_series',
        'protein_series',
        'grade_pyramid',
        'session_frequency',
        'hr_4x4_series',
        'made_up_metric',
      ]) {
        expect(
          computeMetric(MetricConfig(id: id), inputs),
          isA<MetricUnavailable>(),
          reason: id,
        );
      }
    });
  });
}
