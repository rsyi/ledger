/// THE week-start resolver + pure week helpers (2026-10-03, user: "some
/// sort of configuration place where I can set what day the week starts
/// on … I want my week to start on Saturday so that if I miss my
/// Saturday workout, it's okay, I still have the rest of the week").
///
/// One rule, used by the app, the nightly tools and (mirrored in TS) the
/// MCP: the week starts on
///   1. the SYNCED setting (`app_settings` tab, key [weekStartSettingKey])
///      when present and parseable, else
///   2. the current program.yaml version's `week_start:`, else
///   3. Monday.
///
/// The resolved day drives EVERY accounting/schedule week: goals,
/// program sets per lift, moves, skips, missed work, the Week tab, the
/// Program screen's paging, the week planner, the coach's moves section,
/// the weekly review and the nightly program_status rollup.
///
/// NOT driven by it (deliberately): program STRUCTURE that the program
/// declares against Mondays — block boundaries, week_in_block /
/// week_type ([anchorMondayOf]), the cut wave's calendar anchor
/// (`strength_wave_cut.anchor_monday`), the post-cut volume ramp — and
/// the forecast model's ISO-week buckets. Those are the TRAINING
/// calendar, not the accounting week.
///
/// Pure: no Flutter/IO imports.
library;

/// `app_settings` key holding the week-start day (value: a lowercase
/// weekday name, e.g. `saturday`).
const weekStartSettingKey = 'week_start';

const _keys = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

/// `DateTime.monday..sunday` for a weekday name ('saturday', 'Sat',
/// ' SATURDAY ') or a 1..7 number; null when unrecognized.
int? parseWeekday(Object? raw) {
  if (raw is int) return raw >= 1 && raw <= 7 ? raw : null;
  final s = raw?.toString().trim().toLowerCase() ?? '';
  if (s.isEmpty) return null;
  final n = int.tryParse(s);
  if (n != null) return n >= 1 && n <= 7 ? n : null;
  for (var i = 0; i < 7; i++) {
    if (_keys[i] == s || (s.length >= 3 && _keys[i].startsWith(s))) {
      return i + 1;
    }
  }
  return null;
}

/// 'saturday' — the stored form of a weekday.
String weekdayKey(int day) => _keys[day - 1];

/// 'Saturday'.
String weekdayName(int day) {
  final k = _keys[day - 1];
  return '${k[0].toUpperCase()}${k.substring(1)}';
}

/// 'Sat'.
String weekdayShortName(int day) => weekdayName(day).substring(0, 3);

/// Where the resolved week start came from.
enum WeekStartSource {
  /// The synced `app_settings` row ("set here").
  setting,

  /// program.yaml's current `week_start:` ("from program default").
  program,

  /// Neither — Monday.
  fallback,
}

/// The resolved week start + its source (see the library doc).
({int day, WeekStartSource source}) resolveWeekStart({
  Object? setting,
  Map<Object?, Object?>? programVersion,
}) {
  final s = parseWeekday(setting);
  if (s != null) return (day: s, source: WeekStartSource.setting);
  final p = parseWeekday(programVersion?['week_start']);
  if (p != null) return (day: p, source: WeekStartSource.program);
  return (day: DateTime.monday, source: WeekStartSource.fallback);
}

/// [resolveWeekStart]'s day.
int resolveWeekStartDay({
  Object? setting,
  Map<Object?, Object?>? programVersion,
}) =>
    resolveWeekStart(setting: setting, programVersion: programVersion).day;

/// Start (local midnight) of the week containing [d] for weeks that
/// begin on [weekStartDay] (`DateTime.monday..sunday`): the most recent
/// such weekday at or before [d]. A UTC input keeps its calendar date.
DateTime weekStartOf(DateTime d, [int weekStartDay = DateTime.monday]) =>
    DateTime(d.year, d.month, d.day - ((d.weekday - weekStartDay) % 7));

/// Last day (local midnight) of [d]'s week.
DateTime weekEndOf(DateTime d, [int weekStartDay = DateTime.monday]) {
  final s = weekStartOf(d, weekStartDay);
  return DateTime(s.year, s.month, s.day + 6);
}

/// The seven days (local midnights, in order) of [d]'s week.
List<DateTime> weekDaysOf(DateTime d, [int weekStartDay = DateTime.monday]) {
  final s = weekStartOf(d, weekStartDay);
  return [for (var i = 0; i < 7; i++) DateTime(s.year, s.month, s.day + i)];
}

/// Whether [a] and [b] fall in the same week.
bool sameWeek(DateTime a, DateTime b, [int weekStartDay = DateTime.monday]) =>
    weekStartOf(a, weekStartDay) == weekStartOf(b, weekStartDay);

/// The weekday that ends a week starting on [weekStartDay] (Saturday →
/// Friday).
int weekEndDay(int weekStartDay) => (weekStartDay + 5) % 7 + 1;
