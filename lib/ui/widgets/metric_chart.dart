/// Shared compact metric-series chart (extracted from domain_screen so
/// the Program screen's OBSERVED Wilks block renders through the SAME
/// widget as the strength domain's wilks_series — one chart, two
/// callers, no fork).
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/domain_metrics.dart' show MetricSeries;
import 'chart_bottom_axis.dart';
import 'pinned_tooltip_line_chart.dart';

/// Compact series chart: raw points (faint), optional smoothed line
/// (solid), optional flat goal line (dashed tertiary), optional
/// acceptable-drop floor line (dotted error color — the "act if you
/// sink under this" line, e.g. wilks_series' cut floor). Window = the
/// trailing 84 days; widens to full history when the window holds
/// fewer than two points (sparse series like caliper body-fat) or when
/// the series asks for it ([MetricSeries.fullHistory] — monthly
/// trends). Same fl_chart machinery as the Program screen's weight
/// chart, shrunk to header size.
class MetricChart extends StatelessWidget {
  final MetricSeries series;
  final DateTime today;
  final String? goalNote;

  /// Plot height. The 130px default is header/inline size; the domain
  /// screens' Trends mode passes a taller value so charts get the room
  /// the old squeezed-above-the-ledger layout never had.
  final double height;

  const MetricChart({
    super.key,
    required this.series,
    required this.today,
    this.goalNote,
    this.height = 130,
  });

  static double _x(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    var windowStart = DateTime(today.year, today.month, today.day - 84);
    var points = [
      for (final p in series.points)
        if (!p.day.isBefore(windowStart)) p,
    ];
    if (series.fullHistory || points.length < 2) {
      points = series.points;
      if (points.isNotEmpty) windowStart = points.first.day;
    }
    if (points.isEmpty) {
      return Text(
        '(no data in range)',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    final avg = [
      for (final p in series.avg)
        if (!p.day.isBefore(windowStart)) p,
    ];

    final xMin = _x(windowStart);
    final xMax = _x(today);
    final rawSpots = [for (final p in points) FlSpot(_x(p.day), p.value)];
    final avgSpots = [for (final p in avg) FlSpot(_x(p.day), p.value)];
    final goal = series.goal;
    final floor = series.floor;
    final bandLow = series.bandLow;
    final bandHigh = series.bandHigh;

    final ys = [
      for (final s in rawSpots) s.y,
      for (final s in avgSpots) s.y,
      ?goal,
      ?floor,
      ?bandLow,
      ?bandHigh,
    ];
    final yMin = ys.reduce((a, b) => a < b ? a : b);
    final yMax = ys.reduce((a, b) => a > b ? a : b);
    final yPad = ((yMax - yMin).abs() * 0.1).clamp(0.5, 5.0);

    // Goal band (protein): two flat bounds shaded between via
    // fl_chart's betweenBarsData — a range target, not a line. Indices
    // into lineBarsData are positional, so the band pair goes FIRST and
    // everything after is data.
    final bars = <LineChartBarData>[];
    final hasBand = bandLow != null && bandHigh != null;
    if (hasBand) {
      for (final bound in [bandLow, bandHigh]) {
        bars.add(
          LineChartBarData(
            spots: [FlSpot(xMin, bound), FlSpot(xMax, bound)],
            isCurved: false,
            barWidth: 0.8,
            color: scheme.tertiary.withValues(alpha: 0.35),
            dotData: const FlDotData(show: false),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          // LayoutBuilder: the bottom-axis tick keeper needs the plot's
          // pixel width to estimate label overlap (chart_bottom_axis).
          child: LayoutBuilder(
            builder: (context, constraints) => PinnedTooltipLineChart(
              data: LineChartData(
                minX: xMin,
                maxX: xMax,
                minY: yMin - yPad,
                maxY: yMax + yPad,
                clipData: const FlClipData.all(),
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(),
                  topTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 34,
                      getTitlesWidget: (value, meta) => Text(
                        value.toStringAsFixed(0),
                        style: const TextStyle(fontSize: 9),
                      ),
                    ),
                  ),
                  // Explicit non-overlapping date ticks (endpoints +
                  // month starts) — see chart_bottom_axis.dart.
                  bottomTitles: AxisTitles(
                    sideTitles: dateBottomTitles(
                      minX: xMin,
                      maxX: xMax,
                      plotWidth: (constraints.maxWidth - 34).clamp(1, 10000),
                      style: const TextStyle(fontSize: 8),
                      reservedSize: 22,
                      space: 3,
                    ),
                  ),
                ),
                betweenBarsData: [
                  if (hasBand)
                    BetweenBarsData(
                      fromIndex: 0,
                      toIndex: 1,
                      color: scheme.tertiary.withValues(alpha: 0.12),
                    ),
                ],
                lineBarsData: [
                  ...bars,
                  LineChartBarData(
                    spots: rawSpots,
                    isCurved: false,
                    barWidth: 1,
                    color: scheme.primary.withValues(
                      alpha: avgSpots.isEmpty ? 0.9 : 0.25,
                    ),
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, pct, bar, i) => FlDotCirclePainter(
                        radius: 1.8,
                        color: scheme.primary.withValues(
                          alpha: avgSpots.isEmpty ? 0.9 : 0.35,
                        ),
                        strokeWidth: 0,
                      ),
                    ),
                  ),
                  if (avgSpots.isNotEmpty)
                    LineChartBarData(
                      spots: avgSpots,
                      isCurved: false,
                      barWidth: 2.2,
                      color: scheme.primary,
                      dotData: const FlDotData(show: false),
                    ),
                  if (goal != null)
                    LineChartBarData(
                      spots: [FlSpot(xMin, goal), FlSpot(xMax, goal)],
                      isCurved: false,
                      barWidth: 1.5,
                      color: scheme.tertiary,
                      dashArray: [6, 4],
                      dotData: const FlDotData(show: false),
                    ),
                  // Acceptable-drop floor: dotted, error-toned — visually
                  // subordinate to the goal line it hangs under.
                  if (floor != null)
                    LineChartBarData(
                      spots: [FlSpot(xMin, floor), FlSpot(xMax, floor)],
                      isCurved: false,
                      barWidth: 1.2,
                      color: scheme.error.withValues(alpha: 0.7),
                      dashArray: [2, 4],
                      dotData: const FlDotData(show: false),
                    ),
                ],
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) =>
                        Colors.black.withValues(alpha: 0.55),
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (spots) => [
                      for (final s in spots)
                        LineTooltipItem(
                          '${DateFormat('MMM d').format(DateTime.fromMillisecondsSinceEpoch((s.x * 86400000).toInt(), isUtc: true))}\n'
                          '${s.y.toStringAsFixed(1)}',
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            height: 1.3,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (goal != null || floor != null || hasBand || goalNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              [
                if (goal != null)
                  'goal ${goal.toStringAsFixed(goal == goal.roundToDouble() ? 0 : 1)}'
                      '${series.unit == null ? '' : ' ${series.unit}'}',
                if (floor != null)
                  'floor ${floor.toStringAsFixed(floor == floor.roundToDouble() ? 0 : 1)}'
                      '${series.unit == null ? '' : ' ${series.unit}'}',
                if (hasBand)
                  'goal ${bandLow.round()}–${bandHigh.round()}'
                      '${series.unit == null ? '' : ' ${series.unit}'}',
                ?goalNote,
              ].join(' · '),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
