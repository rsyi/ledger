/// Program screen — "what did I declare, what is actually happening,
/// and do they agree?"
///
/// Three sections, deliberately separate:
///  1. DECLARED — the intent layer verbatim: phase.yaml (value,
///     effective_from, reason, target, exit criteria) + program.yaml's
///     block timeline with a you-are-here marker.
///  2. OBSERVED — reality from the ledger: daily weigh-ins queried
///     through airlayer (the `weight` view's declared `avg_weight_lbs`
///     measure grouped by date — one averaged point per day), then the
///     §2.5 windowed formulas from program_metrics/program_observed
///     (7-day avg, weekly rate, 3-week change) computed in pure Dart.
///  3. VERDICT — PHASE_MISMATCH semantics: green (agree), amber
///     (drifting), red (three consecutive mismatch weeks — the flag
///     would fire).
///
/// Read-only: this screen never writes a row anywhere.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/program_current.dart';
import '../services/program_metrics.dart' show WeightRow;
import '../services/program_observed.dart';
import '../services/program_provider.dart';
import '../services/warehouse_connector.dart';

class ProgramScreen extends StatefulWidget {
  final ProgramProvider provider;

  /// Airlayer + local SQLite. Null → the observed/verdict sections show
  /// an "analytics unavailable" note instead of data.
  final AnalyticsEngine? analytics;

  /// Connector + schema for the `weight` view (observed layer's source).
  final WarehouseConnector? weightRepo;
  final ViewSchema? weightView;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  const ProgramScreen({
    super.key,
    required this.provider,
    this.analytics,
    this.weightRepo,
    this.weightView,
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

  const _ProgramData({
    required this.docs,
    required this.daily,
    this.observedError,
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

    final analytics = widget.analytics;
    final view = widget.weightView;
    if (analytics == null || view == null) {
      return _ProgramData(
        docs: docs,
        daily: const [],
        observedError: 'Analytics engine unavailable on this build.',
      );
    }
    try {
      // Refresh the local analytics mirror from the ledger (best-effort:
      // a failure here still lets us query the last-synced cache).
      if (widget.weightRepo != null) {
        try {
          await analytics.db.syncFromSheet(view, widget.weightRepo!);
        } catch (_) {/* stale cache is better than nothing */}
      }
      // The airlayer path: group by date, average weight_lbs — both
      // declared on the weight view. Windowed metrics happen in Dart.
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
      return _ProgramData(docs: docs, daily: daily);
    } catch (e) {
      return _ProgramData(
        docs: docs,
        daily: const [],
        observedError: 'Weight query failed: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Program')),
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
          return _ProgramView(data: data, today: _today);
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

  const _ProgramView({required this.data, required this.today});

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
    final targetRate =
        (phaseVersion?['target_rate_lb_per_week'] as num?)?.toDouble();
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

    final small = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);

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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
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
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (reason != null) ...[
              const SizedBox(height: 6),
              Text(reason,
                  style: small?.copyWith(fontStyle: FontStyle.italic)),
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
    final start =
        dates != null ? DateTime.tryParse(dates[0].toString()) : null;
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
      final done = DateTime(today.year, today.month, today.day)
              .difference(DateTime(start.year, start.month, start.day))
              .inDays +
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
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w500,
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

    final targetToday = blockStart != null &&
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
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
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
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Weight chart: daily weigh-ins (faint dots), trailing 7-day average
/// (solid line), and the current block's target line (dashed, from→to
/// across the block's dates). X spans ~3 weeks before the block through
/// the block's end so early-block views still show recent history.
/// Static (no zoom) — this is an overview, the Apps screen has the
/// interactive charts. Same fl_chart machinery as app_viewer_screen.
class _WeightChart extends StatelessWidget {
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

  static double _x(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Window: 21 days before the block (or before today when no block)
    // through the block end (or today).
    final windowStart = (blockStart ?? today).subtract(
      const Duration(days: 21),
    );
    final windowEnd = blockEnd ?? today;
    final xMin = _x(windowStart);
    final xMax = _x(windowEnd);

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
    final targetSpots = blockStart != null &&
            blockEnd != null &&
            targetFrom != null &&
            targetTo != null
        ? [
            FlSpot(_x(blockStart!), targetFrom!),
            FlSpot(_x(blockEnd!), targetTo!),
          ]
        : const <FlSpot>[];

    if (dailySpots.isEmpty && targetSpots.isEmpty) {
      return const SizedBox(
        height: 100,
        child: Center(child: Text('(no weigh-ins in this window)')),
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
    final rangeDays = xMax - xMin;

    return SizedBox(
      height: 240,
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
                reservedSize: 40,
                getTitlesWidget: (value, meta) => Text(
                  value.toStringAsFixed(0),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                interval: rangeDays <= 45 ? 7 : 30,
                getTitlesWidget: (value, meta) {
                  final dt = DateTime.fromMillisecondsSinceEpoch(
                    (value * 86400000).toInt(),
                    isUtc: true,
                  );
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      DateFormat('MMM d').format(dt),
                      style: const TextStyle(fontSize: 9),
                    ),
                  );
                },
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
                  getDotPainter: (spot, pct, bar, i) => FlDotCirclePainter(
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

    final declared = 'Declared $phase'
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
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: fg),
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

String _fmtSigned(double v) =>
    '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)}';

String _fmtIso(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat('MMM d, yyyy').format(d);
}
