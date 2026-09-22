import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/bulk_window.dart';

/// weighInTrough — the derivation behind app/dashboards.yaml
/// `last_bulk.start` (2026-09-22): the trailing-7-day-average minimum
/// of the weigh-in series in a lookback window before a declared bulk
/// end. Pure + synthetic here; tool/derive_bulk_window.dart runs the
/// same function over the live weight sheet.
void main() {
  DateTime d(int day) => DateTime.utc(2025, 1, day);
  ({DateTime day, double value}) w(int day, double v) =>
      (day: d(day), value: v);

  group('weighInTrough', () {
    test('empty series → null', () {
      expect(weighInTrough(const [], end: d(31)), isNull);
    });

    test('single-day dip in a flat series → the dip day (earliest of the '
        'tied windows containing it)', () {
      // Fourteen days of 170 with one 160 on day 8: every 7-day window
      // ending day 8..14 averages (6×170+160)/7 — tied — so the
      // earliest window end (the dip day itself) wins.
      final series = [
        for (var i = 1; i <= 14; i++) w(i, i == 8 ? 160.0 : 170.0),
      ];
      final t = weighInTrough(series, end: d(14));
      expect(t, isNotNull);
      expect(t!.day, d(8));
      expect(t.avg7, closeTo((6 * 170 + 160) / 7, 1e-9));
    });

    test('trailing average over AVAILABLE days only (gaps skipped)', () {
      // Weigh-ins every other day; the window ending day 9 sees days
      // 3,5,7,9 → mean of those four values.
      final series = [w(3, 172), w(5, 170), w(7, 168), w(9, 166)];
      final t = weighInTrough(series, end: d(9));
      expect(t!.day, d(9));
      expect(t.avg7, closeTo((172 + 170 + 168 + 166) / 4, 1e-9));
    });

    test('multiple weigh-ins on one day are averaged first', () {
      // Day 10 logs 160 and 180 (daily mean 170) — it must not beat
      // day 20's honest 165.
      final series = [
        (day: d(10), value: 160.0),
        (day: d(10), value: 180.0),
        w(20, 165),
      ];
      final t = weighInTrough(series, end: d(20));
      expect(t!.day, d(20));
      expect(t.avg7, closeTo(165, 1e-9));
    });

    test('candidates clip to [end − lookbackDays, end]; an older lower '
        'trough is ignored', () {
      final series = [
        w(1, 150), // lower, but before the lookback window
        w(20, 168),
        w(25, 166),
      ];
      final t = weighInTrough(series, end: d(25), lookbackDays: 10);
      expect(t!.day, d(25));
      expect(t.avg7, closeTo((168 + 166) / 2, 1e-9));
    });

    test('weigh-ins after end are not candidates and never feed a window',
        () {
      final series = [w(10, 170), w(12, 168), w(20, 150)];
      final t = weighInTrough(series, end: d(15));
      expect(t!.day, d(12));
      expect(t.avg7, closeTo((170 + 168) / 2, 1e-9));
    });

    test('pre-window days still feed an early candidate\'s trailing '
        'average (only candidacy is clipped)', () {
      // Lookback admits only days 18..20; day 18's window reaches back
      // to day 12's value.
      final series = [w(12, 150), w(18, 170), w(19, 171), w(20, 172)];
      final t = weighInTrough(series, end: d(20), lookbackDays: 2);
      expect(t!.day, d(18));
      expect(t.avg7, closeTo((150 + 170) / 2, 1e-9));
    });

    test('V-shaped series: the trough is the minimum trailing window, '
        'strictly before the run-up dominates', () {
      // 170 down to 163 (day 8) then up to 172: the trailing average
      // keeps falling a couple of days past the bottom, then rises —
      // the function returns the true minimum window, and it sits
      // before the sustained climb.
      final series = [
        for (var i = 1; i <= 8; i++) w(i, 171.0 - i), // 170 … 163
        for (var i = 9; i <= 17; i++) w(i, 163.0 + (i - 8)), // 164 … 172
      ];
      final t = weighInTrough(series, end: d(17));
      // Hand-computed minimum: the window ending day 11 spans days
      // 5..11 — {166,165,164,163,164,165,166}/7 = 164.714 — centered
      // on the day-8 bottom (a trailing average lags a V by ~3 days).
      expect(t!.day, d(11));
      expect(
        t.avg7,
        closeTo((166 + 165 + 164 + 163 + 164 + 165 + 166) / 7, 1e-9),
      );
    });
  });
}
