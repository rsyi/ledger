/// Shared bottom-axis date ticks for the app's line charts.
///
/// WHY: fl_chart's interval-based title iteration always emits BOTH
/// window endpoints in addition to the aligned interval steps
/// (AxisChartHelper.iterateThroughAxis yields `min`, the interval
/// multiples, then `max`). An interval tick landing near an edge
/// therefore collides with the endpoint label — "Aug" printed over
/// "Sep 4" at the left edge, "Dec 3" against "Dec 13" at the right.
///
/// FIX: compute explicit ticks instead of trusting an interval.
///
///   candidates  = window endpoints + calendar-month starts inside the
///                 window;
///   greedy keep = endpoints always win; interior ticks are dropped
///                 whenever their rendered label — estimated at
///                 [kAxisPxPerChar] per character, centered on the tick
///                 — would overlap the previously kept label or the
///                 right endpoint's label.
///
/// Endpoint labels render shifted inside the plot (fl_chart's
/// `fitInside`), so the left endpoint's label occupies `[0, w]` px and
/// the right endpoint's `[plotWidth - w, plotWidth]`; interior labels
/// stay centered on their tick.
///
/// X units are days-since-epoch (chart x = epoch ms / 86 400 000), the
/// convention every chart in the app already uses. Charts whose dates
/// parse to LOCAL midnights (fractional x) still work: interior ticks
/// snap onto fl_chart's baseline-aligned interval grid, at most half an
/// interval (≤ half a day at interval 1) from the true month start —
/// invisible at these scales.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Estimated label width per character at the axis styles the charts
/// use (fontSize 11 since the 2026-09 readability pass — nothing
/// user-facing below ~11-12sp). Deliberately generous: over-estimating
/// drops a keepable tick, under-estimating overlaps two kept ones.
/// Raise this if the axis font size goes up again.
const double kAxisPxPerChar = 9.0;

/// One kept tick: chart-x position + preformatted label.
class DateAxisTick {
  final double x;
  final String label;
  const DateAxisTick(this.x, this.label);
}

/// The interval handed to fl_chart so interior ticks land on emitted
/// values without iterating thousands of steps on multi-year windows:
/// interior ticks snap to multiples of this (baseline-0 aligned, same
/// grid fl_chart iterates), capping callbacks at ~256 per chart. The
/// snap error (≤ interval/2 days) stays under a pixel at the zoom
/// levels where the interval exceeds 1.
double axisTickInterval(double minX, double maxX) {
  final rangeDays = maxX - minX;
  if (rangeDays <= 256) return 1;
  return (rangeDays / 256).ceilToDouble();
}

DateTime _day(double x) =>
    DateTime.fromMillisecondsSinceEpoch((x * 86400000).round(), isUtc: true);

/// Candidate ticks (endpoints + month starts) reduced by the greedy
/// overlap rule. Always returns at least one tick; endpoints are only
/// sacrificed against EACH OTHER (a window too narrow for both keeps
/// the right/most-recent one).
List<DateAxisTick> dateAxisTicks({
  required double minX,
  required double maxX,
  required double plotWidth,
  double pxPerChar = kAxisPxPerChar,
  double gapPx = 6,
}) {
  // Formats: day-precision edges while a "MMM d" is unambiguous within
  // the window; beyond ~15 months everything carries the year ("Sep
  // ’25") and day precision stops mattering at that zoom.
  final longRange = maxX - minX > 456;
  final edgeFmt = DateFormat(longRange ? "MMM ''yy" : 'MMM d');
  final monthFmt = DateFormat(longRange ? "MMM ''yy" : 'MMM');

  if (maxX <= minX || plotWidth <= 0) {
    return [DateAxisTick(maxX, edgeFmt.format(_day(maxX)))];
  }

  final pxPerDay = plotWidth / (maxX - minX);
  double px(double x) => (x - minX) * pxPerDay;
  double w(String label) => label.length * pxPerChar;

  final left = DateAxisTick(minX, edgeFmt.format(_day(minX)));
  final right = DateAxisTick(maxX, edgeFmt.format(_day(maxX)));
  final leftW = w(left.label);
  final rightW = w(right.label);
  // Endpoints render fit-inside: left spans [0, leftW], right spans
  // [plotWidth - rightW, plotWidth]. If even those two collide, keep
  // only the right (most recent) one.
  if (leftW + gapPx > plotWidth - rightW) return [right];

  final kept = [left];
  var prevRightEdge = leftW; // right px edge of the last kept label
  final rightLeftEdge = plotWidth - rightW;

  // Month starts strictly inside the window, snapped to the fl_chart
  // interval grid so each tick is actually emitted to getTitlesWidget.
  final interval = axisTickInterval(minX, maxX);
  final firstDay = _day(minX);
  final lastDay = _day(maxX);
  var m = DateTime.utc(firstDay.year, firstDay.month + 1, 1);
  while (m.isBefore(lastDay)) {
    final rawX = m.millisecondsSinceEpoch / 86400000.0;
    final x = (rawX / interval).round() * interval;
    if (x > minX && x < maxX) {
      final label = monthFmt.format(m);
      final half = w(label) / 2;
      final c = px(x);
      if (c - half >= prevRightEdge + gapPx &&
          c + half <= rightLeftEdge - gapPx) {
        kept.add(DateAxisTick(x, label));
        prevRightEdge = c + half;
      }
    }
    m = DateTime.utc(m.year, m.month + 1, 1);
  }
  kept.add(right);
  return kept;
}

/// Drop-in [SideTitles] for a date bottom axis. Callers wrap their
/// chart in a LayoutBuilder and pass the plot width (constraint width
/// minus the left axis' reservedSize).
SideTitles dateBottomTitles({
  required double minX,
  required double maxX,
  required double plotWidth,
  required TextStyle style,
  double reservedSize = 24,
  double space = 4,
  double pxPerChar = kAxisPxPerChar,
}) {
  final ticks = dateAxisTicks(
    minX: minX,
    maxX: maxX,
    plotWidth: plotWidth,
    pxPerChar: pxPerChar,
  );
  // Endpoints match the exact doubles fl_chart yields; interior ticks
  // are interval-grid multiples that survive fl_chart's float
  // accumulation via round() (grid values are whole numbers).
  final edge = <double, String>{};
  final grid = <int, String>{};
  for (final t in ticks) {
    if (t.x == minX || t.x == maxX) {
      edge[t.x] = t.label;
    } else {
      grid[t.x.round()] = t.label;
    }
  }
  return SideTitles(
    showTitles: true,
    reservedSize: reservedSize,
    interval: axisTickInterval(minX, maxX),
    getTitlesWidget: (value, meta) {
      final label = edge[value] ?? grid[value.round()];
      if (label == null) return const SizedBox.shrink();
      return SideTitleWidget(
        axisSide: meta.axisSide,
        space: space,
        // Shifts edge labels fully inside the plot instead of letting
        // the chart clip their outer half.
        fitInside: SideTitleFitInsideData.fromTitleMeta(
          meta,
          distanceFromEdge: 0,
        ),
        child: Text(label, style: style, maxLines: 1, softWrap: false),
      );
    },
  );
}
