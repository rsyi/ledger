import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/program_metrics.dart' show WeightRow;
import 'package:airledger/services/weight_series.dart';

void main() {
  group('dailyWeighInsFromRecords', () {
    test('groups by day, averages, sorts ascending', () {
      final rows = dailyWeighInsFromRecords([
        {'date': DateTime(2026, 9, 20), 'weight_lbs': 181.0},
        {'date': DateTime(2026, 9, 18), 'weight_lbs': 183.0},
        // Same day twice → averaged into one point.
        {'date': DateTime(2026, 9, 19), 'weight_lbs': 182.0},
        {'date': DateTime(2026, 9, 19), 'weight_lbs': 184.0},
      ]);
      expect(rows.map((r) => r.date), [
        DateTime.utc(2026, 9, 18),
        DateTime.utc(2026, 9, 19),
        DateTime.utc(2026, 9, 20),
      ]);
      expect(rows.map((r) => r.weightLbs), [183.0, 183.0, 181.0]);
    });

    test('accepts ISO-string dates and numeric-string weights', () {
      final rows = dailyWeighInsFromRecords([
        {'date': '2026-09-18', 'weight_lbs': '183.5'},
        // Datetime-grained date collapses to its calendar day.
        {'date': '2026-09-18T07:30:00', 'weight_lbs': 182.5},
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.date, DateTime.utc(2026, 9, 18));
      expect(rows.single.weightLbs, 183.0);
    });

    test('skips rows missing/invalid date or weight', () {
      final rows = dailyWeighInsFromRecords([
        {'date': DateTime(2026, 9, 18)}, // no weight
        {'date': DateTime(2026, 9, 18), 'weight_lbs': null},
        {'date': DateTime(2026, 9, 18), 'weight_lbs': 'n/a'},
        {'weight_lbs': 180.0}, // no date
        {'date': 'not-a-date', 'weight_lbs': 180.0},
        {'date': DateTime(2026, 9, 19), 'weight_lbs': 181.0},
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.weightLbs, 181.0);
    });

    test('empty input → empty series', () {
      expect(dailyWeighInsFromRecords(const []), isEmpty);
    });
  });

  group('selectWeightSeries', () {
    final a = [WeightRow(date: DateTime.utc(2026, 9, 18), weightLbs: 183)];
    final b = [WeightRow(date: DateTime.utc(2026, 9, 19), weightLbs: 182)];

    test('primary rows win, even when the fallback also has rows', () {
      final r = selectWeightSeries(
        primary: a,
        primaryError: null,
        fallback: b,
        fallbackError: null,
      );
      expect(r.daily, a);
      expect(r.error, isNull);
      expect(r.source, WeightSeriesSource.analytics);
    });

    test('empty primary → fallback serves, primary error suppressed', () {
      final r = selectWeightSeries(
        primary: const [],
        primaryError: 'Weight query failed: boom',
        fallback: b,
        fallbackError: null,
      );
      expect(r.daily, b);
      expect(r.error, isNull, reason: 'fallback served — render normally');
      expect(r.source, WeightSeriesSource.ledger);
    });

    test('both empty → no data, primary error preferred', () {
      final r = selectWeightSeries(
        primary: const [],
        primaryError: 'Weight query failed: boom',
        fallback: const [],
        fallbackError: 'Weight ledger read failed: also boom',
      );
      expect(r.daily, isEmpty);
      expect(r.error, 'Weight query failed: boom');
      expect(r.source, WeightSeriesSource.none);
    });

    test('both empty, only fallback errored → its error surfaces', () {
      final r = selectWeightSeries(
        primary: const [],
        primaryError: null,
        fallback: const [],
        fallbackError: 'Weight ledger read failed: boom',
      );
      expect(r.error, 'Weight ledger read failed: boom');
      expect(r.source, WeightSeriesSource.none);
    });

    test('both empty with no errors → genuinely no weigh-in data', () {
      final r = selectWeightSeries(
        primary: const [],
        primaryError: null,
        fallback: const [],
        fallbackError: null,
      );
      expect(r.daily, isEmpty);
      expect(r.error, isNull);
      expect(r.source, WeightSeriesSource.none);
    });
  });
}
