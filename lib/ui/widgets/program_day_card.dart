import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/view_schema.dart';
import '../../services/day_prescription.dart';
import '../../services/log_event_bus.dart';
import '../../services/prescribed_exercises.dart';
import '../../services/program_current.dart' show programCurrent;
import '../../services/program_provider.dart' show IntentDocs, ProgramProvider;
import '../../services/set_recommendation.dart';
import '../../services/warehouse_connector.dart';

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

  const ProgramDayCard({
    super.key,
    required this.provider,
    required this.label,
    required this.date,
    this.strengthView,
    this.strengthRepo,
  });

  @override
  ProgramDayCardState createState() => ProgramDayCardState();
}

class _DayData {
  final DayPrescription prescription;
  final List<PrescribedItem> items;
  const _DayData(this.prescription, this.items);
}

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
    if (!_sameDay(oldWidget.date, widget.date) || oldWidget.label != widget.label) reload();
  }

  @override
  void dispose() {
    _logSub?.cancel();
    super.dispose();
  }

  void reload() {
    if (mounted) setState(() => _future = _load());
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
    IntentDocs? docs;
    try {
      docs = await provider.load();
    } catch (_) {
      return null;
    }
    final program = docs.program;
    if (program == null) return null;

    final date =
        DateTime(widget.date.year, widget.date.month, widget.date.day);
    final slice = programCurrent(program, docs.phase, date);
    final prescription = dayPrescription(
      label: widget.label,
      weekday: weekdayAbbr(date),
      template: slice?.todayTemplate,
    );

    var items = parsePrescribedProse(prescription.morning, prescription.afternoon);

    final sv = widget.strengthView;
    final sr = widget.strengthRepo;
    if (sv != null && sr != null && items.isNotEmpty) {
      final logged = <String>[];
      try {
        final rows = await sr.list(sv);
        _strengthRows = rows;
        for (final r in rows) {
          final d = _date(r['date']);
          if (d == null || !_sameDay(d, date)) continue;
          final ex = r['exercise']?.toString().trim();
          if (ex != null && ex.isNotEmpty) logged.add(ex);
        }
      } catch (_) {/* honest empty */}
      items = markPrescribedDone(items, logged);
    }
    return _DayData(prescription, items);
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
        final doneCount = data.items.where((e) => e.done).length;

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
                    if (p.isRest)
                      Text('Rest day',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: muted))
                    else if (showChecks && data.items.isNotEmpty)
                      Text('$doneCount / ${data.items.length} done',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: doneCount == data.items.length
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
                    ..._periodBlock(context, data.items, period, showChecks),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _periodBlock(BuildContext context, List<PrescribedItem> items,
      String period, bool showChecks) {
    final group = items.where((e) => e.period == period).toList();
    if (group.isEmpty) return const [];
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final bothPeriods = items.any((e) => e.period == 'AM') &&
        items.any((e) => e.period == 'PM');
    return [
      if (bothPeriods)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text(period,
              style: theme.textTheme.labelSmall
                  ?.copyWith(letterSpacing: 0.8, color: muted)),
        ),
      for (final it in group)
        _ExerciseRow(
          item: it,
          showCheck: showChecks,
          onTap: widget.strengthView == null
              ? null
              : () => _showExerciseInfo(context, it),
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

class _ExerciseRow extends StatelessWidget {
  final PrescribedItem item;
  final bool showCheck;
  final VoidCallback? onTap;
  const _ExerciseRow({required this.item, required this.showCheck, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final done = item.done;
    final partial = !done && item.loggedSets > 0;
    final (icon, markColor) = !showCheck
        ? (Icons.fitness_center, muted)
        : done
            ? (Icons.check_circle, scheme.primary)
            : partial
                ? (Icons.pie_chart_outline, scheme.tertiary)
                : (Icons.circle_outlined, muted);
    // "k/N" when logged against a multi-set target.
    final counter = showCheck && (item.loggedSets > 0 || item.targetSets > 1)
        ? '${item.loggedSets}/${item.targetSets}'
        : null;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1, right: 8),
              child: Icon(icon, size: 16, color: markColor),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: done ? muted : scheme.onSurface,
                      decoration: done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (item.scheme.isNotEmpty)
                    Text(item.scheme,
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: muted)),
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
          ],
        ),
      ),
    );
  }
}
