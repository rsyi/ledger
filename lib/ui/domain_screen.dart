/// Domain screen — one screen per dashboards.yaml domain, records
/// FIRST (per-domain UX redesign 2026-09-21: the old layout stacked the
/// full metric dashboard above the ledger, scrunching the records the
/// user actually came for).
///
/// Domains with metrics get TWO MODES, toggled by the compact segmented
/// control in the strip above the records:
///
///   LOG/RECORDS (default)  the ledger fills the screen. Entry domains:
///        the existing timeline with full affordances (FAB, forms,
///        planning, selection) via [TimelineScreen]'s `header` slot.
///        Integration domains: the denser read-friendly record list —
///        date-grouped, one line per record with the domain's salient
///        `list_fields`, newest first — with the read-only timeline
///        behind the app-bar calendar icon, and (when the view is
///        writable) an overflow "Add entry manually" escape hatch for
///        integration gaps (travel, dead scale battery). The only
///        metrics chrome is the ONE-LINE headline strip (`headline:`
///        ids in dashboards.yaml, sensible defaults otherwise).
///   TRENDS  the full metric dashboard — every configured metric,
///        full-height charts, no ledger squeezed underneath.
///
/// Metric inputs load once per screen open and feed both modes. Every
/// metric degrades independently to a dim placeholder — the records
/// never block on the dashboard. Domains without metrics (daily_notes)
/// skip the strip and Trends entirely.
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
import '../services/program_current.dart' show currentVersion, weekStartDayOf;
import '../services/program_metrics.dart' show StrengthRow, WeightRow;
import '../services/program_provider.dart';
import '../services/qbo_service.dart';
import '../services/warehouse_connector.dart';
import '../services/weight_series.dart';
import 'app_text.dart';
import 'form_screen.dart';
import 'timeline_screen.dart';
import 'widgets/metric_chart.dart';

/// Metric ids that need mapped strength rows.
const _strengthMetricIds = {
  'pl_total',
  'e1rm_reference',
  'recent_e1rm_rpe',
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
  // Recovery domain (Whoop API → recovery tab): each is a per-day max
  // over the raw view rows. Omitting these left `records` empty, so
  // every recovery series computed MetricUnavailable despite live data.
  'recovery_score',
  'hrv_ms',
  'sleep_hours',
};

class DomainScreen extends StatefulWidget {
  final DomainConfig domain;

  /// The domain's primary view — backs both the records body and the
  /// metric inputs.
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

  /// Program docs (1 h cached) — resolves the accounting week's start
  /// day (program.yaml v7 `week_start`) for the weekly Wilks stat.
  /// Null → ISO Monday weeks, the pre-v7 behavior.
  final ProgramProvider? programProvider;

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
    this.programProvider,
    this.today,
  });

  @override
  State<DomainScreen> createState() => _DomainScreenState();
}

class _DomainScreenState extends State<DomainScreen> {
  late final DateTime _today = widget.today ?? DateTime.now();

  /// 0 = records (Log), 1 = Trends. Plain state field; the IndexedStack
  /// below keeps both modes alive so toggling never loses timeline
  /// state (selected date, scroll, selection).
  int _mode = 0;

  /// One inputs load per screen open, shared by the headline strip and
  /// the Trends dashboard. Re-fired by the Trends refresh action and
  /// the record list's pull-to-refresh.
  late Future<DomainMetricInputs> _inputs = _loadInputs();

  bool get _integration => widget.domain.paradigm == DomainParadigm.integration;
  bool get _hasMetrics => widget.domain.metrics.isNotEmpty;

  Future<DomainMetricInputs> _loadInputs() async {
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

    // Accounting-week keying for the weekly Wilks stat (program.yaml
    // v7 `week_start: saturday`, amendment 2026-09-22). Cheap: the doc
    // cache is 1 h; failures fall back to ISO Monday weeks.
    var weekStartDay = DateTime.monday;
    if (widget.programProvider != null &&
        ids.any(_bodyweightRefMetricIds.contains)) {
      try {
        final docs = await widget.programProvider!.load();
        weekStartDay = weekStartDayOf(currentVersion(docs.program));
      } catch (_) {}
    }

    return DomainMetricInputs(
      strengthRows: strengthRows,
      weightDaily: weightDaily,
      records: records,
      today: _today,
      weekStartDay: weekStartDay,
    );
  }

  void _reloadInputs() {
    setState(() => _inputs = _loadInputs());
  }

  @override
  Widget build(BuildContext context) {
    final recordsBody = _integration
        ? _DomainRecordsScreen(
            domain: widget.domain,
            view: widget.view,
            repository: widget.repository,
            header: _hasMetrics ? _modeBar() : null,
            onRefreshExtras: _hasMetrics ? _reloadInputs : null,
          )
        : TimelineScreen(
            view: widget.view,
            repository: widget.repository,
            llm: widget.llm,
            llmCache: widget.llmCache,
            chatModel: widget.chatModel,
            github: widget.github,
            analytics: widget.analytics,
            qboSpec: widget.qboSpec,
            qboService: widget.qboService,
            header: _hasMetrics ? _modeBar() : null,
          );
    if (!_hasMetrics) return recordsBody;
    return IndexedStack(
      index: _mode,
      children: [
        recordsBody,
        _TrendsScreen(
          domain: widget.domain,
          inputs: _inputs,
          today: _today,
          modeBar: _modeBar(),
          onRefresh: _reloadInputs,
        ),
      ],
    );
  }

  Widget _modeBar() => _ModeBar(
    domain: widget.domain,
    inputs: _inputs,
    mode: _mode,
    recordsLabel: _integration ? 'Records' : 'Log',
    onMode: (m) => setState(() => _mode = m),
  );
}

// ---------------------------------------------------------------------------
// Mode bar: headline strip + Log/Trends toggle
// ---------------------------------------------------------------------------

/// One compact row: the domain's 2-3 headline numbers on the left, the
/// mode toggle on the right. Rendered pinned above the records (via the
/// timeline's `header` slot / the record list's header) and as the
/// first row of the Trends body, so the toggle never moves.
class _ModeBar extends StatelessWidget {
  final DomainConfig domain;
  final Future<DomainMetricInputs> inputs;
  final int mode;
  final String recordsLabel;
  final ValueChanged<int> onMode;

  const _ModeBar({
    required this.domain,
    required this.inputs,
    required this.mode,
    required this.recordsLabel,
    required this.onMode,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: FutureBuilder<DomainMetricInputs>(
              future: inputs,
              builder: (context, snap) {
                final data = snap.data;
                final stats = data == null
                    ? const <MetricStat>[]
                    : headlineStats(domain, data);
                if (stats.isEmpty) {
                  return Text(
                    data == null ? '…' : '',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  );
                }
                // Labels at the tag scale, values at the 16sp value
                // scale; two lines of reflow before any ellipsis.
                return Text.rich(
                  TextSpan(
                    children: [
                      for (final (i, s) in stats.indexed) ...[
                        if (i > 0)
                          TextSpan(
                            text: '  ·  ',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        TextSpan(text: '${s.label} '),
                        TextSpan(
                          text: s.value,
                          style: AppText.value(context),
                        ),
                      ],
                    ],
                  ),
                  style: AppText.tag(context),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          SegmentedButton<int>(
            segments: [
              ButtonSegment(value: 0, label: Text(recordsLabel)),
              const ButtonSegment(value: 1, label: Text('Trends')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => onMode(s.first),
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity(horizontal: -3, vertical: -3),
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 10),
              ),
              textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Trends mode: the full metric dashboard
// ---------------------------------------------------------------------------

/// Full-height metric dashboard — every configured metric with room to
/// breathe (charts at 220px instead of the header-strip 130px). Each
/// metric that can't compute renders a dim placeholder; a total input
/// failure degrades everything to placeholders — never an error screen.
class _TrendsScreen extends StatelessWidget {
  final DomainConfig domain;
  final Future<DomainMetricInputs> inputs;
  final DateTime today;
  final Widget modeBar;
  final VoidCallback onRefresh;

  const _TrendsScreen({
    required this.domain,
    required this.inputs,
    required this.today,
    required this.modeBar,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(domain.displayName),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: onRefresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: FutureBuilder<DomainMetricInputs>(
        future: inputs,
        builder: (context, snap) {
          final data = snap.data;
          return ListView(
            children: [
              modeBar,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final m in domain.metrics) ...[
                      _MetricBlock(
                        config: m,
                        data: data == null
                            ? const MetricUnavailable('…')
                            : computeMetric(m, data),
                        today: today,
                        chartHeight: 220,
                      ),
                      if (m != domain.metrics.last) const SizedBox(height: 20),
                    ],
                  ],
                ),
              ),
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
  final double chartHeight;

  const _MetricBlock({
    required this.config,
    required this.data,
    required this.today,
    this.chartHeight = 130,
  });

  @override
  Widget build(BuildContext context) {
    final heading = (config.label ?? config.id).toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(heading, style: AppText.title(context)),
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
            height: chartHeight,
            windowYears: config.windowYears,
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
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
          Text(stat.value, style: AppText.value(context)),
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

/// Read-friendly body for integration domains: the mode bar pinned on
/// top, then date-grouped records — one line per record, salient fields
/// only, newest first, no per-row chrome. The list is a lazy
/// [ListView.builder] over flattened rows, so climbing's ~1.4k records
/// render in chunks as you scroll. Pull to refresh; the app-bar
/// calendar icon opens the classic read-only timeline for date
/// navigation. Writable views (weight — ledger-synced but
/// integration-fed) get an overflow "Add entry manually" that opens the
/// normal form: Withings gaps happen (travel, dead scale battery), so
/// the integration paradigm keeps a manual escape hatch.
class _DomainRecordsScreen extends StatefulWidget {
  final DomainConfig domain;
  final ViewSchema view;
  final WarehouseConnector repository;
  final Widget? header;

  /// Re-fires the domain screen's metric inputs on pull-to-refresh so
  /// the headline strip / Trends stay in step with fresh records.
  final VoidCallback? onRefreshExtras;

  const _DomainRecordsScreen({
    required this.domain,
    required this.view,
    required this.repository,
    this.header,
    this.onRefreshExtras,
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

  /// Manual escape hatch available only when the view actually accepts
  /// writes (input overlay, not read-only). kaya_ascents-style direct
  /// sheet reads stay pure read surfaces.
  bool get _canAddManually =>
      widget.view.hasInputOverlay && !widget.view.readOnly;

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
    widget.onRefreshExtras?.call();
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

  Future<void> _addManually() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            FormScreen(view: widget.view, repository: widget.repository),
      ),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.domain.displayName),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month_outlined),
            tooltip: 'Browse by date',
            onPressed: _openTimeline,
          ),
          if (_canAddManually)
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'add') _addManually();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'add', child: Text('Add entry manually')),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          // Pinned, not a list item — the Trends toggle shouldn't
          // scroll away with the records.
          if (widget.header != null) widget.header!,
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<_ListRow>>(
                future: _rows,
                builder: (context, snap) {
                  final rows = snap.data;
                  Widget trailing;
                  if (snap.hasError) {
                    trailing = _note(context, 'couldn’t load records');
                  } else if (rows == null) {
                    trailing = const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  } else if (rows.isEmpty) {
                    trailing = _note(
                      context,
                      'No records yet — this ledger fills in from '
                      'Integrations (gear icon, Home tab).'
                      '${_canAddManually ? '\nOr use ⋮ → "Add entry manually".' : ''}',
                    );
                  } else {
                    trailing = const SizedBox.shrink();
                  }
                  final items = rows ?? const <_ListRow>[];
                  return ListView.builder(
                    // Refresh must work even when the list is
                    // short/errored.
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: items.length + 1,
                    itemBuilder: (context, i) {
                      if (i == items.length) return trailing;
                      return switch (items[i]) {
                        _DayRow(day: final day, count: final count) =>
                          _dayHeading(context, day, count),
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
          ),
        ],
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
    final now = DateTime.now();
    final fmt = day.year == now.year ? 'EEE, MMM d' : 'EEE, MMM d, yyyy';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Text(
            DateFormat(fmt).format(day).toUpperCase(),
            style: AppText.title(context),
          ),
          const SizedBox(width: 6),
          Text('$count', style: AppText.micro(context)),
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
        // Reflow over ellipsis: salient fields can take a second line.
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
