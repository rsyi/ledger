/// MetricChart range selector — chip taps re-window the plotted span
/// client-side (LineChartData.minX moves; no data reload), and charts
/// whose history can't fill more than one distinct window show no
/// selector at all.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/domain_metrics.dart' show MetricSeries;
import 'package:airledger/ui/widgets/metric_chart.dart';

double dayX(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

Future<void> pumpChart(
  WidgetTester tester,
  MetricSeries series,
  DateTime today, {
  int? windowYears,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MetricChart(
          series: series,
          today: today,
          height: 180,
          windowYears: windowYears,
        ),
      ),
    ),
  );
}

void main() {
  final today = DateTime(2026, 9, 22);

  testWidgets('daily series defaults to 3M; tapping 1Y / All widens the '
      'plotted span', (tester) async {
    // 400 daily points ending today (~13 months of history).
    final series = MetricSeries(
      points: [
        for (var i = 399; i >= 0; i--)
          (
            day: DateTime(today.year, today.month, today.day - i),
            value: 150.0 + (i % 7),
          ),
      ],
    );
    await pumpChart(tester, series, today);

    LineChartData data() =>
        tester.widget<LineChart>(find.byType(LineChart)).data;

    // Default = 3M: axis starts three calendar months back.
    expect(find.text('3M'), findsOneWidget);
    expect(data().minX, dayX(DateTime(2026, 6, 22)));
    expect(data().maxX, dayX(today));

    await tester.tap(find.text('1Y'));
    await tester.pumpAndSettle();
    expect(data().minX, dayX(DateTime(2025, 9, 22)));

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(data().minX, dayX(series.points.first.day));

    // Narrowing back down re-clips the same series.
    await tester.tap(find.text('1M'));
    await tester.pumpAndSettle();
    expect(data().minX, dayX(DateTime(2026, 8, 22)));
  });

  testWidgets('short history collapses every chip onto All — no selector '
      'chrome', (tester) async {
    final series = MetricSeries(
      points: [
        for (var i = 13; i >= 0; i--)
          (day: DateTime(2026, 9, 22 - i), value: 100.0 + i),
      ],
    );
    await pumpChart(tester, series, today);
    expect(find.text('All'), findsNothing);
    expect(find.text('3M'), findsNothing);
    // The chart itself still renders, hugging the data.
    final data = tester.widget<LineChart>(find.byType(LineChart)).data;
    expect(data.minX, dayX(DateTime(2026, 9, 9)));
  });

  testWidgets('full-history monthly series: window_years seeds the 4Y '
      'default; All widens past it', (tester) async {
    // Six years of monthly points → 3M · 6M · 1Y · 4Y · All all live.
    final series = MetricSeries(
      points: [
        for (var i = 0; i < 72; i++)
          (day: DateTime(2020, 10 + i, 1), value: 300.0 + i),
      ],
      fullHistory: true,
    );
    await pumpChart(tester, series, today, windowYears: 4);

    LineChartData data() =>
        tester.widget<LineChart>(find.byType(LineChart)).data;

    expect(find.text('4Y'), findsOneWidget);
    expect(data().minX, dayX(DateTime(2022, 9, 22)));

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(data().minX, dayX(DateTime(2020, 10, 1)));
  });
}
