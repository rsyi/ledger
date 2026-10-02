import 'package:flutter/material.dart';

import '../../models/view_schema.dart';
import '../../services/warehouse_connector.dart';
import '../design/design.dart';

/// Top-of-Today readiness: Whoop recovery score + hours slept for the
/// selected day. Recovery is keyed on the wake date (one row per day).
class RecoveryCard extends StatefulWidget {
  final ViewSchema? recoveryView;
  final WarehouseConnector? recoveryRepo;
  final DateTime date;

  const RecoveryCard({
    super.key,
    required this.recoveryView,
    required this.recoveryRepo,
    required this.date,
  });

  @override
  RecoveryCardState createState() => RecoveryCardState();
}

class _Recovery {
  final double? score; // 0-100
  final double? sleepHours;
  final double? hrv;
  final double? restingHr;
  const _Recovery({this.score, this.sleepHours, this.hrv, this.restingHr});
}

class RecoveryCardState extends State<RecoveryCard> {
  late Future<_Recovery?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(RecoveryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameDay(oldWidget.date, widget.date)) reload();
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

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  Future<_Recovery?> _load() async {
    final view = widget.recoveryView;
    final repo = widget.recoveryRepo;
    if (view == null || repo == null) return null;
    try {
      for (final r in await repo.list(view)) {
        final d = _date(r['date']);
        if (d == null || !_sameDay(d, widget.date)) continue;
        return _Recovery(
          score: _num(r['recovery_score']),
          sleepHours: _num(r['sleep_hours']),
          hrv: _num(r['hrv_ms']),
          restingHr: _num(r['resting_hr']),
        );
      }
    } catch (_) {/* honest empty */}
    return const _Recovery();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Recovery?>(
      future: _future,
      builder: (context, snap) {
        if (widget.recoveryView == null) return const SizedBox.shrink();
        final r = snap.data;
        final hasData =
            r != null && (r.score != null || r.sleepHours != null);

        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const SizedBox(
            height: 18,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        } else if (!hasData) {
          body = Text('No recovery data for this day.',
              style: AppText.meta(context));
        } else {
          body = StatStrip(items: [
            if (r.score != null)
              StatItem('Recovery', '${r.score!.round()}%',
                  status: recoveryStatus(r.score)),
            if (r.sleepHours != null)
              StatItem('Sleep', '${r.sleepHours!.toStringAsFixed(1)}h'),
            if (r.hrv != null) StatItem('HRV', '${r.hrv!.round()}'),
            if (r.restingHr != null)
              StatItem('RHR', '${r.restingHr!.round()}'),
          ]);
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpace.gutter, 2, AppSpace.gutter, AppSpace.sectionGap),
          child: body,
        );
      },
    );
  }
}

/// Whoop bands: green >= 67, amber 34-66, red < 34.
ItemStatus? recoveryStatus(double? score) {
  if (score == null) return null;
  if (score >= 67) return ItemStatus.done;
  if (score >= 34) return ItemStatus.partial;
  return ItemStatus.problem;
}
