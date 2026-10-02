import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/view_schema.dart';
import '../../services/accessory_progression.dart';
import '../../services/day_prescription.dart';
import '../../services/home_synthesis.dart' show strengthRowFromRecord;
import '../../services/log_event_bus.dart';
import '../../services/missed_work.dart';
import '../../services/prescribed_exercises.dart';
import '../../services/program_item_pricing.dart';
import '../../services/program_metrics.dart'
    show StrengthRow, mainLiftByExercise;
import '../../services/program_moves.dart';
import '../../services/program_provider.dart' show ProgramProvider;
import '../../services/program_week.dart' show dayOnly, mondayOf;
import '../../services/routine_display.dart' show SessionLine;
import '../../services/set_recommendation.dart';
import '../../services/sync_scheduler.dart';
import '../../services/warehouse_connector.dart';
import '../../services/week_state_loader.dart';
import '../../services/whoop_activity.dart';
import '../../services/wm_tabs.dart' show WmSnapshot;

/// The program view for a day: the prescribed session as a CHECKLIST
/// (every lift and accessory the routine names — squat, muscle-ups,
/// front-lever up-downs, hanging leg raises, dips, curls), each ticking
/// GREEN the moment a logged set satisfies it. Tightly coupled to the
/// ledger: the live log bus refreshes the marks as you log.
///
/// No AI commentary here — this is the plan. (The coach's read lives on
/// the Today tab.)
class ProgramDayCard extends StatefulWidget {
  final ProgramProvider? provider;

  /// Relative label ("Today" / "Tomorrow" / "Yesterday" / a date).
  final String label;

  /// The calendar day to show (date-only).
  final DateTime date;

  /// Strength view/repo — drives the green completion marks; log events
  /// refresh them live.
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;

  /// Whoop workouts — a Whoop climb on the card's day ticks the
  /// prescribed climb (Kaya exports lag). Null → logged sets only.
  final ViewSchema? workoutsView;
  final WarehouseConnector? workoutsRepo;

  /// Calisthenics log — a logged handstand/muscle-up set ticks the
  /// matching skill item.
  final ViewSchema? calisthenicsView;
  final WarehouseConnector? calisthenicsRepo;

  /// `program_moves` — relocations within the Mon–Sun week. Null → the
  /// card shows the plain prescription (no Move to… / Undo).
  final ViewSchema? programMovesView;
  final WarehouseConnector? programMovesRepo;

  /// Cardio (4x4 sessions) + climbing (Kaya ascents) — inputs to the
  /// "Missed this week" section on today's card. Null → those kinds
  /// count as not logged.
  final ViewSchema? cardioView;
  final WarehouseConnector? cardioRepo;
  final ViewSchema? climbingView;
  final WarehouseConnector? climbingRepo;

  /// Training-max tabs (`WmStore.snapshot`, 3-min cached) — prices each
  /// item exactly like the Plan tab's Program screen. Null → the
  /// reference-e1rm fallback (main lifts may then show no load).
  final Future<WmSnapshot?> Function()? wmSnapshot;

  /// Clock for "is this today's card" — tests pin it.
  final DateTime Function() now;

  const ProgramDayCard({
    super.key,
    required this.provider,
    required this.label,
    required this.date,
    this.strengthView,
    this.strengthRepo,
    this.workoutsView,
    this.workoutsRepo,
    this.calisthenicsView,
    this.calisthenicsRepo,
    this.programMovesView,
    this.programMovesRepo,
    this.cardioView,
    this.cardioRepo,
    this.climbingView,
    this.climbingRepo,
    this.wmSnapshot,
    this.now = DateTime.now,
  });

  @override
  ProgramDayCardState createState() => ProgramDayCardState();
}

class _DayData {
  final DayPrescription prescription;

  /// The card day's effective items (ghosts of moved-out items included,
  /// moved-in items appended), done-marked + Whoop-credited.
  final List<EffectiveItem> items;

  /// The whole effective Mon–Sun week — feeds the Move to… sheet's
  /// per-day load summary.
  final Map<DateTime, List<EffectiveItem>> week;

  /// Today's card only; null elsewhere.
  final MissedWork? missed;

  /// The week priced like the Plan tab + each item's lines, keyed by
  /// [_itemKey] (home day + name).
  final PricedWeek priced;
  final Map<String, List<SessionLine>> lines;

  /// The week's skips ([skipKey] → row).
  final Map<String, ProgramMove> skips;

  /// Strength history (accessory suggestions in the info sheet).
  final List<StrengthRow> history;

  const _DayData(
    this.prescription,
    this.items,
    this.week,
    this.missed, {
    this.priced = PricedWeek.empty,
    this.lines = const {},
    this.skips = const {},
    this.history = const [],
  });

  List<SessionLine> linesOf(EffectiveItem e) =>
      lines[_itemKey(e.home, e.item.name)] ?? const [];

  /// The skip row when [e] is skipped on [day] (ghosts never are).
  ProgramMove? skipOf(EffectiveItem e, DateTime day) =>
      e.isGhost ? null : skips[skipKey(day, e.item.name)];

  /// Items that live on the card's day and aren't skipped — the "k / N
  /// done" denominator.
  List<EffectiveItem> liveOn(DateTime day) => [
        for (final e in items)
          if (!e.isGhost && skipOf(e, day) == null) e,
      ];
}

String _itemKey(DateTime home, String name) =>
    '${dayOnly(home).toIso8601String()}|${name.trim().toLowerCase()}';

/// Each item's priced lines for the effective [week], matched per HOME
/// day over that day's own items (ghosts included, moved-in excluded) so
/// a moved item keeps the load its home day priced it at.
Map<String, List<SessionLine>> _matchWeek(
    Map<DateTime, List<EffectiveItem>> week, PricedWeek priced) {
  final out = <String, List<SessionLine>>{};
  week.forEach((day, entries) {
    final own = [
      for (final e in entries)
        if (e.movedFrom == null) e.item,
    ];
    final lines = priced.on(day);
    if (own.isEmpty || lines.isEmpty) return;
    final m = matchItemLines(own, lines);
    for (var i = 0; i < own.length; i++) {
      if (m[i].isNotEmpty) out[_itemKey(day, own[i].name)] = m[i];
    }
  });
  return out;
}

const _wdNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _wd(DateTime d) => _wdNames[d.weekday - 1];
String _dayLabel(DateTime d) => '${_wd(d)} ${d.month}/${d.day}';

/// "Bench heavy — Wed, 0/1 sets" / "Climb — Tue, not logged".
String missedLine(MissedItem m) => '${m.item.name} — ${_wd(m.day)}, '
    '${m.isSession ? 'not logged' : '${m.item.loggedSets}/${m.item.targetSets} sets'}';

class ProgramDayCardState extends State<ProgramDayCard> {
  late Future<_DayData?> _future;

  /// One delayed retry when the training-max read came back empty.
  bool _wmRetried = false;
  StreamSubscription<LogEvent>? _logSub;

  /// Strength rows from the last [_load] — reused by the info sheet so a
  /// tap doesn't re-list the whole table (thousands of rows) before the
  /// sheet can open. Refreshed with every reload (log events included).
  List<Map<String, Object?>>? _strengthRows;

  /// The last loaded data for the CURRENT day — shown while a reload (a
  /// log event, a move) is in flight, so the card never collapses to a
  /// spinner after its first load. Cleared when the day changes.
  _DayData? _last;

  @override
  void initState() {
    super.initState();
    _future = _load();
    if (widget.strengthView != null) {
      _logSub = LogEventBus.instance.stream.listen((_) => reload());
    }
  }

  @override
  void didUpdateWidget(ProgramDayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameDay(oldWidget.date, widget.date) || oldWidget.label != widget.label) {
      _last = null; // another day's data must not stand in
      _future = _load(); // build follows didUpdateWidget — no setState
    }
  }

  @override
  void dispose() {
    _logSub?.cancel();
    super.dispose();
  }

  void reload() {
    // Block body: an arrow would return the Future to setState (asserts).
    if (mounted) {
      setState(() {
        _future = _load();
      });
    }
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<_DayData?> _load() async {
    final provider = widget.provider;
    if (provider == null) return null;
    final date = dayOnly(widget.date);
    final isToday = date == dayOnly(widget.now());
    // The TM snapshot is read alongside the week (WmStore caches it).
    final wmFuture = () async {
      try {
        return await widget.wmSnapshot?.call();
      } catch (_) {
        return null; // honest: reference fallback
      }
    }();
    // One shared loader (card, coach, synthesis, carryover check): the
    // effective week + logged work, each source read ONCE per load.
    final state = await WeekStateLoader(
      loadDocs: provider.load,
      programMovesView: widget.programMovesView,
      programMovesRepo: widget.programMovesRepo,
      strengthView: widget.strengthView,
      strengthRepo: widget.strengthRepo,
      workoutsView: widget.workoutsView,
      workoutsRepo: widget.workoutsRepo,
      cardioView: widget.cardioView,
      cardioRepo: widget.cardioRepo,
      climbingView: widget.climbingView,
      climbingRepo: widget.climbingRepo,
      calisthenicsView: widget.calisthenicsView,
      calisthenicsRepo: widget.calisthenicsRepo,
    ).load(date, label: widget.label, withMissed: isToday);
    if (state == null) return null;
    var entries = state.day;

    // Done-marking + Whoop credit apply to the items that live here
    // (ghosts are shown, never counted).
    List<EffectiveItem> mapLive(
        List<PrescribedItem> Function(List<PrescribedItem>) f) {
      final live = [for (final e in entries) if (!e.isGhost) e];
      if (live.isEmpty) return entries;
      final marked = f([for (final e in live) e.item]);
      var i = 0;
      return [
        for (final e in entries)
          e.isGhost
              ? e
              : EffectiveItem(
                  item: marked[i++],
                  home: e.home,
                  movedFrom: e.movedFrom,
                  movedTo: e.movedTo,
                  move: e.move,
                ),
      ];
    }

    if (widget.strengthView != null && widget.strengthRepo != null) {
      if (state.strengthRows != null) _strengthRows = state.strengthRows;
      // One exclusive allocation (each working set credits one item) —
      // the same one the missed-work detector runs per day.
      entries = mapLive((items) => allocateDay(items, state.loggedOnDate));
    }
    final day = [
      for (final a in state.whoop)
        if (_sameDay(a.date, date)) a,
    ];
    if (day.isNotEmpty) {
      entries = mapLive((items) => creditClimbItems(items, day));
    }

    // Plan-tab pricing (training max / wave / %TM / double progression).
    final wm = await wmFuture;
    // The TM tabs are a direct Sheets read: on a cold start it can fail
    // (network not up yet) and the card then only reloads on a log event —
    // loads stayed blank. Retry once shortly after (not cached on failure).
    if (wm == null && widget.wmSnapshot != null && !_wmRetried) {
      _wmRetried = true;
      Future.delayed(const Duration(seconds: 6), () {
        if (mounted) reload();
      });
    }
    var priced = PricedWeek.empty;
    var lines = const <String, List<SessionLine>>{};
    var history = const <StrengthRow>[];
    final program = state.docs.program;
    if (program != null) {
      try {
        history = [
          for (final r in state.strengthRows ?? const <Map<String, Object?>>[])
            ?strengthRowFromRecord(r),
        ];
        priced = pricedWeek(program, state.docs.phase, mondayOf(date),
            wm: wm, history: history, today: dayOnly(widget.now()));
        lines = _matchWeek(state.week, priced);
      } catch (_) {/* honest: prose schemes */}
    }
    return _DayData(state.prescription, entries, state.week, state.missed,
        priced: priced, lines: lines, skips: state.skips, history: history);
  }

  bool get _canMove =>
      widget.programMovesView != null && widget.programMovesRepo != null;

  /// Bottom sheet of the week's days (Mon–Sun of [anyDay]); the
  /// [current] day and days before today are disabled (a missed item
  /// moved into the past is immediately missed again) — except [home],
  /// which stays pickable when the item lives elsewhere (= back home).
  /// Returns the picked day or null.
  Future<DateTime?> _pickDay(BuildContext context, String itemName,
      DateTime anyDay, DateTime current, DateTime home, _DayData data) {
    final mon = mondayOf(anyDay);
    final today = dayOnly(widget.now());
    return showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final muted = theme.colorScheme.onSurfaceVariant;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('Move $itemName to…',
                    style: theme.textTheme.titleMedium),
              ),
              for (var i = 0; i < 7; i++)
                () {
                  final d = DateTime(mon.year, mon.month, mon.day + i);
                  final live = (data.week[d] ?? const <EffectiveItem>[])
                      .where((e) => !e.isGhost)
                      .length;
                  final isCurrent = d == current;
                  final backHome = d == home && !isCurrent;
                  final past = d.isBefore(today) && !backHome;
                  final enabled = !isCurrent && !past;
                  return ListTile(
                    dense: true,
                    enabled: enabled,
                    title: Text(
                        '${_dayLabel(d)}${d == today ? ' · today' : ''}',
                        style: d == today
                            ? const TextStyle(fontWeight: FontWeight.w700)
                            : null),
                    subtitle: Text(
                      isCurrent
                          ? 'current day'
                          : backHome
                              ? 'back home (program day)'
                              : past
                                  ? 'past'
                                  : live == 0
                              ? 'rest'
                              : '$live item${live == 1 ? '' : 's'}',
                      style: TextStyle(color: muted),
                    ),
                    onTap: enabled ? () => Navigator.pop(ctx, d) : null,
                  );
                }(),
            ],
          ),
        );
      },
    );
  }

  /// Writes a manual move (latest row per from+item wins; to == from is
  /// "back home"), then syncs + reloads.
  Future<void> _moveItem(BuildContext context, _DayData data,
      {required PrescribedItem item,
      required DateTime home,
      required DateTime current}) async {
    final view = widget.programMovesView;
    final repo = widget.programMovesRepo;
    if (view == null || repo == null) return;
    final to = await _pickDay(context, item.name, home, current, home, data);
    if (to == null) return;
    final move = ProgramMove(
      id: const Uuid().v4(),
      to: to,
      from: home,
      item: item.name,
      period: item.period,
      source: 'manual',
      createdAt: DateTime.now(),
    );
    await _write(() => repo.create(view, move.toRecord()));
  }

  /// Sends the item home: writes a `to == from` "back home" row (latest
  /// per key wins → no active move). Deleting only the latest row would
  /// re-activate an OLDER move of the same item instead.
  Future<void> _undoMove(ProgramMove move) async {
    final view = widget.programMovesView;
    final repo = widget.programMovesRepo;
    if (view == null || repo == null) return;
    final back = ProgramMove(
      id: const Uuid().v4(),
      to: move.from,
      from: move.from,
      item: move.item,
      period: move.period,
      source: 'manual',
      createdAt: DateTime.now(),
      note: 'back home',
    );
    await _write(() => repo.create(view, back.toRecord()));
  }

  /// Skip… — asks for a (required) reason, then records the item as
  /// intentionally skipped on [day]: a `program_moves` row with source
  /// `skip`, date == from_date == [day], note = the reason. Not a move,
  /// not missed; the coach sees the reason.
  Future<void> _skipItem(
      BuildContext context, PrescribedItem item, DateTime day) async {
    final view = widget.programMovesView;
    final repo = widget.programMovesRepo;
    if (view == null || repo == null) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _SkipDialog(itemName: item.name, day: day),
    );
    if (reason == null || reason.trim().isEmpty) return;
    final skip = ProgramMove(
      id: const Uuid().v4(),
      to: dayOnly(day),
      from: dayOnly(day),
      item: item.name,
      period: item.period,
      source: skipSource,
      createdAt: DateTime.now(),
      note: reason.trim(),
    );
    await _write(() => repo.create(view, skip.toRecord()), what: 'Skip');
  }

  /// Undo skip — deletes every skip row of the item on [day] (a stale
  /// duplicate would keep it skipped).
  Future<void> _undoSkip(String itemName, DateTime day) async {
    final view = widget.programMovesView;
    final repo = widget.programMovesRepo;
    if (view == null || repo == null) return;
    await _write(() async {
      final rows = await repo.list(view);
      final ids = {
        for (final m in skipRowsFor(
            [for (final r in rows) ?ProgramMove.fromRecord(r)], day, itemName))
          m.id,
      };
      for (final r in rows) {
        if (ids.contains(r['id']?.toString())) await repo.delete(view, r);
      }
      return null;
    }, what: 'Undo skip');
  }

  Future<void> _write(Future<Object?> Function() op,
      {String what = 'Move'}) async {
    try {
      await op();
      unawaited(SyncScheduler.instance?.maybeSync(manual: true));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('$what failed: $e')));
      }
    }
    reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DayData?>(
      future: _future,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        if (!loading) _last = snap.data;
        if (loading && _last == null) {
          return const Card(
            margin: EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SizedBox(
              height: 96,
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        final data = loading ? _last : snap.data;
        if (data == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurfaceVariant;
        final p = data.prescription;
        final showChecks = widget.strengthView != null;
        final live = data.liveOn(dayOnly(widget.date));
        final doneCount = live.where((e) => e.item.done).length;
        final missed = data.missed;

        return Card(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('${p.label} — program',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(width: 6),
                    Text(p.weekday,
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: muted)),
                    const Spacer(),
                    if (p.isRest && live.isEmpty)
                      Text('Rest day',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: muted))
                    else if (showChecks && live.isNotEmpty)
                      Text('$doneCount / ${live.length} done',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: doneCount == live.length
                                ? theme.colorScheme.primary
                                : muted,
                          )),
                  ],
                ),
                const SizedBox(height: 6),
                if (data.items.isEmpty && !p.isRest)
                  Text(
                    [p.morning, p.afternoon]
                        .where((s) => s != null)
                        .join('\n'),
                    style: theme.textTheme.bodyMedium,
                  )
                else
                  for (final period in const ['AM', 'PM'])
                    ..._periodBlock(context, data, period, showChecks),
                if (missed != null && !missed.isEmpty)
                  ..._missedBlock(context, data, missed),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _periodBlock(
      BuildContext context, _DayData data, String period, bool showChecks) {
    final items = data.items;
    final group = items.where((e) => e.item.period == period).toList();
    if (group.isEmpty) return const [];
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final bothPeriods = items.any((e) => e.item.period == 'AM') &&
        items.any((e) => e.item.period == 'PM');
    return [
      if (bothPeriods)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text(period,
              style: theme.textTheme.labelSmall
                  ?.copyWith(letterSpacing: 0.8, color: muted)),
        ),
      for (final e in group)
        () {
          final day = dayOnly(widget.date);
          final skip = data.skipOf(e, day);
          final lines = data.linesOf(e);
          return _ExerciseRow(
            item: e.item,
            showCheck: showChecks,
            movedTo: e.movedTo,
            movedFrom: e.movedFrom,
            pricedLines: [
              for (final l in lines)
                (
                  itemLineText(l, e.item, tm: data.priced.tmFor(l)),
                  l.top,
                ),
            ],
            skipReason: skip?.note,
            onTap: widget.strengthView == null
                ? null
                : () => _showExerciseInfo(context, e, data),
            menu: !_canMove
                ? null
                : e.isGhost
                    // Moved-out origin: undo from here too (no Move to… —
                    // the item lives on its target day).
                    ? (e.move == null
                        ? null
                        : _RowMenu(onUndo: () => _undoMove(e.move!)))
                    : skip != null
                        ? _RowMenu(
                            onUndoSkip: () => _undoSkip(e.item.name, day))
                        : _RowMenu(
                            onMove: () => _moveItem(context, data,
                                item: e.item, home: e.home, current: day),
                            onSkip: () => _skipItem(context, e.item, day),
                            onUndo: e.movedFrom == null || e.move == null
                                ? null
                                : () => _undoMove(e.move!),
                          ),
          );
        }(),
    ];
  }

  /// MISSED THIS WEEK (today's card only): due before today, not covered
  /// by the week's logged work — each with a one-tap Move to….
  List<Widget> _missedBlock(
      BuildContext context, _DayData data, MissedWork missed) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return [
      const SizedBox(height: 8),
      Text('MISSED THIS WEEK',
          style: theme.textTheme.labelSmall
              ?.copyWith(letterSpacing: 0.8, color: muted)),
      for (final m in missed.missed)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.error_outline,
                    size: 16, color: theme.colorScheme.tertiary),
              ),
              Expanded(
                child: Text(missedLine(m), style: theme.textTheme.bodyMedium),
              ),
              if (_canMove) ...[
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _skipItem(context, m.item, m.day),
                  child: const Text('Skip…'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _moveItem(context, data,
                      item: m.item, home: m.home, current: m.day),
                  child: const Text('Move to…'),
                ),
              ],
            ],
          ),
        ),
    ];
  }

  /// Tap a prescribed movement → TODAY's priced prescription (the Plan
  /// tab's numbers) + a recommendation consistent with it, with the last
  /// comparable session as context. Unpriced items fall back to the
  /// last-session heuristic ([recommendSet]).
  Future<void> _showExerciseInfo(
      BuildContext context, EffectiveItem e, _DayData data) async {
    final sv = widget.strengthView;
    final sr = widget.strengthRepo;
    if (sv == null || sr == null) return;
    final item = e.item;
    final today = dayOnly(widget.date);
    final lines = data.linesOf(e);

    List<Map<String, Object?>> rows = const [];
    try {
      rows = _strengthRows ?? await sr.list(sv);
    } catch (_) {/* honest empty */}

    String? todayText;
    late final SetRecommendation rec;
    LastSession? last;
    if (lines.isNotEmpty) {
      // Same lift, same role: a top-set item compares against the last
      // session's top set, back-offs against its back-offs.
      final exercises = {for (final l in lines) l.exercise};
      final main = lines.any((l) => mainLiftByExercise[l.exercise] != null);
      final allTop = lines.every((l) => l.top);
      last = lastComparableSession(rows,
          matches: exercises.contains,
          before: today,
          role: !main
              ? SetRole.all
              : allTop
                  ? SetRole.top
                  : lines.any((l) => l.top)
                      ? SetRole.all
                      : SetRole.backoff);
      final cut = data.priced.cutWave[dayOnly(e.home)];
      final texts = [
        for (final l in lines)
          itemLineText(l, item, tm: data.priced.tmFor(l)),
      ];
      todayText = [
        for (var i = 0; i < lines.length; i++)
          () {
            final ctx = lineContext(lines[i],
                cutWaveWeek: cut?.week, cutDeload: cut?.deload ?? false);
            return '${texts[i]}${ctx == null ? '' : ' ($ctx)'}';
          }(),
      ].join('\n');
      AccessorySuggestion? acc;
      if (!main) {
        final l = lines.first;
        acc = suggestAccessoryLoad(
          exercise: l.exercise,
          history: data.history,
          asOf: e.home,
          repRangeHigh: l.repsHi?.toInt(),
          rule: AccessoryRule.fromVersion(data.priced.version),
        );
      }
      rec = recommendForPrescription(
        lines: texts,
        mainLift: main,
        top: lines.any((l) => l.top),
        weighted: lines.any((l) => l.weight != null),
        last: last,
        accessory: acc,
        backoff: data.priced.backoff,
      );
    } else {
      final names = {
        for (final r in rows) (r['exercise'] ?? '').toString().trim(),
      }..remove('');
      last = lastComparableSession(rows,
          matches: historyMatcher(item.name, names), before: today);
      rec = recommendSet(last?.sets ?? const []);
    }
    final note = last?.note;
    final lastDay = last?.day;

    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final muted = theme.colorScheme.onSurfaceVariant;
        Text label(String t) => Text(t,
            style: theme.textTheme.labelSmall
                ?.copyWith(letterSpacing: 0.8, color: muted));
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, style: theme.textTheme.titleMedium),
                if (item.scheme.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text('Prescribed: ${item.scheme}',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                ],
                if (todayText != null) ...[
                  const SizedBox(height: 14),
                  label('TODAY'),
                  const SizedBox(height: 3),
                  Text(todayText,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ],
                const SizedBox(height: 14),
                if (rec.lastSessionSummary != null) ...[
                  label(lastDay == null
                      ? 'LAST SESSION'
                      : 'LAST SESSION · ${_dayLabel(lastDay)}'),
                  const SizedBox(height: 3),
                  Text(rec.lastSessionSummary!,
                      style: theme.textTheme.bodyMedium),
                  if (note != null) ...[
                    const SizedBox(height: 4),
                    Text('Note: $note',
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: muted)),
                  ],
                  const SizedBox(height: 14),
                ],
                label('RECOMMENDATION'),
                const SizedBox(height: 3),
                Text(rec.advice, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RowMenu {
  final VoidCallback? onMove;
  final VoidCallback? onUndo;
  final VoidCallback? onSkip;
  final VoidCallback? onUndoSkip;
  const _RowMenu({this.onMove, this.onUndo, this.onSkip, this.onUndoSkip});
}

/// Skip… dialog: a required short reason (for the coach), with quick
/// chips. Pops the reason, or null on cancel.
class _SkipDialog extends StatefulWidget {
  final String itemName;
  final DateTime day;
  const _SkipDialog({required this.itemName, required this.day});

  @override
  State<_SkipDialog> createState() => _SkipDialogState();
}

class _SkipDialogState extends State<_SkipDialog> {
  static const _quick = ['time', 'pain', 'fatigue', 'equipment'];
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _chip(String c) {
    final t = _ctrl.text.trim();
    _ctrl.text = t.isEmpty ? c : '$c — $t';
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ok = _ctrl.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text('Skip ${widget.itemName}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_dayLabel(widget.day)} — the coach sees the reason; a '
              'skipped item is not counted as missed.'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            children: [
              for (final c in _quick)
                ActionChip(label: Text(c), onPressed: () => _chip(c)),
            ],
          ),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Reason (required)',
              hintText: 'e.g. elbow sore, gym closed',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: ok ? () => Navigator.pop(context, _ctrl.text.trim()) : null,
          child: const Text('Skip'),
        ),
      ],
    );
  }
}

class _ExerciseRow extends StatelessWidget {
  final PrescribedItem item;
  final bool showCheck;
  final VoidCallback? onTap;

  /// Ghost (moved-out origin): muted, "→ Fri", no checkbox; its menu
  /// only offers Undo move.
  final DateTime? movedTo;

  /// Moved-in: a small "from Wed" chip.
  final DateTime? movedFrom;

  /// Trailing overflow menu (Move to… / Skip… / Undo); null → none.
  final _RowMenu? menu;

  /// The Plan tab's priced lines (text, is-top-set) — replace the prose
  /// scheme when present.
  final List<(String, bool)> pricedLines;

  /// Non-null when the item was skipped that day (muted, "skipped — …").
  final String? skipReason;

  const _ExerciseRow({
    required this.item,
    required this.showCheck,
    this.onTap,
    this.movedTo,
    this.movedFrom,
    this.menu,
    this.pricedLines = const [],
    this.skipReason,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final ghost = movedTo != null;
    final skipped = !ghost && skipReason != null;
    final done = !ghost && !skipped && item.done;
    final partial = !ghost && !skipped && !done && item.loggedSets > 0;
    final (icon, markColor) = skipped
        ? (Icons.block, muted)
        : !showCheck
        ? (Icons.fitness_center, muted)
        : done
            ? (Icons.check_circle, scheme.primary)
            : partial
                ? (Icons.pie_chart_outline, scheme.tertiary)
                : (Icons.circle_outlined, muted);
    // Whoop credit note ("strain 14.8") wins over the set counter.
    final counter = ghost
        ? '→ ${_wd(movedTo!)}'
        : skipped
        ? null
        : item.creditNote ??
            (showCheck && (item.loggedSets > 0 || item.targetSets > 1)
                ? '${item.loggedSets}/${item.targetSets}'
                : null);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1, right: 8),
              child: ghost
                  ? const SizedBox(width: 16, height: 16)
                  : Icon(icon, size: 16, color: markColor),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          ghost || skipped ? FontWeight.w400 : FontWeight.w600,
                      color: done || ghost || skipped ? muted : scheme.onSurface,
                      decoration: done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (pricedLines.isNotEmpty)
                    for (final (text, top) in pricedLines)
                      Text(text,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                            fontWeight:
                                top && !skipped ? FontWeight.w600 : null,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ))
                  else if (item.scheme.isNotEmpty)
                    Text(item.scheme,
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: muted)),
                  if (skipped)
                    Text('skipped — $skipReason',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: muted, fontStyle: FontStyle.italic)),
                  if (movedFrom != null)
                    Container(
                      margin: const EdgeInsets.only(top: 3),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('from ${_wd(movedFrom!)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSecondaryContainer)),
                    ),
                ],
              ),
            ),
            if (counter != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(counter,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: done ? scheme.primary : muted,
                      fontWeight: FontWeight.w600,
                    )),
              ),
            if (onTap != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 1),
                child: Icon(Icons.info_outline, size: 14, color: muted),
              ),
            if (menu != null)
              SizedBox(
                width: 28,
                height: 20,
                child: PopupMenuButton<String>(
                  tooltip: 'Move / skip',
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: Icon(Icons.more_vert, size: 18, color: muted),
                  onSelected: (v) {
                    if (v == 'move') menu!.onMove?.call();
                    if (v == 'undo') menu!.onUndo?.call();
                    if (v == 'skip') menu!.onSkip?.call();
                    if (v == 'unskip') menu!.onUndoSkip?.call();
                  },
                  itemBuilder: (_) => [
                    if (menu!.onMove != null)
                      const PopupMenuItem(
                          value: 'move', child: Text('Move to…')),
                    if (menu!.onSkip != null)
                      const PopupMenuItem(value: 'skip', child: Text('Skip…')),
                    if (menu!.onUndo != null)
                      const PopupMenuItem(
                          value: 'undo', child: Text('Undo move')),
                    if (menu!.onUndoSkip != null)
                      const PopupMenuItem(
                          value: 'unskip', child: Text('Undo skip')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
