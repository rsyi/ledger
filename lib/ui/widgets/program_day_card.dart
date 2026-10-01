import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/view_schema.dart';
import '../../services/day_prescription.dart';
import '../../services/log_event_bus.dart';
import '../../services/prescribed_exercises.dart';
import '../../services/program_current.dart' show programCurrent;
import '../../services/program_provider.dart' show IntentDocs, ProgramProvider;
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
        for (final r in await sr.list(sv)) {
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
      for (final it in group) _ExerciseRow(item: it, showCheck: showChecks),
    ];
  }
}

class _ExerciseRow extends StatelessWidget {
  final PrescribedItem item;
  final bool showCheck;
  const _ExerciseRow({required this.item, required this.showCheck});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final done = item.done;
    final markColor = done ? theme.colorScheme.primary : muted;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: Icon(
              showCheck
                  ? (done ? Icons.check_circle : Icons.circle_outlined)
                  : Icons.fitness_center,
              size: 16,
              color: showCheck ? markColor : muted,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: done ? muted : theme.colorScheme.onSurface,
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
        ],
      ),
    );
  }
}
