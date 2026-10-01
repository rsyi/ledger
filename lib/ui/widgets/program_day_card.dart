import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/view_schema.dart';
import '../../services/day_prescription.dart';
import '../../services/log_event_bus.dart';
import '../../services/program_current.dart' show programCurrent;
import '../../services/program_provider.dart' show IntentDocs, ProgramProvider;
import '../../services/today_training.dart';
import '../../services/warehouse_connector.dart';

/// A program-day reference card: the routine's PRESCRIBED session for a
/// date (the full AM/PM prose — front-lever work, hanging leg raises,
/// muscle-ups and all), optionally paired with a live "logged so far"
/// rollup so logging on the same screen visibly ticks the plan off.
///
/// Used two ways:
///  - Today tab → TOMORROW's plan (prose only, [strengthView] null).
///  - Log tab → TODAY's plan + what's been logged (live via LogEventBus).
class ProgramDayCard extends StatefulWidget {
  final ProgramProvider? provider;

  /// Relative label ("Today" / "Tomorrow") and day offset from today.
  final String label;
  final int dayOffset;

  /// When non-null, the card also shows the day's logged sets and keeps
  /// them live (log events refresh). Null → prescription only.
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;

  const ProgramDayCard({
    super.key,
    required this.provider,
    required this.label,
    required this.dayOffset,
    this.strengthView,
    this.strengthRepo,
  });

  @override
  ProgramDayCardState createState() => ProgramDayCardState();
}

class _DayData {
  final DayPrescription prescription;
  final TrainingToday? logged; // null when no strength overlay requested
  const _DayData(this.prescription, this.logged);
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
  void dispose() {
    _logSub?.cancel();
    super.dispose();
  }

  /// Re-reads program docs + (if shown) the day's logged sets.
  void reload() {
    if (mounted) setState(() => _future = _load());
  }

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.round();
    return null;
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
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

    final now = DateTime.now();
    final date = DateTime(now.year, now.month, now.day)
        .add(Duration(days: widget.dayOffset));
    final slice = programCurrent(program, docs.phase, date);
    final prescription = dayPrescription(
      label: widget.label,
      weekday: weekdayAbbr(date),
      template: slice?.todayTemplate,
    );

    TrainingToday? logged;
    final sv = widget.strengthView;
    final sr = widget.strengthRepo;
    if (sv != null && sr != null) {
      final sets = <TrainingSet>[];
      try {
        for (final r in await sr.list(sv)) {
          final d = _date(r['date']);
          if (d == null ||
              d.year != date.year ||
              d.month != date.month ||
              d.day != date.day) {
            continue;
          }
          final ex = r['exercise']?.toString().trim();
          if (ex == null || ex.isEmpty) continue;
          sets.add(TrainingSet(
            exercise: ex,
            reps: _int(r['reps']),
            weight: _num(r['weight']),
          ));
        }
      } catch (_) {/* honest empty */}
      logged = summarizeTraining(sets);
    }
    return _DayData(prescription, logged);
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
              height: 92,
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        final data = snap.data;
        if (data == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurfaceVariant;
        final p = data.prescription;
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
                    Text(p.label,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(width: 6),
                    Text(p.weekday,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                    const Spacer(),
                    if (p.isRest)
                      Text('Rest day',
                          style:
                              theme.textTheme.bodyMedium?.copyWith(color: muted)),
                  ],
                ),
                if (p.blockNote != null) ...[
                  const SizedBox(height: 2),
                  Text(p.blockNote!,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                ],
                if (p.morning != null) _Prose(tag: 'AM', text: p.morning!),
                if (p.afternoon != null) _Prose(tag: 'PM', text: p.afternoon!),
                if (data.logged != null) ...[
                  const Divider(height: 20),
                  _LoggedSoFar(logged: data.logged!),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Prose extends StatelessWidget {
  final String tag;
  final String text;
  const _Prose({required this.tag, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Text(tag,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                )),
          ),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// The live "what you've logged for this day" rollup under the plan.
class _LoggedSoFar extends StatelessWidget {
  final TrainingToday logged;
  const _LoggedSoFar({required this.logged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('LOGGED SO FAR',
            style: theme.textTheme.labelSmall
                ?.copyWith(letterSpacing: 0.8, color: muted)),
        const SizedBox(height: 4),
        if (logged.isEmpty)
          Text('Nothing logged yet.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted))
        else
          for (final e in logged.exercises)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle,
                      size: 15, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(trainingLineFor(e),
                        style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
