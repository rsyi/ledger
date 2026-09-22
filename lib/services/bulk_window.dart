/// Bulk-window derivation — where app/dashboards.yaml `last_bulk.start`
/// comes from (2026-09-22).
///
/// The user asked the home STRENGTH card to show "my numbers from my
/// last bulk". The bulk's END is declared (coach/phase.yaml v1: cut
/// effective 2025-10-06, "Ending the 2025 bulk at 186.5"); the START
/// is not declared anywhere, so it is DERIVED from the weigh-in series:
/// the bodyweight trough before the run-up — the minimum trailing
/// 7-day average in the ~14 months before the declared end. Derived
/// once (2025-02-05 @ 167.6 lb 7d-avg, tool/derive_bulk_window.dart)
/// and written EXPLICITLY into dashboards.yaml, where it stays
/// user-editable; the app reads the config, not this function, at
/// runtime — this stays as the reproducible, tested derivation.
library;

/// The trailing-7-day-average minimum of a weigh-in series in the
/// [lookbackDays] window ending at [end] — the bulk-start trough.
///
/// Mechanics: weigh-ins are averaged per calendar day first (a
/// double-logged day must not double-count), every day with a weigh-in
/// in `[end − lookbackDays, end]` is a CANDIDATE, and each candidate's
/// value is the mean of the daily means over its trailing window
/// `[day − 6, day]` (available days only — gaps just shrink the
/// window; days before the lookback still feed an early candidate's
/// average, only candidacy is clipped). Minimum wins; ties go to the
/// EARLIEST day, so a flat trough reports its first day. Null when no
/// candidate exists.
///
/// 427 days ≈ 14 months: long enough to clear a year of bulk plus its
/// ramp, short enough that the previous cut's low can't win.
({DateTime day, double avg7})? weighInTrough(
  Iterable<({DateTime day, double value})> weighIns, {
  required DateTime end,
  int lookbackDays = 427,
}) {
  DateTime dayOf(DateTime d) => DateTime.utc(d.year, d.month, d.day);
  final endDay = dayOf(end);
  final firstDay = endDay.subtract(Duration(days: lookbackDays));

  final sums = <DateTime, double>{};
  final counts = <DateTime, int>{};
  for (final w in weighIns) {
    final d = dayOf(w.day);
    if (d.isAfter(endDay)) continue; // post-end can never feed a window
    sums[d] = (sums[d] ?? 0) + w.value;
    counts[d] = (counts[d] ?? 0) + 1;
  }
  final daily = {for (final d in sums.keys) d: sums[d]! / counts[d]!};

  ({DateTime day, double avg7})? best;
  final candidates = daily.keys.toList()..sort();
  for (final d in candidates) {
    if (d.isBefore(firstDay)) continue;
    var sum = 0.0;
    var n = 0;
    for (var k = 0; k < 7; k++) {
      final v = daily[d.subtract(Duration(days: k))];
      if (v == null) continue;
      sum += v;
      n++;
    }
    final avg = sum / n; // n >= 1 — d itself has a weigh-in
    if (best == null || avg < best.avg7) best = (day: d, avg7: avg);
  }
  return best;
}
