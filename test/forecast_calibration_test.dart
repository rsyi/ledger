// Unit tests for lib/services/forecast_calibration.dart — the
// replay-based tracking check, the guarded refit (±50% drift guard)
// and the forecast_meta codec.
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/forecast_calibration.dart';
import 'package:airledger/services/program_metrics.dart' show WeightRow;
import 'package:airledger/services/sim2_harness.dart';
import 'package:airledger/services/sim2_model.dart';

final _today = DateTime.utc(2026, 11, 16); // a Monday, 8 wks into the cut

List<WeightRow> weighInsAtRate(double lbPerDay,
    {double endLb = 158, int days = 120}) => [
      for (var i = days; i >= 0; i--)
        WeightRow(
          date: _today.subtract(Duration(days: i)),
          weightLbs: endLb - lbPerDay * i,
        ),
    ];

void main() {
  group('sim2ExtendSteadyState', () {
    test('appends ONE flat recomp continuation block — no cycles', () {
      final blocks = sim2DefaultBlocks();
      final ext = sim2ExtendSteadyState(blocks, extraWeeks: 52);
      expect(ext.length, blocks.length + 1);
      final cont = ext.last;
      expect(cont.emphasis, 'lifting');
      expect(cont.r, sim2RecompR);
      expect(cont.start, blocks.last.end.add(const Duration(days: 1)));
      expect(cont.end, blocks.last.end.add(const Duration(days: 364)));
      expect(cont.n, blocks.last.n + 1);
      // The sim runs clean over the extended calendar.
      final run = sim2Run(
        params: Sim2Params.fitted(),
        blocks: ext,
        start: sim2StartMonday(DateTime.utc(2026, 9, 28)),
      );
      expect(run.weeks.last.monday.isAfter(blocks.last.end), isTrue);
    });

    test('no-ops on empty or zero extension', () {
      expect(sim2ExtendSteadyState(const [], extraWeeks: 52), isEmpty);
      final blocks = sim2DefaultBlocks();
      expect(sim2ExtendSteadyState(blocks, extraWeeks: 0), same(blocks));
    });
  });

  group('bw7dAvgAt', () {
    test('averages the trailing week; null when empty', () {
      final daily = weighInsAtRate(0, endLb: 160, days: 10);
      expect(bw7dAvgAt(daily, _today), closeTo(160, 0.001));
      expect(bw7dAvgAt(const [], _today), isNull);
      expect(
        bw7dAvgAt(daily, _today.subtract(const Duration(days: 60))),
        isNull,
      );
    });
  });

  group('calibrateForecast', () {
    final params = Sim2Params.fitted();
    final blocks = sim2DefaultBlocks();

    test('tracking on-band: actuals following the predicted rate → no '
        'persistent error', () {
      // Replay r = −0.75 (the cut) and actuals losing ~0.75/wk
      // (negative rate: the helper's slope is lb gained per day).
      final cal = calibrateForecast(
        params: params,
        blocks: blocks,
        dailyWeighIns: weighInsAtRate(-0.75 / 7),
        observedIndexByMonday: const {},
        today: _today,
        rReplayLbWk: -0.75,
      )!;
      expect(cal.bw, isNotEmpty);
      expect(cal.bwPersistent, isFalse);
      expect(cal.strengthPersistent, isFalse); // no strength actuals
    });

    test('persistent bw error: flat actuals under a cut prediction', () {
      final cal = calibrateForecast(
        params: params,
        blocks: blocks,
        dailyWeighIns: weighInsAtRate(0), // scale did not move
        observedIndexByMonday: const {},
        today: _today,
        rReplayLbWk: -0.75,
      )!;
      expect(cal.bwPersistent, isTrue,
          reason: 'predicted −0.75/wk vs flat actuals drifts past the '
              '1.25 lb band within 6 weeks');
      expect(cal.bwMae, greaterThan(1.25));
    });

    test('null when anchors are missing (pre-calendar or no weigh-ins)',
        () {
      expect(
        calibrateForecast(
          params: params,
          blocks: blocks,
          dailyWeighIns: const [],
          observedIndexByMonday: const {},
          today: _today,
        ),
        isNull,
      );
      expect(
        calibrateForecast(
          params: params,
          blocks: blocks,
          dailyWeighIns: weighInsAtRate(0),
          observedIndexByMonday: const {},
          today: DateTime.utc(2026, 9, 22), // < weeksBack into the plan
        ),
        isNull,
      );
    });
  });

  group('guardedRefit', () {
    ForecastCalibration cal({
      required List<WeeklyCheck> bw,
      required List<WeeklyCheck> strength,
    }) =>
        ForecastCalibration(
          bw: bw,
          strength: strength,
          bwBandLb: 1.25,
          strengthBandLb: 25,
          persistWeeks: 3,
        );

    DateTime m(int i) => DateTime.utc(2026, 10, 5 + 7 * i);

    test('no persistent error → identity', () {
      final r = guardedRefit(cal(bw: [
        WeeklyCheck(m(0), 160, 160.2),
        WeeklyCheck(m(1), 159.5, 159.4),
        WeeklyCheck(m(2), 159.0, 159.2),
      ], strength: const []));
      expect(r.any, isFalse);
      expect(r.aScale, 1);
      expect(r.maintenanceOffsetKcal, 0);
    });

    test('persistent strength error scales a/b by the progression '
        'ratio, clamped ±50%', () {
      // Predicted +12 lb over the window, actual −6 → raw ratio −0.5,
      // clamped to the 0.5 floor (the drift guard).
      final r = guardedRefit(cal(bw: const [], strength: [
        WeeklyCheck(m(0), 880, 850),
        WeeklyCheck(m(1), 886, 848),
        WeeklyCheck(m(2), 892, 846),
      ]));
      expect(r.moved, contains('capacity gain ×0.50'));
      expect(r.aScale, 0.5);
      expect(r.bScale, 0.5);
      // Applies onto a params copy.
      final p = Sim2Params.fitted();
      final adjusted = r.apply(p);
      expect(adjusted.a, closeTo(p.a * 0.5, 1e-9));
      expect(adjusted.b, closeTo(p.b * 0.5, 1e-9));
      expect(p.a, Sim2Params.fitted().a); // original untouched
    });

    test('near-flat predicted progression refuses to scale', () {
      final r = guardedRefit(cal(bw: const [], strength: [
        WeeklyCheck(m(0), 880, 850),
        WeeklyCheck(m(1), 881, 848),
        WeeklyCheck(m(2), 882, 846),
      ]));
      expect(r.any, isFalse, reason: 'predicted Δ 2 lb < minSlopeLb 4');
    });

    test('persistent bw error becomes a clamped maintenance offset', () {
      // Predicted losing 0.75/wk, actual flat → rate error −0.75 lb/wk
      // → offset −375 kcal (predicted rate BELOW actual ⇒ maintenance
      // was over-estimated ⇒ negative correction). Five checks so the
      // LAST three all clear the 1.25 band (persistence gate).
      final r = guardedRefit(cal(strength: const [], bw: [
        for (var i = 0; i < 5; i++)
          WeeklyCheck(m(i), 160 - 0.75 * i, 160),
      ]));
      expect(r.maintenanceOffsetKcal, closeTo(-375, 1));
      expect(r.moved.single, contains('maintenance -375 kcal'));

      // A huge error still clamps to ±500.
      final big = guardedRefit(cal(strength: const [], bw: [
        WeeklyCheck(m(0), 157, 162),
        WeeklyCheck(m(1), 154, 162),
        WeeklyCheck(m(2), 151, 162),
      ]));
      expect(big.maintenanceOffsetKcal, -500);
    });
  });

  group('ForecastMeta codec', () {
    test('round-trips through tab rows', () {
      final meta = ForecastMeta(
        generatedAt: DateTime.utc(2026, 9, 28, 23, 30),
        maintenanceKcal: 2410,
        maintenanceBandKcal: 180,
        maintenanceMethod: 'energy_balance',
        maintenancePairedDays: 6,
        intake14Kcal: 1980,
        protein14G: 168,
        carbs14G: 205,
        rProjectedLbWk: -0.86,
        tracking: 'adjusted',
        aScale: 0.8,
        bScale: 0.8,
        maintenanceOffsetKcal: -150,
        events: [
          RecalEvent(DateTime.utc(2026, 9, 28), 'capacity gain ×0.80'),
        ],
      );
      final tab = [forecastMetaHeaders, ...meta.toRows()];
      final back = ForecastMeta.fromTab(tab);
      expect(back.maintenanceKcal, 2410);
      expect(back.maintenanceMethod, 'energy_balance');
      expect(back.maintenancePairedDays, 6);
      expect(back.rProjectedLbWk, closeTo(-0.86, 1e-9));
      expect(back.adjusted, isTrue);
      expect(back.aScale, closeTo(0.8, 1e-9));
      expect(back.maintenanceOffsetKcal, -150);
      expect(back.events.single.what, 'capacity gain ×0.80');
      expect(back.lastEvent!.date, DateTime.utc(2026, 9, 28));
    });

    test('empty / malformed tab degrades to defaults', () {
      final meta = ForecastMeta.fromTab(const []);
      expect(meta.tracking, 'on');
      expect(meta.aScale, 1);
      expect(meta.events, isEmpty);
      final junk = ForecastMeta.fromTab([
        ['key', 'value'],
        ['events_json', 'not json'],
        ['tracking', 'garbage'],
      ]);
      expect(junk.events, isEmpty);
      expect(junk.tracking, 'on');
    });

    test('mergeRecalibration: adjustment prepends a deduped event and '
        'flips tracking; identity refit keeps history but reads on',
        () {
      const prev = ForecastMeta();
      final refit = RefitResult(
        aScale: 0.9,
        bScale: 0.9,
        moved: const ['capacity gain ×0.90'],
      );
      final adjusted = mergeRecalibration(
          previous: prev, refit: refit, today: _today);
      expect(adjusted.tracking, 'adjusted');
      expect(adjusted.events.single.what, 'capacity gain ×0.90');
      // Same night re-run: no duplicate event.
      final again = mergeRecalibration(
          previous: adjusted, refit: refit, today: _today);
      expect(again.events, hasLength(1));
      // Next night, back on-band: scales reset (non-cumulative), the
      // event history stays.
      final calm = mergeRecalibration(
          previous: again, refit: const RefitResult(), today: _today);
      expect(calm.tracking, 'on');
      expect(calm.aScale, 1);
      expect(calm.events, hasLength(1));
    });
  });

  group('observedIndexTotals', () {
    test('sums SBD when all present; skips gaps', () {
      final mondays = [DateTime.utc(2026, 10, 5), DateTime.utc(2026, 10, 12)];
      final out = observedIndexTotals(
        mondays: mondays,
        squat: [330, 332],
        bench: [244, null],
        deadlift: [342, 344],
      );
      expect(out, hasLength(1));
      expect(out[DateTime.utc(2026, 10, 5)], 916);
    });
  });
}
