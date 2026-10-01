import 'package:flutter/material.dart';

import '../../models/view_schema.dart';
import '../../services/warehouse_connector.dart';

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
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final muted = scheme.onSurfaceVariant;
        final r = snap.data;
        final hasData =
            r != null && (r.score != null || r.sleepHours != null);

        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const SizedBox(
            height: 20,
            child: Center(
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        } else if (!hasData) {
          body = Text('No recovery data for this day.',
              style: theme.textTheme.bodyMedium?.copyWith(color: muted));
        } else {
          body = Row(
            children: [
              _Metric(
                label: 'Recovery',
                value: r.score == null ? '—' : '${r.score!.round()}%',
                color: _recoveryColor(r.score, scheme),
              ),
              const SizedBox(width: 24),
              _Metric(
                label: 'Slept',
                value: r.sleepHours == null
                    ? '—'
                    : '${r.sleepHours!.toStringAsFixed(1)}h',
                color: scheme.onSurface,
              ),
              const Spacer(),
              if (r.restingHr != null || r.hrv != null)
                Text(
                  [
                    if (r.hrv != null) 'HRV ${r.hrv!.round()}',
                    if (r.restingHr != null) 'RHR ${r.restingHr!.round()}',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
            ],
          );
        }

        return Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: body,
          ),
        );
      },
    );
  }

  // Whoop bands: green >=67, yellow 34-66, red <34.
  Color _recoveryColor(double? score, ColorScheme scheme) {
    if (score == null) return scheme.onSurface;
    if (score >= 67) return scheme.primary;
    if (score >= 34) return scheme.tertiary;
    return scheme.error;
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Metric({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(value,
            style: theme.textTheme.titleLarge
                ?.copyWith(color: color, fontWeight: FontWeight.w700)),
        const SizedBox(width: 5),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
