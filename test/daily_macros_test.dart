import 'package:airledger/services/daily_macros.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildDailyMacros', () {
    test('protein below floor → low; met → good', () {
      final low = buildDailyMacros(
        proteinEaten: 95, proteinFloor: 160,
        carbsEaten: 0, fatEaten: 0, kcalEaten: 1240,
      );
      expect(low[0].label, 'Protein');
      expect(low[0].state, MacroState.low);
      expect(low[0].fraction, closeTo(95 / 160, 1e-9));

      final met = buildDailyMacros(
        proteinEaten: 170, proteinFloor: 160,
        carbsEaten: 0, fatEaten: 0, kcalEaten: 2000,
      );
      expect(met[0].state, MacroState.good);
      expect(met[0].fraction, 1.0); // clamped
    });

    test('no target in force → none, bar empty', () {
      final bars = buildDailyMacros(
        proteinEaten: 50, proteinFloor: null,
        carbsEaten: 100, carbsFloor: null,
        fatEaten: 20, fatMin: null,
        kcalEaten: 800, maintenanceKcal: null,
      );
      for (final b in bars) {
        expect(b.state, MacroState.none);
        expect(b.fraction, 0);
      }
    });

    test('calories deficit: good under maintenance, high over it', () {
      final under = buildDailyMacros(
        proteinEaten: 0, carbsEaten: 0, fatEaten: 0,
        kcalEaten: 1800, maintenanceKcal: 2400, calorieMode: 'deficit',
      );
      expect(under[3].label, 'Calories');
      expect(under[3].state, MacroState.good);

      final over = buildDailyMacros(
        proteinEaten: 0, carbsEaten: 0, fatEaten: 0,
        kcalEaten: 2800, maintenanceKcal: 2400, calorieMode: 'deficit',
      );
      expect(over[3].state, MacroState.high);
    });

    test('calories surplus: good at/above maintenance', () {
      final bars = buildDailyMacros(
        proteinEaten: 0, carbsEaten: 0, fatEaten: 0,
        kcalEaten: 2600, maintenanceKcal: 2400, calorieMode: 'surplus',
      );
      expect(bars[3].state, MacroState.good);
    });

    test('nothing logged yet → all none even with targets', () {
      final bars = buildDailyMacros(
        proteinEaten: 0, proteinFloor: 160,
        carbsEaten: 0, carbsFloor: 225,
        fatEaten: 0, fatMin: 55,
        kcalEaten: 0, maintenanceKcal: 2400, calorieMode: 'deficit',
      );
      for (final b in bars) {
        expect(b.state, MacroState.none);
      }
    });
  });
}
