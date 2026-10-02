/// The Plan tab's PRICED prescription, mapped onto the program day card's
/// prose items (2026-10-02 user request: "the program view on the logs
/// and the homepage [should] contain the same rep by set information …
/// but each object [stays] a separate line").
///
/// One source of numbers: [pricedWeek] runs exactly the Program screen's
/// pipeline — training maxes + active RPE caps from the working-max tabs,
/// 42-day reference e1rms (fallback), accessory double-progression
/// history → `buildWeekPlannedEntries(snapToWeekStart: false)` →
/// `sessionLinesByDay` — so the card and the Plan tab can never disagree.
/// [matchItemLines] then assigns each priced line to the prose item it
/// belongs to (name matching via prescribed_exercises.dart); items with
/// no line (climb, 4x4, prose-only work) keep their prose scheme.
///
/// Pure: no Flutter/IO imports.
library;

import 'prescribed_exercises.dart';
import 'program_current.dart';
import 'program_metrics.dart'
    show StrengthRow, liftReferencesAsOf, mainLiftByExercise;
import 'routine_display.dart';
import 'week_planner.dart' show buildWeekPlannedEntries;
import 'wm_tabs.dart';
import 'working_max.dart' show LoadPolicy, loadPolicies, policyForDate;

/// A Mon–Sun week of priced session lines (Plan-tab numbers).
class PricedWeek {
  /// Working lines per day (local midnight), warm-ups dropped.
  final Map<DateTime, List<SessionLine>> lines;

  /// The calendar-anchored cut wave in force per day (null outside it).
  final Map<DateTime, CutWaveWeekSpec?> cutWave;

  /// Current training max per lift (squat/bench/deadlift/press).
  final Map<String, double> maxes;

  /// `hold ≤8 · drop 2.5-5% if over` — the back-off rule, or null.
  final String? backoff;

  /// The program version in force (accessory rule lookups).
  final Map<Object?, Object?>? version;

  const PricedWeek({
    required this.lines,
    this.cutWave = const {},
    this.maxes = const {},
    this.backoff,
    this.version,
  });

  static const empty = PricedWeek(lines: {});

  List<SessionLine> on(DateTime day) =>
      lines[DateTime(day.year, day.month, day.day)] ?? const [];

  /// Training max for [line]'s lift, or null (accessories).
  double? tmFor(SessionLine line) => maxes[mainLiftByExercise[line.exercise]];
}

/// Prices [monday]'s Mon–Sun week exactly as the Program screen does.
/// [wm] null (tabs unreadable / no store) → the reference-e1rm fallback.
PricedWeek pricedWeek(
  Map<Object?, Object?> program,
  Map<Object?, Object?>? phase,
  DateTime monday, {
  WmSnapshot? wm,
  List<StrengthRow> history = const [],
  required DateTime today,
}) {
  final version = currentVersion(program);
  if (version == null) return PricedWeek.empty;
  final mon = DateTime(monday.year, monday.month, monday.day - (monday.weekday - 1));
  final maxes = wm == null
      ? const <String, double>{}
      : currentWorkingMaxesByLift(wm.workingMax);
  final policies = loadPolicies(version);
  LoadPolicy? policyOn(DateTime d) {
    if (policies.isEmpty) return null;
    final slice = programCurrent(program, phase, d);
    return policyForDate(
      policies,
      date: d,
      block: slice?.block['number'] as int?,
      weekType: slice?.weekType,
    );
  }

  final caps = wm == null
      ? const <String, double>{}
      : activeCapsByLift(wm, policyOn);
  final entries = buildWeekPlannedEntries(
    program,
    mon,
    references: liftReferencesAsOf(history, today),
    workingMaxes: maxes,
    capRpeByLift: caps,
    accessoryHistory: history,
    snapToWeekStart: false,
  );
  final lines = <DateTime, List<SessionLine>>{};
  sessionLinesByDay(entries).forEach((d, ls) {
    lines[DateTime(d.year, d.month, d.day)] = ls;
  });
  final cut = <DateTime, CutWaveWeekSpec?>{};
  for (var i = 0; i < 7; i++) {
    final d = DateTime(mon.year, mon.month, mon.day + i);
    final slice = programCurrent(program, phase, d);
    cut[d] = strengthWaveCutFor(version,
        blockN: slice?.block['number'] as int?, day: d);
  }
  return PricedWeek(
    lines: lines,
    cutWave: cut,
    maxes: maxes,
    backoff: backoffLine(version['backoff_rule']),
    version: version,
  );
}

/// Top-set intent from the item NAME: "heavy"/"top" → true,
/// "back-offs"/"volume" → false, else null (a combined or non-lift item).
bool? _wantsTop(PrescribedItem item) {
  final n = item.name.toLowerCase();
  if (n.contains('heavy') || RegExp(r'\btop\b').hasMatch(n)) return true;
  if (n.contains('back-off') ||
      n.contains('backoff') ||
      n.contains('volume')) {
    return false;
  }
  return null;
}

int _extraTokens(String line, String item) =>
    sharedTokenCount(line, line) - sharedTokenCount(line, item);

/// Assigns the day's priced [lines] to its prose [items]: result[i] is
/// item i's lines (possibly empty), each line used at most once.
///
/// Greedy best-first over (item, line) pairs: a STRONG match
/// ([loggedCoversPrescribed]: every identifying word of the item, no
/// added variant — so "Squat heavy" never takes Bulgarian split squat)
/// beats a loose one (shared word, no added variant qualifier —
/// "Handstand practice" ~ "Handstand Hold"); fewer extra words win ties
/// ("Muscle-ups" → "Muscle Up", "Banded muscle-ups" → the band line);
/// then program order. A main-lift line's top flag must agree with the
/// item's name ("Bench heavy" → the top set, "Bench back-offs" → the
/// non-top line). Leftover lines of an exercise an UN-tagged item already
/// holds join it (one "Squat" item covering top set + back-offs).
List<List<SessionLine>> matchItemLines(
    List<PrescribedItem> items, List<SessionLine> lines) {
  final out = [for (final _ in items) <SessionLine>[]];
  if (lines.isEmpty) return out;
  final pairs = <(int score, int i, int j)>[];
  for (var i = 0; i < items.length; i++) {
    final want = _wantsTop(items[i]);
    for (var j = 0; j < lines.length; j++) {
      final l = lines[j];
      if (want != null &&
          mainLiftByExercise[l.exercise] != null &&
          l.top != want) {
        continue;
      }
      final name = items[i].name;
      final extra = _extraTokens(l.exercise, name);
      int score;
      if (loggedCoversPrescribed(l.exercise, name)) {
        score = 1000 - extra;
      } else if (loggedMatchesPrescribed(l.exercise, name) &&
          !loggedAddsVariant(l.exercise, name)) {
        score = 100 * sharedTokenCount(l.exercise, name) - extra;
      } else {
        continue;
      }
      pairs.add((score, i, j));
    }
  }
  pairs.sort((a, b) {
    if (a.$1 != b.$1) return b.$1.compareTo(a.$1);
    if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
    return a.$3.compareTo(b.$3);
  });
  final used = List<bool>.filled(lines.length, false);
  final owner = <int, int>{}; // line → item
  for (final (_, i, j) in pairs) {
    if (used[j] || out[i].isNotEmpty) continue;
    used[j] = true;
    owner[j] = i;
    out[i].add(lines[j]);
  }
  // Leftovers join an untagged item already holding that exercise.
  for (var j = 0; j < lines.length; j++) {
    if (used[j]) continue;
    for (var i = 0; i < items.length; i++) {
      if (_wantsTop(items[i]) != null) continue;
      if (out[i].any((l) => l.exercise == lines[j].exercise)) {
        used[j] = true;
        out[i].add(lines[j]);
        break;
      }
    }
  }
  // Keep each item's lines in the planner's (program) order.
  for (final ls in out) {
    ls.sort((a, b) => lines.indexOf(a).compareTo(lines.indexOf(b)));
  }
  return out;
}

/// The card's line for one priced [line] under [item]: the Plan tab's
/// `formatSessionLine`, minus the exercise name when the item already
/// names it ("Deadlift heavy" → `1×5 · 275 lb (81%)`); a choice ("RDL or
/// leg curl") or loose match keeps it (`Romanian Deadlift 2×8-12`).
String itemLineText(SessionLine line, PrescribedItem item, {double? tm}) {
  final full = formatSessionLine(line, tm: tm);
  final keepName = RegExp(r'\s+or\s+', caseSensitive: false)
          .hasMatch(item.name) ||
      !loggedCoversPrescribed(line.exercise, item.name);
  if (keepName) return full;
  final prefix = '${exerciseDisplayName(line.exercise)} ';
  return full.startsWith(prefix) ? full.substring(prefix.length) : full;
}

/// Why the line says what it says — `wave wk1, 81% TM` (cut-wave top),
/// `wave deload, 70% TM`, `75% TM` (%TM slot), `double progression`
/// (weighted accessory), or null.
String? lineContext(SessionLine line,
    {int? cutWaveWeek, bool cutDeload = false}) {
  final pct = line.pct == null ? null : '${(line.pct! * 100).round()}% TM';
  if (line.top) {
    final wave = cutDeload
        ? 'wave deload'
        : cutWaveWeek != null
            ? 'wave wk$cutWaveWeek'
            : 'top set';
    return pct == null ? wave : '$wave, $pct';
  }
  if (pct != null) return pct;
  if (mainLiftByExercise[line.exercise] == null && line.weight != null) {
    return 'double progression';
  }
  return null;
}

/// Key for [mainLiftByItem]: the item's HOME day (the program's day, so
/// a moved item keeps its lift) + its name, case-blind.
String itemLiftKey(DateTime home, String name) =>
    '${home.year}-${home.month}-${home.day}|${name.trim().toLowerCase()}';

/// Main lift (squat/bench/deadlift/press) of every prescribed item that
/// IS main-lift work, keyed by [itemLiftKey] — from the same
/// [matchItemLines] mapping the program card prices with ("Bench
/// volume" → its Flat Barbell Bench Press line → bench; "Bulgarian split
/// squat" → its own accessory line → absent). Items no priced line
/// claims fall back to [mainLiftOfItemName]. Items whose lines span two
/// lifts take the first line's.
Map<String, String> mainLiftByItem(
  Map<DateTime, List<PrescribedItem>> prescribed,
  PricedWeek priced,
) {
  final out = <String, String>{};
  prescribed.forEach((day, items) {
    final matched = matchItemLines(items, priced.on(day));
    for (var i = 0; i < items.length; i++) {
      String? lift;
      for (final l in matched[i]) {
        lift = mainLiftByExercise[l.exercise];
        if (lift != null) break;
      }
      if (matched[i].isEmpty) lift = mainLiftOfItemName(items[i].name);
      if (lift != null) out[itemLiftKey(day, items[i].name)] = lift;
    }
  });
  return out;
}

/// Name-only fallback: the item NAME starts with the main lift
/// ("Squat heavy", "OHP back-offs", "Overhead press 3x8", "Bench") →
/// that lift; anything else (incl. "Bulgarian split squat", "RDL") →
/// null.
String? mainLiftOfItemName(String name) {
  final n = name.trim().toLowerCase();
  if (n.startsWith('overhead press') || n.startsWith('military press')) {
    return 'press';
  }
  final first = RegExp(r'^[a-z]+').firstMatch(n)?.group(0);
  return switch (first) {
    'squat' => 'squat',
    'bench' => 'bench',
    'deadlift' => 'deadlift',
    'ohp' || 'press' => 'press',
    _ => null,
  };
}
