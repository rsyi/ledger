import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:jinja/jinja.dart' hide Template;

import '../../models/view_schema.dart';
import '../../services/list_display_render.dart';
import '../../services/sheets_repository.dart';
import '../../services/warehouse_connector.dart';
import 'chart_bottom_axis.dart';
import 'chart_range.dart';
import 'pinned_tooltip_line_chart.dart';

/// Opens a modal bottom sheet listing past records that share [dim]'s
/// current [value]. Sorted by `view.dateField` descending (newest first)
/// when available, otherwise by sheet row order. Each row renders via
/// [ListDisplayRender] for consistency with the timeline.
///
/// Generalized via the `history: true` opt-in on a dimension's input spec.
/// The trigger lives on the field widget (form view) and on the record
/// tile (timeline view).
Future<void> showHistorySheet({
  required BuildContext context,
  required ViewSchema view,
  required Dimension dim,
  required Object? value,
  required WarehouseConnector repository,
}) async {
  final v = value?.toString().trim();
  if (v == null || v.isEmpty) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) =>
        _HistorySheet(view: view, dim: dim, value: v, repository: repository),
  );
}

class _HistorySheet extends StatefulWidget {
  final ViewSchema view;
  final Dimension dim;
  final String value;
  final WarehouseConnector repository;

  const _HistorySheet({
    required this.view,
    required this.dim,
    required this.value,
    required this.repository,
  });

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  late Future<List<Record>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Record>> _load() async {
    final rows = await widget.repository.list(widget.view);
    final filtered = rows
        .where((r) => r[widget.dim.name]?.toString() == widget.value)
        .toList();
    final dateField = widget.view.dateField;
    if (dateField != null) {
      filtered.sort((a, b) {
        final av = a[dateField];
        final bv = b[dateField];
        if (av == null && bv == null) return 0;
        if (av == null) return 1;
        if (bv == null) return -1;
        // DateTimes compare directly; strings fall back to lexicographic
        // which works for ISO dates.
        if (av is DateTime && bv is DateTime) return bv.compareTo(av);
        return bv.toString().compareTo(av.toString());
      });
    }
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The "Trend" tab only makes sense when the view declares a top_metric
    // (otherwise there's no scalar score to plot per day).
    final hasTrend = widget.view.topMetric != null;
    return DefaultTabController(
      length: hasTrend ? 2 : 1,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        builder: (ctx, scrollController) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.value,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'History · ${widget.dim.name}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (hasTrend)
                TabBar(
                  tabs: const [
                    Tab(text: 'Sets'),
                    Tab(text: 'Trend'),
                  ],
                  labelColor: scheme.primary,
                ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<Record>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Failed to load: ${snapshot.error}',
                          style: TextStyle(color: scheme.error),
                        ),
                      );
                    }
                    final rows = snapshot.data ?? const [];
                    if (rows.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No past entries for "${widget.value}".',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      );
                    }
                    final scores = [
                      for (final r in rows) scoreTopMetric(widget.view, r),
                    ];
                    final dayMaxes = _computeDayMaxScores(
                      rows: rows,
                      scores: scores,
                      view: widget.view,
                    );
                    final setsTab = _buildSetsList(
                      rows: rows,
                      scores: scores,
                      dayMaxes: dayMaxes,
                      scrollController: scrollController,
                    );
                    if (!hasTrend) return setsTab;
                    return TabBarView(
                      children: [
                        setsTab,
                        _TrendChart(
                          view: widget.view,
                          dayMaxes: dayMaxes,
                          metricName: widget.view.topMetric!,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSetsList({
    required List<Record> rows,
    required List<double?> scores,
    required Map<String, double> dayMaxes,
    required ScrollController scrollController,
  }) {
    return ListView.separated(
      controller: scrollController,
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final r = rows[i];
        return _HistoryTile(
          view: widget.view,
          record: r,
          isDayMax: _isDayTop(
            r: r,
            score: scores[i],
            view: widget.view,
            dayMaxes: dayMaxes,
          ),
        );
      },
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final ViewSchema view;
  final Record record;

  /// True when this row holds the day's max for at least one numeric
  /// dimension. Rendered bold + tinted so a glance picks out the top set
  /// (or longest hold, or highest reps) for each day.
  final bool isDayMax;

  const _HistoryTile({
    required this.view,
    required this.record,
    this.isDayMax = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dateField = view.dateField;
    final dateRaw = dateField == null ? null : record[dateField];
    final dateStr = _formatDate(dateRaw);
    final subtitle = ListDisplayRender.subtitle(view, record);
    final titleText = subtitle ?? ListDisplayRender.title(view, record);
    return ListTile(
      dense: true,
      tileColor: isDayMax ? scheme.primaryContainer : null,
      leading: dateStr == null
          ? null
          : SizedBox(
              width: 64,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isDayMax) ...[
                    Icon(Icons.bolt, size: 14, color: scheme.primary),
                    const SizedBox(width: 2),
                  ],
                  Expanded(
                    child: Text(
                      dateStr,
                      style: TextStyle(
                        color: isDayMax
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                        fontWeight: isDayMax ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      title: Text(
        titleText,
        style: TextStyle(
          fontWeight: isDayMax ? FontWeight.w700 : FontWeight.w400,
          color: isDayMax ? scheme.onPrimaryContainer : null,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : _OtherFields(view: view, record: record),
    );
  }

  static String? _formatDate(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return DateFormat('MMM d').format(raw);
    final s = raw.toString();
    final parsed = DateTime.tryParse(s);
    if (parsed != null) return DateFormat('MMM d').format(parsed);
    return s;
  }
}

/// Jinja env for evaluating a measure's `expr` against a row. Registers
/// a custom `round` filter (jinja 0.6.6's built-in is broken).
final _jinjaEnv = Environment(
  filters: {
    'round': (Object? value) {
      final n = value is num ? value : num.tryParse(value.toString());
      return n?.round() ?? value;
    },
  },
);

/// Identifiers Jinja accepts as variable names (no spaces, no operators).
/// Used to decide whether a dim's sheet header (`expr`) can safely be
/// registered as an alias for the dim's value during measure evaluation.
final _safeIdent = RegExp(r'^[A-Za-z_][A-Za-z_0-9]*$');

/// Evaluates the view's [ViewSchema.topMetric] measure against [r] and
/// returns the numeric score. Returns null when:
///   - no topMetric is configured on the view,
///   - the named measure doesn't exist or has no expr,
///   - evaluation throws (e.g. null operand),
///   - the rendered result isn't a number.
double? scoreTopMetric(ViewSchema view, Record r) {
  final metricName = view.topMetric;
  if (metricName == null) return null;
  Measure? m;
  for (final mm in view.measures) {
    if (mm.name == metricName) {
      m = mm;
      break;
    }
  }
  if (m == null || m.expr == null) return null;
  final ctx = <String, Object?>{};
  for (final d in view.dimensions) {
    final v = r[d.name];
    ctx[d.name] = v;
    // The measure's `expr` is written against the sheet column names
    // (Dimension.expr), not the dim's lower-case `name`. Register an
    // alias so `Weight * (1 + Reps / 30.0)` resolves. Skip exprs with
    // spaces/punctuation — those aren't valid Jinja identifiers.
    if (d.expr != d.name && _safeIdent.hasMatch(d.expr)) {
      ctx[d.expr] = v;
    }
  }
  try {
    final rendered = _jinjaEnv.fromString('{{ ${m.expr} }}').render(ctx);
    return double.tryParse(rendered.toString());
  } catch (_) {
    return null;
  }
}

/// Per-day max of [scores]. Keyed by `yyyy-MM-dd` day string from the
/// view's date field.
Map<String, double> _computeDayMaxScores({
  required List<Record> rows,
  required List<double?> scores,
  required ViewSchema view,
}) {
  final result = <String, double>{};
  final dateField = view.dateField;
  for (var i = 0; i < rows.length; i++) {
    final s = scores[i];
    if (s == null) continue;
    final key = dateField == null ? '' : _dayKey(rows[i][dateField]);
    final cur = result[key];
    if (cur == null || s > cur) result[key] = s;
  }
  return result;
}

bool _isDayTop({
  required Record r,
  required double? score,
  required ViewSchema view,
  required Map<String, double> dayMaxes,
}) {
  if (score == null) return false;
  final dateField = view.dateField;
  final key = dateField == null ? '' : _dayKey(r[dateField]);
  final max = dayMaxes[key];
  if (max == null) return false;
  // Tolerance handles float-arithmetic equality (`e1rm` rounding noise).
  return (score - max).abs() < 1e-6;
}

String _dayKey(Object? raw) {
  if (raw == null) return '';
  if (raw is DateTime) return DateFormat('yyyy-MM-dd').format(raw);
  final s = raw.toString();
  final parsed = DateTime.tryParse(s);
  if (parsed != null) return DateFormat('yyyy-MM-dd').format(parsed);
  return s;
}

/// Line chart of per-day max [topMetric] scores. Reuses the already-computed
/// [dayMaxes] map (keyed by yyyy-MM-dd) so we don't re-evaluate the measure
/// expression. One dot per day; tap a dot for a date + value tooltip.
///
/// Range chips `3M · 1Y · All` (2026-09-22, default All — the chart's
/// original full-history view) clip the same computed series by date.
/// Trailing windows anchor at the LAST entry, not the wall clock, so a
/// value not logged in months still gets a meaningful 3M. Chips that
/// would be empty or identical to All hide; the pinned tooltip clears
/// on range switch. Selection is in-memory sheet state, not persisted.
class _TrendChart extends StatefulWidget {
  final ViewSchema view;
  final Map<String, double> dayMaxes;
  final String metricName;

  const _TrendChart({
    required this.view,
    required this.dayMaxes,
    required this.metricName,
  });

  @override
  State<_TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<_TrendChart> {
  ChartRange? _selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.dayMaxes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No scoreable entries yet.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    // Day-ascending points so the line draws left-to-right without
    // backtracking.
    final entries = widget.dayMaxes.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final points = <ChartSeriesPoint>[
      for (final e in entries)
        if (DateTime.tryParse(e.key) case final DateTime dt)
          (day: dt, value: e.value),
    ];
    if (points.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not parse dates for trend.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final anchor = points.last.day;
    final chips = visibleRanges(
      points: points,
      ranges: const [ChartRange.m3, ChartRange.y1, ChartRange.all],
      today: anchor,
    );
    final range = resolveRange(chips, _selected ?? ChartRange.all);
    final clipped = clipSeriesToRange(points, range, anchor);

    // x = days-since-epoch (float), y = score.
    double dayX(DateTime d) => d.millisecondsSinceEpoch / (1000 * 60 * 60 * 24);
    final spots = [for (final p in clipped) FlSpot(dayX(p.day), p.value)];
    final windowStart = range.startFor(anchor) ?? clipped.first.day;
    var xMin = dayX(windowStart);
    final xMax = spots.last.x;
    if (xMax - xMin < 1) xMin = xMax - 1;
    final yValues = spots.map((s) => s.y).toList();
    final yMin = yValues.reduce((a, b) => a < b ? a : b);
    final yMax = yValues.reduce((a, b) => a > b ? a : b);
    final yPad = (yMax - yMin).abs() * 0.1 + 0.5;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Daily max · ${widget.metricName}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (chips.length > 1)
                ChartRangeSelector(
                  ranges: chips,
                  selected: range,
                  onChanged: (r) => setState(() => _selected = r),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            // LayoutBuilder: the bottom-axis tick keeper needs the
            // plot's pixel width to estimate label overlap.
            child: LayoutBuilder(
              builder: (context, constraints) => PinnedTooltipLineChart(
                // Re-key on range switch so the pinned tooltip clears
                // with the window.
                key: ValueKey(range),
                data: LineChartData(
                  minX: xMin,
                  maxX: xMax,
                  minY: yMin - yPad,
                  maxY: yMax + yPad,
                  gridData: const FlGridData(
                    show: true,
                    drawVerticalLine: false,
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border(
                      left: BorderSide(color: scheme.outlineVariant),
                      bottom: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  titlesData: FlTitlesData(
                    rightTitles: const AxisTitles(),
                    topTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        getTitlesWidget: (value, meta) => Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Text(
                            value.toStringAsFixed(0),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                    // Explicit non-overlapping date ticks (endpoints +
                    // month starts) — see chart_bottom_axis.dart.
                    bottomTitles: AxisTitles(
                      sideTitles: dateBottomTitles(
                        minX: xMin,
                        maxX: xMax,
                        plotWidth: (constraints.maxWidth - 44).clamp(1, 10000),
                        style: const TextStyle(fontSize: 11),
                        reservedSize: 32,
                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: false,
                      barWidth: 2,
                      color: scheme.primary,
                      dotData: FlDotData(
                        show: spots.length < 80,
                        getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                          radius: 3,
                          color: scheme.primary,
                          strokeWidth: 0,
                        ),
                      ),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    enabled: true,
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) =>
                          Colors.black.withValues(alpha: 0.7),
                      getTooltipItems: (touched) {
                        return touched.map((s) {
                          final dt = DateTime.fromMillisecondsSinceEpoch(
                            (s.x * 86400000).toInt(),
                            isUtc: true,
                          );
                          return LineTooltipItem(
                            '${DateFormat('yyyy-MM-dd').format(dt)}\n'
                            '${s.y.toStringAsFixed(1)}',
                            const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              height: 1.3,
                            ),
                          );
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${spots.length} day(s) · '
              'range ${yMin.toStringAsFixed(1)}–${yMax.toStringAsFixed(1)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact secondary line showing fields other than the title/subtitle ones
/// the user already sees. Skips empty values and the date (already in
/// leading). Helps surface context like RPE, notes, day-of-week.
class _OtherFields extends StatelessWidget {
  final ViewSchema view;
  final Record record;
  const _OtherFields({required this.view, required this.record});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final skip = <String>{
      if (view.dateField != null) view.dateField!,
      if (view.listDisplay?.title != null) view.listDisplay!.title,
    };
    final parts = <String>[];
    for (final dim in view.dimensions) {
      if (skip.contains(dim.name)) continue;
      if (dim.name == 'id') continue;
      final v = record[dim.name];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isEmpty) continue;
      parts.add('${dim.name}: $s');
      if (parts.length >= 4) break;
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
