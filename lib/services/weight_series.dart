/// Shared daily weigh-in loader — the observed layer's data path,
/// extracted from the Program screen so the home dashboard's BODY card
/// reuses the exact same machinery (airlayer semantic query over the
/// `weight` view: group by date, average `weight_lbs`; windowed metrics
/// stay in pure Dart downstream).
///
/// Two paths (perf #6, 2026-10-12 — order SWAPPED):
///  1. LEDGER — read the weight view's rows straight off the repository
///     (the engine store — the exact list() the timeline renders from)
///     and average per day in Dart. Used whenever [repo] is given and
///     the read succeeds (an empty ledger is an honest "no data").
///  2. ANALYTICS — airlayer-compiled SQL over the LocalDb SQLite mirror
///     AS IT STANDS, only when there is no repo or its read failed. The
///     mirror is NO LONGER rebuilt here: every call used to DROP +
///     re-INSERT the whole weight table just to average it per day.
///     (chat run_query still refreshes the mirror for its own queries.)
/// "No weigh-in data" is true only when BOTH paths come back empty.
library;

import '../models/view_schema.dart';
import 'analytics_engine.dart';
import 'perf.dart';
import 'program_metrics.dart' show WeightRow;
import 'warehouse_connector.dart';

/// Which path actually served [WeightSeriesResult.daily].
enum WeightSeriesSource { analytics, ledger, none }

/// Daily series + optional error. [daily] is one averaged point per day,
/// date-ascending. [error] is non-null only when NO path produced data —
/// callers render it as a note instead of data. [source] says which path
/// served the rows ([WeightSeriesSource.none] when both were empty).
typedef WeightSeriesResult = ({
  List<WeightRow> daily,
  String? error,
  WeightSeriesSource source,
});

/// Loads the daily weigh-in series: direct ledger read first, the
/// analytics mirror as the fallback (see the library doc). Null
/// [analytics]/[view]/[repo] degrade path by path; only all-paths-empty
/// surfaces an error.
Future<WeightSeriesResult> loadDailyWeighIns({
  required AnalyticsEngine? analytics,
  required ViewSchema? view,
  WarehouseConnector? repo,
}) =>
    Perf.span(
      'weight.daily',
      () => _loadDailyWeighIns(analytics: analytics, view: view, repo: repo),
      metaOf: (r) => {'days': r.daily.length, 'source': r.source.name},
    );

Future<WeightSeriesResult> _loadDailyWeighIns({
  required AnalyticsEngine? analytics,
  required ViewSchema? view,
  WarehouseConnector? repo,
}) async {
  String? ledgerError;
  if (view != null && repo != null) {
    try {
      final daily = dailyWeighInsFromRecords(await repo.list(view));
      return (
        daily: daily,
        error: null,
        source: daily.isEmpty
            ? WeightSeriesSource.none
            : WeightSeriesSource.ledger,
      );
    } catch (e) {
      ledgerError = 'Weight ledger read failed: $e';
    }
  }

  var primary = const <WeightRow>[];
  String? primaryError;
  if (view == null) {
    primaryError = 'Weight view unavailable on this build.';
  } else if (analytics == null) {
    primaryError = 'Analytics engine unavailable on this build.';
  } else {
    try {
      final rows = await analytics.run(view, query: {
        'dimensions': ['weight.date'],
        'measures': ['weight.avg_weight_lbs'],
        'order': [
          {'id': 'weight.date', 'desc': false},
        ],
      });
      primary = [
        for (final r in rows)
          ?_weightRow(r['weight__date'], r['weight__avg_weight_lbs']),
      ];
    } catch (e) {
      primaryError = 'Weight query failed: $e';
    }
  }
  return selectWeightSeries(
    primary: primary,
    primaryError: ledgerError ?? primaryError,
    fallback: const [],
    fallbackError: null,
  );
}

/// Pure selection: primary path wins when it has rows; otherwise the
/// fallback's rows; an error only when both are empty (primary's error
/// first — it's the richer diagnostic — then the fallback's).
WeightSeriesResult selectWeightSeries({
  required List<WeightRow> primary,
  required String? primaryError,
  required List<WeightRow> fallback,
  required String? fallbackError,
}) {
  if (primary.isNotEmpty) {
    return (
      daily: primary,
      error: null,
      source: WeightSeriesSource.analytics,
    );
  }
  if (fallback.isNotEmpty) {
    return (daily: fallback, error: null, source: WeightSeriesSource.ledger);
  }
  return (
    daily: const <WeightRow>[],
    error: primaryError ?? fallbackError,
    source: WeightSeriesSource.none,
  );
}

/// Pure fallback builder: raw weight-view records (as the repository's
/// `list()` returns them — `date` a DateTime or ISO string, `weight_lbs`
/// a num or numeric string) → one averaged point per day, ascending.
/// Rows missing either field are skipped.
List<WeightRow> dailyWeighInsFromRecords(
  Iterable<Map<String, Object?>> records,
) {
  final sums = <DateTime, double>{};
  final counts = <DateTime, int>{};
  for (final r in records) {
    final date = _asUtcDay(r['date']);
    final lbs = _asDouble(r['weight_lbs']);
    if (date == null || lbs == null) continue;
    sums[date] = (sums[date] ?? 0) + lbs;
    counts[date] = (counts[date] ?? 0) + 1;
  }
  final days = sums.keys.toList()..sort();
  return [
    for (final d in days) WeightRow(date: d, weightLbs: sums[d]! / counts[d]!),
  ];
}

WeightRow? _weightRow(Object? dateRaw, Object? lbsRaw) {
  final date = _asUtcDay(dateRaw);
  final lbs = _asDouble(lbsRaw);
  if (date == null || lbs == null) return null;
  return WeightRow(date: date, weightLbs: lbs);
}

DateTime? _asUtcDay(Object? v) {
  final d = v is DateTime ? v : DateTime.tryParse(v?.toString() ?? '');
  return d == null ? null : DateTime.utc(d.year, d.month, d.day);
}

double? _asDouble(Object? v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
