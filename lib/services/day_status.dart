/// ONE per-item status for a program day — the single source of truth
/// shared by the Today program card (its ticks + achievement meta), the
/// day synthesis ("coach's read") prompt and CoachBrain's today section,
/// so the three can never disagree (2026-10-02: the read told the user to
/// "make sure that PM light climbing session actually happens" after the
/// card had already ticked the climb from a Whoop MORNING session — the
/// prompt re-derived the day from routine prose instead of the card's
/// state).
///
/// Built over the effective (post-moves) day: the day's working sets are
/// exclusively allocated to its items ([achieveDay] — same allocation as
/// the missed-work detector), then sessions credit climb / 4x4 items: a
/// Whoop climb ([creditClimbItems]), Kaya ascents, a logged 4x4. Moved-out
/// ghosts are MOVED, skip rows are SKIPPED — neither is today's work.
///
/// Pure: no Flutter/IO imports.
library;

import 'day_achievement.dart';
import 'missed_work.dart' show programItemKind;
import 'prescribed_exercises.dart';
import 'program_moves.dart';
import 'program_week.dart' show dayOnly;
import 'whoop_activity.dart';

enum DayItemState { done, partial, pending, movedOut, skipped }

/// One item of the day with its resolved state.
class DayItemStatus {
  /// The (marked) entry — `item.loggedSets` / `item.creditNote` applied.
  final EffectiveItem entry;
  final DayItemState state;

  /// 'lift' | 'climb' | 'cardio' ([programItemKind]).
  final String kind;

  /// Working sets credited to (or folded into) this item, and their clips.
  final List<AchievedSet> sets;
  final List<DayClip> clips;

  /// Top-set item (achievement reads "top 275×6").
  final bool top;

  /// The skip reason when [state] is skipped.
  final String? skipReason;

  /// The Whoop session that credited this item (climb), if any.
  final WhoopActivity? whoop;

  const DayItemStatus({
    required this.entry,
    required this.state,
    required this.kind,
    this.sets = const [],
    this.clips = const [],
    this.top = false,
    this.skipReason,
    this.whoop,
  });

  PrescribedItem get item => entry.item;

  /// Lives on the day and is not skipped (the "k / N done" denominator).
  bool get isLive =>
      state != DayItemState.movedOut && state != DayItemState.skipped;

  /// Still to do (pending or partially logged).
  bool get isOpen =>
      state == DayItemState.pending || state == DayItemState.partial;

  bool get isDone => state == DayItemState.done;

  /// What was ACHIEVED, exactly as the card shows it ("top 275×6",
  /// "2×4 · 255 lb", "1 of 3 sets", a credit note like "strain 8.0");
  /// null when nothing is achieved yet.
  String? get achievedText {
    if (!isLive) return null;
    if (item.creditNote != null) return item.creditNote;
    final done = item.done;
    if (!done && item.loggedSets == 0) return null;
    return achievedMeta(sets, target: item.targetSets, top: top) ??
        (done
            ? '${item.loggedSets} set${item.loggedSets == 1 ? '' : 's'}'
            : '${item.loggedSets} of ${item.targetSets} sets');
  }
}

/// The whole day.
class DayStatus {
  final DateTime date;

  /// Every entry in effective order (ghosts included).
  final List<DayItemStatus> items;

  /// Logged work that matched no item.
  final List<ExtraWork> extra;

  /// Whoop sessions on [date] (context for the prompt's lifting note).
  final List<WhoopActivity> whoop;

  /// False when no strength source was available — lift states are then
  /// unknown (rendered pending, never "done").
  final bool trackSets;

  const DayStatus({
    required this.date,
    required this.items,
    this.extra = const [],
    this.whoop = const [],
    this.trackSets = true,
  });

  List<DayItemStatus> get live => [
    for (final i in items)
      if (i.isLive) i,
  ];
  List<DayItemStatus> get pending => [
    for (final i in items)
      if (i.isOpen) i,
  ];
  int get doneCount => live.where((i) => i.isDone).length;
  bool get allDone => live.isNotEmpty && live.every((i) => i.isDone);

  /// Today's (live) program includes a climb.
  bool get climbPrescribed => live.any((i) => i.kind == 'climb');

  /// A climb is still to do (no logged/Whoop/Kaya session credits it).
  bool get climbPending => pending.any((i) => i.kind == 'climb');

  /// Live lift items / those done — the notification tally.
  int get liftsPlanned => live.where((i) => i.kind == 'lift').length;
  int get liftsHit => live.where((i) => i.kind == 'lift' && i.isDone).length;

  /// The explicit status block for LLM prompts (day synthesis + coach
  /// chat). DONE items carry no AM/PM label (a done item is done,
  /// whenever it happened); PENDING items keep their planned period.
  String promptBlock() {
    final b = StringBuffer()
      ..writeln(
        'PROGRAM STATUS — ${_dayLabel(date)} (authoritative: the '
        'exact checklist the Today card shows; do not re-derive it from '
        'the routine text):',
      );
    if (items.isEmpty) {
      b.writeln('- rest day (nothing prescribed)');
    }
    for (final i in items) {
      b.writeln('- ${_line(i)}');
    }
    if (extra.isNotEmpty) {
      b.writeln(
        'ALSO LOGGED (outside the program): ${[for (final x in extra)
          if (x.sets.isNotEmpty) '${x.exercise} (${x.sets.length} set${x.sets.length == 1 ? '' : 's'})'].join(', ')}',
      );
    }
    final open = pending;
    if (items.isNotEmpty) {
      b.writeln(
        open.isEmpty
            ? "TRAINING LEFT TODAY: none — today's training is complete."
            : 'TRAINING LEFT TODAY: ${open.map((i) => i.item.name).join(', ')}',
      );
    }
    if (whoop.any((a) => a.kind == ActivityKind.lift) &&
        open.any((i) => i.kind == 'lift')) {
      b.writeln(
        'NOTE: Whoop recorded a lifting session today — PENDING '
        "lifts may simply be unlogged; don't nag about them.",
      );
    }
    if (!trackSets && live.any((i) => i.kind == 'lift')) {
      b.writeln('NOTE: no strength log available — lift status unknown.');
    }
    return b.toString().trimRight();
  }

  static String _line(DayItemStatus i) {
    final name = i.item.name;
    final from = i.entry.movedFrom == null
        ? ''
        : ' (moved in from ${_wd(i.entry.movedFrom!)})';
    switch (i.state) {
      case DayItemState.movedOut:
        return 'MOVED $name → ${_wd(i.entry.movedTo!)} (not today\'s work)';
      case DayItemState.skipped:
        final r = i.skipReason?.trim() ?? '';
        return 'SKIPPED $name${r.isEmpty ? '' : ' — $r'}';
      case DayItemState.done:
        final w = i.whoop;
        if (w != null) {
          final parts = [
            'Whoop ${w.sport}${w.start == null ? '' : ' ${_hm(w.start!)}'}',
            if (w.strain != null) 'strain ${w.strain!.toStringAsFixed(1)}',
            if (w.durationMin != null) '${w.durationMin!.round()} min',
          ];
          return 'DONE $name$from — ${parts.join(', ')}${_timing(i, w)}';
        }
        final a = i.achievedText;
        return 'DONE $name$from${a == null ? '' : ' — $a'}';
      case DayItemState.partial:
      case DayItemState.pending:
        final scheme = i.item.scheme.trim().replaceAll(RegExp(r'\.+$'), '');
        final progress = i.kind == 'lift'
            ? '${i.item.loggedSets} of ${i.item.targetSets} sets logged'
            : 'not done yet';
        final detail = [
          if (scheme.isNotEmpty) scheme,
          if (i.item.period.isNotEmpty) 'planned ${i.item.period}',
        ];
        return 'PENDING $name$from — $progress'
            '${detail.isEmpty ? '' : ' (${detail.join('; ')})'}';
    }
  }

  /// "(planned PM, done earlier — complete)" when a Whoop session landed
  /// in the other half of the day than the item's planned period.
  static String _timing(DayItemStatus i, WhoopActivity w) {
    final s = w.start;
    final p = i.item.period;
    if (s == null) return '';
    if (p == 'PM' && s.hour < 12) {
      return ' (planned PM, done earlier — complete)';
    }
    if (p == 'AM' && s.hour >= 12) {
      return ' (planned AM, done later — complete)';
    }
    return '';
  }
}

const _wdNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _wd(DateTime d) => _wdNames[d.weekday - 1];
String _dayLabel(DateTime d) => '${_wd(d)} ${d.month}/${d.day}';
String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Resolves [date]'s [entries] (its effective items, ghosts included)
/// against what happened:
///   * [logged] — the day's WORKING sets in allocation order (strength +
///     calisthenics). Null = no strength source: lift items stay pending.
///   * [clips] / [isTop] — card display refinements ([achieveDay]); when
///     [isTop] is null an item whose scheme says "top set" is a top item.
///   * [whoop] — Whoop sessions (any days; filtered to [date]).
///   * [kayaDays] — Kaya ascent dates; [cardio4x4Days] — logged 4x4 days.
///   * [skips] — the week's skip rows keyed by [skipKey].
DayStatus buildDayStatus({
  required DateTime date,
  required List<EffectiveItem> entries,
  required List<AchievedSet>? logged,
  List<DayClip> clips = const [],
  bool Function(EffectiveItem e)? isTop,
  List<WhoopActivity> whoop = const [],
  Iterable<DateTime> kayaDays = const [],
  Set<DateTime> cardio4x4Days = const {},
  Map<String, ProgramMove> skips = const {},
}) {
  final day = dayOnly(date);
  bool topOf(EffectiveItem e) =>
      isTop?.call(e) ??
      RegExp(r'\btop set\b', caseSensitive: false).hasMatch(e.item.scheme);

  final live = [
    for (final e in entries)
      if (!e.isGhost) e,
  ];
  var items = [for (final e in live) e.item];
  var sets = [for (final _ in live) const <AchievedSet>[]];
  var itemClips = [for (final _ in live) const <DayClip>[]];
  var extra = const <ExtraWork>[];
  if (logged != null) {
    final r = achieveDay(
      items: items,
      logged: logged,
      clips: clips,
      isTop: [for (final e in live) topOf(e)],
    );
    items = r.items;
    sets = r.sets;
    itemClips = r.clips;
    extra = r.extra;
  }

  // Session credits: Whoop climb first (its note is the card's "strain
  // N"), then Kaya ascents, then a logged 4x4.
  final dayWhoop = [
    for (final a in whoop)
      if (dayOnly(a.date) == day) a,
  ];
  WhoopActivity? climbSession;
  if (dayWhoop.isNotEmpty) {
    items = creditClimbItems(items, dayWhoop);
    final climbs = dayWhoop.where((a) => a.kind == ActivityKind.climb);
    // The hardest climb (the one whose strain the credit note carries).
    for (final c in climbs) {
      if (climbSession == null ||
          (c.strain ?? -1) > (climbSession.strain ?? -1)) {
        climbSession = c;
      }
    }
  }
  final kayaClimbed = climbDaysUnion(
    kayaDays,
    whoopClimbDays(whoop),
  ).contains(day);
  final did4x4 = cardio4x4Days.map(dayOnly).contains(day);
  final credited = <bool>[];
  for (var k = 0; k < items.length; k++) {
    final i = items[k];
    final kind = programItemKind(i);
    final byWhoop = i.creditNote != null && climbSession != null;
    credited.add(byWhoop);
    if (i.done) continue;
    if (kind == 'climb' && kayaClimbed) {
      items[k] = i.withCredit('logged in Kaya');
    } else if (kind == 'cardio' && did4x4) {
      items[k] = i.withCredit('4x4 logged');
    }
  }

  final out = <DayItemStatus>[];
  var k = 0;
  for (final e in entries) {
    if (e.isGhost) {
      out.add(
        DayItemStatus(
          entry: e,
          state: DayItemState.movedOut,
          kind: programItemKind(e.item),
        ),
      );
      continue;
    }
    final idx = k++;
    final item = items[idx];
    final marked = EffectiveItem(
      item: item,
      home: e.home,
      movedFrom: e.movedFrom,
      movedTo: e.movedTo,
      move: e.move,
    );
    final skip = skips[skipKey(day, item.name)];
    final state = skip != null
        ? DayItemState.skipped
        : item.done
        ? DayItemState.done
        : item.loggedSets > 0
        ? DayItemState.partial
        : DayItemState.pending;
    out.add(
      DayItemStatus(
        entry: marked,
        state: state,
        kind: programItemKind(item),
        sets: sets[idx],
        clips: itemClips[idx],
        top: topOf(e),
        skipReason: skip?.note,
        whoop: credited[idx] ? climbSession : null,
      ),
    );
  }
  return DayStatus(
    date: day,
    items: out,
    extra: extra,
    whoop: dayWhoop,
    trackSets: logged != null,
  );
}
