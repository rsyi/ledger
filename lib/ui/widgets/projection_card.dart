/// FROZEN PHASE PROJECTION card (phase-projections spec 2026-10-02):
/// one metric's projection frozen at the block start — the shaded band
/// + the projected line — with the actuals overlaid, a tracking chip
/// (on track / ahead / behind) and one plain-language line
/// ("0.4 lb ahead of projection").
///
/// No snapshot for the block yet → the LIVE model line for the block
/// with the actuals, labelled "No frozen projection yet" (graceful
/// fallback; the nightly writer freezes one at the block's first run).
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/projection_snapshot.dart';
import '../../services/projection_tracking.dart';
import '../design/design.dart';
import 'chart_bottom_axis.dart';

/// Plain title per metric.
String projectionMetricTitle(String metric) => switch (metric) {
  ProjectionMetric.bodyweight => 'Bodyweight',
  ProjectionMetric.bodyFat => 'Body fat',
  ProjectionMetric.strengthTotal => 'Strength total',
  ProjectionMetric.e1rmSquat => 'Squat estimated max',
  ProjectionMetric.e1rmBench => 'Bench estimated max',
  ProjectionMetric.e1rmDeadlift => 'Deadlift estimated max',
  ProjectionMetric.e1rmPress => 'Overhead press estimated max',
  ProjectionMetric.vo2max => 'VO2 max',
  ProjectionMetric.climbingGrade => 'Climbing grade',
  _ => metric,
};

/// "160.7 lb", "12.1%", "895 lb", "V5.2", "52.3".
String fmtProjectionValue(String metric, double v) => switch (metric) {
  ProjectionMetric.bodyweight => '${v.toStringAsFixed(1)} lb',
  ProjectionMetric.bodyFat => '${v.toStringAsFixed(1)}%',
  ProjectionMetric.vo2max => v.toStringAsFixed(1),
  ProjectionMetric.climbingGrade => 'V${v.toStringAsFixed(1)}',
  _ => '${v.round()} lb',
};

/// Chip label + status colour for a tracking status.
(String, ItemStatus) trackingChip(TrackingStatus s) => switch (s) {
  TrackingStatus.onTrack => ('on track', ItemStatus.done),
  TrackingStatus.ahead => ('ahead', ItemStatus.done),
  TrackingStatus.behind => ('behind', ItemStatus.partial),
  TrackingStatus.noData => ('no data', ItemStatus.muted),
};

class ProjectionCard extends StatelessWidget {
  final String metric;
  final String? title;

  /// The block's FIRST snapshot (frozen); null → live fallback.
  final ProjectionSnapshot? snapshot;

  /// Actual sources (weigh-ins, BF, strength, climbs).
  final PhaseProjections? projections;
  final DateTime today;

  /// The date tracked against (default [today]; a past block passes its
  /// end day).
  final DateTime? trackDay;

  /// Live model line for the current block (the no-snapshot fallback).
  final List<(DateTime, double)> liveLine;

  /// Card chrome off (when nested inside another card/fold).
  final bool bare;

  const ProjectionCard({
    super.key,
    required this.metric,
    required this.today,
    this.title,
    this.snapshot,
    this.projections,
    this.trackDay,
    this.liveLine = const [],
    this.bare = false,
  });

  @override
  Widget build(BuildContext context) {
    final points = snapshot?.metrics[metric] ?? const <ProjectionPoint>[];
    final frozen = points.isNotEmpty;
    final day = trackDay ?? today;
    final meta = AppText.meta(context);

    DateTime d0(DateTime d) => DateTime.utc(d.year, d.month, d.day);
    final todayD = d0(today);
    final from = frozen
        ? points.first.weekStart
        : (liveLine.isEmpty ? todayD : d0(liveLine.first.$1));
    final to = frozen
        ? points.last.weekStart
        : (liveLine.isEmpty ? todayD : d0(liveLine.last.$1));
    final actualTo = todayD.isBefore(to) ? todayD : to;
    final actual = projections == null
        ? const <(DateTime, double)>[]
        : projections!.actualSeries(metric, from, actualTo);

    final tracking = frozen
        ? trackMetric(
            metric: metric,
            points: points,
            day: day,
            actual: projections?.actualAt(metric, day),
            emphasis: snapshot!.emphasis,
          )
        : null;

    final header = Row(
      children: [
        Expanded(
          child: Text(
            title ?? projectionMetricTitle(metric),
            style: AppText.title(context),
          ),
        ),
        if (tracking != null)
          () {
            final (label, status) = trackingChip(tracking.status);
            return StatusChip(
              key: ValueKey('projection-chip-$metric'),
              label: label,
              status: status,
            );
          }()
        else
          StatusChip(
            key: ValueKey('projection-chip-$metric'),
            label: 'not frozen',
            status: ItemStatus.muted,
          ),
      ],
    );

    final fmt = DateFormat('MMM d');
    final body = Column(
      key: bare ? ValueKey('projection-card-$metric') : null,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: 6),
        if (frozen || liveLine.isNotEmpty)
          _ProjectionChart(
            key: ValueKey('projection-chart-$metric'),
            points: points,
            liveLine: liveLine,
            actual: actual,
            today: todayD,
            decimals:
                metric == ProjectionMetric.bodyweight ||
                    metric == ProjectionMetric.bodyFat ||
                    metric == ProjectionMetric.climbingGrade ||
                    metric == ProjectionMetric.vo2max
                ? 1
                : 0,
          ),
        const SizedBox(height: 6),
        if (tracking != null) ...[
          Text(
            sentenceCaseFirst(tracking.line),
            key: ValueKey('projection-line-$metric'),
            style: AppText.row(context),
          ),
          if (tracking.projected != null)
            Text(
              '${tracking.actual == null ? 'No actual yet' : 'Now ${fmtProjectionValue(metric, tracking.actual!)}'}'
              ' · projected ${fmtProjectionValue(metric, tracking.projected!)}'
              ' (range ${fmtProjectionValue(metric, tracking.lo!)}–'
              '${fmtProjectionValue(metric, tracking.hi!)})',
              key: ValueKey('projection-detail-$metric'),
              style: meta,
            ),
          Text(
            'Projected at the block start '
            '(${fmt.format(points.first.weekStart)}) and frozen — the '
            'shaded band is the projected range; the solid line is what '
            'actually happened.',
            style: meta,
          ),
        ] else
          Text(
            'No frozen projection yet — showing the live model line '
            '(it recalibrates nightly). The block\'s projection is frozen '
            'at its first nightly run.',
            key: ValueKey('projection-none-$metric'),
            style: meta,
          ),
      ],
    );
    if (bare) return body;
    return AppCard(
      key: ValueKey('projection-card-$metric'),
      padding: const EdgeInsets.all(12),
      child: body,
    );
  }
}

/// "0.4 lb ahead…" → "0.4 lb ahead…"; "on projection…" → "On projection…".
String sentenceCaseFirst(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

double _x(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

class _ProjectionChart extends StatelessWidget {
  final List<ProjectionPoint> points;
  final List<(DateTime, double)> liveLine;
  final List<(DateTime, double)> actual;
  final DateTime today;
  final int decimals;

  const _ProjectionChart({
    super.key,
    required this.points,
    required this.liveLine,
    required this.actual,
    required this.today,
    required this.decimals,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final frozen = points.isNotEmpty;
    final xs = [
      if (frozen) ...[
        _x(points.first.weekStart),
        _x(points.last.weekStart),
      ] else if (liveLine.isNotEmpty) ...[
        _x(liveLine.first.$1),
        _x(liveLine.last.$1),
      ],
    ];
    if (xs.isEmpty) return const SizedBox.shrink();
    final xMin = xs.first;
    final xMax = math.max(xs.last, xMin + 7);
    final ys = <double>[
      for (final p in points) ...[p.lo, p.hi],
      for (final p in liveLine) p.$2,
      for (final p in actual) p.$2,
    ];
    final yMin = ys.reduce(math.min);
    final yMax = ys.reduce(math.max);
    final yPad = ((yMax - yMin).abs() * 0.08).clamp(0.2, 20.0);
    final tx = _x(today);

    final bars = <LineChartBarData>[
      if (frozen) ...[
        LineChartBarData(
          spots: [for (final p in points) FlSpot(_x(p.weekStart), p.lo)],
          color: Colors.transparent,
          barWidth: 0,
          dotData: const FlDotData(show: false),
        ),
        LineChartBarData(
          spots: [for (final p in points) FlSpot(_x(p.weekStart), p.hi)],
          color: Colors.transparent,
          barWidth: 0,
          dotData: const FlDotData(show: false),
        ),
        LineChartBarData(
          spots: [for (final p in points) FlSpot(_x(p.weekStart), p.projected)],
          color: scheme.primary.withValues(alpha: 0.8),
          barWidth: 2,
          dashArray: const [6, 4],
          dotData: const FlDotData(show: false),
        ),
      ] else if (liveLine.isNotEmpty)
        LineChartBarData(
          spots: [for (final p in liveLine) FlSpot(_x(p.$1), p.$2)],
          color: scheme.outline,
          barWidth: 1.6,
          dashArray: const [3, 4],
          dotData: const FlDotData(show: false),
        ),
      if (actual.isNotEmpty)
        LineChartBarData(
          spots: [for (final p in actual) FlSpot(_x(p.$1), p.$2)],
          color: scheme.secondary,
          barWidth: 2.4,
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, pct, bar, i) => FlDotCirclePainter(
              radius: 2.2,
              color: scheme.secondary,
              strokeWidth: 0,
            ),
          ),
        ),
    ];

    return SizedBox(
      height: 170,
      child: LayoutBuilder(
        builder: (context, constraints) => LineChart(
          LineChartData(
            minX: xMin,
            maxX: xMax,
            minY: yMin - yPad,
            maxY: yMax + yPad,
            clipData: const FlClipData.all(),
            gridData: const FlGridData(show: true, drawVerticalLine: false),
            borderData: FlBorderData(show: false),
            betweenBarsData: [
              if (frozen)
                BetweenBarsData(
                  fromIndex: 0,
                  toIndex: 1,
                  color: scheme.primary.withValues(alpha: 0.12),
                ),
            ],
            extraLinesData: ExtraLinesData(
              verticalLines: [
                if (tx > xMin && tx < xMax)
                  VerticalLine(
                    x: tx,
                    color: scheme.outline.withValues(alpha: 0.6),
                    strokeWidth: 1,
                    dashArray: const [2, 3],
                  ),
              ],
            ),
            titlesData: FlTitlesData(
              rightTitles: const AxisTitles(),
              topTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (value, meta) => Text(
                    value.toStringAsFixed(decimals),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: dateBottomTitles(
                  minX: xMin,
                  maxX: xMax,
                  plotWidth: (constraints.maxWidth - 40).clamp(1, 10000),
                  style: const TextStyle(fontSize: 11),
                  reservedSize: 28,
                ),
              ),
            ),
            lineBarsData: bars,
            lineTouchData: const LineTouchData(enabled: false),
          ),
        ),
      ),
    );
  }
}
