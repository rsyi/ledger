/// Pure builder for the Today tab's daily-progress bars — calories + the
/// three macros, each as today's intake against its target. Day-scale by
/// design (macros are a daily input); the week-scale adherence lives on
/// the Week tab.
///
/// Targets arrive already resolved to absolute numbers (the caller prices
/// the cut's per-lb protein against bodyweight and reads maintenance from
/// the nutrition model) so this layer is pure formatting + state.
library;

/// Progress state for one bar, driving its colour.
enum MacroState {
  /// No target in force, or nothing logged yet — neutral.
  none,

  /// Below a floor target (protein/carbs/fat) or a surplus goal.
  low,

  /// In the good zone — floor met, or intake on the correct side of
  /// maintenance for the phase.
  good,

  /// Over the ceiling — calories above maintenance on a cut.
  high,
}

/// One daily-progress bar.
class MacroBar {
  final String label;

  /// Today's intake in [unit].
  final double current;

  /// The reference target (a floor for macros, maintenance for calories).
  /// Null when no target is in force — the bar shows the bare intake.
  final double? target;

  final String unit; // 'g' | 'kcal'
  final MacroState state;

  const MacroBar({
    required this.label,
    required this.current,
    required this.target,
    required this.unit,
    required this.state,
  });

  /// Bar fill fraction (0–1): intake toward the target, clamped. Zero
  /// when there is no usable target.
  double get fraction {
    final t = target;
    if (t == null || t <= 0) return 0;
    return (current / t).clamp(0.0, 1.0).toDouble();
  }
}

/// Builds the four daily bars in display order: Protein, Carbs, Fat,
/// Calories. All targets are absolute ([null] = not in force this phase).
///
/// [calorieMode]: 'deficit' (cut — good below maintenance), 'surplus'
/// (bulk — good at/above maintenance), or null/other (maintenance —
/// neutral once a target exists).
List<MacroBar> buildDailyMacros({
  required double proteinEaten,
  double? proteinFloor,
  required double carbsEaten,
  double? carbsFloor,
  required double fatEaten,
  double? fatMin,
  required double kcalEaten,
  double? maintenanceKcal,
  String? calorieMode,
}) {
  final anyIntake =
      kcalEaten > 0 || proteinEaten > 0 || carbsEaten > 0 || fatEaten > 0;

  MacroState floorState(double eaten, double? floor) {
    if (floor == null || floor <= 0 || !anyIntake) return MacroState.none;
    return eaten >= floor ? MacroState.good : MacroState.low;
  }

  MacroState calorieState(double eaten, double? maint) {
    if (maint == null || maint <= 0 || !anyIntake) return MacroState.none;
    switch (calorieMode) {
      case 'deficit':
        return eaten <= maint ? MacroState.good : MacroState.high;
      case 'surplus':
        return eaten >= maint ? MacroState.good : MacroState.low;
      default:
        return MacroState.good; // maintenance band — neutral/green
    }
  }

  return [
    MacroBar(
      label: 'Protein',
      current: proteinEaten,
      target: proteinFloor,
      unit: 'g',
      state: floorState(proteinEaten, proteinFloor),
    ),
    MacroBar(
      label: 'Carbs',
      current: carbsEaten,
      target: carbsFloor,
      unit: 'g',
      state: floorState(carbsEaten, carbsFloor),
    ),
    MacroBar(
      label: 'Fat',
      current: fatEaten,
      target: fatMin,
      unit: 'g',
      state: floorState(fatEaten, fatMin),
    ),
    MacroBar(
      label: 'Calories',
      current: kcalEaten,
      target: maintenanceKcal,
      unit: 'kcal',
      state: calorieState(kcalEaten, maintenanceKcal),
    ),
  ];
}
