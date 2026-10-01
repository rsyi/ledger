import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/view_schema.dart';
import '../../services/log_event_bus.dart';
import '../../services/today_training.dart';
import '../../services/warehouse_connector.dart';

/// "What you've trained" for the selected day — logged strength grouped
/// per exercise (Squat — 3 sets · top 275×3). Live via the log bus.
class TrainingProgressCard extends StatefulWidget {
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;
  final DateTime date;

  const TrainingProgressCard({
    super.key,
    required this.strengthView,
    required this.strengthRepo,
    required this.date,
  });

  @override
  TrainingProgressCardState createState() => TrainingProgressCardState();
}

class TrainingProgressCardState extends State<TrainingProgressCard> {
  late Future<TrainingToday> _future;
  StreamSubscription<LogEvent>? _logSub;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _logSub = LogEventBus.instance.stream.listen((_) => reload());
  }

  @override
  void didUpdateWidget(TrainingProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameDay(oldWidget.date, widget.date)) reload();
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

  Future<TrainingToday> _load() async {
    final sv = widget.strengthView;
    final sr = widget.strengthRepo;
    if (sv == null || sr == null) return const TrainingToday([]);
    final sets = <TrainingSet>[];
    try {
      for (final r in await sr.list(sv)) {
        final d = _date(r['date']);
        if (d == null || !_sameDay(d, widget.date)) continue;
        final ex = r['exercise']?.toString().trim();
        if (ex == null || ex.isEmpty) continue;
        sets.add(TrainingSet(
          exercise: ex,
          reps: _int(r['reps']),
          weight: _num(r['weight']),
        ));
      }
    } catch (_) {/* honest empty */}
    return summarizeTraining(sets);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TrainingToday>(
      future: _future,
      builder: (context, snap) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final muted = scheme.onSurfaceVariant;
        final t = snap.data;
        return Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TRAINED',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(letterSpacing: 0.8, color: muted)),
                const SizedBox(height: 6),
                if (t == null)
                  const SizedBox(height: 14)
                else if (t.isEmpty)
                  Text('Nothing logged yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted))
                else
                  for (final e in t.exercises)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1, right: 8),
                            child: Icon(Icons.check_circle,
                                size: 15, color: scheme.primary),
                          ),
                          Expanded(
                            child: Text(trainingLineFor(e),
                                style: theme.textTheme.bodyMedium),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}
