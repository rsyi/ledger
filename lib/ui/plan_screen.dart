/// Plan tab — PHASES + PROGRESS (tab split, 2026-09-28): "what did I
/// declare, is it working, and where does it go from here?"
///
/// The ROUTINE (this week's sessions + working maxes) lives on the
/// separate Program screen (program_screen.dart, the app-bar action
/// here); this tab deliberately carries NO day-to-day surface.
///
/// Default view (UI redesign phase 6, 2026-10-02 — plain-language
/// summaries first): the VERDICT (is the declared phase working?), the
/// phase declaration + block timeline with the you-are-here marker,
/// then the SINGLE-TRAJECTORY forecast (2026-09-28 directive): the
/// plain projection summary + ONE combined strength chart, the
/// NUTRITION card (Macrofactor intake → adaptive maintenance → the
/// sim's rate; calorie-delta what-if is the ONLY lever), body comp /
/// climbing / VO2 / fatigue folds, and ONE "Model details" disclosure
/// holding every model internal (tracking, caveats, parameter sheet).
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/forecast_meta_store.dart';
import '../services/home_synthesis.dart' show strengthRowFromRecord;
import '../services/nutrition_model.dart'
    show buildNutritionForecast, mealRowsFromRecords;
import '../services/program_current.dart';
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

class PlanScreen extends StatefulWidget {
  final ProgramProvider provider;

  /// Airlayer + local SQLite. Null → the observed/verdict sections show
  /// an "analytics unavailable" note instead of data.
  final AnalyticsEngine? analytics;

  /// Connector + schema for the `weight` view (observed layer's source).
  final WarehouseConnector? weightRepo;
  final ViewSchema? weightView;

  /// Connector + schema for the `strength` view — feeds the FORECAST
  /// section's initial state (same list→strengthRowFromRecord path the
  /// domain screen uses). Null → the forecast shows a placeholder.
  final WarehouseConnector? strengthRepo;
  final ViewSchema? strengthView;

  /// Connector + schema for the `climbing` view (kaya_ascents,
  /// read-only) — the FORECAST section's observed grade p75 anchor.
  /// Null → the climbing forecast is omitted.
  final WarehouseConnector? climbingRepo;
  final ViewSchema? climbingView;

  /// Connector + schema for the `meals` view (Macrofactor) — the
  /// forecast's NUTRITION input. Null → the nutrition card shows the
  /// no-data note and the sim runs the declared block rates.
  final WarehouseConnector? mealsRepo;
  final ViewSchema? mealsView;

  /// Nightly recalibration state reader (forecast_meta tab). Null →
  /// tracking shows "on" with no adjustment applied.
  final ForecastMetaStore? metaStore;

  /// Routine (Program screen) opener. Non-null (the bottom-nav shell
  /// passes it) → the app bar gets the routine action; the Program
  /// screen itself pushes on the root navigator.
  final VoidCallback? onOpenRoutine;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  const PlanScreen({
    super.key,
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
    this.onOpenRoutine,
    this.today,
  });

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanData {
  final IntentDocs docs;

  /// One averaged weigh-in per day, date-ascending (from airlayer).
  final List<WeightRow> daily;

  /// Non-null when the weight query path failed (missing analytics lib,
  /// sync error, etc.) — shown as a note in the forecast section.
  final String? observedError;

  /// Fully assembled forecast inputs; null when the sim can't run
  /// (missing world model / program docs / local history) — the
  /// section renders a placeholder instead.
  final ForecastInputs? forecast;

  const _PlanData({
    required this.docs,
    required this.daily,
    this.observedError,
    this.forecast,
  });
}

class _PlanScreenState extends State<PlanScreen> {
  late Future<_PlanData?> _load;
  late final DateTime _today;

  @override
  void initState() {
    super.initState();
    _today = widget.today ?? DateTime.now();
    _load = _fetch();
  }

  /// Pull-to-refresh: bust the shared doc cache (intent docs +
  /// world_model.yaml) and re-run the whole load — including the
  /// local-history refit (design §8 "the app refits on demand").
  Future<void> _refresh() async {
    ProgramProvider.clearCache();
    final next = _fetch();
    setState(() => _load = next);
    await next;
  }

  Future<_PlanData?> _fetch() async {
    final IntentDocs docs;
    try {
      docs = await widget.provider.load();
    } catch (_) {
      return null;
    }

    // Shared loader (weight_series.dart) — the home dashboard's BODY
    // card reads through the same path, so the two always agree.
    final series = await loadDailyWeighIns(
      analytics: widget.analytics,
      view: widget.weightView,
      repo: widget.weightRepo,
    );

    // Strength rows for the sim's initial state — the same raw-list →
    // strengthRowFromRecord path the domain screen's dashboard uses.
    // Errors degrade to an empty list (the section shows a placeholder).
    var strengthRows = const <StrengthRow>[];
    if (widget.strengthRepo != null && widget.strengthView != null) {
      try {
        final recs = await widget.strengthRepo!.list(widget.strengthView!);
        strengthRows = [for (final r in recs) ?strengthRowFromRecord(r)];
      } catch (_) {}
    }

    // Meals (Macrofactor) — the forecast's nutrition input. Errors
    // degrade to empty (the nutrition card says "no data" honestly).
    var meals = const <Map<String, Object?>>[];
    if (widget.mealsRepo != null && widget.mealsView != null) {
      try {
        meals = await widget.mealsRepo!.list(widget.mealsView!);
      } catch (_) {}
    }

    // Climbing ascents (kaya_ascents) — dates + numeric V grades for
    // the observed p75 anchor. Missing plumbing → no climbing forecast.
    final climbs = <ClimbAscent>[];
    if (widget.climbingRepo != null && widget.climbingView != null) {
      try {
        final recs = await widget.climbingRepo!.list(widget.climbingView!);
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

    return _PlanData(
      docs: docs,
      daily: series.daily,
      observedError: series.error,
      forecast: await _buildForecast(
        docs,
        series.daily,
        strengthRows,
        climbs,
        meals,
      ),
    );
  }

  /// Assembles [ForecastInputs] for the sim2 section: the block
  /// calendar from program.yaml (required — null → placeholder card)
  /// plus optional local-history anchors (observed bw + the app's
  /// Epley-index total; missing history degrades to the [log] seeds,
  /// it never blocks the forecast).
  Future<ForecastInputs?> _buildForecast(
    IntentDocs docs,
    List<WeightRow> daily,
    List<StrengthRow> strengthRows,
    List<ClimbAscent> climbs,
    List<Map<String, Object?>> mealRecords,
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
    // Nightly recalibration state — optional, degrades to null.
    final meta = await widget.metaStore?.load();
    return ForecastInputs(
      blocks: blocks,
      observedDaily: daily,
      stats: observedWeightStats(daily, _today),
      observedBw: observedBw,
      observedIndexTotal: observedIndexTotal,
      // v10 expectations_1yr — faint "range, not target" band.
      expectations: sim2ExpectationsFromProgramDocs(docs.program),
      // NUTRITION as the input (the only lever): actual Macrofactor
      // days + weigh-in trend → adaptive maintenance + implied rate.
      nutrition: buildNutritionForecast(
        meals: mealRowsFromRecords(mealRecords),
        weighIns: daily,
        today: _today,
      ),
      meta: meta,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan'),
        actions: [
          if (widget.onOpenRoutine != null)
            IconButton(
              icon: const Icon(Icons.fitness_center_outlined),
              tooltip: "This week's routine",
              onPressed: widget.onOpenRoutine,
            ),
        ],
      ),
      body: FutureBuilder<_PlanData?>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          if (data == null || data.docs.program == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Program data unavailable — check GitHub config.'),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: _PlanView(data: data, today: _today),
          );
        },
      ),
    );
  }
}


// ---------------------------------------------------------------------------
// Main view
// ---------------------------------------------------------------------------

class _PlanView extends StatelessWidget {
  final _PlanData data;
  final DateTime today;

  const _PlanView({required this.data, required this.today});

  @override
  Widget build(BuildContext context) {
    final program = data.docs.program!;
    final phaseVersion = currentVersion(data.docs.phase);
    final programVersion = currentVersion(program);
    final slice = programCurrent(program, data.docs.phase, today);

    final stats = observedWeightStats(data.daily, today);
    final phase = phaseVersion?['value']?.toString();
    final targetRate = (phaseVersion?['target_rate_lb_per_week'] as num?)
        ?.toDouble();
    final verdict = phase == null
        ? null
        : phaseVerdict(
            phase: phase,
            targetRateLbWk: targetRate,
            recentRates: stats.recentRates,
            bw3wkChange: stats.bw3wkChange,
          );

    const gutter = EdgeInsets.symmetric(horizontal: AppSpace.gutter);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        // Plain-language answer first: is the declared phase working?
        const SectionHeader(label: 'Verdict'),
        Padding(
          padding: gutter,
          child: _VerdictCard(
            phase: phase,
            targetRate: targetRate,
            verdict: verdict,
            stats: stats,
          ),
        ),
        const SectionHeader(label: 'Phase'),
        Padding(
          padding: gutter,
          child: _DeclaredCard(
            phaseVersion: phaseVersion,
            targetRate: targetRate,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: gutter,
          child: _BlockTimeline(
            programVersion: programVersion,
            slice: slice,
            today: today,
          ),
        ),
        if (data.forecast != null)
          // Single trajectory: summary + chart, nutrition lever, folds,
          // one Model details disclosure.
          ForecastSection(inputs: data.forecast!, today: today)
        else ...[
          const SectionHeader(label: 'Projection'),
          Padding(
            padding: gutter,
            child: AppCard(
              child: Text(
                data.observedError ??
                    'Forecast unavailable — needs the program block '
                        'calendar (coach/program.yaml; pull to refresh '
                        'once online).',
                style: AppText.meta(context),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 1. Declared
// ---------------------------------------------------------------------------

class _DeclaredCard extends StatelessWidget {
  final Map<Object?, Object?>? phaseVersion;
  final double? targetRate;

  const _DeclaredCard({required this.phaseVersion, required this.targetRate});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = phaseVersion;
    if (p == null) {
      return AppCard(
        child: Text(
          'No phase declared (coach/phase.yaml missing).',
          style: AppText.meta(context),
        ),
      );
    }
    final value = p['value']?.toString() ?? '?';
    final since = p['effective_from']?.toString();
    final targetWt = p['target_weight_lb'];
    final reason = p['reason']?.toString();
    final exit = p['exit_criteria']?.toString();

    final small = AppText.meta(context);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                ),
                child: Text(
                  value.toUpperCase(),
                  style: AppText.section(context).copyWith(
                    color: scheme.onPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (since != null)
                Text('since ${_fmtIso(since)}', style: small),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            [
              if (targetWt != null) 'Target $targetWt lb',
              if (targetRate != null) '${_fmtSigned(targetRate!)} lb/wk',
            ].join(' · '),
            style: AppText.title(context),
          ),
          if (reason != null) ...[
            const SizedBox(height: 6),
            Text(reason, style: small.copyWith(fontStyle: FontStyle.italic)),
          ],
          if (exit != null) ...[
            const SizedBox(height: 6),
            Text('Exit: $exit', style: small),
          ],
        ],
      ),
    );
  }
}

/// The 8 program blocks as a vertical timeline with a you-are-here
/// marker on the current block (block-progress bar + week N).
class _BlockTimeline extends StatelessWidget {
  final Map<Object?, Object?>? programVersion;
  final ProgramSlice? slice;
  final DateTime today;

  const _BlockTimeline({
    required this.programVersion,
    required this.slice,
    required this.today,
  });

  static Color _emphasisColor(BuildContext context, String emphasis) {
    final scheme = Theme.of(context).colorScheme;
    return switch (emphasis) {
      'cut' => scheme.error,
      'reverse' => scheme.tertiary,
      'climbing' => scheme.secondary,
      _ => scheme.primary, // lifting
    };
  }

  @override
  Widget build(BuildContext context) {
    final blocks = programVersion?['blocks'];
    if (blocks is! List) return const SizedBox.shrink();
    final currentN = slice?.block['number'] as int?;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        children: [
          for (final b in blocks)
            if (b is Map) _blockRow(context, b, currentN),
        ],
      ),
    );
  }

  Widget _blockRow(BuildContext context, Map b, int? currentN) {
    final scheme = Theme.of(context).colorScheme;
    final n = b['n'] as int?;
    final isCurrent = n != null && n == currentN;
    final emphasis = b['emphasis']?.toString() ?? '';
    final dates = b['dates'] as List?;
    final weights = b['weight'] as List?;
    final start = dates != null ? DateTime.tryParse(dates[0].toString()) : null;
    final end = dates != null ? DateTime.tryParse(dates[1].toString()) : null;
    final dateStr = start != null && end != null
        ? '${DateFormat('MMM d yy').format(start)} – '
              '${DateFormat('MMM d yy').format(end)}'
        : '';
    final wtStr = weights != null && weights.length == 2
        ? '${weights[0]}→${weights[1]} lb'
        : '';
    final color = _emphasisColor(context, emphasis);

    // Block progress for the you-are-here marker.
    double? progress;
    if (isCurrent && start != null && end != null) {
      final total = end.difference(start).inDays + 1;
      final done =
          DateTime(
            today.year,
            today.month,
            today.day,
          ).difference(DateTime(start.year, start.month, start.day)).inDays +
          1;
      if (total > 0) progress = (done / total).clamp(0.0, 1.0);
    }

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                padding: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isCurrent ? 1.0 : 0.15),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  'B$n',
                  textAlign: TextAlign.center,
                  style: AppText.meta(context).copyWith(
                    fontWeight: FontWeight.w700,
                    color: isCurrent ? scheme.surface : color,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 68,
                child: Text(
                  emphasis,
                  style: AppText.meta(context).copyWith(
                    color: scheme.onSurface,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              Expanded(
                child: Text(dateStr, style: AppText.meta(context)),
              ),
              Text(wtStr, style: AppText.meta(context)),
            ],
          ),
          if (isCurrent && progress != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 40),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                      color: color,
                      backgroundColor: color.withValues(alpha: 0.15),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                const SizedBox(width: 40),
                // Expanded so the line WRAPS at narrow widths (360dp)
                // instead of overflowing — reflow over ellipsis.
                Expanded(
                  child: Text(
                    'You are here — week ${slice?.weekInBlock} of block $n'
                    '${slice?.weekType != 'normal' ? ' (${slice?.weekType} week)' : ''}',
                    style: AppText.meta(context).copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    if (!isCurrent) return row;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: row,
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Verdict
// ---------------------------------------------------------------------------

class _VerdictCard extends StatelessWidget {
  final String? phase;
  final double? targetRate;
  final PhaseVerdict? verdict;
  final ObservedWeightStats stats;

  const _VerdictCard({
    required this.phase,
    required this.targetRate,
    required this.verdict,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final v = verdict;
    if (phase == null || v == null) {
      return AppCard(
        child: Text(
          'No declared phase — nothing to compare against.',
          style: AppText.meta(context),
        ),
      );
    }

    // Shared status palette: green agree, amber drift, red only for a
    // real mismatch, muted when unknown.
    final (status, icon) = switch (v.state) {
      VerdictState.agree => (ItemStatus.done, Icons.check_circle_outline),
      VerdictState.drift => (ItemStatus.partial, Icons.warning_amber_outlined),
      VerdictState.mismatch => (ItemStatus.problem, Icons.error_outline),
      VerdictState.unknown => (ItemStatus.muted, Icons.help_outline),
    };
    final fg = StatusColors.of(context).forStatus(context, status);

    final declared =
        'Declared $phase'
        '${targetRate != null ? ' (target ${_fmtSigned(targetRate!)} lb/wk)' : ''}';
    final observed = v.observedRateLbWk == null
        ? 'no observed rate yet'
        : 'observed ${_fmtSigned(v.observedRateLbWk!)} lb/wk over 3 wks';

    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 22),
          const SizedBox(width: AppSpace.leadGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.label, style: AppText.title(context).copyWith(color: fg)),
                const SizedBox(height: 4),
                Text('$declared · $observed', style: AppText.meta(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

String _fmtSigned(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)}';

String _fmtIso(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat('MMM d, yyyy').format(d);
}
