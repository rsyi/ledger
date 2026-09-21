/// Shared daily weigh-in loader — the observed layer's data path,
/// extracted from the Program screen so the home dashboard's BODY card
/// reuses the exact same machinery (airlayer semantic query over the
/// `weight` view: group by date, average `weight_lbs`; windowed metrics
/// stay in pure Dart downstream).
library;

import '../models/view_schema.dart';
import 'analytics_engine.dart';
import 'program_metrics.dart' show WeightRow;
import 'warehouse_connector.dart';

/// Daily series + optional error. [daily] is one averaged point per day,
/// date-ascending. [error] is non-null when the query path failed —
/// callers render it as a note instead of data.
typedef WeightSeriesResult = ({List<WeightRow> daily, String? error});

/// Loads the daily weigh-in series through airlayer. Best-effort mirror
/// refresh first (a sync failure still lets us query the last-synced
/// cache); a null [analytics] or [view] short-circuits to an
/// "unavailable" error so screens degrade gracefully offline.
Future<WeightSeriesResult> loadDailyWeighIns({
  required AnalyticsEngine? analytics,
  required ViewSchema? view,
  WarehouseConnector? repo,
}) async {
  if (analytics == null || view == null) {
    return (
      daily: const <WeightRow>[],
      error: 'Analytics engine unavailable on this build.',
    );
  }
  try {
    if (repo != null) {
      try {
        await analytics.db.syncFromSheet(view, repo);
      } catch (_) {/* stale cache is better than nothing */}
    }
    final rows = await analytics.run(view, query: {
      'dimensions': ['weight.date'],
      'measures': ['weight.avg_weight_lbs'],
      'order': [
        {'id': 'weight.date', 'desc': false},
      ],
    });
    final daily = <WeightRow>[];
    for (final r in rows) {
      final lbs = (r['weight__avg_weight_lbs'] as num?)?.toDouble();
      final dateRaw = r['weight__date']?.toString();
      if (lbs == null || dateRaw == null) continue;
      final date = DateTime.tryParse(dateRaw);
      if (date == null) continue;
      daily.add(WeightRow(
        date: DateTime.utc(date.year, date.month, date.day),
        weightLbs: lbs,
      ));
    }
    return (daily: daily, error: null);
  } catch (e) {
    return (
      daily: const <WeightRow>[],
      error: 'Weight query failed: $e',
    );
  }
}
