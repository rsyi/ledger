import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_metrics.dart';
import 'package:airledger/services/program_observed.dart';

WeightRow w(String date, double lbs) =>
    WeightRow(date: DateTime.parse(date), weightLbs: lbs);

void main() {
  group('sevenDayAvgSeries', () {
    test('averages the trailing 7 days ending on each point', () {
      final daily = [
        w('2026-09-01', 160),
        w('2026-09-02', 162),
        w('2026-09-03', 158),
      ];
      final series = sevenDayAvgSeries(daily);
      expect(series.length, 3);
      expect(series[0].weightLbs, 160);
      expect(series[1].weightLbs, closeTo(161, 1e-9));
      expect(series[2].weightLbs, closeTo(160, 1e-9));
    });

    test('drops points older than 7 days from the window', () {
      final daily = [
        w('2026-09-01', 100), // 8 days before Sep 9 — outside the window
        w('2026-09-03', 160),
        w('2026-09-09', 162),
      ];
      final series = sevenDayAvgSeries(daily);
      // Window for Sep 9 = Sep 3..Sep 9 inclusive → (160+162)/2.
      expect(series.last.weightLbs, closeTo(161, 1e-9));
    });

    test('sorts unsorted input by date', () {
      final daily = [
        w('2026-09-03', 158),
        w('2026-09-01', 160),
      ];
      final series = sevenDayAvgSeries(daily);
      expect(series.first.date, DateTime.parse('2026-09-01'));
      expect(series.last.weightLbs, closeTo(159, 1e-9));
    });

    test('empty input → empty output', () {
      expect(sevenDayAvgSeries(const []), isEmpty);
    });
  });

  group('targetLineValue', () {
    final start = DateTime.utc(2026, 9, 21);
    final end = DateTime.utc(2026, 12, 13);

    test('start of block → from', () {
      expect(
        targetLineValue(day: start, start: start, end: end, from: 163, to: 154),
        163,
      );
    });

    test('end of block → to', () {
      expect(
        targetLineValue(day: end, start: start, end: end, from: 163, to: 154),
        154,
      );
    });

    test('midpoint interpolates linearly', () {
      // 83 days total; day 41.5 doesn't exist — use exact fractions instead.
      final quarter = start.add(const Duration(days: 41)); // t = 41/83
      final v = targetLineValue(
          day: quarter, start: start, end: end, from: 163, to: 154);
      expect(v, closeTo(163 + (154 - 163) * 41 / 83, 1e-9));
    });

    test('clamps outside the block', () {
      expect(
        targetLineValue(
            day: start.subtract(const Duration(days: 10)),
            start: start,
            end: end,
            from: 163,
            to: 154),
        163,
      );
      expect(
        targetLineValue(
            day: end.add(const Duration(days: 10)),
            start: start,
            end: end,
            from: 163,
            to: 154),
        154,
      );
    });

    test('zero-length block → from', () {
      expect(
        targetLineValue(day: start, start: start, end: start, from: 160, to: 160),
        160,
      );
    });
  });

  group('observedWeightStats', () {
    test('empty data → all-null stats', () {
      final s = observedWeightStats(const [], DateTime.utc(2026, 9, 21));
      expect(s.bw7dAvg, isNull);
      expect(s.bwRateLbWk, isNull);
      expect(s.bw3wkChange, isNull);
      expect(s.recentRates, isEmpty);
      expect(s.lastWeighIn, isNull);
    });

    test('linear decline yields the decline rate via weekly rollup', () {
      // 168 → declining 0.1 lb/day (0.7 lb/wk) for 5 weeks of daily data.
      // Aug 17 2026 is a Monday; today = Sunday Sep 20.
      final start = DateTime.utc(2026, 8, 17);
      final daily = [
        for (var i = 0; i < 35; i++)
          WeightRow(
            date: start.add(Duration(days: i)),
            weightLbs: 168 - 0.1 * i,
          ),
      ];
      final today = DateTime.utc(2026, 9, 20);
      final s = observedWeightStats(daily, today);
      // Trailing 7 days ending Sep 20 = indices 28..34 → mean of 165.2..164.6.
      expect(s.bw7dAvg, closeTo(164.9, 1e-9));
      // Week-over-week 7d-avg delta on a perfect line = 7 * 0.1 = 0.7 down.
      expect(s.bwRateLbWk, closeTo(-0.7, 1e-9));
      expect(s.bw3wkChange, closeTo(-2.1, 1e-9));
      expect(s.recentRates.length, 3);
      expect(s.recentRates.last, closeTo(-0.7, 1e-9));
      expect(s.lastWeighIn, DateTime.utc(2026, 9, 20));
    });

    test('bw7dAvg is trailing-today even mid-week', () {
      final daily = [
        w('2026-09-14', 165), // Monday
        w('2026-09-15', 164),
      ];
      // Tuesday: trailing window = Sep 9..15.
      final s = observedWeightStats(daily, DateTime.utc(2026, 9, 15));
      expect(s.bw7dAvg, closeTo(164.5, 1e-9));
    });
  });

  group('phaseVerdict — cut', () {
    PhaseVerdict v({List<double?> rates = const [], double? chg3}) =>
        phaseVerdict(
          phase: 'cut',
          targetRateLbWk: -0.75,
          recentRates: rates,
          bw3wkChange: chg3,
        );

    test('no data → unknown', () {
      final r = v();
      expect(r.state, VerdictState.unknown);
      expect(r.label, 'not enough weigh-in data');
      expect(r.observedRateLbWk, isNull);
    });

    test('on pace: observed at or below target', () {
      final r = v(rates: [-0.8, -0.7, -0.8], chg3: -2.4);
      expect(r.state, VerdictState.agree);
      expect(r.label, 'cutting, on pace');
      expect(r.observedRateLbWk, closeTo(-0.8, 1e-9));
    });

    test('slightly slow: between target and half target (user example)', () {
      // -0.5 lb/wk observed vs -0.75 target → agree, slightly slow.
      final r = v(rates: [-0.4, -0.6, -0.5], chg3: -1.5);
      expect(r.state, VerdictState.agree);
      expect(r.label, 'cutting, slightly slow');
      expect(r.observedRateLbWk, closeTo(-0.5, 1e-9));
    });

    test('too slow: below half target but still moving down', () {
      final r = v(rates: [-0.2, -0.1, -0.3], chg3: -0.6);
      expect(r.state, VerdictState.drift);
      expect(r.label, 'cutting, too slow');
    });

    test('stalled: scale flat', () {
      final r = v(rates: [0.0, 0.1, -0.1], chg3: 0.0);
      expect(r.state, VerdictState.drift);
      expect(r.label, 'stalled — scale is flat');
    });

    test('gaining but not yet 3 weeks → drift', () {
      final r = v(rates: [-0.3, 0.3, 0.4], chg3: 0.9);
      expect(r.state, VerdictState.drift);
      expect(r.label, 'gaining — mismatch fires after 3 weeks');
    });

    test('three consecutive mismatch weeks → mismatch (PHASE_MISMATCH)', () {
      final r = v(rates: [0.2, 0.3, 0.4], chg3: 0.9);
      expect(r.state, VerdictState.mismatch);
      expect(r.label, 'gaining — PHASE_MISMATCH would fire');
    });

    test('observed rate falls back to latest weekly rate without chg3', () {
      final r = v(rates: [null, null, -0.6]);
      expect(r.observedRateLbWk, closeTo(-0.6, 1e-9));
      expect(r.state, VerdictState.agree);
    });
  });

  group('phaseVerdict — bulk / maintain', () {
    test('bulk mirrors cut', () {
      final on = phaseVerdict(
        phase: 'bulk',
        targetRateLbWk: 0.4,
        recentRates: const [0.4, 0.5, 0.4],
        bw3wkChange: 1.3,
      );
      expect(on.state, VerdictState.agree);
      expect(on.label, 'gaining, on pace');

      final losing = phaseVerdict(
        phase: 'bulk',
        targetRateLbWk: 0.4,
        recentRates: const [-0.2, -0.3, -0.2],
        bw3wkChange: -0.7,
      );
      expect(losing.state, VerdictState.mismatch);
      expect(losing.label, 'losing — PHASE_MISMATCH would fire');
    });

    test('maintain: steady vs drifting', () {
      final steady = phaseVerdict(
        phase: 'maintain',
        recentRates: const [0.1, -0.1, 0.0],
        bw3wkChange: 0.2,
      );
      expect(steady.state, VerdictState.agree);
      expect(steady.label, 'holding steady');

      final drifting = phaseVerdict(
        phase: 'maintain',
        recentRates: const [0.6, 0.7, 0.6],
        bw3wkChange: 1.9,
      );
      expect(drifting.state, VerdictState.mismatch);
      expect(drifting.label, 'drifting off maintenance');
    });
  });
}
