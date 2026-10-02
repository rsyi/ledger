/// Shared loader for the forecast-backed pages (IA restructure
/// 2026-10-02 — the Plan tab folded into Progress): the Weight page,
/// the Strength page and the per-lift page all read the SAME data the
/// old Plan tab assembled — intent docs, daily weigh-ins, strength
/// history, Macrofactor meals, Kaya ascents and the nightly
/// recalibration state — and build one [ForecastInputs] from it.
///
/// Every source degrades independently (a dead repo → empty list, the
/// page shows an honest placeholder); only missing intent docs make the
/// whole load null.
library;

import 'package:flutter/material.dart';

import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/forecast_calibration.dart' show ForecastMeta;
import '../services/forecast_meta_store.dart';
import '../services/home_synthesis.dart' show strengthRowFromRecord;
import '../services/nutrition_model.dart'
    show buildNutritionForecast, mealRowsFromRecords;
import '../services/program_metrics.dart' show StrengthRow, WeightRow;
import '../services/program_observed.dart';
import '../services/program_provider.dart';
import '../services/sim_fit.dart' show ClimbAscent, buildWeeklySeries;
import '../services/sim_program.dart' show simInitialFromSeries;
import '../services/sim2_harness.dart'
    show sim2BlocksFromProgramDocs, sim2ExpectationsFromProgramDocs;
import '../services/warehouse_connector.dart';
import '../services/weight_series.dart';
import 'design/design.dart';
import 'widgets/forecast_section.dart';

/// Where the forecast pages read from (the bottom-nav shell builds one
/// and hands it to every page it opens).
class PlanSources {
  final ProgramProvider provider;

  /// Airlayer + local SQLite for the weigh-in series (falls back to a
  /// direct ledger read when null/empty).
  final AnalyticsEngine? analytics;

  final WarehouseConnector? weightRepo;
  final ViewSchema? weightView;
  final WarehouseConnector? strengthRepo;
  final ViewSchema? strengthView;

  /// kaya_ascents (read-only) — the climbing projection's anchor.
  final WarehouseConnector? climbingRepo;
  final ViewSchema? climbingView;

  /// Macrofactor meals — the forecast's nutrition input.
  final WarehouseConnector? mealsRepo;
  final ViewSchema? mealsView;

  /// Nightly recalibration state (forecast_meta tab).
  final ForecastMetaStore? metaStore;

  const PlanSources({
    required this.provider,
    this.analytics,
    this.weightRepo,
    this.weightView,
    this.strengthRepo,
    this.strengthView,
    this.climbingRepo,
    this.climbingView,
    this.mealsRepo,
    this.mealsView,
    this.metaStore,
  });
}

class PlanData {
  final IntentDocs docs;

  /// One averaged weigh-in per day, date-ascending.
  final List<WeightRow> daily;

  /// Mapped strength history (empty when unavailable).
  final List<StrengthRow> strengthRows;

  /// Non-null when the weight query path failed.
  final String? observedError;

  /// Fully assembled forecast inputs; null when the sim can't run
  /// (no block calendar in program.yaml).
  final ForecastInputs? forecast;

  const PlanData({
    required this.docs,
    required this.daily,
    this.strengthRows = const [],
    this.observedError,
    this.forecast,
  });
}

/// Loads everything the forecast pages need. Null only when the intent
/// docs can't load.
Future<PlanData?> loadPlanData(PlanSources src, DateTime today) async {
  final IntentDocs docs;
  try {
    docs = await src.provider.load();
  } catch (_) {
    return null;
  }

  // Shared loader (weight_series.dart) — the Progress rows read
  // through the same path, so the two always agree.
  final series = await loadDailyWeighIns(
    analytics: src.analytics,
    view: src.weightView,
    repo: src.weightRepo,
  );

  var strengthRows = const <StrengthRow>[];
  if (src.strengthRepo != null && src.strengthView != null) {
    try {
      final recs = await src.strengthRepo!.list(src.strengthView!);
      strengthRows = [for (final r in recs) ?strengthRowFromRecord(r)];
    } catch (_) {}
  }

  var meals = const <Map<String, Object?>>[];
  if (src.mealsRepo != null && src.mealsView != null) {
    try {
      meals = await src.mealsRepo!.list(src.mealsView!);
    } catch (_) {}
  }

  final climbs = <ClimbAscent>[];
  if (src.climbingRepo != null && src.climbingView != null) {
    try {
      final recs = await src.climbingRepo!.list(src.climbingView!);
      final vRe = RegExp(r'^v(\d+)', caseSensitive: false);
      for (final r in recs) {
        final raw = r['date'];
        final d = raw is DateTime
            ? raw
            : DateTime.tryParse(raw?.toString() ?? '');
        if (d == null) continue;
        final g = vRe.firstMatch(r['grade']?.toString().trim() ?? '');
        climbs.add((
          date: d,
          vGrade: g == null ? null : int.parse(g.group(1)!),
        ));
      }
    } catch (_) {}
  }

  return PlanData(
    docs: docs,
    daily: series.daily,
    strengthRows: strengthRows,
    observedError: series.error,
    forecast: await _buildForecast(
      src,
      docs,
      series.daily,
      strengthRows,
      climbs,
      meals,
      today,
    ),
  );
}

/// The block calendar from program.yaml (required — null → placeholder)
/// plus optional local-history anchors (observed bw + the app's Epley
/// index total; missing history degrades to the seeds, it never blocks
/// the forecast).
Future<ForecastInputs?> _buildForecast(
  PlanSources src,
  IntentDocs docs,
  List<WeightRow> daily,
  List<StrengthRow> strengthRows,
  List<ClimbAscent> climbs,
  List<Map<String, Object?>> mealRecords,
  DateTime today,
) async {
  final blocks = sim2BlocksFromProgramDocs(docs.program);
  if (blocks == null) return null;
  double? observedBw;
  double? observedIndexTotal;
  try {
    if (strengthRows.isNotEmpty && daily.isNotEmpty) {
      final series = buildWeeklySeries(
        strengthRows: strengthRows,
        weightRows: daily,
        climbs: climbs,
      );
      final initial = simInitialFromSeries(series);
      observedBw = initial?.bw;
      final e = initial?.e1rm;
      if (e != null &&
          e.containsKey('squat') &&
          e.containsKey('bench') &&
          e.containsKey('deadlift')) {
        observedIndexTotal = e['squat']! + e['bench']! + e['deadlift']!;
      }
    }
  } catch (_) {} // history anchors are optional
  final meta = await _guardMeta(src);
  return ForecastInputs(
    blocks: blocks,
    observedDaily: daily,
    stats: observedWeightStats(daily, today),
    observedBw: observedBw,
    observedIndexTotal: observedIndexTotal,
    expectations: sim2ExpectationsFromProgramDocs(docs.program),
    nutrition: buildNutritionForecast(
      meals: mealRowsFromRecords(mealRecords),
      weighIns: daily,
      today: today,
    ),
    meta: meta,
  );
}

Future<ForecastMeta?> _guardMeta(PlanSources src) async {
  try {
    return await src.metaStore?.load();
  } catch (_) {
    return null;
  }
}

/// Shared page shell for the forecast pages: app bar, a pull-to-refresh
/// that busts the doc cache and re-runs the whole load (the local
/// refit included), a spinner while loading, and an honest message when
/// the intent docs are unavailable.
class PlanDataPage extends StatefulWidget {
  final String title;
  final PlanSources sources;
  final DateTime today;
  final List<Widget> Function(BuildContext context, PlanData data) build;

  const PlanDataPage({
    super.key,
    required this.title,
    required this.sources,
    required this.today,
    required this.build,
  });

  @override
  State<PlanDataPage> createState() => _PlanDataPageState();
}

class _PlanDataPageState extends State<PlanDataPage> {
  late Future<PlanData?> _load;

  @override
  void initState() {
    super.initState();
    _load = loadPlanData(widget.sources, widget.today);
  }

  Future<void> _refresh() async {
    ProgramProvider.clearCache();
    final next = loadPlanData(widget.sources, widget.today);
    setState(() => _load = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder<PlanData?>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          if (data == null || data.docs.program == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Program data unavailable — check GitHub config.',
                  style: AppText.meta(context),
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              physics: const AlwaysScrollableScrollPhysics(),
              children: widget.build(context, data),
            ),
          );
        },
      ),
    );
  }
}

/// Placeholder card when the forecast can't run (no block calendar).
Widget forecastUnavailableCard(BuildContext context, PlanData data) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
  child: AppCard(
    child: Text(
      data.observedError ??
          'Forecast unavailable — needs the program block calendar '
              '(coach/program.yaml; pull to refresh once online).',
      style: AppText.meta(context),
    ),
  ),
);
