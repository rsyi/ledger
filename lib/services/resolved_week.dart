/// One configured week of the program, after `program_moves` — the
/// single resolution every week surface shares (WeekStateLoader, the
/// Program screen, the week planner, the coach, tool/missed_work.dart,
/// tool/coach_msg.dart), so pulled-forward work (2026-10-03: a move may
/// pull an item from next week into this one, up to 7 days earlier)
/// renders identically everywhere.
///
/// Pure: no Flutter/IO imports — the nightly tools use it. The PRICED
/// counterpart (`effectivePricedWeek`) lives in effective_plan.dart
/// (app-side: pricing pulls in the planner).
library;

import 'intent_docs.dart';
import 'prescribed_exercises.dart';
import 'program_moves.dart';
import 'program_week.dart';

class ResolvedWeek {
  /// `DateTime.monday..sunday` the week starts on.
  final int weekStartDay;

  /// First day (local midnight).
  final DateTime start;

  /// Active moves touching the week (incl. pulled-in / pulled-out).
  final Map<String, ProgramMove> moves;

  /// The week's skips, keyed by [skipKey].
  final Map<String, ProgramMove> skips;

  /// The week's 7 days + any next-week home day a move pulls work from.
  final Map<DateTime, List<PrescribedItem>> prescribed;

  /// The effective week — exactly the 7 days, in order.
  final Map<DateTime, List<EffectiveItem>> week;

  const ResolvedWeek({
    required this.weekStartDay,
    required this.start,
    required this.moves,
    required this.skips,
    required this.prescribed,
    required this.week,
  });

  /// The 7 days (local midnights).
  List<DateTime> get days =>
      [for (var i = 0; i < 7; i++) DateTime(start.year, start.month, start.day + i)];

  /// Last day.
  DateTime get end => DateTime(start.year, start.month, start.day + 6);

  /// Prescribed days outside the week (pulled-in home days).
  List<DateTime> get extraDays => [
        for (final d in prescribed.keys)
          if (d.isBefore(start) || d.isAfter(end)) d,
      ];
}

/// Resolves [anyDay]'s [weekStartDay] week over every `program_moves` row
/// [all] (moves + skips).
ResolvedWeek resolveProgramWeek(
  IntentDocs docs,
  DateTime anyDay,
  Iterable<ProgramMove> all, {
  int weekStartDay = DateTime.monday,
  String label = 'Today',
}) {
  final start = weekStartOf(anyDay, weekStartDay);
  final moves = activeMoves(all, start, weekStartDay: weekStartDay);
  final skips = activeSkips(all, start, weekStartDay: weekStartDay);
  final prescribed = prescribedWeek(
    docs,
    start,
    label: label,
    weekStartDay: weekStartDay,
    extraDays: pulledInHomeDays(moves, start, weekStartDay: weekStartDay),
  );
  return ResolvedWeek(
    weekStartDay: weekStartDay,
    start: start,
    moves: moves,
    skips: skips,
    prescribed: prescribed,
    week: effectiveWeek(prescribed, moves, weekStart: start),
  );
}
