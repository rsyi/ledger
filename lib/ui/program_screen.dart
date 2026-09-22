/// Program screen — "what did I declare, what is actually happening,
/// and do they agree?"
///
/// Four sections, deliberately separate:
///  1. DECLARED — the intent layer verbatim: phase.yaml (value,
///     effective_from, reason, target, exit criteria) + program.yaml's
///     block timeline with a you-are-here marker.
///  2. CONFIGURATION — the working-max controller (append-only
///     `working_max` tab via WmStore): per-lift value/variant/source,
///     Confirm on pending seeds, manual "Set working max…". The one
///     part of this screen that writes (appends) anywhere.
///  3. OBSERVED — reality from the ledger: daily weigh-ins queried
///     through airlayer (the `weight` view's declared `avg_weight_lbs`
///     measure grouped by date — one averaged point per day), then the
///     §2.5 windowed formulas from program_metrics/program_observed
///     (7-day avg, weekly rate, 3-week change) computed in pure Dart.
///     Below the weight chart: the Wilks block — the strength domain's
///     monthly wilks_series (same MetricChart widget, same
///     dashboards.yaml config, so the two screens always agree) with
///     its cut-start reference + floor lines, plus the weekly-current
///     stat line from the hero's wilksStability math ("Wilks 327.5 ·
///     floor 319.3 · 0 wks below").
///  4. VERDICT — PHASE_MISMATCH semantics: green (agree), amber
///     (drifting), red (three consecutive mismatch weeks — the flag
///     would fire).
library;

import 'package:fl_chart/fl_chart.dart';
import 'widgets/chart_bottom_axis.dart';
import 'widgets/chart_range.dart';
import 'widgets/pinned_tooltip_line_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/domain_config.dart';
import '../services/domain_metrics.dart';
import '../services/home_synthesis.dart' show strengthRowFromRecord;
import '../services/phase_eigenvectors.dart' show wilksStability;
import '../services/program_current.dart';
import '../services/program_metrics.dart' show StrengthRow, WeightRow;
import '../services/program_observed.dart';
import '../services/program_provider.dart';
import '../services/warehouse_connector.dart';
import '../services/weight_series.dart';
import '../services/wilks.dart' show WilksWeek, weeklyWilksSeries;
import '../services/wm_store.dart';
import 'widgets/metric_chart.dart';
import 'widgets/working_max_card.dart';

class ProgramScreen extends StatefulWidget {
  final ProgramProvider provider;

  /// Airlayer + local SQLite. Null → the observed/verdict sections show
  /// an "analytics unavailable" note instead of data.
  final AnalyticsEngine? analytics;

  /// Connector + schema for the `weight` view (observed layer's source).
  final WarehouseConnector? weightRepo;
  final ViewSchema? weightView;

  /// Connector + schema for the `strength` view — feeds the OBSERVED
  /// Wilks block (same list→strengthRowFromRecord path the domain
  /// screen uses). Null → the block is omitted.
  final WarehouseConnector? strengthRepo;
  final ViewSchema? strengthView;

  /// dashboards.yaml provider (shared 1 h cache) — the Wilks block
  /// reads the strength domain's `wilks_series` metric config from it
  /// (from/floor_pct), so this screen and the strength domain always
  /// agree. Null → the block is omitted.
  final DomainConfigProvider? dashboards;

  /// Working-max controller tabs — the CONFIGURATION section's card.
  /// Null → the section is omitted.
  final WmStore? wmStore;

  /// Week-plan opener. Non-null (the bottom-nav shell passes it) → the
  /// app bar gets an event-note action; the Week Plan screen itself
  /// still pushes on the root navigator.
  final VoidCallback? onOpenWeekPlan;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  const ProgramScreen({
    super.key,
    required this.provider,
    this.analytics,
    this.weightRepo,
    this.weightView,
    this.strengthRepo,
    this.strengthView,
    this.dashboards,
    this.wmStore,
    this.onOpenWeekPlan,
    this.today,
  });

  @override
  State<ProgramScreen> createState() => _ProgramScreenState();
}

class _ProgramData {
  final IntentDocs docs;

  /// One averaged weigh-in per day, date-ascending (from airlayer).
  final List<WeightRow> daily;

  /// Non-null when the weight query path failed (missing analytics lib,
  /// sync error, etc.) — shown as a note in the observed section.
  final String? observedError;

  /// Mapped strength-ledger rows for the Wilks block (empty on error /
  /// when the build has no strength view).
  final List<StrengthRow> strengthRows;

  /// The strength domain's `wilks_series` metric config from
  /// dashboards.yaml. Null → no Wilks block.
  final MetricConfig? wilksConfig;

  const _ProgramData({
    required this.docs,
    required this.daily,
    this.observedError,
    this.strengthRows = const [],
    this.wilksConfig,
  });
}

class _ProgramScreenState extends State<ProgramScreen> {
  late final Future<_ProgramData?> _load;
  late final DateTime _today;

  @override
  void initState() {
    super.initState();
    _today = widget.today ?? DateTime.now();
    _load = _fetch();
  }

  Future<_ProgramData?> _fetch() async {
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

    // Strength rows for the Wilks block — the same raw-list →
    // strengthRowFromRecord path the domain screen's dashboard uses.
    // Errors degrade to an empty list (the block shows a placeholder).
    var strengthRows = const <StrengthRow>[];
    if (widget.strengthRepo != null && widget.strengthView != null) {
      try {
        final recs = await widget.strengthRepo!.list(widget.strengthView!);
        strengthRows = [for (final r in recs) ?strengthRowFromRecord(r)];
      } catch (_) {}
    }

    // wilks_series config: whichever domain declares it (strength).
    // One config source — this screen can never disagree with the
    // strength domain's chart about the reference/floor.
    MetricConfig? wilksConfig;
    if (widget.dashboards != null) {
      try {
        final domains = await widget.dashboards!.load();
        for (final d in domains ?? const <DomainConfig>[]) {
          for (final m in d.metrics) {
            if (m.id == 'wilks_series') wilksConfig ??= m;
          }
        }
      } catch (_) {}
    }

    return _ProgramData(
      docs: docs,
      daily: series.daily,
      observedError: series.error,
      strengthRows: strengthRows,
      wilksConfig: wilksConfig,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Program'),
        actions: [
          if (widget.onOpenWeekPlan != null)
            IconButton(
              icon: const Icon(Icons.event_note_outlined),
              tooltip: 'Week plan',
              onPressed: widget.onOpenWeekPlan,
            ),
        ],
      ),
      body: FutureBuilder<_ProgramData?>(
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
          return _ProgramView(
            data: data,
            today: _today,
            wmStore: widget.wmStore,
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Main view
// ---------------------------------------------------------------------------

class _ProgramView extends StatelessWidget {
  final _ProgramData data;
  final DateTime today;
  final WmStore? wmStore;

  const _ProgramView({
    required this.data,
    required this.today,
    required this.wmStore,
  });

  @override
  Widget build(BuildContext context) {
    final program = data.docs.program!;
    final phaseVersion = currentVersion(data.docs.phase);
    final programVersion = currentVersion(program);
    final slice = programCurrent(program, data.docs.phase, today);

    // Current block window + target weights (for the chart + verdict).
    final block = slice?.block;
    DateTime? blockStart, blockEnd;
    double? targetFrom, targetTo;
    if (block != null) {
      final dates = block['dates'];
      final weights = block['target_weight'];
      if (dates is List && dates.length == 2) {
        blockStart = DateTime.tryParse(dates[0].toString());
        blockEnd = DateTime.tryParse(dates[1].toString());
      }
      if (weights is List && weights.length == 2) {
        targetFrom = (weights[0] as num?)?.toDouble();
        targetTo = (weights[1] as num?)?.toDouble();
      }
    }

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

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        _SectionLabel('Declared'),
        _DeclaredCard(phaseVersion: phaseVersion, targetRate: targetRate),
        const SizedBox(height: 8),
        _BlockTimeline(
          programVersion: programVersion,
          slice: slice,
          today: today,
        ),
        if (wmStore != null) ...[
          const SizedBox(height: 16),
          _SectionLabel('Configuration'),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: WorkingMaxCard(store: wmStore!),
          ),
        ],
        const SizedBox(height: 16),
        _SectionLabel('Observed'),
        _ObservedCard(
          daily: data.daily,
          stats: stats,
          today: today,
          blockStart: blockStart,
          blockEnd: blockEnd,
          targetFrom: targetFrom,
          targetTo: targetTo,
          error: data.observedError,
        ),
        if (data.wilksConfig != null) ...[
          const SizedBox(height: 8),
          _WilksCard(
            config: data.wilksConfig!,
            strengthRows: data.strengthRows,
            daily: data.daily,
            today: today,
            blockStart: blockStart,
            // Accounting-week keying for the weekly-current stat
            // (program.yaml v7 week_start — saturday since 2026-09-22).
            weekStartDay: weekStartDayOf(programVersion),
          ),
        ],
        const SizedBox(height: 16),
        _SectionLabel('Verdict'),
        _VerdictCard(
          phase: phase,
          targetRate: targetRate,
          verdict: verdict,
          stats: stats,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 4),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
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
      return Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No phase declared (coach/phase.yaml missing).'),
        ),
      );
    }
    final value = p['value']?.toString() ?? '?';
    final since = p['effective_from']?.toString();
    final targetWt = p['target_weight_lb'];
    final reason = p['reason']?.toString();
    final exit = p['exit_criteria']?.toString();

    final small = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    value.toUpperCase(),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w700,
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
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (reason != null) ...[
              const SizedBox(height: 6),
              Text(reason, style: small?.copyWith(fontStyle: FontStyle.italic)),
            ],
            if (exit != null) ...[
              const SizedBox(height: 6),
              Text('Exit: $exit', style: small),
            ],
          ],
        ),
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
    final scheme = Theme.of(context).colorScheme;
    final currentN = slice?.block['number'] as int?;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          children: [
            for (final b in blocks)
              if (b is Map) _blockRow(context, b, currentN),
          ],
        ),
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
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  dateStr,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                wtStr,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.onSurfaceVariant,
                ),
              ),
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
                Text(
                  'You are here — week ${slice?.weekInBlock} of block $n'
                  '${slice?.weekType != 'normal' ? ' (${slice?.weekType} week)' : ''}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
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
        borderRadius: BorderRadius.circular(8),
      ),
      child: row,
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Observed
// ---------------------------------------------------------------------------

class _ObservedCard extends StatelessWidget {
  final List<WeightRow> daily;
  final ObservedWeightStats stats;
  final DateTime today;
  final DateTime? blockStart;
  final DateTime? blockEnd;
  final double? targetFrom;
  final double? targetTo;
  final String? error;

  const _ObservedCard({
    required this.daily,
    required this.stats,
    required this.today,
    required this.blockStart,
    required this.blockEnd,
    required this.targetFrom,
    required this.targetTo,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (error != null) {
      return Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(error!, style: Theme.of(context).textTheme.bodySmall),
        ),
      );
    }
    if (daily.isEmpty) {
      return Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No weigh-ins in the ledger yet.'),
        ),
      );
    }

    final targetToday =
        blockStart != null &&
            blockEnd != null &&
            targetFrom != null &&
            targetTo != null
        ? targetLineValue(
            day: today,
            start: blockStart!,
            end: blockEnd!,
            from: targetFrom!,
            to: targetTo!,
          )
        : null;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _WeightChart(
              daily: daily,
              today: today,
              blockStart: blockStart,
              blockEnd: blockEnd,
              targetFrom: targetFrom,
              targetTo: targetTo,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _Stat(
                  label: '7-day avg',
                  value: stats.bw7dAvg == null
                      ? '—'
                      : '${stats.bw7dAvg!.toStringAsFixed(1)} lb',
                ),
                _Stat(
                  label: 'rate / wk',
                  value: stats.bwRateLbWk == null
                      ? '—'
                      : '${_fmtSigned(stats.bwRateLbWk!)} lb',
                ),
                _Stat(
                  label: '3-wk change',
                  value: stats.bw3wkChange == null
                      ? '—'
                      : '${_fmtSigned(stats.bw3wkChange!)} lb',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (targetToday != null)
                  'block target today ${targetToday.toStringAsFixed(1)} lb',
                if (stats.lastWeighIn != null)
                  'last weigh-in ${DateFormat('MMM d').format(stats.lastWeighIn!)}',
              ].join(' · '),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Weight chart: daily weigh-ins (faint dots), trailing 7-day average
/// (solid line), and the current block's target line (dashed, from→to
/// across the block's dates).
///
/// Range chips `Block · 3M · 1Y · All` (2026-09-22) re-window the same
/// loaded series client-side. Block — the default, and the chart's
/// original fixed window — spans ~3 weeks before the block through the
/// block's end so early-block views still show recent history; the
/// trailing chips end at today instead. Chips that would be empty or
/// identical to All hide; the pinned tooltip clears on range switch.
/// The selection is in-memory widget state only (resets on screen
/// re-entry; deliberately not persisted).
class _WeightChart extends StatefulWidget {
  final List<WeightRow> daily;
  final DateTime today;
  final DateTime? blockStart;
  final DateTime? blockEnd;
  final double? targetFrom;
  final double? targetTo;

  const _WeightChart({
    required this.daily,
    required this.today,
    required this.blockStart,
    required this.blockEnd,
    required this.targetFrom,
    required this.targetTo,
  });

  @override
  State<_WeightChart> createState() => _WeightChartState();
}

class _WeightChartState extends State<_WeightChart> {
  /// The block window — months=null like All, distinguished by label;
  /// windowing special-cases it before the trailing-months helpers.
  static const _blockRange = ChartRange('Block', null);

  ChartRange? _selected;

  static double _x(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final daily = widget.daily;
    final today = widget.today;
    final blockStart = widget.blockStart;
    final blockEnd = widget.blockEnd;
    final targetFrom = widget.targetFrom;
    final targetTo = widget.targetTo;

    final seriesPoints = [
      for (final w in daily) (day: w.date, value: w.weightLbs),
    ];
    final hasBlock = blockStart != null && blockEnd != null;
    final chips = [
      if (hasBlock) _blockRange,
      ...visibleRanges(
        points: seriesPoints,
        ranges: const [ChartRange.m3, ChartRange.y1, ChartRange.all],
        today: today,
      ),
    ];
    var range = _selected ?? (hasBlock ? _blockRange : ChartRange.m3);
    if (!chips.contains(range)) {
      range = resolveRange(chips, range == _blockRange ? ChartRange.m3 : range);
    }

    // Window: Block = 21 days before the block through the block end
    // (the original fixed view); trailing chips end at today; All hugs
    // the data.
    final DateTime windowStart;
    final DateTime windowEnd;
    if (range == _blockRange) {
      windowStart = blockStart!.subtract(const Duration(days: 21));
      windowEnd = blockEnd!;
    } else {
      windowStart =
          range.startFor(today) ??
          (seriesPoints.isEmpty ? today : seriesPoints.first.day);
      windowEnd = today;
    }
    var xMin = _x(windowStart);
    final xMax = _x(windowEnd);
    if (xMax - xMin < 1) xMin = xMax - 1;

    final visibleDaily = [
      for (final w in daily)
        if (!w.date.isBefore(windowStart) && !w.date.isAfter(windowEnd)) w,
    ];
    // 7-day average computed over ALL history (so the first visible
    // point already has its trailing window), then clipped to view.
    final avg = [
      for (final w in sevenDayAvgSeries(daily))
        if (!w.date.isBefore(windowStart) && !w.date.isAfter(windowEnd)) w,
    ];

    final dailySpots = [
      for (final w in visibleDaily) FlSpot(_x(w.date), w.weightLbs),
    ];
    final avgSpots = [for (final w in avg) FlSpot(_x(w.date), w.weightLbs)];
    final targetSpots =
        blockStart != null &&
            blockEnd != null &&
            targetFrom != null &&
            targetTo != null
        ? [FlSpot(_x(blockStart), targetFrom), FlSpot(_x(blockEnd), targetTo)]
        : const <FlSpot>[];

    // Selector rendered even over an empty window so a data gap can
    // always be escaped by switching range.
    final selector = chips.length > 1
        ? Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: ChartRangeSelector(
              ranges: chips,
              selected: range,
              onChanged: (r) => setState(() => _selected = r),
            ),
          )
        : null;

    if (dailySpots.isEmpty && targetSpots.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?selector,
          const SizedBox(
            height: 100,
            child: Center(child: Text('(no weigh-ins in this window)')),
          ),
        ],
      );
    }

    final ys = [
      for (final s in dailySpots) s.y,
      for (final s in avgSpots) s.y,
      for (final s in targetSpots) s.y,
    ];
    final yMin = ys.reduce((a, b) => a < b ? a : b);
    final yMax = ys.reduce((a, b) => a > b ? a : b);
    final yPad = ((yMax - yMin).abs() * 0.1).clamp(0.5, 5.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?selector,
        SizedBox(
          height: 240,
          // LayoutBuilder: the bottom-axis tick keeper needs the plot's
          // pixel width to estimate label overlap (chart_bottom_axis).
          child: LayoutBuilder(
            builder: (context, constraints) => PinnedTooltipLineChart(
              // Re-key on range switch so the pinned tooltip clears
              // with the window (spot indices shift under the pin).
              key: ValueKey(range),
              data: LineChartData(
                minX: xMin,
                maxX: xMax,
                minY: yMin - yPad,
                maxY: yMax + yPad,
                clipData: const FlClipData.all(),
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(),
                  topTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (value, meta) => Text(
                        value.toStringAsFixed(0),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                  // Explicit non-overlapping date ticks (endpoints + month
                  // starts) — see chart_bottom_axis.dart.
                  bottomTitles: AxisTitles(
                    sideTitles: dateBottomTitles(
                      minX: xMin,
                      maxX: xMax,
                      plotWidth: (constraints.maxWidth - 40).clamp(1, 10000),
                      style: const TextStyle(fontSize: 9),
                      reservedSize: 28,
                    ),
                  ),
                ),
                lineBarsData: [
                  // Daily weigh-ins: faint dots, hairline connection.
                  if (dailySpots.isNotEmpty)
                    LineChartBarData(
                      spots: dailySpots,
                      isCurved: false,
                      barWidth: 1,
                      color: scheme.primary.withValues(alpha: 0.25),
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, pct, bar, i) =>
                            FlDotCirclePainter(
                              radius: 2,
                              color: scheme.primary.withValues(alpha: 0.35),
                              strokeWidth: 0,
                            ),
                      ),
                    ),
                  // 7-day average: the real signal.
                  if (avgSpots.isNotEmpty)
                    LineChartBarData(
                      spots: avgSpots,
                      isCurved: false,
                      barWidth: 2.5,
                      color: scheme.primary,
                      dotData: const FlDotData(show: false),
                    ),
                  // Block target line: dashed from→to across the block dates.
                  if (targetSpots.isNotEmpty)
                    LineChartBarData(
                      spots: targetSpots,
                      isCurved: false,
                      barWidth: 1.5,
                      color: scheme.tertiary,
                      dashArray: [6, 4],
                      dotData: const FlDotData(show: false),
                    ),
                ],
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) =>
                        Colors.black.withValues(alpha: 0.55),
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (spots) => [
                      for (final s in spots)
                        LineTooltipItem(
                          // Multi-year windows (1Y spanning a New Year /
                          // All) carry the year so old points can't read
                          // as recent.
                          '${DateFormat(windowStart.year != windowEnd.year ? "MMM d ''yy" : 'MMM d').format(DateTime.fromMillisecondsSinceEpoch((s.x * 86400000).toInt(), isUtc: true))}\n'
                          '${s.y.toStringAsFixed(1)}',
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            height: 1.3,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// OBSERVED §2: the Wilks block, below the weight chart. Chart = the
/// strength domain's monthly `wilks_series` (rendered through the SAME
/// shared [MetricChart], computed by the same [computeMetric] — cut-
/// start reference + acceptable-drop floor lines included). Stat line =
/// the weekly-current [wilksStability] output the PHASE hero shows
/// ("Wilks 327.5 · floor 319.3 · 0 wks below"), so home, strength
/// domain, and this screen can never disagree.
class _WilksCard extends StatelessWidget {
  final MetricConfig config;
  final List<StrengthRow> strengthRows;
  final List<WeightRow> daily;
  final DateTime today;

  /// Fallback reference anchor when the config has no `from:` — same
  /// default the hero's Wilks eigenvectors use.
  final DateTime? blockStart;

  /// Accounting-week start for the weekly-current stat (v7 week_start).
  final int weekStartDay;

  const _WilksCard({
    required this.config,
    required this.strengthRows,
    required this.daily,
    required this.today,
    required this.blockStart,
    this.weekStartDay = DateTime.monday,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = computeMetric(
      config,
      DomainMetricInputs(
        strengthRows: strengthRows,
        weightDaily: daily,
        today: today,
        weekStartDay: weekStartDay,
      ),
    );

    // Weekly-current stat line (the monthly chart is the trend; THIS is
    // where the cut stands right now).
    final weeks = strengthRows.isEmpty || daily.isEmpty
        ? const <WilksWeek>[]
        : weeklyWilksSeries(
            strengthRows,
            daily,
            through: today,
            weekStartDay: weekStartDay,
          );
    final s = wilksStability(
      weeks: weeks,
      from: config.from ?? blockStart,
      floorPct: config.floorPct,
    );
    String? statLine;
    if (s.current != null) {
      statLine = [
        'Wilks ${s.current!.toStringAsFixed(1)}',
        if (s.floor != null) 'floor ${s.floor!.toStringAsFixed(1)}',
        if (s.floor != null)
          '${s.weeksBelowFloor} wk${s.weeksBelowFloor == 1 ? '' : 's'} below',
      ].join(' · ');
    }

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (config.label ?? 'Wilks').toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            switch (data) {
              MetricSeries() => MetricChart(
                series: data,
                today: today,
                goalNote: config.goalNote,
                windowYears: config.windowYears,
              ),
              _ => Text(
                data is MetricUnavailable ? data.message : 'unavailable',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            },
            if (statLine != null) ...[
              const SizedBox(height: 6),
              Text(
                statLine,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                'weekly-current (chart is monthly)',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
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
    final scheme = Theme.of(context).colorScheme;
    final v = verdict;
    if (phase == null || v == null) {
      return Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No declared phase — nothing to compare against.'),
        ),
      );
    }

    final (bg, fg, icon) = switch (v.state) {
      VerdictState.agree => (
        Colors.green.withValues(alpha: 0.15),
        Colors.green.shade800,
        Icons.check_circle_outline,
      ),
      VerdictState.drift => (
        Colors.amber.withValues(alpha: 0.2),
        Colors.orange.shade900,
        Icons.warning_amber_outlined,
      ),
      VerdictState.mismatch => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_outline,
      ),
      VerdictState.unknown => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        Icons.help_outline,
      ),
    };

    final declared =
        'Declared $phase'
        '${targetRate != null ? ' (target ${_fmtSigned(targetRate!)} lb/wk)' : ''}';
    final observed = v.observedRateLbWk == null
        ? 'no observed rate yet'
        : 'observed ${_fmtSigned(v.observedRateLbWk!)} lb/wk over 3 wks';

    return Card(
      elevation: 0,
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: fg, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.label,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$declared · $observed',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: fg),
                  ),
                ],
              ),
            ),
          ],
        ),
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
