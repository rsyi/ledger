/// Missed-work detector over the effective (post-moves) Mon–Sun week —
/// spec 2026-10-02-missed-work-carryover-design §3.
///
/// An item is MISSED when it was due on a day strictly before today and
/// the week's logged work doesn't cover it. Accounting is week-to-date,
/// so doing Wed's bench on Thu without a move still clears it:
///   * lifts — logged WORKING sets (one row per set; warm-ups filtered
///     upstream by `workingSetRecords`); each set credits at most one
///     item. Pass 1: each day's items claim that day's sets via
///     [allocateDay] (the same allocation the program day card shows),
///     so today's work is today's, not a makeup. Pass 2: past-due
///     shortfalls draw on the week's unclaimed (Mon..today) sets in day
///     order — STRONG matches only (`loggedCoversPrescribed`), so one
///     shared token ("triceps") can't credit a different movement.
///   * climb items (`isClimbItem`) — sessions: one climb day covers one
///     item. Same order: today, own day, then any spare climb day.
///   * 4x4 items (name/scheme mentions "4x4") — same, vs cardio 4x4 days.
/// Ghost entries (moved-out origins) never count. Optional prose yields
/// no item upstream, so it can never be missed.
///
/// Pure: no Flutter/IO imports.
library;

import 'prescribed_exercises.dart';
import 'program_moves.dart' show EffectiveItem;
import 'program_week.dart' show dayOnly, mondayOf;
import 'whoop_activity.dart' show isClimbItem;

/// One prescribed item that was due before today and isn't covered.
class MissedItem {
  /// As prescribed (loggedSets = the sets credited to it).
  final PrescribedItem item;

  /// The day it was due (after moves).
  final DateTime day;

  /// The program's original day for it.
  final DateTime home;

  /// Sets short of target; 1 for session items (climb / 4x4).
  final int setsShort;

  /// 'lift' | 'climb' | 'cardio'.
  final String kind;

  const MissedItem({
    required this.item,
    required this.day,
    required this.home,
    required this.setsShort,
    required this.kind,
  });

  bool get isSession => kind != 'lift';
}

class MissedWork {
  /// Due before today, not done — day order, then program order.
  final List<MissedItem> missed;

  /// today..Sunday (local midnights) — where missed work can still go.
  final List<DateTime> remainingDays;

  const MissedWork({required this.missed, required this.remainingDays});

  bool get isEmpty => missed.isEmpty;

  /// One compact line per missed item ('' when none):
  /// `- Bench top set (1x3 @ RPE 8) — due Wed 9/30, 0/1 sets`
  /// `- Hard climb — due Tue 9/29, session not logged`
  String toPromptLines() => [
    for (final m in missed)
      '- ${m.item.name}${_schemePart(m.item.scheme)} — due '
          '${_dayLabel(m.day)}, '
          '${m.isSession ? 'session not logged' : '${m.item.loggedSets}/${m.item.targetSets} sets'}',
  ].join('\n');
}

const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _dayLabel(DateTime d) => '${_wd[d.weekday - 1]} ${d.month}/${d.day}';

/// The nightly's expiry wording for a planning [target] planned on
/// [runDay] (spec §3: unplaced work expires at the end of Sunday). Null
/// unless [target] is a Sunday — a Saturday-night run planning Sunday
/// says "expires end of Sun 10/4"; a Sunday run adds "(tonight)".
String? expiryLabel(DateTime target, DateTime runDay) {
  if (target.weekday != DateTime.sunday) return null;
  final tonight = dayOnly(runDay) == dayOnly(target);
  return 'expires end of ${_dayLabel(target)}${tonight ? ' (tonight)' : ''}';
}

/// Scheme without parentheticals, whitespace-collapsed, capped at 24
/// chars; '' (no parens at all) when nothing remains.
String _schemePart(String scheme) {
  var s = scheme
      .replaceAll(RegExp(r'\([^)]*\)?'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  s = s.replaceAll(RegExp(r'^[,;:\-–—\s]+|[,;:\-–—\s]+$'), '');
  if (s.isEmpty) return '';
  if (s.length > 24) s = '${s.substring(0, 23).trimRight()}…';
  return ' ($s)';
}

bool _has4x4(String s) => s.toLowerCase().contains('4x4');
bool _hasClimb(String s) =>
    RegExp(r'climb', caseSensitive: false).hasMatch(s);

/// 'lift' | 'climb' | 'cardio' (4x4) — the detector's item kinds, shared
/// with the day synthesis' moved-item handling.
String programItemKind(PrescribedItem i) => _kindOf(i);

/// The NAME decides first: the live Tue "Climb — HARD session" scheme
/// mentions "AM-4x4" in its prose, which must not make it a 4x4 item.
String _kindOf(PrescribedItem i) {
  if (_has4x4(i.name)) return 'cardio';
  if (_hasClimb(i.name)) return 'climb';
  if (_has4x4(i.scheme)) return 'cardio';
  if (isClimbItem(i)) return 'climb';
  return 'lift';
}

/// Exclusive allocation of one day's logged sets to that day's items:
/// each set credits at most one item. Strong matches
/// (`loggedCoversPrescribed`) are claimed first, then loose ones
/// (`loggedMatchesPrescribed`) fill remaining shortfalls; within each
/// phase items claim in list order, sets in logged order.
///
/// ORDER: pass items in program order — own items first, moved-in items
/// after (the order `effectiveWeek` produces). So Fri's own "Bench
/// volume 3x8" claims Fri's bench sets before a moved-in "Bench heavy".
///
/// Returns per-item claimed counts and the claimed mask over [logged].
/// Only lift items take part ([programItemKind]); session items get 0.
({List<int> got, List<bool> claimed}) _allocate(
    List<PrescribedItem> items, List<String> logged) {
  final got = List<int>.filled(items.length, 0);
  final claimed = List<bool>.filled(logged.length, false);
  final lift = [for (final i in items) _kindOf(i) == 'lift'];
  for (final strong in [true, false]) {
    for (var i = 0; i < items.length; i++) {
      if (!lift[i]) continue;
      for (var j = 0;
          j < logged.length && got[i] < items[i].targetSets;
          j++) {
        if (claimed[j]) continue;
        final ok = strong
            ? loggedCoversPrescribed(logged[j], items[i].name)
            : loggedMatchesPrescribed(logged[j], items[i].name);
        if (!ok) continue;
        claimed[j] = true;
        got[i]++;
      }
    }
  }
  return (got: got, claimed: claimed);
}

/// [items] with `loggedSets` set by ONE exclusive per-day allocation of
/// [loggedNames] (one entry per WORKING set logged that day) — shared by
/// the program day card, the day synthesis and the detector's pass 1 so
/// they always agree. Session items (climb / 4x4) are returned unchanged.
List<PrescribedItem> allocateDay(
    List<PrescribedItem> items, List<String> loggedNames) {
  final r = _allocate(items, loggedNames);
  return [
    for (var i = 0; i < items.length; i++)
      _kindOf(items[i]) == 'lift' ? items[i].withLogged(r.got[i]) : items[i],
  ];
}

class _Slot {
  final EffectiveItem e;
  final DateTime day;
  final String kind;
  final int need;
  int got = 0;
  _Slot(this.e, this.day, this.kind)
    : need = kind == 'lift' ? e.item.targetSets : 1;
  bool get short => got < need;
}

/// Detects missed work for [today]'s Mon–Sun week. [strengthRows] is one
/// entry per logged set; [climbDays] is Part 1's `climbDaysUnion`.
MissedWork detectMissedWork({
  required Map<DateTime, List<EffectiveItem>> week,
  required List<({DateTime date, String exercise})> strengthRows,
  required Set<DateTime> climbDays,
  required Set<DateTime> cardio4x4Days,
  required DateTime today,
}) {
  final t = dayOnly(today);
  final mon = mondayOf(t);
  final remaining = [
    for (var i = t.weekday - 1; i < 7; i++)
      DateTime(mon.year, mon.month, mon.day + i),
  ];
  bool inWeekToDate(DateTime d) => !d.isBefore(mon) && !d.isAfter(t);

  // Slots for today and every earlier day of the week, day order then
  // program order. Ghosts never count.
  final days = week.keys.map(dayOnly).where(inWeekToDate).toSet().toList()
    ..sort();
  final slots = <_Slot>[];
  for (final day in days) {
    for (final entry in week.entries) {
      if (dayOnly(entry.key) != day) continue;
      for (final e in entry.value) {
        if (e.isGhost) continue;
        slots.add(_Slot(e, day, _kindOf(e.item)));
      }
    }
  }
  if (slots.isEmpty) {
    return MissedWork(missed: const [], remainingDays: remaining);
  }

  // Allocation order: today's slots, then the rest in day order.
  final ordered = [
    ...slots.where((s) => s.day == t),
    ...slots.where((s) => s.day != t),
  ];

  // --- Lifts: pools of unclaimed sets.
  final pool = [
    for (final r in strengthRows)
      if (inWeekToDate(dayOnly(r.date)))
        (day: dayOnly(r.date), exercise: r.exercise),
  ];
  final claimed = List<bool>.filled(pool.length, false);
  // Pass 1 (lifts): per day, the shared exclusive allocation.
  for (final day in days) {
    final daySlots = [
      for (final s in slots)
        if (s.day == day && s.kind == 'lift') s,
    ];
    final idx = [
      for (var i = 0; i < pool.length; i++)
        if (pool[i].day == day) i,
    ];
    if (daySlots.isEmpty || idx.isEmpty) continue;
    final r = _allocate([for (final s in daySlots) s.e.item],
        [for (final i in idx) pool[i].exercise]);
    for (var k = 0; k < daySlots.length; k++) {
      daySlots[k].got += r.got[k];
    }
    for (var k = 0; k < idx.length; k++) {
      if (r.claimed[k]) claimed[idx[k]] = true;
    }
  }
  // Pass 2 (lifts): spare sets from any day — strong matches only.
  void claimSpareLift(_Slot s) {
    for (var i = 0; i < pool.length && s.short; i++) {
      if (claimed[i]) continue;
      if (!loggedCoversPrescribed(pool[i].exercise, s.e.item.name)) continue;
      claimed[i] = true;
      s.got++;
    }
  }

  // --- Sessions: unclaimed session days per kind.
  final sessionDays = <String, Set<DateTime>>{
    'climb': {
      for (final d in climbDays)
        if (inWeekToDate(dayOnly(d))) dayOnly(d),
    },
    'cardio': {
      for (final d in cardio4x4Days)
        if (inWeekToDate(dayOnly(d))) dayOnly(d),
    },
  };
  void claimSession(_Slot s, {required bool sameDayOnly}) {
    final avail = sessionDays[s.kind]!;
    if (!s.short || avail.isEmpty) return;
    DateTime? pick;
    if (avail.contains(s.day)) {
      pick = s.day;
    } else if (!sameDayOnly) {
      pick = (avail.toList()..sort()).first;
    }
    if (pick == null) return;
    avail.remove(pick);
    s.got++;
  }

  // Pass 1 (sessions): every slot (today first) takes its own day's
  // session. (Lifts were allocated per day above.)
  for (final s in ordered) {
    if (s.kind != 'lift') claimSession(s, sameDayOnly: true);
  }
  // Pass 2: past-due shortfalls draw on the week's spare work, in day
  // order. Today's slots aren't due, so they don't compete here.
  for (final s in slots) {
    if (s.day == t) continue;
    if (s.kind == 'lift') {
      claimSpareLift(s);
    } else {
      claimSession(s, sameDayOnly: false);
    }
  }

  return MissedWork(
    missed: [
      for (final s in slots)
        if (s.day.isBefore(t) && s.short)
          MissedItem(
            item: s.e.item.withLogged(s.kind == 'lift' ? s.got : 0),
            day: s.day,
            home: s.e.home,
            setsShort: s.need - s.got,
            kind: s.kind,
          ),
    ],
    remainingDays: remaining,
  );
}
