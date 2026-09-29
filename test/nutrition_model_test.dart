// Unit tests for lib/services/nutrition_model.dart — the adaptive
// maintenance estimate + nutrition-derived forecast inputs (user
// directive 2026-09-28: nutrition is THE lever).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/nutrition_model.dart';
import 'package:airledger/services/program_metrics.dart' show WeightRow;
import 'package:airledger/services/recomp_review.dart' show MealRow;

final _today = DateTime.utc(2026, 9, 28);

MealRow meal(DateTime day, double kcal,
        {double protein = 150, double carbs = 250, double fat = 60}) =>
    MealRow(
      eatenAt: DateTime.utc(day.year, day.month, day.day, 12),
      calories: kcal,
      proteinG: protein,
      carbsG: carbs,
      fatG: fat,
    );

/// [days] full logging days ending today: one meal per day at [kcal].
List<MealRow> mealsAt(double kcal,
    {int days = 14, double protein = 150, double carbs = 250}) => [
      for (var i = 0; i < days; i++)
        meal(_today.subtract(Duration(days: i)), kcal,
            protein: protein, carbs: carbs),
    ];

/// Daily weigh-ins with a constant trend rate (lb/day), ending today.
List<WeightRow> weighInsAtRate(double lbPerDay,
    {double endLb = 160, int days = 60}) => [
      for (var i = days; i >= 0; i--)
        WeightRow(
          date: _today.subtract(Duration(days: i)),
          weightLbs: endLb - lbPerDay * i,
        ),
    ];

void main() {
  group('nutritionDays', () {
    test('sums meals per calendar day, ascending', () {
      final d = _today;
      final days = nutritionDays([
        meal(d, 600, protein: 40, carbs: 70),
        meal(d, 900, protein: 60, carbs: 100),
        meal(d.subtract(const Duration(days: 1)), 2000),
      ]);
      expect(days, hasLength(2));
      expect(days.last.day, DateTime.utc(2026, 9, 28));
      expect(days.last.kcal, 1500);
      expect(days.last.proteinG, 100);
      expect(days.last.carbsG, 170);
      expect(days.first.kcal, 2000);
    });

    test('completeness floor: tiny days are not logged days', () {
      expect(
        isLoggedDay(NutritionDay(
            day: _today, kcal: 300, proteinG: 20, carbsG: 30, fatG: 10)),
        isFalse,
      );
    });
  });

  group('nutritionWindowAvg', () {
    test('averages logged days only; missing days are absent, not zero',
        () {
      // 4 logged days + 1 partial in the last 7 — the partial is
      // excluded and the average is over the 4 real days.
      final meals = [
        for (var i = 0; i < 4; i++)
          meal(_today.subtract(Duration(days: i)), 2000 + 100.0 * i),
        meal(_today.subtract(const Duration(days: 5)), 200), // partial
      ];
      final avg = nutritionWindowAvg(nutritionDays(meals),
          today: _today, windowDays: 7)!;
      expect(avg.loggedDays, 4);
      expect(avg.kcal, closeTo(2150, 0.01));
    });

    test('null when nothing logged in the window', () {
      final meals = [meal(_today.subtract(const Duration(days: 30)), 2200)];
      expect(
        nutritionWindowAvg(nutritionDays(meals),
            today: _today, windowDays: 7),
        isNull,
      );
    });
  });

  group('estimateMaintenance', () {
    test('flat weight at steady intake → maintenance ≈ intake', () {
      final est = estimateMaintenance(
        days: nutritionDays(mealsAt(2400)),
        weighIns: weighInsAtRate(0),
        today: _today,
      )!;
      expect(est.kcal, closeTo(2400, 1));
      expect(est.method, 'energy_balance'); // < 21 pairs
      expect(est.bandKcal, greaterThanOrEqualTo(100));
    });

    test('losing 0.1 lb/day at 2000 kcal → maintenance ≈ 2350', () {
      // ΔW = −0.1 lb/day ⇒ m = 2000 − 3500·(−0.1) = 2350.
      final est = estimateMaintenance(
        days: nutritionDays(mealsAt(2000)),
        weighIns: weighInsAtRate(-0.1),
        today: _today,
      )!;
      expect(est.kcal, closeTo(2350, 5));
    });

    test('regression method kicks in with ≥ 21 varied days and a sane β',
        () {
      // 28 days alternating 1800/2600 around maintenance 2500 with the
      // exact energy-balance response ⇒ regression recovers it.
      const m = 2500.0;
      final meals = <MealRow>[];
      final weights = <WeightRow>[];
      var w = 162.0;
      for (var i = 28; i >= 0; i--) {
        final day = _today.subtract(Duration(days: i));
        final kcal = i.isEven ? 1800.0 : 2600.0;
        meals.add(meal(day, kcal));
        weights.add(WeightRow(date: day, weightLbs: w));
        w += (kcal - m) / kcalPerLb;
      }
      // Use the raw weigh-ins as their own trend proxy is smoothed by
      // sevenDayAvgSeries; the recovered maintenance stays within the
      // band of the true value.
      final est = estimateMaintenance(
        days: nutritionDays(meals),
        weighIns: weights,
        today: _today,
      )!;
      expect(est.pairedDays, greaterThanOrEqualTo(21));
      expect(est.kcal, closeTo(m, est.bandKcal + 100));
    });

    test('null under minPairedDays — honest no-data', () {
      expect(
        estimateMaintenance(
          days: nutritionDays(mealsAt(2200, days: 3)),
          weighIns: weighInsAtRate(0),
          today: _today,
        ),
        isNull,
      );
      // No weigh-ins at all → null too.
      expect(
        estimateMaintenance(
          days: nutritionDays(mealsAt(2200)),
          weighIns: const [],
          today: _today,
        ),
        isNull,
      );
    });

    test('partial-log days are excluded from pairing', () {
      final meals = [
        ...mealsAt(2400, days: 6),
        meal(_today.subtract(const Duration(days: 6)), 150), // partial
      ];
      final est = estimateMaintenance(
        days: nutritionDays(meals),
        weighIns: weighInsAtRate(0),
        today: _today,
      )!;
      // 6 logged days minus today (no d+1 trend yet) = 5 pairs; the
      // partial day never pairs.
      expect(est.pairedDays, 5);
      expect(est.kcal, closeTo(2400, 1));
    });
  });

  group('NutritionForecast', () {
    NutritionForecast forecast({double delta = 0}) => buildNutritionForecast(
          meals: mealsAt(2100, protein: 160, carbs: 240),
          weighIns: weighInsAtRate(-0.05),
          today: _today,
          calorieDelta: delta,
        );

    test('projects r from intake vs maintenance', () {
      final f = forecast();
      // maintenance = 2100 + 3500·0.05 = 2275; r = (2100−2275)/3500×7 =
      // −0.35 lb/wk.
      expect(f.maintenance!.kcal, closeTo(2275, 5));
      expect(f.rProjectedLbWk!, closeTo(-0.35, 0.02));
      expect(f.rCurrentLbWk, f.rProjectedLbWk);
      expect(f.avg7!.kcal, closeTo(2100, 1));
      expect(f.avg14!.proteinG, closeTo(160, 1));
    });

    test('calorie delta is the one lever: shifts r, scales macros '
        'proportionally, leaves actuals alone', () {
      final f = forecast(delta: 350);
      expect(f.rProjectedLbWk!, closeTo(-0.35 + 0.7, 0.02));
      expect(f.rCurrentLbWk!, closeTo(-0.35, 0.02)); // actuals untouched
      expect(f.avg14!.kcal, closeTo(2100, 1));
      final scale = (2100 + 350) / 2100;
      expect(f.projectedProteinG!, closeTo(160 * scale, 0.5));
      expect(f.projectedCarbsG!, closeTo(240 * scale, 0.5));
      expect(f.proteinGPerLb(160)!, closeTo(160 * scale / 160, 0.01));
    });

    test('recalibration maintenance offset shifts the projection', () {
      final f = forecast().withMaintenanceOffset(175);
      // Maintenance 2275 + 175 = 2450 → r = (2100−2450)/3500×7 = −0.7.
      expect(f.effectiveMaintenanceKcal!, closeTo(2450, 5));
      expect(f.rProjectedLbWk!, closeTo(-0.7, 0.02));
      // The raw estimate stays untouched (provenance).
      expect(f.maintenance!.kcal, closeTo(2275, 5));
    });

    test('withDelta round-trips', () {
      final f = forecast().withDelta(-200);
      expect(f.calorieDelta, -200);
      expect(f.rProjectedLbWk!, closeTo(-0.35 - 0.4, 0.02));
    });

    test('no meals → nothing projects, nothing throws', () {
      final f = buildNutritionForecast(
        meals: const [],
        weighIns: weighInsAtRate(0),
        today: _today,
      );
      expect(f.canProject, isFalse);
      expect(f.rProjectedLbWk, isNull);
      expect(f.projectedProteinG, isNull);
      expect(f.proteinGPerLb(160), isNull);
    });
  });

  group('mealRowsFromRecords', () {
    test('parses repo records, skipping undated rows', () {
      final rows = mealRowsFromRecords([
        {
          'eaten_at': '2026-09-28T08:30:00',
          'calories': 650,
          'protein_g': '42.5',
          'carbs_g': 80,
          'fat_g': null,
        },
        {'calories': 500}, // no date → skipped
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.calories, 650);
      expect(rows.single.proteinG, 42.5);
      expect(rows.single.fatG, isNull);
    });
  });
}
