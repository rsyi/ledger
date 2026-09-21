/// Pure week-plan builder — resolves a DayPlan for each day of an ISO week.
///
/// Zero Flutter/IO imports; testable in pure Dart. The UI layer (WeekPlanScreen)
/// calls [buildWeekPlan] and [defaultWeekStart].
library;

import 'program_current.dart';

/// The resolved plan for a single calendar day.
class DayPlan {
  /// The calendar date (UTC midnight).
  final DateTime date;

  /// The resolved [ProgramSlice] for this date, or null when the date falls
  /// outside every program block (pre-program or post-program).
  final ProgramSlice? slice;

  const DayPlan({required this.date, required this.slice});

  /// True when morning and afternoon are both absent.
  bool get isOff {
    if (slice == null) return true;
    final m = slice!.todayTemplate['morning'];
    final a = slice!.todayTemplate['afternoon'];
    return (m == null || (m as Object?).toString().trim().isEmpty) &&
        (a == null || (a as Object?).toString().trim().isEmpty);
  }
}

/// Returns the Monday of the ISO week to show on first open.
///
/// - Normally: the Monday of the week containing [today].
/// - If [today] is a Sunday (weekday == 7): the Monday of the NEXT week,
///   because on Sundays the user checks their upcoming week.
///
/// [today] should be the current date (local calendar).
DateTime defaultWeekStart(DateTime today) {
  final day = DateTime.utc(today.year, today.month, today.day);
  if (day.weekday == DateTime.sunday) {
    // Jump to next Monday (7 days ahead, then back to Monday = 1 day).
    return day.add(const Duration(days: 1));
  }
  // Monday of this week (weekday: Mon=1 … Sat=6).
  return day.subtract(Duration(days: day.weekday - 1));
}

/// Builds the full 7-day plan for the ISO week containing [anyDayInWeek]
/// (Mon–Sun). Always returns exactly 7 [DayPlan] entries in weekday order.
///
/// [programYaml] is the parsed `coach/program.yaml` map.
/// [phaseYaml] is the parsed `coach/phase.yaml` map (may be null).
///
/// Each day is resolved via [programCurrent]; days outside every block get a
/// [DayPlan] with `slice == null`.
List<DayPlan> buildWeekPlan(
  Map<Object?, Object?> programYaml,
  Map<Object?, Object?>? phaseYaml,
  DateTime anyDayInWeek,
) {
  final day = DateTime.utc(
      anyDayInWeek.year, anyDayInWeek.month, anyDayInWeek.day);
  // Normalise to Monday of this ISO week.
  final monday = day.subtract(Duration(days: day.weekday - 1));

  return [
    for (var i = 0; i < 7; i++)
      () {
        final d = monday.add(Duration(days: i));
        return DayPlan(
          date: d,
          slice: programCurrent(programYaml, phaseYaml, d),
        );
      }(),
  ];
}
