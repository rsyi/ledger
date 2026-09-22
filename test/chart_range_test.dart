/// chart_range — the pure client-side windowing layer behind every
/// full-size chart's range selector (3M · 6M · 1Y · … · All chips).
///
/// Contract under test:
///   • [clipSeriesToRange] clips an already-loaded series by date —
///     no refetch; a range longer than the data is All-equivalent
///     (returns everything); an empty result is an empty list, never
///     a throw.
///   • [visibleRanges] hides chips that would render an empty or
///     identical-to-All window (e.g. a 4Y chip when history is
///     shorter), so the selector never offers dead options.
///   • [resolveRange] maps a preferred default onto the visible set,
///     widening to the next larger chip when the preferred one was
///     hidden (sparse series: 3M with <2 points → 1Y/All), matching
///     the old MetricChart "widen when sparse" behavior.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/ui/widgets/chart_range.dart';

ChartSeriesPoint p(int y, int m, int d, [double v = 1]) =>
    (day: DateTime(y, m, d), value: v);

void main() {
  final today = DateTime(2026, 9, 22);

  group('ChartRange', () {
    test('startFor: trailing calendar months; All is unbounded', () {
      expect(ChartRange.m3.startFor(today), DateTime(2026, 6, 22));
      expect(ChartRange.y1.startFor(today), DateTime(2025, 9, 22));
      expect(ChartRange.all.startFor(today), isNull);
    });

    test('years factory labels and equality', () {
      expect(ChartRange.years(4).label, '4Y');
      expect(ChartRange.years(4).months, 48);
      expect(ChartRange.years(1), ChartRange.y1);
    });
  });

  group('clipSeriesToRange', () {
    // Two years of monthly points, Oct 2024 .. Sep 2026.
    final series = [
      for (var i = 0; i < 24; i++)
        p(2024, 10 + i, 1, i.toDouble()), // DateTime normalizes months
    ];

    test('clips by date, start-inclusive', () {
      final clipped = clipSeriesToRange(series, ChartRange.m3, today);
      expect(clipped, [
        p(2026, 7, 1, 21),
        p(2026, 8, 1, 22),
        p(2026, 9, 1, 23),
      ]);
      // A point exactly on the window start is kept.
      final edge = clipSeriesToRange(
        [p(2026, 6, 22, 5), p(2026, 9, 1, 6)],
        ChartRange.m3,
        today,
      );
      expect(edge.first.value, 5);
    });

    test('All returns the series untouched', () {
      expect(clipSeriesToRange(series, ChartRange.all, today), series);
    });

    test('range longer than the data is All-equivalent', () {
      expect(clipSeriesToRange(series, ChartRange.years(4), today), series);
    });

    test('empty result guard: stale or empty input yields empty list', () {
      final stale = [p(2020, 1, 1), p(2020, 6, 1)];
      expect(clipSeriesToRange(stale, ChartRange.m1, today), isEmpty);
      expect(clipSeriesToRange(const [], ChartRange.y1, today), isEmpty);
    });
  });

  group('visibleRanges', () {
    test('drops fixed chips identical to All (short history)', () {
      // 5 months of history: 1M and 3M are real windows; 6M/1Y/4Y all
      // collapse onto All and disappear.
      final series = [for (var i = 0; i < 5; i++) p(2026, 5 + i, 1)];
      final visible = visibleRanges(
        points: series,
        ranges: monthlyChartRanges(4),
        today: today,
      );
      expect(visible, [ChartRange.m3, ChartRange.all]);
    });

    test('drops chips whose window holds fewer than two points', () {
      // Sparse caliper-style series: nothing in the last 3 months,
      // two points inside the trailing year.
      final series = [p(2025, 1, 10), p(2025, 11, 2), p(2026, 2, 14)];
      final visible = visibleRanges(
        points: series,
        ranges: dailyChartRanges,
        today: today,
      );
      expect(visible, [ChartRange.y1, ChartRange.all]);
    });

    test('collapses to All alone when history is shorter than every chip', () {
      final series = [p(2026, 9, 10), p(2026, 9, 18)];
      expect(
        visibleRanges(points: series, ranges: dailyChartRanges, today: today),
        [ChartRange.all],
      );
    });

    test('empty series yields no chips at all', () {
      expect(
        visibleRanges(points: const [], ranges: dailyChartRanges, today: today),
        isEmpty,
      );
    });
  });

  group('resolveRange', () {
    test('keeps the preferred range when visible', () {
      expect(resolveRange(dailyChartRanges, ChartRange.m3), ChartRange.m3);
    });

    test('widens to the next larger chip when preferred is hidden', () {
      expect(
        resolveRange([ChartRange.y1, ChartRange.all], ChartRange.m3),
        ChartRange.y1,
      );
    });

    test('falls back to All', () {
      expect(resolveRange([ChartRange.all], ChartRange.m3), ChartRange.all);
      expect(resolveRange(const [], ChartRange.m3), ChartRange.all);
      // Preferred All with only fixed chips visible → widest fixed chip.
      expect(
        resolveRange([ChartRange.m1, ChartRange.m3], ChartRange.all),
        ChartRange.m3,
      );
    });
  });

  group('monthlyChartRanges', () {
    test('window_years seeds an nY chip: 3M · 6M · 1Y · 4Y · All', () {
      expect(
        [for (final r in monthlyChartRanges(4)) r.label],
        ['3M', '6M', '1Y', '4Y', 'All'],
      );
    });

    test('dedupes window_years already covered (1Y) and handles null', () {
      expect(
        [for (final r in monthlyChartRanges(1)) r.label],
        ['3M', '6M', '1Y', 'All'],
      );
      expect(
        [for (final r in monthlyChartRanges(null)) r.label],
        ['3M', '6M', '1Y', 'All'],
      );
    });
  });
}
