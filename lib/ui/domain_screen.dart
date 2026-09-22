/// Domain screen (app-IA redesign P2) — one screen per dashboards.yaml
/// domain:
///
///   HEADER  the domain dashboard: per-metric stat chips and/or a series
///           chart, computed by services/domain_metrics.dart from the
///           domain's own view data. Every metric degrades independently
///           to a dim placeholder — the timeline below never blocks on
///           the dashboard.
///   BODY    entry domains: the existing timeline with full affordances
///           (FAB, forms, planning, selection) via [TimelineScreen]'s
///           `header` slot. Integration domains (P3): a denser
///           read-friendly record list — date-grouped, one line per
///           record with the domain's salient `list_fields`, newest
///           first, no per-row chrome; the dashboard header scrolls as
///           the first list item. The read-only timeline stays
///           reachable via the app-bar calendar icon (date navigation).
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/model_config.dart';
import '../models/quickbooks_config.dart';
import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/domain_config.dart';
import '../services/domain_metrics.dart';
import '../services/domain_records.dart';
import '../services/github_client.dart';
import '../services/home_synthesis.dart' show strengthRowFromRecord;
import '../services/llm_client.dart';
import '../services/llm_response_cache.dart';
import '../services/program_metrics.dart' show StrengthRow, WeightRow;
import '../services/qbo_service.dart';
import '../services/warehouse_connector.dart';
import '../services/weight_series.dart';
import 'timeline_screen.dart';
import 'widgets/metric_chart.dart';

/// Metric ids that need mapped strength rows.
const _strengthMetricIds = {
  'pl_total',
  'e1rm_reference',
  'all_time_best_weight',
  'wilks',
  'wilks_series',
};

/// Metric ids on NON-weight domains that also need the daily weigh-in
/// series as a bodyweight reference (wilks: kg bodyweight for the
/// coefficient; protein_series additionally gates on its band config).
const _bodyweightRefMetricIds = {'wilks', 'wilks_series'};

/// Metric ids that need the domain's own daily weigh-in series.
const _weightMetricIds = {'bw_series', 'bf_series'};

/// Metric ids computed from the primary view's raw records.
const _recordMetricIds = {
  'bf_series',
  'kcal_series',
  'protein_series',
  'grade_pyramid',
  'session_frequency',
  'hr_4x4_series',
};

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

  /// The weight view + its repo, for metrics that scale against current
  /// bodyweight from OTHER domains (protein_series' goal band on meals).
  /// Null → those metrics render bandless; nothing breaks.
  final ViewSchema? weightView;
  final WarehouseConnector? weightRepository;

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
    this.weightView,
    this.weightRepository,
    this.today,
  });

  bool get _integration => domain.paradigm == DomainParadigm.integration;

  @override
  Widget build(BuildContext context) {
    final header = domain.metrics.isEmpty
        ? null
        : DomainDashboardHeader(
            domain: domain,
            view: view,
            repository: repository,
            analytics: analytics,
            weightView: weightView,
            weightRepository: weightRepository,
            today: today,
          );
    // Integration domains are read surfaces: the denser record list is
    // the body; the read-only timeline stays one calendar-icon away.
    if (_integration) {
      return _DomainRecordsScreen(
        domain: domain,
        view: view,
        repository: repository,
        header: header,
      );
    }
    return TimelineScreen(
      view: view,
      repository: repository,
      llm: llm,
      llmCache: llmCache,
      chatModel: chatModel,
      github: github,
      analytics: analytics,
      qboSpec: qboSpec,
      qboService: qboService,
      header: header,
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

  /// Bodyweight reference for cross-domain metrics (protein band). See
  /// [DomainScreen.weightView].
  final ViewSchema? weightView;
  final WarehouseConnector? weightRepository;

  final DateTime? today;

  const DomainDashboardHeader({
    super.key,
    required this.domain,
    required this.view,
    required this.repository,
    this.analytics,
    this.weightView,
    this.weightRepository,
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
    var records = const <Map<String, Object?>>[];

    // One raw fetch of the primary view serves the strength mapping AND
    // every record-based metric (bf/meals/climbing/cardio).
    if (ids.any(_strengthMetricIds.contains) ||
        ids.any(_recordMetricIds.contains)) {
      try {
        records = await widget.repository.list(widget.view);
      } catch (_) {
        // offline → metrics degrade individually
      }
    }
    if (ids.any(_strengthMetricIds.contains)) {
      strengthRows = [for (final r in records) ?strengthRowFromRecord(r)];
    }

    // Daily weigh-ins: the weight domain reads its OWN view; other
    // domains needing a bodyweight reference (protein band) read the
    // passed-in weight view. On the weight domain they're the same.
    if (ids.any(_weightMetricIds.contains)) {
      try {
        final series = await loadDailyWeighIns(
          analytics: widget.analytics,
          view: widget.view,
          repo: widget.repository,
        );
        weightDaily = series.daily;
      } catch (_) {}
    } else if ((ids.any(_bodyweightRefMetricIds.contains) ||
            widget.domain.metrics.any(
              (m) => m.id == 'protein_series' && m.goalBandPerLb != null,
            )) &&
        widget.weightView != null) {
      try {
        final series = await loadDailyWeighIns(
          analytics: widget.analytics,
          view: widget.weightView,
          repo: widget.weightRepository,
        );
        weightDaily = series.daily;
      } catch (_) {}
    }

    return DomainMetricInputs(
      strengthRows: strengthRows,
      weightDaily: weightDaily,
      records: records,
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
          MetricSeries() => MetricChart(
            series: data as MetricSeries,
            today: today,
            goalNote: config.goalNote,
          ),
          MetricBars(bars: final bars, note: final note) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _BarList(bars: bars),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: _dim(context, note),
                ),
            ],
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
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Horizontal bar list (grade pyramid): one row per grade — label,
/// count-proportional bar, count. Not a chart widget on purpose: a
/// pyramid is a ranked list, and rows must stay readable at any count.
class _BarList extends StatelessWidget {
  final List<({String label, int count})> bars;
  const _BarList({required this.bars});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxCount = bars.fold<int>(1, (m, b) => b.count > m ? b.count : m);
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Column(
      children: [
        for (final b in bars)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(
              children: [
                SizedBox(width: 44, child: Text(b.label, style: labelStyle)),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: b.count / maxCount,
                      child: Container(
                        height: 10,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${b.count}',
                    textAlign: TextAlign.right,
                    style: labelStyle?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Integration read view — the record list
// ---------------------------------------------------------------------------

/// Read-friendly body for integration domains: the dashboard header
/// scrolls as the first item, then date-grouped records — one line per
/// record, salient fields only, newest first, no per-row chrome. The
/// list is a lazy [ListView.builder] over flattened rows, so climbing's
/// ~1.4k records render in chunks as you scroll. Pull to refresh; the
/// app-bar calendar icon opens the classic read-only timeline for
/// date navigation.
class _DomainRecordsScreen extends StatefulWidget {
  final DomainConfig domain;
  final ViewSchema view;
  final WarehouseConnector repository;
  final Widget? header;

  const _DomainRecordsScreen({
    required this.domain,
    required this.view,
    required this.repository,
    this.header,
  });

  @override
  State<_DomainRecordsScreen> createState() => _DomainRecordsScreenState();
}

/// One flattened list row: a day heading or a record line.
sealed class _ListRow {
  const _ListRow();
}

class _DayRow extends _ListRow {
  final DateTime day;
  final int count;
  const _DayRow(this.day, this.count);
}

class _RecordRow extends _ListRow {
  final Map<String, Object?> record;
  const _RecordRow(this.record);
}

class _DomainRecordsScreenState extends State<_DomainRecordsScreen> {
  late Future<List<_ListRow>> _rows = _load();

  String get _dateKey => widget.view.dateField ?? 'date';

  Future<List<_ListRow>> _load() async {
    final records = await widget.repository.list(widget.view);
    final groups = groupRecordsByDay(records, dateKey: _dateKey);
    return [
      for (final g in groups) ...[
        _DayRow(g.day, g.records.length),
        for (final r in g.records) _RecordRow(r),
      ],
    ];
  }

  Future<void> _refresh() async {
    final fresh = _load();
    setState(() => _rows = fresh);
    await fresh;
  }

  void _openTimeline() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TimelineScreen(
          view: widget.view,
          repository: widget.repository,
          forceReadOnly: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.domain.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            tooltip: 'Browse by date',
            onPressed: _openTimeline,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<_ListRow>>(
          future: _rows,
          builder: (context, snap) {
            final rows = snap.data;
            // Header always occupies slot 0 so the dashboard shows even
            // while records load / when the fetch fails.
            final extra = widget.header == null ? 0 : 1;
            Widget trailing;
            if (snap.hasError) {
              trailing = _note(context, 'couldn’t load records');
            } else if (rows == null) {
              trailing = const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              );
            } else if (rows.isEmpty) {
              trailing = _note(context, 'no records yet');
            } else {
              trailing = const SizedBox.shrink();
            }
            final items = rows ?? const <_ListRow>[];
            return ListView.builder(
              // Refresh must work even when the list is short/errored.
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: extra + items.length + 1,
              itemBuilder: (context, i) {
                if (extra == 1 && i == 0) return widget.header!;
                final idx = i - extra;
                if (idx == items.length) return trailing;
                return switch (items[idx]) {
                  _DayRow(day: final day, count: final count) => _dayHeading(
                    context,
                    day,
                    count,
                  ),
                  _RecordRow(record: final record) => _recordLine(
                    context,
                    record,
                  ),
                };
              },
            );
          },
        ),
      ),
    );
  }

  Widget _note(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
    ),
  );

  Widget _dayHeading(BuildContext context, DateTime day, int count) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final fmt = day.year == now.year ? 'EEE, MMM d' : 'EEE, MMM d, yyyy';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Text(
            DateFormat(fmt).format(day).toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.outline,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recordLine(BuildContext context, Map<String, Object?> record) {
    final scheme = Theme.of(context).colorScheme;
    final parts = recordLineParts(
      widget.view,
      widget.domain.listFields,
      record,
    );
    final lead = parts.isEmpty ? '—' : parts.first;
    final rest = parts.skip(1).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: lead,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (rest.isNotEmpty)
              TextSpan(
                text: ' · $rest',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        style: Theme.of(context).textTheme.bodyMedium,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
