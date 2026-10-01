/// What TODAY's program calls for, per Log-tab domain — the "today:"
/// badge on the Log domain list (home_screen). Pure: program map + phase
/// + the day, plus the same weight inputs the routine screen uses
/// (training maxes / reference e1rms) so the strength badge can name the
/// day ("today: squat heavy + bench volume").
///
/// Keyed by VIEW name (the domain's primary view — strength / cardio /
/// climbing …), the vocabulary [DomainConfig] groups on. A view with no
/// program call today is ABSENT from the map (quiet, no badge) — rest
/// days and untracked domains never get a badge.
///
/// Zero Flutter/IO imports; every branch is covered by
/// test/today_program_call_test.dart.
library;

import 'program_current.dart' show ProgramSlice, programCurrent;
import 'program_metrics.dart' show StrengthRow;
import 'routine_display.dart' show SessionLine, daySummary, sessionLinesByDay;
import 'week_planner.dart' show buildWeekPlannedEntries;

/// The program's call for [day], split by the Log-tab domain (view name)
/// it belongs to. Absent keys = nothing scheduled for that domain today.
///
/// Values are the short badge text WITHOUT a "today:" prefix (the widget
/// adds it) — e.g. `strength → "squat heavy + bench volume"`,
/// `cardio → "4x4"`, `climbing → "hard session"`.
///
/// [references] / [workingMaxes] / [capRpeByLift] / [accessoryHistory]
/// are threaded straight into [buildWeekPlannedEntries] so the strength
/// call reflects the same planned lines the routine + timeline show; all
/// default empty (the strength call then names lifts without loads,
/// which the badge never shows anyway).
Map<String, String> todayProgramCallByView(
  Map<Object?, Object?> program,
  Map<Object?, Object?>? phase,
  DateTime day, {
  Map<String, double> references = const {},
  Map<String, double> workingMaxes = const {},
  Map<String, double> capRpeByLift = const {},
  List<StrengthRow> accessoryHistory = const [],
}) {
  final slice = programCurrent(program, phase, day);
  if (slice == null) return const {};

  final out = <String, String>{};

  final strength = _strengthCall(
    program,
    slice,
    day,
    references: references,
    workingMaxes: workingMaxes,
    capRpeByLift: capRpeByLift,
    accessoryHistory: accessoryHistory,
  );
  if (strength != null) out['strength'] = strength;

  final prose = _prose(slice);
  if (prose.contains('4x4')) out['cardio'] = '4x4';

  final climb = _climbCall(prose);
  if (climb != null) out['climbing'] = climb;

  if (_calisthenicsToday(prose, strength)) {
    out['calisthenics'] = 'skill work';
  }

  return out;
}

/// The strength day's call — lifts only (climb/4x4/calisthenics tokens
/// are stripped; those belong to their own domains). Null when the day
/// has no lifting/accessory work.
String? _strengthCall(
  Map<Object?, Object?> program,
  ProgramSlice slice,
  DateTime day, {
  required Map<String, double> references,
  required Map<String, double> workingMaxes,
  required Map<String, double> capRpeByLift,
  required List<StrengthRow> accessoryHistory,
}) {
  final entries = buildWeekPlannedEntries(
    program,
    day,
    references: references,
    workingMaxes: workingMaxes,
    capRpeByLift: capRpeByLift,
    accessoryHistory: accessoryHistory,
    snapToWeekStart: false,
  );
  final dayUtc = DateTime.utc(day.year, day.month, day.day);
  final lines = <SessionLine>[];
  sessionLinesByDay(entries).forEach((d, ls) {
    if (d == dayUtc) lines.addAll(ls);
  });
  // Reuse the routine's summary, then drop the non-strength tokens so the
  // strength badge names lifts/accessories only. Passing empty prose
  // keeps daySummary from adding 4x4/climb/calisthenics tokens.
  final summary = daySummary(lines: lines);
  if (summary == 'Rest') return null;
  // daySummary joins with " · "; the badge reads more naturally with "+".
  return summary.replaceAll(' · ', ' + ');
}

String _prose(ProgramSlice slice) {
  final t = slice.todayTemplate;
  return '${t['morning'] ?? ''} ${t['afternoon'] ?? ''}'.toLowerCase();
}

/// The climbing call for the day, with its flavor in plain words, or
/// null when the day has no climb.
String? _climbCall(String prose) {
  if (!prose.contains('climb')) return null;
  // The routine labels the day with an explicit "<flavor> session" —
  // match that first (the prose may also mention "limit climbing" in a
  // note; the session label is the day's real intensity).
  if (prose.contains('hard session')) return 'hard session';
  if (prose.contains('limit session')) return 'limit session';
  if (prose.contains('light session')) return 'light session';
  if (prose.contains('technique')) return 'technique session';
  return 'climb';
}

/// Whether the refresh-triggered gated sync should prompt the intrusive
/// Kaya sync (which opens the Kaya app for its email export).
///
/// PURE decision — the UI reads it with today's [programCall] (from
/// [todayProgramCallByView]) and [loggedClimbCount] (climbing rows logged
/// today, from the kaya snapshot). True ONLY when today's program expects
/// a climb AND none is logged yet: an already-logged climb needs no
/// re-export, and a non-climb day never bothers the user with the Kaya
/// launch. The non-intrusive weight/meals/recovery sync is never gated
/// on this — only the Kaya prompt is program-conditional.
bool shouldPromptKayaSync({
  required Map<String, String> programCall,
  required int loggedClimbCount,
}) {
  final expectsClimb = programCall.containsKey('climbing');
  return expectsClimb && loggedClimbCount <= 0;
}

/// True when the day's prose is a calisthenics/skill day (muscle-ups,
/// handstands) AND it isn't already a barbell strength day.
bool _calisthenicsToday(String prose, String? strengthCall) {
  final isSkill = prose.contains('calisthenics') ||
      prose.contains('muscle-up') ||
      prose.contains('handstand');
  if (!isSkill) return false;
  // A barbell day that also mentions skill work stays a strength badge.
  final barbell = strengthCall != null &&
      (strengthCall.contains('heavy') || strengthCall.contains('volume'));
  return !barbell;
}
