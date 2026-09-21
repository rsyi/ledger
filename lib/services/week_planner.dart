/// Weekly auto-planner — generates the week's planned strength rows from
/// the coach program (`coach/program.yaml` v3 `planned` keys) into the
/// device-local PlanStore, where the timeline renders them with Log-now.
///
/// Two layers:
///  - [buildWeekPlannedEntries]: pure core (zero Flutter/IO imports) —
///    program map + week Monday in, PlannedEntry-shaped maps out. Each
///    map carries ONLY `date` + `exercise` + `reps` — NEVER rpe, notes,
///    or weight (planned rows must not fabricate performance data).
///  - [WeekPlanner.ensureCurrentWeek]: thin runner — weekly idempotence
///    via the `week_planner_generated_monday` ledger meta key; writes
///    through the same PlanStore path coach proposals use.
library;

import 'package:airledger_engine/airledger_engine.dart';
import 'package:intl/intl.dart';

import '../models/planned_entry.dart';
import '../models/view_schema.dart';
import 'plan_store.dart';
import 'program_current.dart' show currentVersion;
import 'program_provider.dart';
import 'week_plan.dart' show defaultWeekStart;

const List<String> _weekdayKeys = [
  'mon',
  'tue',
  'wed',
  'thu',
  'fri',
  'sat',
  'sun',
];

DateTime _parseDay(Object? s) {
  final d = DateTime.parse(s.toString());
  return DateTime.utc(d.year, d.month, d.day);
}

/// The block containing [day] (inclusive both ends), or null.
Map<Object?, Object?>? _blockFor(Map<Object?, Object?> version, DateTime day) {
  final blocks = version['blocks'];
  if (blocks is! List) return null;
  for (final b in blocks) {
    if (b is! Map) continue;
    final dates = b['dates'];
    if (dates is! List || dates.length < 2) continue;
    final start = _parseDay(dates[0]);
    final end = _parseDay(dates[1]);
    if (!day.isBefore(start) && !day.isAfter(end)) {
      return Map<Object?, Object?>.from(b);
    }
  }
  return null;
}

/// Expands the current program version's `planned` lifts into one map per
/// SET for the ISO week containing [weekMonday] (any day of the week is
/// accepted; it's normalised to Monday).
///
/// Returned maps have exactly three keys:
///   - `date`     — UTC-midnight [DateTime] of the entry's weekday
///   - `exercise` — the exact logged exercise name (metrics depend on it)
///   - `reps`     — planned reps for that one set
///
/// `sets: N` items expand into N entries (one row per set convention).
/// Alternation-aware: when a day's `planned` is an a/b map, parity comes
/// from `planned_alternation.anchor_monday` — whole ISO weeks since the
/// anchor, even (incl. 0) = `a`, odd = `b`.
///
/// Weeks that fall outside every block (pre-program) and days without a
/// `planned` key produce nothing. Malformed structures are skipped, never
/// thrown on.
List<Map<String, Object?>> buildWeekPlannedEntries(
  Map<Object?, Object?> program,
  DateTime weekMonday,
) {
  final version = currentVersion(program);
  if (version == null) return const [];

  final day0 = DateTime.utc(weekMonday.year, weekMonday.month, weekMonday.day);
  final monday = day0.subtract(Duration(days: day0.weekday - 1));

  // a/b parity for this week. Defaults to 'a' when no anchor is declared.
  var parity = 'a';
  final alternation = version['planned_alternation'];
  if (alternation is Map && alternation['anchor_monday'] != null) {
    final anchor = _parseDay(alternation['anchor_monday']);
    final weeks = monday.difference(anchor).inDays ~/ 7;
    parity = weeks.isEven ? 'a' : 'b';
  }

  final entries = <Map<String, Object?>>[];
  for (var i = 0; i < 7; i++) {
    final day = monday.add(Duration(days: i));
    final block = _blockFor(version, day);
    if (block == null) continue; // outside every block: nothing to plan
    final blockN = block['n'];
    final block0Template = version['weekly_template_block_0'];
    final Object? template = (blockN == 0 && block0Template is Map)
        ? block0Template
        : version['weekly_template'];
    if (template is! Map) continue;
    final dayMap = template[_weekdayKeys[i]];
    if (dayMap is! Map) continue;
    Object? planned = dayMap['planned'];
    if (planned is Map) planned = planned[parity]; // alternation day
    if (planned is! List) continue;
    for (final item in planned) {
      if (item is! Map) continue;
      final exercise = item['exercise'];
      final reps = item['reps'];
      if (exercise is! String || exercise.isEmpty || reps is! num) continue;
      final rawSets = item['sets'];
      final sets = rawSets is num && rawSets >= 1 ? rawSets.toInt() : 1;
      for (var s = 0; s < sets; s++) {
        // ONLY exercise + reps (+ date). Never rpe/notes/weight — those
        // describe what happened, and nothing has happened yet.
        entries.add({'date': day, 'exercise': exercise, 'reps': reps});
      }
    }
  }
  return entries;
}

/// Thin runner around [buildWeekPlannedEntries]. Call fire-and-forget from
/// the home-screen bootstrap after SyncScheduler.init; never throws.
class WeekPlanner {
  /// Ledger meta key holding the `yyyy-MM-dd` Monday of the last week we
  /// generated. Matching value = this week is done, do nothing (so logged
  /// or user-deleted rows are never touched or re-created).
  static const metaGeneratedKey = 'week_planner_generated_monday';

  /// Ledger meta key the runner writes the last swallowed error into.
  static const metaErrorKey = 'week_planner_error';

  /// Timeline group header for generated rows (same mechanism as template
  /// / coach-proposal grouping: PlannedEntry.templateName).
  static const templateLabel = 'program: week plan';

  /// Ensures the current week's planned rows exist (once per week).
  ///
  /// Week selection follows [defaultWeekStart]: the Monday of this ISO
  /// week — except on Sundays, when it targets the UPCOMING week (the
  /// app-wide "on Sunday you plan next week" convention).
  ///
  /// First run mid-week only adds entries dated today or later — no
  /// backfilling of already-past days. Skips silently (without marking
  /// the week done) when program.yaml is missing or unparseable. Any
  /// error is swallowed into the [metaErrorKey] meta.
  static Future<void> ensureCurrentWeek({
    required EngineLedgerRepository repo,
    required ProgramProvider provider,
    required ViewSchema strengthView,
    DateTime Function() now = DateTime.now,
  }) async {
    try {
      final today = now();
      final targetMonday = defaultWeekStart(today);
      final mondayStr = DateFormat('yyyy-MM-dd').format(targetMonday);
      if (await repo.metaGet(metaGeneratedKey) == mondayStr) return;

      final docs = await provider.load();
      final program = docs.program;
      if (program == null) return; // no/bad program.yaml: retry next launch

      final todayDay = DateTime.utc(today.year, today.month, today.day);
      final entries = <PlannedEntry>[];
      for (final e in buildWeekPlannedEntries(program, targetMonday)) {
        final date = e['date'] as DateTime;
        if (date.isBefore(todayDay)) continue; // today-forward on first run
        entries.add(PlannedEntry.create(
          view: strengthView,
          date: DateTime(date.year, date.month, date.day),
          values: {'exercise': e['exercise'], 'reps': e['reps']},
          templateName: templateLabel,
        ));
      }
      if (entries.isNotEmpty) {
        await PlanStore.addAll(strengthView, entries);
      }
      // Mark the week done even when empty (e.g. pre-program week) so we
      // don't re-evaluate on every launch.
      await repo.metaSet(metaGeneratedKey, mondayStr);
    } catch (e) {
      try {
        await repo.metaSet(metaErrorKey, e.toString());
      } catch (_) {
        // Meta write failed too — nothing left to do; stay silent.
      }
    }
  }
}
