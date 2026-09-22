/// Client-side chart range windowing + the compact chip selector.
///
/// Every full-size line chart offers `3M · 6M · 1Y · … · All` chips
/// that re-window the SAME already-loaded series by date — no refetch.
/// The pure helpers here own the three rules the charts share:
///
///   • [clipSeriesToRange] — trailing-calendar-month clip; a range
///     longer than the data degrades to All (everything), an empty
///     window degrades to an empty list (the chart's existing
///     "(no data)" path), never a throw.
///   • [visibleRanges] — hide chips that would render an EMPTY or
///     IDENTICAL-to-All window (e.g. the 4Y chip when history is
///     shorter, or a 3M chip holding fewer than two points), so the
///     selector never offers dead options; when only All survives the
///     charts skip the selector row entirely.
///   • [resolveRange] — map a chart's preferred default onto the
///     visible set, widening to the next larger chip when the
///     preferred one was hidden (sparse series: 3M → 1Y → All). This
///     reproduces the old "widen when the window is sparse" behavior.
///
/// Range selection is per-chart, IN-MEMORY widget state only — it
/// survives Log/Trends mode toggles because the domain screen's
/// IndexedStack keeps both subtrees alive, and deliberately resets on
/// screen re-entry (no persistence; a fresh open should show the
/// chart's tuned default, not a stale zoom).
library;

import 'package:flutter/material.dart';

/// The (day, value) point shape shared by MetricSeries and the ad-hoc
/// chart series (program weight, history trend).
typedef ChartSeriesPoint = ({DateTime day, double value});

/// One selectable trailing window. [months] is calendar months back
/// from "today"; null = All (full history).
@immutable
class ChartRange {
  final String label;
  final int? months;

  const ChartRange(this.label, this.months);

  static const m1 = ChartRange('1M', 1);
  static const m3 = ChartRange('3M', 3);
  static const m6 = ChartRange('6M', 6);
  static const y1 = ChartRange('1Y', 12);
  static const all = ChartRange('All', null);

  /// An n-year chip ('4Y'), for dashboards.yaml `window_years:`.
  static ChartRange years(int n) =>
      n == 1 ? y1 : ChartRange('${n}Y', n * 12);

  /// Window start for [today]; null = unbounded (All).
  DateTime? startFor(DateTime today) => months == null
      ? null
      : DateTime(today.year, today.month - months!, today.day);

  @override
  bool operator ==(Object other) =>
      other is ChartRange && other.label == label && other.months == months;

  @override
  int get hashCode => Object.hash(label, months);

  @override
  String toString() => 'ChartRange($label)';
}

/// Chip set for daily-cadence series (kcal, protein, weight, HR):
/// 1M · 3M · 1Y · All. Default 3M ≈ the old fixed 84-day window.
const dailyChartRanges = [
  ChartRange.m1,
  ChartRange.m3,
  ChartRange.y1,
  ChartRange.all,
];

/// Chip set for monthly-cadence full-history series (wilks_series):
/// 3M · 6M · 1Y · <window_years>Y · All. The window_years chip (when
/// declared and not already in the set) is the chart's default — the
/// same trailing window computeMetric used to hard-clip to before the
/// selector existed.
List<ChartRange> monthlyChartRanges(int? windowYears) {
  final ranges = [ChartRange.m3, ChartRange.m6, ChartRange.y1];
  if (windowYears != null &&
      !ranges.any((r) => r.months == windowYears * 12)) {
    ranges.add(ChartRange.years(windowYears));
  }
  ranges.sort((a, b) => a.months!.compareTo(b.months!));
  return [...ranges, ChartRange.all];
}

/// Clip [points] (day-ascending) to [range]'s trailing window ending at
/// [today]. Start-inclusive. All → the list untouched; a range longer
/// than the data returns everything (All-equivalent); no points in the
/// window returns an empty list.
List<ChartSeriesPoint> clipSeriesToRange(
  List<ChartSeriesPoint> points,
  ChartRange range,
  DateTime today,
) {
  final start = range.startFor(today);
  if (start == null) return points;
  if (points.isNotEmpty && !points.first.day.isBefore(start)) {
    return points; // window covers all data — All-equivalent
  }
  return [
    for (final p in points)
      if (!p.day.isBefore(start)) p,
  ];
}

/// The chips worth showing for [points]: fixed ranges are dropped when
/// their window is identical to All (start on/before the first point)
/// or holds fewer than [minPoints] points; All survives whenever there
/// is any data. Length ≤ 1 → callers hide the selector row.
List<ChartRange> visibleRanges({
  required List<ChartSeriesPoint> points,
  required List<ChartRange> ranges,
  required DateTime today,
  int minPoints = 2,
}) {
  if (points.isEmpty) return const [];
  final visible = <ChartRange>[];
  for (final r in ranges) {
    final start = r.startFor(today);
    if (start == null) {
      visible.add(r); // All
      continue;
    }
    if (!points.first.day.isBefore(start)) continue; // == All
    var n = 0;
    for (final p in points) {
      if (!p.day.isBefore(start) && ++n >= minPoints) break;
    }
    if (n >= minPoints) visible.add(r);
  }
  return visible;
}

/// Map [preferred] onto [visible]: itself when offered, else the next
/// larger window (the sparse-series widen), else All.
ChartRange resolveRange(List<ChartRange> visible, ChartRange preferred) {
  if (visible.contains(preferred)) return preferred;
  if (preferred.months != null) {
    for (final r in visible) {
      if (r.months != null && r.months! > preferred.months!) return r;
    }
  }
  for (final r in visible.reversed) {
    if (r.months != null) return r; // preferred=All, only fixed chips left
  }
  return ChartRange.all;
}

/// Compact right-aligned segmented control of range chips — small
/// enough to sit above a chart without stealing its height; matches
/// the Log/Trends SegmentedButton visual language.
class ChartRangeSelector extends StatelessWidget {
  final List<ChartRange> ranges;
  final ChartRange selected;
  final ValueChanged<ChartRange> onChanged;

  const ChartRangeSelector({
    super.key,
    required this.ranges,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: SegmentedButton<ChartRange>(
        segments: [
          for (final r in ranges)
            ButtonSegment(value: r, label: Text(r.label)),
        ],
        selected: {selected},
        onSelectionChanged: (s) => onChanged(s.first),
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity(horizontal: -4, vertical: -4),
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 7),
          ),
          textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 10)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}
