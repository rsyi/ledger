/// chart_bottom_axis — the greedy endpoint-wins date-tick keeper.
///
/// Regression target: fl_chart emits BOTH window endpoints on top of
/// the interval ticks, so interval math alone produced "AugSep 4" at
/// the left edge and "Dec 3 Dec 13" at the right on the program weight
/// chart. The pure tests pin the greedy rule; the widget test renders a
/// chart at a narrow width and asserts no two kept labels are closer
/// than their estimated widths allow.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/ui/widgets/chart_bottom_axis.dart';

double dayX(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

void main() {
  group('dateAxisTicks', () {
    // The screenshot window: Sep 4 → Dec 13 (block + 3-week lead-in).
    final minX = dayX(DateTime(2026, 9, 4));
    final maxX = dayX(DateTime(2026, 12, 13));

    test('keeps both endpoints and only non-overlapping month starts', () {
      final ticks = dateAxisTicks(minX: minX, maxX: maxX, plotWidth: 300);
      expect(ticks.first.x, minX);
      expect(ticks.first.label, 'Sep 4');
      expect(ticks.last.x, maxX);
      expect(ticks.last.label, 'Dec 13');
      // Interior candidates are month starts only.
      for (final t in ticks.sublist(1, ticks.length - 1)) {
        final d = DateTime.fromMillisecondsSinceEpoch(
          (t.x * 86400000).round(),
          isUtc: true,
        );
        expect(d.day, 1, reason: 'interior tick $t is not a month start');
      }
    });

    test('no two kept ticks closer than their estimated label widths', () {
      for (final width in [120.0, 200.0, 280.0, 360.0]) {
        final ticks = dateAxisTicks(minX: minX, maxX: maxX, plotWidth: width);
        final pxPerDay = width / (maxX - minX);
        for (var i = 1; i < ticks.length; i++) {
          final a = ticks[i - 1];
          final b = ticks[i];
          // Rendered extents: endpoints are shifted fully inside the
          // plot (fitInside), interior labels are centered.
          double leftEdge(DateAxisTick t) => t.x == minX
              ? 0
              : t.x == maxX
              ? width - t.label.length * kAxisPxPerChar
              : (t.x - minX) * pxPerDay - t.label.length * kAxisPxPerChar / 2;
          double rightEdge(DateAxisTick t) =>
              leftEdge(t) + t.label.length * kAxisPxPerChar;
          expect(
            leftEdge(b) - rightEdge(a),
            greaterThanOrEqualTo(0),
            reason: 'labels "${a.label}"/"${b.label}" overlap at $width px',
          );
        }
      }
    });

    test('December start (2 days before right endpoint) is dropped', () {
      // "Dec 1" would sit under "Dec 13" — the endpoint must win.
      final ticks = dateAxisTicks(minX: minX, maxX: maxX, plotWidth: 300);
      expect(ticks.where((t) => t.label == 'Dec'), isEmpty);
    });

    test('window too narrow for both endpoints keeps the right one', () {
      final ticks = dateAxisTicks(minX: minX, maxX: maxX, plotWidth: 60);
      expect(ticks, hasLength(1));
      expect(ticks.single.x, maxX);
    });

    test('multi-year windows label with years and stay sparse', () {
      final lo = dayX(DateTime(2023, 3, 15));
      final hi = dayX(DateTime(2026, 9, 21));
      final ticks = dateAxisTicks(minX: lo, maxX: hi, plotWidth: 320);
      expect(ticks.first.label, "Mar '23");
      expect(ticks.last.label, "Sep '26");
      // Every interior tick must land on the fl_chart interval grid so
      // it actually gets a title callback.
      final interval = axisTickInterval(lo, hi);
      for (final t in ticks.sublist(1, ticks.length - 1)) {
        expect((t.x / interval).round() * interval, t.x);
      }
    });
  });

  group('rendered chart', () {
    testWidgets(
      'narrow chart renders bottom labels without horizontal overlap',
      (tester) async {
        final minX = dayX(DateTime(2026, 9, 4));
        final maxX = dayX(DateTime(2026, 12, 13));
        const chartWidth = 320.0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: chartWidth,
                  height: 200,
                  child: LineChart(
                    LineChartData(
                      minX: minX,
                      maxX: maxX,
                      minY: 0,
                      maxY: 10,
                      titlesData: FlTitlesData(
                        rightTitles: const AxisTitles(),
                        topTitles: const AxisTitles(),
                        leftTitles: const AxisTitles(),
                        bottomTitles: AxisTitles(
                          sideTitles: dateBottomTitles(
                            minX: minX,
                            maxX: maxX,
                            plotWidth: chartWidth,
                            style: const TextStyle(fontSize: 9),
                          ),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: [FlSpot(minX, 2), FlSpot(maxX, 8)],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // Extra pump: SideTitleWidget measures itself post-frame for the
        // fitInside shift.
        await tester.pump();

        final rects =
            tester
                .widgetList<Text>(find.byType(Text))
                .map((t) => t.data!)
                .toSet()
                .map((label) => tester.getRect(find.text(label)))
                .toList()
              ..sort((a, b) => a.left.compareTo(b.left));
        expect(
          rects.length,
          greaterThanOrEqualTo(2),
          reason: 'expected endpoint labels to render',
        );
        for (var i = 1; i < rects.length; i++) {
          expect(
            rects[i].left,
            greaterThanOrEqualTo(rects[i - 1].right),
            reason:
                'labels $i-1 and $i overlap: '
                '${rects[i - 1]} vs ${rects[i]}',
          );
        }

        // The kept ticks themselves honor the estimated-width spacing.
        final ticks = dateAxisTicks(
          minX: minX,
          maxX: maxX,
          plotWidth: chartWidth,
        );
        final pxPerDay = chartWidth / (maxX - minX);
        for (var i = 1; i < ticks.length; i++) {
          final estWidth =
              ticks[i - 1].label.length * kAxisPxPerChar / 2 +
              ticks[i].label.length * kAxisPxPerChar / 2;
          expect(
            (ticks[i].x - ticks[i - 1].x) * pxPerDay +
                // endpoints are edge-shifted, freeing half a label each
                (i == 1 ? ticks.first.label.length * kAxisPxPerChar / 2 : 0) +
                (i == ticks.length - 1
                    ? ticks.last.label.length * kAxisPxPerChar / 2
                    : 0),
            greaterThanOrEqualTo(estWidth),
            reason:
                'ticks "${ticks[i - 1].label}" and "${ticks[i].label}" '
                'closer than their estimated label width',
          );
        }
      },
    );
  });
}
