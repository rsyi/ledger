import 'package:fl_chart/fl_chart.dart';
import 'package:airledger/ui/widgets/pinned_tooltip_line_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bare 300x300 chart: no titles/border reserved space, so chart
/// coordinates map linearly onto the widget rect. x,y both span 0..10 →
/// spot (5,5) paints at the widget center.
Widget _chart({List<FlSpot>? spots}) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 300,
          height: 300,
          child: PinnedTooltipLineChart(
            data: LineChartData(
              minX: 0,
              maxX: 10,
              minY: 0,
              maxY: 10,
              titlesData: const FlTitlesData(show: false),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: spots ??
                      const [FlSpot(1, 1), FlSpot(5, 5), FlSpot(9, 9)],
                ),
              ],
              lineTouchData: const LineTouchData(
                touchTooltipData: LineTouchTooltipData(),
              ),
            ),
          ),
        ),
      ),
    );

/// The tooltip indicators the inner LineChart is CURRENTLY rendering.
List<ShowingTooltipIndicators> _shown(WidgetTester tester) =>
    tester.widget<LineChart>(find.byType(LineChart)).data
        .showingTooltipIndicators;

Offset _center(WidgetTester tester) =>
    tester.getCenter(find.byType(PinnedTooltipLineChart));

void main() {
  testWidgets('tap pins the nearest spot tooltip persistently',
      (tester) async {
    await tester.pumpWidget(_chart());
    expect(_shown(tester), isEmpty);

    // Tap the middle spot (chart center). Tooltip must survive the
    // gesture ending.
    await tester.tapAt(_center(tester));
    await tester.pumpAndSettle();

    final shown = _shown(tester);
    expect(shown, hasLength(1));
    expect(shown.single.showingSpots.single.x, 5);
    expect(shown.single.showingSpots.single.y, 5);
    // The spot indicator is pinned too.
    final bar = tester
        .widget<LineChart>(find.byType(LineChart))
        .data
        .lineBarsData
        .single;
    expect(bar.showingIndicators, [1]);
  });

  testWidgets('tapping the pinned spot again unpins it', (tester) async {
    await tester.pumpWidget(_chart());
    await tester.tapAt(_center(tester));
    await tester.pumpAndSettle();
    expect(_shown(tester), hasLength(1));

    await tester.tapAt(_center(tester));
    await tester.pumpAndSettle();
    expect(_shown(tester), isEmpty);
  });

  testWidgets('tapping another spot moves the pin', (tester) async {
    await tester.pumpWidget(_chart());
    final c = _center(tester);
    await tester.tapAt(c);
    await tester.pumpAndSettle();
    expect(_shown(tester).single.showingSpots.single.x, 5);

    // Spot (9,9) paints near the top-right corner: x = 9/10 of width.
    await tester.tapAt(c + const Offset(120, -120));
    await tester.pumpAndSettle();
    expect(_shown(tester).single.showingSpots.single.x, 9);
  });

  testWidgets('tapping empty space clears the pin', (tester) async {
    await tester.pumpWidget(_chart());
    final c = _center(tester);
    await tester.tapAt(c);
    await tester.pumpAndSettle();
    expect(_shown(tester), hasLength(1));

    // fl_chart hit-tests line charts by x-distance; x=7 (60px right of
    // center) is 60px from both the x=5 and x=9 spots — beyond the 10px
    // touch threshold.
    await tester.tapAt(c + const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(_shown(tester), isEmpty);
  });

  testWidgets('hold-drag previews live and clears on release',
      (tester) async {
    await tester.pumpWidget(_chart());
    final c = _center(tester);

    final gesture = await tester.startGesture(c);
    await tester.pump(const Duration(milliseconds: 600)); // long-press hold
    expect(_shown(tester).single.showingSpots.single.x, 5,
        reason: 'holding on a spot must preview its tooltip');

    await gesture.moveTo(c + const Offset(120, -120));
    await tester.pump();
    expect(_shown(tester).single.showingSpots.single.x, 9,
        reason: 'dragging must move the preview to the nearest spot');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_shown(tester), isEmpty,
        reason: 'release without a tap keeps nothing pinned');
  });

  testWidgets('pin survives a data refresh with valid indices',
      (tester) async {
    await tester.pumpWidget(_chart());
    await tester.tapAt(_center(tester));
    await tester.pumpAndSettle();
    expect(_shown(tester), hasLength(1));

    // Same shape, new values at the pinned index → pin re-resolves.
    await tester.pumpWidget(
      _chart(spots: const [FlSpot(1, 2), FlSpot(5, 6), FlSpot(9, 8)]),
    );
    await tester.pumpAndSettle();
    expect(_shown(tester).single.showingSpots.single.y, 6);

    // Shrunk data → out-of-range pin drops silently, no crash.
    await tester.pumpWidget(_chart(spots: const [FlSpot(1, 1)]));
    await tester.pumpAndSettle();
    expect(_shown(tester), isEmpty);
  });
}
