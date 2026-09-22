/// Shared fl_chart line-chart wrapper: tap a curve to PIN the nearest
/// point's tooltip (and spot indicator) so it stays open for reading;
/// hold-drag still previews live, exactly like fl_chart's built-in
/// behavior.
///
/// fl_chart's built-in touch handling only shows tooltips WHILE the
/// finger is down. This wrapper sets `handleBuiltInTouches: false` and
/// reimplements the same display on top of persistent state:
///
///   • any in-progress gesture (tap-down / pan / long-press) shows a
///     transient tooltip at the touched spot — the classic
///     hold-to-inspect preview;
///   • [FlTapUpEvent] on a spot pins it: tap the SAME spot again to
///     unpin, a different spot to move the pin, empty space to clear;
///   • gesture end clears only the transient preview — the pin stays.
///
/// Callers build [LineChartData] exactly as before (including
/// [LineTouchData.touchTooltipData] for tooltip content/appearance);
/// any `handleBuiltInTouches` / `touchCallback` in the passed data are
/// overridden here.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class PinnedTooltipLineChart extends StatefulWidget {
  final LineChartData data;

  const PinnedTooltipLineChart({super.key, required this.data});

  @override
  State<PinnedTooltipLineChart> createState() =>
      _PinnedTooltipLineChartState();
}

class _PinnedTooltipLineChartState extends State<PinnedTooltipLineChart> {
  /// Pinned spot positions as (barIndex, spotIndex) — indices, not
  /// [LineBarSpot]s, so a data refresh under an open pin re-resolves
  /// against the new bars (and silently drops out-of-range indices).
  List<(int, int)>? _pinned;

  /// Live preview while a gesture is in progress; wins over [_pinned]
  /// for display, cleared when the gesture ends.
  List<(int, int)>? _transient;

  static List<(int, int)>? _positions(LineTouchResponse? response) {
    final spots = response?.lineBarSpots;
    if (spots == null || spots.isEmpty) return null;
    return [for (final s in spots) (s.barIndex, s.spotIndex)];
  }

  static bool _same(List<(int, int)>? a, List<(int, int)>? b) {
    if (a == null || b == null) return identical(a, b);
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _onTouch(FlTouchEvent event, LineTouchResponse? response) {
    if (!mounted) return;
    if (event is FlTapUpEvent) {
      // Tap: pin (or toggle off when re-tapping the pinned spot; clear
      // when tapping empty space — _positions is null there).
      final tapped = _positions(response);
      setState(() {
        _transient = null;
        _pinned = _same(tapped, _pinned) ? null : tapped;
      });
      return;
    }
    if (!event.isInterestedForInteractions) {
      // Gesture ended/cancelled: drop the preview, keep the pin.
      if (_transient != null) setState(() => _transient = null);
      return;
    }
    final touched = _positions(response);
    if (!_same(touched, _transient)) {
      setState(() => _transient = touched);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.data;
    final shown = _transient ?? _pinned;

    // Resolve stored positions against the CURRENT data.
    final spots = <LineBarSpot>[];
    if (shown != null) {
      for (final (barIndex, spotIndex) in shown) {
        if (barIndex < 0 || barIndex >= base.lineBarsData.length) continue;
        final bar = base.lineBarsData[barIndex];
        if (spotIndex < 0 || spotIndex >= bar.spots.length) continue;
        spots.add(LineBarSpot(bar, barIndex, bar.spots[spotIndex]));
      }
    }
    // Highest y first — same tooltip row order as the built-in handler.
    spots.sort((a, b) => b.y.compareTo(a.y));

    return LineChart(
      base.copyWith(
        showingTooltipIndicators: [
          if (spots.isNotEmpty) ShowingTooltipIndicators(spots),
        ],
        lineBarsData: [
          for (var i = 0; i < base.lineBarsData.length; i++)
            base.lineBarsData[i].copyWith(
              showingIndicators: [
                for (final s in spots)
                  if (s.barIndex == i) s.spotIndex,
              ],
            ),
        ],
        lineTouchData: base.lineTouchData.copyWith(
          enabled: true,
          handleBuiltInTouches: false,
          touchCallback: _onTouch,
        ),
      ),
    );
  }
}
