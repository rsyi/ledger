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
import 'chart_range.dart';
import 'pinned_tooltip_line_chart.dart';

/// Compact series chart: raw points (faint), optional smoothed line
/// (solid), optional flat goal line (dashed tertiary), optional
/// acceptable-drop floor line (dotted error color — the "act if you
/// sink under this" line, e.g. wilks_series' cut floor), optional
/// all-time benchmark line (long-dashed secondary + "best ever …"
/// caption — wilks_series' absolute-max yardstick, 2026-09-22).
///
/// Windowing (2026-09-22): a compact range-chip row above the plot
/// re-windows the SAME already-loaded series client-side (clip by
/// date — no refetch). Daily series get `1M · 3M · 1Y · All` with a 3M
/// default (≈ the old fixed 84-day window); full-history monthly
/// series (wilks) get `3M · 6M · 1Y · <window_years>Y · All`,
/// defaulting to the dashboards.yaml `window_years:` chip. Chips whose
/// window would be empty or identical to All are hidden
/// ([visibleRanges]); a hidden default widens to the next larger chip
/// ([resolveRange] — the old "sparse series show full history"
/// behavior). Goal/floor/band lines and the bottom-axis tick keeper
/// re-span to the selected window; the pinned tooltip clears on range
/// switch (the chart is re-keyed). The selection is per-chart
/// IN-MEMORY state only — it survives Log/Trends toggles via the
/// domain screen's IndexedStack and intentionally is not persisted.
class MetricChart extends StatefulWidget {
  final MetricSeries series;
  final DateTime today;
  final String? goalNote;

  /// Plot height. The 130px default is header/inline size; the domain
  /// screens' Trends mode passes a taller value so charts get the room
  /// the old squeezed-above-the-ledger layout never had.
  final double height;

  /// dashboards.yaml `window_years:` for full-history series — seeds
  /// the default range chip (4 → a selected '4Y'); null → All.
  final int? windowYears;

  const MetricChart({
    super.key,
    required this.series,
    required this.today,
    this.goalNote,
    this.height = 130,
    this.windowYears,
  });

  @override
  State<MetricChart> createState() => _MetricChartState();
}

class _MetricChartState extends State<MetricChart> {
  /// User's chip choice; null until tapped → the per-series default.
  ChartRange? _selected;

  static double _x(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final series = widget.series;
    final today = widget.today;

    final ranges = series.fullHistory
        ? monthlyChartRanges(widget.windowYears)
        : dailyChartRanges;
    final preferred = series.fullHistory
        ? (widget.windowYears == null
              ? ChartRange.all
              : ChartRange.years(widget.windowYears!))
        : ChartRange.m3;
    final visible = visibleRanges(
      points: series.points,
      ranges: ranges,
      today: today,
    );
    final range = resolveRange(visible, _selected ?? preferred);
    final points = clipSeriesToRange(series.points, range, today);

    if (points.isEmpty) {
      return Text(
        '(no data in range)',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    // Fixed chips span their whole nominal window (a 3M chip is a
    // 3-month axis even when the left weeks are empty); All hugs the
    // data.
    final windowStart = range.startFor(today) ?? points.first.day;
    final avg = [
      for (final p in series.avg)
        if (!p.day.isBefore(windowStart)) p,
    ];

    var xMin = _x(windowStart);
    final xMax = _x(today);
    if (xMax - xMin < 1) xMin = xMax - 1; // single-point-today guard
    final rawSpots = [for (final p in points) FlSpot(_x(p.day), p.value)];
    final avgSpots = [for (final p in avg) FlSpot(_x(p.day), p.value)];
    final goal = series.goal;
    final floor = series.floor;
    final benchmark = series.benchmark;
    final bandLow = series.bandLow;
    final bandHigh = series.bandHigh;

    final ys = [
      for (final s in rawSpots) s.y,
      for (final s in avgSpots) s.y,
      ?goal,
      ?floor,
      ?benchmark,
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
        if (visible.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: ChartRangeSelector(
              ranges: visible,
              selected: range,
              onChanged: (r) => setState(() => _selected = r),
            ),
          ),
        SizedBox(
          height: widget.height,
          // LayoutBuilder: the bottom-axis tick keeper needs the plot's
          // pixel width to estimate label overlap (chart_bottom_axis).
          child: LayoutBuilder(
            builder: (context, constraints) => PinnedTooltipLineChart(
              // Re-key on range switch: the spot indices change under
              // the pin, so the pinned tooltip clears with the window.
              key: ValueKey(range),
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
                  // All-time benchmark: long-dashed, secondary-toned —
                  // distinct from the goal (tertiary) and floor (error)
                  // so "best ever" reads as its own yardstick.
                  if (benchmark != null)
                    LineChartBarData(
                      spots: [
                        FlSpot(xMin, benchmark),
                        FlSpot(xMax, benchmark),
                      ],
                      isCurved: false,
                      barWidth: 1.5,
                      color: scheme.secondary,
                      dashArray: [8, 4],
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
                          // Multi-year windows (full-history / windowed
                          // Wilks) carry the year — "Sep 22 '25" — so a
                          // point three years back can't read as recent;
                          // single-year windows stay compact.
                          '${DateFormat(windowStart.year != today.year ? "MMM d ''yy" : 'MMM d').format(DateTime.fromMillisecondsSinceEpoch((s.x * 86400000).toInt(), isUtc: true))}\n'
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
        if (goal != null ||
            floor != null ||
            hasBand ||
            widget.goalNote != null ||
            series.benchmarkNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              [
                ?series.benchmarkNote,
                if (goal != null)
                  'goal ${goal.toStringAsFixed(goal == goal.roundToDouble() ? 0 : 1)}'
                      '${series.unit == null ? '' : ' ${series.unit}'}',
                if (floor != null)
                  'floor ${floor.toStringAsFixed(floor == floor.roundToDouble() ? 0 : 1)}'
                      '${series.unit == null ? '' : ' ${series.unit}'}',
                if (hasBand)
                  'goal ${bandLow.round()}–${bandHigh.round()}'
                      '${series.unit == null ? '' : ' ${series.unit}'}',
                ?widget.goalNote,
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
