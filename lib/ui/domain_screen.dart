/// Domain screen (app-IA redesign P2) — one screen per dashboards.yaml
/// domain:
///
///   HEADER  the domain dashboard: per-metric stat chips and/or a series
///           chart, computed by services/domain_metrics.dart from the
///           domain's own view data. Every metric degrades independently
///           to a dim placeholder — the timeline below never blocks on
///           the dashboard.
///   BODY    the existing timeline. Entry domains keep the full
///           affordances (FAB, forms, planning, selection); integration
///           domains ride the same read-only gating as `read_only`
///           views via [TimelineScreen.forceReadOnly] (a denser
///           read-friendly list is P3).
///
/// Implemented as a thin composition over [TimelineScreen] (its new
/// `header` slot) so the timeline's date bar, caching, and mutation
/// machinery stay single-sourced.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/model_config.dart';
import '../models/quickbooks_config.dart';
import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/domain_config.dart';
import '../services/domain_metrics.dart';
import '../services/github_client.dart';
import '../services/home_synthesis.dart' show strengthRowFromRecord;
import '../services/llm_client.dart';
import '../services/llm_response_cache.dart';
import '../services/program_metrics.dart' show StrengthRow, WeightRow;
import '../services/qbo_service.dart';
import '../services/warehouse_connector.dart';
import '../services/weight_series.dart';
import 'timeline_screen.dart';

/// Metric ids that need mapped strength rows.
const _strengthMetricIds = {
  'pl_total',
  'e1rm_reference',
  'all_time_best_weight',
};

/// Metric ids that need the weigh-in series / raw weight records.
const _weightMetricIds = {'bw_series', 'bf_series'};

class DomainScreen extends StatelessWidget {
  final DomainConfig domain;

  /// The domain's primary view — backs both the timeline body and the
  /// header's metric inputs.
  final ViewSchema view;
  final WarehouseConnector repository;

  final AnalyticsEngine? analytics;
  final LlmClient? llm;
  final LlmResponseCache? llmCache;
  final ModelConfig? chatModel;
  final GithubClient? github;
  final QboPushSpec? qboSpec;
  final QboService? qboService;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  const DomainScreen({
    super.key,
    required this.domain,
    required this.view,
    required this.repository,
    this.analytics,
    this.llm,
    this.llmCache,
    this.chatModel,
    this.github,
    this.qboSpec,
    this.qboService,
    this.today,
  });

  bool get _integration => domain.paradigm == DomainParadigm.integration;

  @override
  Widget build(BuildContext context) {
    return TimelineScreen(
      view: view,
      repository: repository,
      // Integration domains are read surfaces: no post-log hooks, no
      // QBO push — mirrors the read-only view pathway.
      llm: _integration ? null : llm,
      llmCache: _integration ? null : llmCache,
      chatModel: chatModel,
      github: github,
      analytics: analytics,
      qboSpec: _integration ? null : qboSpec,
      qboService: _integration ? null : qboService,
      forceReadOnly: _integration,
      header: domain.metrics.isEmpty
          ? null
          : DomainDashboardHeader(
              domain: domain,
              view: view,
              repository: repository,
              analytics: analytics,
              today: today,
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboard header
// ---------------------------------------------------------------------------

/// Loads the metric inputs once (per screen open) and renders every
/// configured metric: stat chips for stat/best kinds, a compact line
/// chart for series. Each metric that can't compute renders a dim
/// placeholder; a total input failure degrades the whole header to
/// placeholders — never an error screen.
class DomainDashboardHeader extends StatefulWidget {
  final DomainConfig domain;
  final ViewSchema view;
  final WarehouseConnector repository;
  final AnalyticsEngine? analytics;
  final DateTime? today;

  const DomainDashboardHeader({
    super.key,
    required this.domain,
    required this.view,
    required this.repository,
    this.analytics,
    this.today,
  });

  @override
  State<DomainDashboardHeader> createState() => _DomainDashboardHeaderState();
}

class _DomainDashboardHeaderState extends State<DomainDashboardHeader> {
  late final DateTime _today = widget.today ?? DateTime.now();
  late final Future<DomainMetricInputs> _inputs = _load();

  Future<DomainMetricInputs> _load() async {
    final ids = {for (final m in widget.domain.metrics) m.id};
    var strengthRows = const <StrengthRow>[];
    var weightDaily = const <WeightRow>[];
    var weightRecords = <Map<String, Object?>>[];

    if (ids.any(_strengthMetricIds.contains)) {
      try {
        final recs = await widget.repository.list(widget.view);
        strengthRows = [for (final r in recs) ?strengthRowFromRecord(r)];
      } catch (_) {
        // offline → metrics degrade individually
      }
    }
    if (ids.any(_weightMetricIds.contains)) {
      try {
        final series = await loadDailyWeighIns(
          analytics: widget.analytics,
          view: widget.view,
          repo: widget.repository,
        );
        weightDaily = series.daily;
      } catch (_) {}
      try {
        weightRecords = (await widget.repository.list(widget.view)).toList();
      } catch (_) {}
    }
    return DomainMetricInputs(
      strengthRows: strengthRows,
      weightDaily: weightDaily,
      weightRecords: weightRecords,
      today: _today,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: FutureBuilder<DomainMetricInputs>(
        future: _inputs,
        builder: (context, snap) {
          final inputs = snap.data;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final m in widget.domain.metrics) ...[
                _MetricBlock(
                  config: m,
                  data: inputs == null
                      ? const MetricUnavailable('…')
                      : computeMetric(m, inputs),
                  today: _today,
                ),
                if (m != widget.domain.metrics.last) const SizedBox(height: 8),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// One metric: heading (label + optional goal note) and its content.
class _MetricBlock extends StatelessWidget {
  final MetricConfig config;
  final MetricData data;
  final DateTime today;

  const _MetricBlock({
    required this.config,
    required this.data,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final heading = (config.label ?? config.id).toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        switch (data) {
          MetricStats(stats: final stats, note: final note) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final s in stats) _StatChip(stat: s)],
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: _dim(context, note),
                ),
            ],
          ),
          MetricSeries() => _MetricChart(
            series: data as MetricSeries,
            today: today,
            goalNote: config.goalNote,
          ),
          MetricUnavailable(message: final msg) => _dim(context, msg),
        },
      ],
    );
  }

  Widget _dim(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    ),
  );
}

class _StatChip extends StatelessWidget {
  final MetricStat stat;
  const _StatChip({required this.stat});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            stat.value,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            stat.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact series chart: raw points (faint), optional smoothed line
/// (solid), optional flat goal line (dashed tertiary). Window = the
/// trailing 84 days; widens to full history when the window holds
/// fewer than two points (sparse series like caliper body-fat). Same
/// fl_chart machinery as the Program screen's weight chart, shrunk to
/// header size.
class _MetricChart extends StatelessWidget {
  final MetricSeries series;
  final DateTime today;
  final String? goalNote;

  const _MetricChart({
    required this.series,
    required this.today,
    this.goalNote,
  });

  static double _x(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    var windowStart = DateTime(today.year, today.month, today.day - 84);
    var points = [
      for (final p in series.points)
        if (!p.day.isBefore(windowStart)) p,
    ];
    if (points.length < 2) {
      points = series.points;
      if (points.isNotEmpty) windowStart = points.first.day;
    }
    if (points.isEmpty) {
      return Text(
        '(no data in range)',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    final avg = [
      for (final p in series.avg)
        if (!p.day.isBefore(windowStart)) p,
    ];

    final xMin = _x(windowStart);
    final xMax = _x(today);
    final rawSpots = [for (final p in points) FlSpot(_x(p.day), p.value)];
    final avgSpots = [for (final p in avg) FlSpot(_x(p.day), p.value)];
    final goal = series.goal;

    final ys = [
      for (final s in rawSpots) s.y,
      for (final s in avgSpots) s.y,
      ?goal,
    ];
    final yMin = ys.reduce((a, b) => a < b ? a : b);
    final yMax = ys.reduce((a, b) => a > b ? a : b);
    final yPad = ((yMax - yMin).abs() * 0.1).clamp(0.5, 5.0);
    final rangeDays = xMax - xMin;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 130,
          child: LineChart(
            LineChartData(
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
                    reservedSize: 34,
                    getTitlesWidget: (value, meta) => Text(
                      value.toStringAsFixed(0),
                      style: const TextStyle(fontSize: 9),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    interval: rangeDays <= 45 ? 14 : 30,
                    getTitlesWidget: (value, meta) {
                      final dt = DateTime.fromMillisecondsSinceEpoch(
                        (value * 86400000).toInt(),
                        isUtc: true,
                      );
                      return Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          DateFormat('MMM d').format(dt),
                          style: const TextStyle(fontSize: 8),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: rawSpots,
                  isCurved: false,
                  barWidth: 1,
                  color: scheme.primary.withValues(
                    alpha: avgSpots.isEmpty ? 0.9 : 0.25,
                  ),
                  dotData: FlDotData(
                    show: true,
                    getDotPainter: (spot, pct, bar, i) => FlDotCirclePainter(
                      radius: 1.8,
                      color: scheme.primary.withValues(
                        alpha: avgSpots.isEmpty ? 0.9 : 0.35,
                      ),
                      strokeWidth: 0,
                    ),
                  ),
                ),
                if (avgSpots.isNotEmpty)
                  LineChartBarData(
                    spots: avgSpots,
                    isCurved: false,
                    barWidth: 2.2,
                    color: scheme.primary,
                    dotData: const FlDotData(show: false),
                  ),
                if (goal != null)
                  LineChartBarData(
                    spots: [FlSpot(xMin, goal), FlSpot(xMax, goal)],
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
                  getTooltipColor: (_) => Colors.black.withValues(alpha: 0.55),
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      LineTooltipItem(
                        '${DateFormat('MMM d').format(DateTime.fromMillisecondsSinceEpoch((s.x * 86400000).toInt(), isUtc: true))}\n'
                        '${s.y.toStringAsFixed(1)}',
                        const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
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
        if (goal != null || goalNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              [
                if (goal != null)
                  'goal ${goal.toStringAsFixed(goal == goal.roundToDouble() ? 0 : 1)}'
                      '${series.unit == null ? '' : ' ${series.unit}'}',
                ?goalNote,
              ].join(' · '),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
