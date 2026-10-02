import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/view_schema.dart';
import '../../services/day_prescription.dart';
import '../../services/log_event_bus.dart';
import '../../services/missed_work.dart';
import '../../services/prescribed_exercises.dart';
import '../../services/program_moves.dart';
import '../../services/program_provider.dart' show ProgramProvider;
import '../../services/program_week.dart' show dayOnly, mondayOf;
import '../../services/set_recommendation.dart';
import '../../services/sync_scheduler.dart';
import '../../services/warehouse_connector.dart';
import '../../services/week_state_loader.dart';
import '../../services/whoop_activity.dart';

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
    this.programMovesView,
    this.programMovesRepo,
    this.cardioView,
    this.cardioRepo,
    this.climbingView,
    this.climbingRepo,
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

  const _DayData(this.prescription, this.items, this.week, this.missed);

  List<EffectiveItem> get live => [
        for (final e in items)
          if (!e.isGhost) e,
      ];
}

const _wdNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _wd(DateTime d) => _wdNames[d.weekday - 1];
String _dayLabel(DateTime d) => '${_wd(d)} ${d.month}/${d.day}';

/// "Bench heavy — Wed, 0/1 sets" / "Climb — Tue, not logged".
String missedLine(MissedItem m) => '${m.item.name} — ${_wd(m.day)}, '
    '${m.isSession ? 'not logged' : '${m.item.loggedSets}/${m.item.targetSets} sets'}';

class ProgramDayCardState extends State<ProgramDayCard> {
  late Future<_DayData?> _future;
  StreamSubscription<LogEvent>? _logSub;

  /// Strength rows from the last [_load] — reused by the info sheet so a
  /// tap doesn't re-list the whole table (thousands of rows) before the
  /// sheet can open. Refreshed with every reload (log events included).
  List<Map<String, Object?>>? _strengthRows;

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

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  Future<_DayData?> _load() async {
    final provider = widget.provider;
    if (provider == null) return null;
    final date = dayOnly(widget.date);
    final isToday = date == dayOnly(widget.now());
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
      entries =
          mapLive((items) => markPrescribedDone(items, state.loggedOnDate));
    }
    final day = [
      for (final a in state.whoop)
        if (_sameDay(a.date, date)) a,
    ];
    if (day.isNotEmpty) {
      entries = mapLive((items) => creditClimbItems(items, day));
    }
    return _DayData(state.prescription, entries, state.week, state.missed);
  }

  bool get _canMove =>
      widget.programMovesView != null && widget.programMovesRepo != null;

  /// Bottom sheet of the week's days (Mon–Sun of [anyDay]); the
  /// [current] day is disabled. Returns the picked day or null.
  Future<DateTime?> _pickDay(BuildContext context, String itemName,
      DateTime anyDay, DateTime current, _DayData data) {
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
                  return ListTile(
                    dense: true,
                    enabled: !isCurrent,
                    title: Text(
                        '${_dayLabel(d)}${d == today ? ' · today' : ''}',
                        style: d == today
                            ? const TextStyle(fontWeight: FontWeight.w700)
                            : null),
                    subtitle: Text(
                      isCurrent
                          ? 'current day'
                          : live == 0
                              ? 'rest'
                              : '$live item${live == 1 ? '' : 's'}',
                      style: TextStyle(color: muted),
                    ),
                    onTap: isCurrent ? null : () => Navigator.pop(ctx, d),
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
    final to = await _pickDay(context, item.name, home, current, data);
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

  Future<void> _undoMove(ProgramMove move) async {
    final view = widget.programMovesView;
    final repo = widget.programMovesRepo;
    if (view == null || repo == null) return;
    await _write(() => repo.delete(view, <String, Object?>{'id': move.id}));
  }

  Future<void> _write(Future<Object?> Function() op) async {
    try {
      await op();
      unawaited(SyncScheduler.instance?.maybeSync(manual: true));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('Move failed: $e')));
      }
    }
    reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DayData?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Card(
            margin: EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SizedBox(
              height: 96,
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        final data = snap.data;
        if (data == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurfaceVariant;
        final p = data.prescription;
        final showChecks = widget.strengthView != null;
        final live = data.live;
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
        _ExerciseRow(
          item: e.item,
          showCheck: showChecks,
          movedTo: e.movedTo,
          movedFrom: e.movedFrom,
          onTap: widget.strengthView == null
              ? null
              : () => _showExerciseInfo(context, e.item),
          menu: e.isGhost || !_canMove
              ? null
              : _RowMenu(
                  onMove: () => _moveItem(context, data,
                      item: e.item,
                      home: e.home,
                      current: dayOnly(widget.date)),
                  onUndo: e.movedFrom == null || e.move == null
                      ? null
                      : () => _undoMove(e.move!),
                ),
        ),
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
              if (_canMove)
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
          ),
        ),
    ];
  }

  /// Tap a prescribed movement → how last week's comparable session went
  /// (sets, reps, load, RPE, notes) + a recommendation for today.
  Future<void> _showExerciseInfo(
      BuildContext context, PrescribedItem item) async {
    final sv = widget.strengthView;
    final sr = widget.strengthRepo;
    if (sv == null || sr == null) return;
    final today =
        DateTime(widget.date.year, widget.date.month, widget.date.day);

    // Latest comparable session strictly before the shown day.
    final byDay = <DateTime, List<PriorSet>>{};
    String? note;
    try {
      for (final r in _strengthRows ?? await sr.list(sv)) {
        final ex = r['exercise']?.toString();
        if (ex == null || !loggedMatchesPrescribed(ex, item.name)) continue;
        final d = _date(r['date']);
        if (d == null) continue;
        final day = DateTime(d.year, d.month, d.day);
        if (!day.isBefore(today)) continue;
        (byDay[day] ??= []).add(PriorSet(
          reps: _int(r['reps']),
          weight: _numOf(r['weight']),
          rpe: _numOf(r['rpe']),
        ));
        final n = r['notes']?.toString().trim();
        if (n != null && n.isNotEmpty) note = n;
      }
    } catch (_) {/* honest empty */}

    DateTime? lastDay;
    for (final d in byDay.keys) {
      if (lastDay == null || d.isAfter(lastDay)) lastDay = d;
    }
    final rec = recommendSet(lastDay == null ? const [] : byDay[lastDay]!);

    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final muted = theme.colorScheme.onSurfaceVariant;
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
                const SizedBox(height: 14),
                if (rec.lastSessionSummary != null) ...[
                  Text('LAST SESSION',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(letterSpacing: 0.8, color: muted)),
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
                Text('RECOMMENDATION',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(letterSpacing: 0.8, color: muted)),
                const SizedBox(height: 3),
                Text(rec.advice, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        );
      },
    );
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.round();
    return null;
  }

  static double? _numOf(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

class _RowMenu {
  final VoidCallback onMove;
  final VoidCallback? onUndo;
  const _RowMenu({required this.onMove, this.onUndo});
}

class _ExerciseRow extends StatelessWidget {
  final PrescribedItem item;
  final bool showCheck;
  final VoidCallback? onTap;

  /// Ghost (moved-out origin): muted, "→ Fri", no checkbox, no menu.
  final DateTime? movedTo;

  /// Moved-in: a small "from Wed" chip.
  final DateTime? movedFrom;

  /// Trailing overflow menu (Move to… / Undo move); null → none.
  final _RowMenu? menu;

  const _ExerciseRow({
    required this.item,
    required this.showCheck,
    this.onTap,
    this.movedTo,
    this.movedFrom,
    this.menu,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final ghost = movedTo != null;
    final done = !ghost && item.done;
    final partial = !ghost && !done && item.loggedSets > 0;
    final (icon, markColor) = !showCheck
        ? (Icons.fitness_center, muted)
        : done
            ? (Icons.check_circle, scheme.primary)
            : partial
                ? (Icons.pie_chart_outline, scheme.tertiary)
                : (Icons.circle_outlined, muted);
    // Whoop credit note ("strain 14.8") wins over the set counter.
    final counter = ghost
        ? '→ ${_wd(movedTo!)}'
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
                      fontWeight: ghost ? FontWeight.w400 : FontWeight.w600,
                      color: done || ghost ? muted : scheme.onSurface,
                      decoration: done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (item.scheme.isNotEmpty)
                    Text(item.scheme,
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: muted)),
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
                  tooltip: 'Move',
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: Icon(Icons.more_vert, size: 18, color: muted),
                  onSelected: (v) {
                    if (v == 'move') menu!.onMove();
                    if (v == 'undo') menu!.onUndo?.call();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'move', child: Text('Move to…')),
                    if (menu!.onUndo != null)
                      const PopupMenuItem(
                          value: 'undo', child: Text('Undo move')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
