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

/// Returns the start of the accounting week to show/plan on first open.
///
/// - Normally: the start of the week containing [today] (Monday for the
///   default ISO weeks; the configured day when [weekStartDay] is set —
///   program.yaml v7 `week_start: saturday` keys weeks Sat–Fri).
/// - If [today] is the LAST day of the week (Sunday for Monday-start
///   weeks, Friday for Saturday-start ones): the start of the NEXT
///   week, because on the closing day the user checks the upcoming week.
///
/// [today] should be the current date (local calendar).
DateTime defaultWeekStart(DateTime today, {int weekStartDay = DateTime.monday}) {
  final day = DateTime.utc(today.year, today.month, today.day);
  // UTC-midnight arithmetic (weekStartOf returns local midnights; this
  // function's contract — and its callers' date keys — are UTC days).
  final start = day.subtract(Duration(days: (day.weekday - weekStartDay) % 7));
  final lastDay = start.add(const Duration(days: 6));
  if (day == lastDay) return start.add(const Duration(days: 7));
  return start;
}

/// Builds the full 7-day plan for the week containing [anyDayInWeek] —
/// the [weekStartDay] week (week_start.dart; Monday = ISO Mon–Sun).
/// Always returns exactly 7 [DayPlan] entries in day order.
///
/// [programYaml] is the parsed `coach/program.yaml` map.
/// [phaseYaml] is the parsed `coach/phase.yaml` map (may be null).
///
/// Each day is resolved via [programCurrent]; days outside every block get a
/// [DayPlan] with `slice == null`.
List<DayPlan> buildWeekPlan(
  Map<Object?, Object?> programYaml,
  Map<Object?, Object?>? phaseYaml,
  DateTime anyDayInWeek, {
  int weekStartDay = DateTime.monday,
}) {
  final day = DateTime.utc(
      anyDayInWeek.year, anyDayInWeek.month, anyDayInWeek.day);
  // Normalise to the week's first day.
  final monday = day.subtract(Duration(days: (day.weekday - weekStartDay) % 7));

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
