/// LIFT page (IA restructure 2026-10-02): opened from a Progress-tab
/// lift row — replaces the long "Lifts" text sheet with a dedicated
/// page per main lift:
///
///   * NOW — recent estimated max vs the last bulk's best and the
///     all-time best (the Progress row's numbers, each with its Wilks
///     points);
///   * ESTIMATED MAX OVER TIME — the best RPE-adjusted e1RM per session
///     (same basis as the Progress number), cut / bulk periods shaded
///     from coach/phase.yaml's versions + dashboards.yaml `last_bulk`;
///   * RECENT TOP SETS — the last 8 sessions' best set (date, weight ×
///     reps, RPE, e1RM);
///   * TRAINING MAX — the value in force + its history from the
///     append-only working_max tab (value, from-date, source, reason);
///   * PROJECTION — this lift's estimated max projected at the current
///     block's start and FROZEN (band + projected line, actuals overlaid,
///     tracking chip + one line — phase-projections spec 2026-10-02);
///     the rolling outlook ("Squat 404 by Dec '28", end of block) sits in
///     a Model details fold below it.
///
/// The how-it's-measured explanations sit at the bottom as small text
/// ([LiftExplainer]) — no info icons.
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/home_synthesis.dart' show fmtLb, fmtMonthTag;
import '../services/program_metrics.dart'
    show StrengthRow, mainLiftByExercise, rpeAdjustedE1rm;
import '../services/program_provider.dart';
import '../services/projection_snapshot.dart' show ProjectionMetric;
import '../services/sim2_harness.dart' show Sim2WeekPoint, sim2CurrentBlockN;
import '../services/wm_tabs.dart' show WmSnapshot, WorkingMaxRow;
import 'design/design.dart';
import 'home_dashboard.dart'
    show fmtAgoWords, fmtLbDelta, liftDeltaStatus, liftTitle;
import 'plan_data.dart';
import 'widgets/chart_bottom_axis.dart';
import 'widgets/chart_range.dart';
import 'widgets/forecast_section.dart' show forecastBaselineRun;
import 'widgets/projection_card.dart';

/// One value on the Progress lift row: pounds + the date + its Wilks
/// points (null when no bodyweight covers the date).
typedef LiftFigure = ({double value, DateTime date, double? wilks});

/// The numbers the Progress tab already computed for one lift, handed
/// to the lift page so both always agree.
class LiftSummary {
  final LiftFigure? recent;
  final LiftFigure? lastBulk;
  final LiftFigure? best;

  /// dashboards.yaml `last_bulk:` window; null → no bulk comparison.
  final ({DateTime start, DateTime end, String label})? bulkWindow;

  /// Bodyweight the recent figure's Wilks is priced at.
  final double? currentBwLbs;

  const LiftSummary({
    this.recent,
    this.lastBulk,
    this.best,
    this.bulkWindow,
    this.currentBwLbs,
  });
}

/// One session's best set for a lift.
typedef LiftSessionTop = ({
  DateTime date,
  double weight,
  int reps,
  double? rpe,
  double e1rm,
});

/// Per-day best set of [lift] by RPE-adjusted e1RM (the Progress
/// number's basis), date-ascending. Sets with no load or reps are
/// skipped.
List<LiftSessionTop> liftSessionTops(List<StrengthRow> rows, String lift) {
  final byDay = <DateTime, LiftSessionTop>{};
  for (final r in rows) {
    if (mainLiftByExercise[r.exercise] != lift) continue;
    if (r.weight <= 0 || r.reps < 1) continue;
    final day = DateTime(r.date.year, r.date.month, r.date.day);
    final e = rpeAdjustedE1rm(r.weight, r.reps, r.rpe);
    final cur = byDay[day];
    if (cur == null || e > cur.e1rm) {
      byDay[day] = (
        date: day,
        weight: r.weight,
        reps: r.reps,
        rpe: r.rpe,
        e1rm: e,
      );
    }
  }
  return byDay.values.toList()..sort((a, b) => a.date.compareTo(b.date));
}

/// A shaded period on the e1RM chart.
typedef PhaseSpan = ({DateTime start, DateTime end, String kind, String label});

/// Cut / bulk periods for shading: every coach/phase.yaml version (not
/// pending) runs from its effective_from to the next version's (the
/// current one to [today]); the dashboards.yaml last-bulk window adds a
/// bulk span when the phase history doesn't already cover it.
List<PhaseSpan> liftPhaseSpans(
  Map<Object?, Object?>? phaseDoc,
  ({DateTime start, DateTime end, String label})? bulkWindow,
  DateTime today,
) {
  final out = <PhaseSpan>[];
  final versions = phaseDoc?['versions'];
  final live = <(DateTime, String)>[];
  if (versions is List) {
    for (final v in versions) {
      if (v is! Map || v['pending'] == true) continue;
      final from = DateTime.tryParse(v['effective_from']?.toString() ?? '');
      final value = v['value']?.toString() ?? '';
      if (from != null && value.isNotEmpty) live.add((from, value));
    }
  }
  live.sort((a, b) => a.$1.compareTo(b.$1));
  for (var i = 0; i < live.length; i++) {
    final end = i + 1 < live.length ? live[i + 1].$1 : today;
    if (!end.isAfter(live[i].$1)) continue;
    out.add((
      start: live[i].$1,
      end: end,
      kind: live[i].$2,
      label: live[i].$2,
    ));
  }
  final w = bulkWindow;
  if (w != null &&
      !out.any((s) => s.kind == 'bulk' && !s.end.isBefore(w.start) &&
          !s.start.isAfter(w.end))) {
    out.add((start: w.start, end: w.end, kind: 'bulk', label: w.label));
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

class LiftScreen extends StatefulWidget {
  /// squat | bench | deadlift | press.
  final String lift;
  final LiftSummary summary;

  /// Strength history, phase docs and the forecast. Null → the page
  /// shows only [summary].
  final PlanSources? sources;

  /// Training-max tabs (WmStore.snapshot). Null → no TM section data.
  final Future<WmSnapshot?> Function()? wmSnapshot;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  const LiftScreen({
    super.key,
    required this.lift,
    required this.summary,
    this.sources,
    this.wmSnapshot,
    this.today,
  });

  @override
  State<LiftScreen> createState() => _LiftScreenState();
}

typedef _LiftData = ({PlanData? plan, WmSnapshot? wm});

class _LiftScreenState extends State<LiftScreen> {
  late final DateTime _today;
  late Future<_LiftData> _load;

  @override
  void initState() {
    super.initState();
    _today = widget.today ?? DateTime.now();
    _load = _fetch();
  }

  Future<_LiftData> _fetch() async {
    final planF = widget.sources == null
        ? Future<PlanData?>.value()
        : loadPlanData(widget.sources!, _today);
    final wmF = () async {
      try {
        return await widget.wmSnapshot?.call();
      } catch (_) {
        return null;
      }
    }();
    PlanData? plan;
    try {
      plan = await planF;
    } catch (_) {}
    return (plan: plan, wm: await wmF);
  }

  Future<void> _refresh() async {
    ProgramProvider.clearCache();
    final next = _fetch();
    setState(() => _load = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    return Scaffold(
      appBar: AppBar(
        title: Text(liftTitle(widget.lift)),
      ),
      body: FutureBuilder<_LiftData>(
        future: _load,
        builder: (context, snap) {
          final loading = snap.connectionState != ConnectionState.done;
          final data = snap.data;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SectionHeader(label: 'Now'),
                _NowCard(summary: s, today: _today),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  ..._history(context, data?.plan),
                  ..._trainingMax(context, data?.wm),
                  ..._projection(context, data?.plan),
                ],
                const SectionHeader(label: 'How these are measured'),
                LiftExplainer(
                  bulkWindow: s.bulkWindow,
                  currentBwLbs: s.currentBwLbs,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _history(BuildContext context, PlanData? plan) {
    final tops = liftSessionTops(plan?.strengthRows ?? const [], widget.lift);
    const gutter = EdgeInsets.symmetric(horizontal: AppSpace.gutter);
    if (tops.isEmpty) {
      return [
        const SectionHeader(label: 'Estimated max over time'),
        Padding(
          padding: gutter,
          child: AppCard(
            child: Text(
              'No logged sets for this lift yet.',
              style: AppText.meta(context),
            ),
          ),
        ),
      ];
    }
    final spans = liftPhaseSpans(
      plan?.docs.phase,
      widget.summary.bulkWindow,
      _today,
    );
    final recent = tops.reversed.take(8).toList();
    return [
      const SectionHeader(label: 'Estimated max over time'),
      Padding(
        padding: gutter,
        child: AppCard(
          padding: const EdgeInsets.all(12),
          child: _E1rmChart(tops: tops, spans: spans, today: _today),
        ),
      ),
      SectionHeader(label: 'Recent top sets', count: 'last ${recent.length}'),
      RowGroupCard(
        key: const ValueKey('lift-top-sets'),
        rows: [
          for (final t in recent)
            ExerciseRow(
              name: DateFormat('EEE MMM d').format(t.date),
              meta:
                  '${fmtLb(t.weight)} lb × ${t.reps}'
                  '${t.rpe == null ? '' : ' · RPE ${fmtLb(t.rpe!)}'}',
              status: ItemStatus.muted,
              trailing: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${t.e1rm.round()} lb',
                  style: AppText.row(context).copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter,
          6,
          AppSpace.gutter,
          0,
        ),
        child: Text(
          'Right-hand number: the set\'s estimated 1-rep max (reps in '
          'reserve count as reps).',
          style: AppText.meta(context),
        ),
      ),
    ];
  }

  List<Widget> _trainingMax(BuildContext context, WmSnapshot? wm) {
    final rows = [
      for (final r in wm?.workingMax ?? const <WorkingMaxRow>[])
        if (r.lift == widget.lift) r,
    ];
    const gutter = EdgeInsets.symmetric(horizontal: AppSpace.gutter);
    const header = SectionHeader(label: 'Training max');
    if (rows.isEmpty) {
      return [
        header,
        Padding(
          padding: gutter,
          child: AppCard(
            child: Text(
              wm == null
                  ? 'Training maxes unavailable — pull to retry.'
                  : 'No training max recorded for this lift yet.',
              style: AppText.meta(context),
            ),
          ),
        ),
      ];
    }
    // Append-only tab: chronological order; newest first here.
    final history = rows.reversed.take(10).toList();
    final current = rows.last;
    String source(String s) => switch (s) {
      'rule' => 'auto',
      'manual' => 'set by you',
      'seed' => 'starting value',
      'test' => 'test',
      'pain_cap' => 'pain cap',
      _ => s,
    };
    return [
      header,
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.gutter,
          0,
          AppSpace.gutter,
          8,
        ),
        child: Text(
          'The program prices sessions off this number (not a measured '
          'max). Now ${fmtLb(current.valueLb)} lb, since '
          '${DateFormat('MMM d, yyyy').format(current.effectiveFrom)}.',
          key: const ValueKey('lift-tm-current'),
          style: AppText.meta(context),
        ),
      ),
      RowGroupCard(
        key: const ValueKey('lift-tm-history'),
        rows: [
          for (final r in history)
            ExerciseRow(
              name: '${fmtLb(r.valueLb)} lb',
              meta:
                  '${DateFormat('MMM d, yyyy').format(r.effectiveFrom)}'
                  ' · ${source(r.source)}',
              status: identical(r, current)
                  ? ItemStatus.done
                  : ItemStatus.muted,
              subtitle: r.reason.trim().isEmpty ? null : Text(r.reason.trim()),
            ),
        ],
      ),
    ];
  }

  List<Widget> _projection(BuildContext context, PlanData? plan) {
    final inputs = plan?.forecast;
    if (inputs == null) return const [];
    final run = forecastBaselineRun(inputs, _today);
    if (run.weeks.isEmpty) return const [];
    double of(Sim2WeekPoint w) => switch (widget.lift) {
      'squat' => w.squat,
      'bench' => w.bench,
      'deadlift' => w.deadlift,
      _ => w.press,
    };
    final fmt = DateFormat("MMM d ''yy");
    final currentBlock = run.weeks.first.blockN;
    final blockEnd = run.weeks.lastWhere((w) => w.blockN == currentBlock);
    final horizon = run.weeks.last;
    final name = liftTitle(widget.lift);
    final metric = ProjectionMetric.e1rm(widget.lift);
    final blockN = sim2CurrentBlockN(inputs.blocks, _today);
    final projections = plan?.projections;
    const gutter = EdgeInsets.symmetric(horizontal: AppSpace.gutter);
    return [
      const SectionHeader(label: 'Projection'),
      Padding(
        padding: gutter,
        child: ProjectionCard(
          metric: metric,
          title: 'Estimated max this block',
          snapshot: blockN == null ? null : projections?.byBlock[blockN],
          projections: projections,
          today: _today,
          // Live fallback on the index basis (what logged e1RMs show).
          liveLine: [
            for (final w in run.weeks)
              if (w.blockN == blockN)
                (
                  w.monday.add(const Duration(days: 7)),
                  of(w) * w.sIdx / w.sTrue,
                ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: gutter,
        child: AppCard(
          padding: EdgeInsets.zero,
          child: Theme(
            data: Theme.of(
              context,
            ).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey('lift-model-details'),
              tilePadding: const EdgeInsets.symmetric(
                horizontal: AppSpace.gutter,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(
                AppSpace.gutter,
                0,
                AppSpace.gutter,
                AppSpace.gutter,
              ),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text('Model details', style: AppText.row(context)),
              children: [
                Text(
                  'Rolling outlook — the live model, recalibrated nightly '
                  '(not the frozen projection above).',
                  style: AppText.meta(context),
                ),
                const SizedBox(height: 4),
                Text(
                  '$name ${of(horizon).round()} lb by '
                  '${fmt.format(horizon.monday.add(const Duration(days: 6)))}',
                  key: const ValueKey('lift-projection'),
                  style: AppText.row(context),
                ),
                const SizedBox(height: 4),
                Text(
                  '${of(blockEnd).round()} lb at the end of this '
                  '${blockEnd.emphasis} block '
                  '(${fmt.format(blockEnd.monday.add(const Duration(days: 6)))})',
                  style: AppText.row(context),
                ),
                const SizedBox(height: 4),
                Text(
                  'Expected strength staying on this program (true '
                  'strength, which logged e1RMs lag) — the model behind it '
                  'is on the Strength page.',
                  style: AppText.meta(context),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

/// NOW: recent estimated max vs last bulk best vs all-time best.
class _NowCard extends StatelessWidget {
  final LiftSummary summary;
  final DateTime today;

  const _NowCard({required this.summary, required this.today});

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final hasBulk = s.bulkWindow != null;
    final value = AppText.row(context).copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    String wilks(LiftFigure f) => f.wilks == null
        ? ''
        : ' · ${f.wilks!.toStringAsFixed(1)} Wilks points';
    Widget figure(LiftFigure? f) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(f == null ? '—' : '${fmtLb(f.value.roundToDouble())} lb',
          style: value),
    );
    final recentStatus = hasBulk
        ? liftDeltaStatus(s.recent?.value, s.lastBulk?.value)
        : (s.recent == null ? ItemStatus.pending : ItemStatus.done);
    return RowGroupCard(
      key: const ValueKey('lift-now'),
      rows: [
        ExerciseRow(
          name: 'Recent estimated max',
          status: recentStatus,
          subtitle: Text(
            s.recent == null
                ? 'no recent work'
                : '${fmtAgoWords(s.recent!.date, today)}${wilks(s.recent!)}',
          ),
          trailing: figure(s.recent),
        ),
        if (hasBulk)
          ExerciseRow(
            name: 'Last bulk best',
            status: ItemStatus.muted,
            subtitle: Text(
              s.lastBulk == null
                  ? 'none in the ${s.bulkWindow!.label}'
                  : '${fmtMonthTag(s.lastBulk!.date)}'
                        '${s.recent == null ? '' : ' · change '
                                  '${fmtLbDelta(s.recent!.value, s.lastBulk!.value)}'}'
                        '${wilks(s.lastBulk!)}',
            ),
            trailing: figure(s.lastBulk),
          ),
        ExerciseRow(
          name: 'All-time best',
          status: ItemStatus.muted,
          subtitle: Text(
            s.best == null
                ? 'no history'
                : '${fmtMonthTag(s.best!.date)}${wilks(s.best!)}',
          ),
          trailing: figure(s.best),
        ),
      ],
    );
  }
}

/// Session-best e1RM over time with cut/bulk shading and range chips.
class _E1rmChart extends StatefulWidget {
  final List<LiftSessionTop> tops;
  final List<PhaseSpan> spans;
  final DateTime today;

  const _E1rmChart({
    required this.tops,
    required this.spans,
    required this.today,
  });

  @override
  State<_E1rmChart> createState() => _E1rmChartState();
}

class _E1rmChartState extends State<_E1rmChart> {
  ChartRange? _selected;

  static double _x(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

  Color _spanColor(ColorScheme scheme, String kind) => switch (kind) {
    'cut' => scheme.error,
    'bulk' => scheme.primary,
    _ => scheme.tertiary,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final series = <ChartSeriesPoint>[
      for (final t in widget.tops) (day: t.date, value: t.e1rm),
    ];
    final chips = visibleRanges(
      points: series,
      ranges: const [
        ChartRange.m3,
        ChartRange.m6,
        ChartRange.y1,
        ChartRange.all,
      ],
      today: widget.today,
    );
    final range = resolveRange(chips, _selected ?? ChartRange.y1);
    final clipped = clipSeriesToRange(series, range, widget.today);
    final pts = clipped.isEmpty ? series : clipped;
    var xMin = _x(range.startFor(widget.today) ?? pts.first.day);
    final xMax = math.max(_x(widget.today), _x(pts.last.day));
    if (xMax - xMin < 7) xMin = xMax - 7;
    final ys = [for (final p in pts) p.value];
    final yMin = ys.reduce(math.min);
    final yMax = ys.reduce(math.max);
    final yPad = (yMax - yMin).abs() * 0.1 + 5;
    final visibleSpans = [
      for (final s in widget.spans)
        if (_x(s.end) > xMin && _x(s.start) < xMax) s,
    ];
    final meta = AppText.meta(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chips.length > 1)
          ChartRangeSelector(
            ranges: chips,
            selected: range,
            onChanged: (r) => setState(() => _selected = r),
          ),
        const SizedBox(height: 8),
        SizedBox(
          height: 200,
          child: LayoutBuilder(
            builder: (context, constraints) => LineChart(
              key: const ValueKey('lift-e1rm-chart'),
              LineChartData(
                minX: xMin,
                maxX: xMax,
                minY: yMin - yPad,
                maxY: yMax + yPad,
                clipData: const FlClipData.all(),
                gridData: const FlGridData(
                  show: true,
                  drawVerticalLine: false,
                ),
                borderData: FlBorderData(show: false),
                rangeAnnotations: RangeAnnotations(
                  verticalRangeAnnotations: [
                    for (final s in visibleSpans)
                      VerticalRangeAnnotation(
                        x1: math.max(_x(s.start), xMin),
                        x2: math.min(_x(s.end), xMax),
                        color: _spanColor(
                          scheme,
                          s.kind,
                        ).withValues(alpha: 0.08),
                      ),
                  ],
                ),
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(),
                  topTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (value, m) => Text(
                        value.toStringAsFixed(0),
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: dateBottomTitles(
                      minX: xMin,
                      maxX: xMax,
                      plotWidth: (constraints.maxWidth - 40).clamp(1, 10000),
                      style: const TextStyle(fontSize: 11),
                      reservedSize: 28,
                    ),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: [for (final p in pts) FlSpot(_x(p.day), p.value)],
                    isCurved: false,
                    barWidth: 2,
                    color: scheme.primary,
                    dotData: FlDotData(
                      show: pts.length < 80,
                      getDotPainter: (spot, pct, bar, i) => FlDotCirclePainter(
                        radius: 2.5,
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
                    getTooltipItems: (touched) => [
                      for (final s in touched)
                        LineTooltipItem(
                          '${DateFormat('MMM d, yyyy').format(DateTime.fromMillisecondsSinceEpoch((s.x * 86400000).round(), isUtc: true))}\n'
                          '${s.y.toStringAsFixed(0)} lb',
                          const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (visibleSpans.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            key: const ValueKey('lift-phase-legend'),
            spacing: 12,
            runSpacing: 2,
            children: [
              for (final kind in {for (final s in visibleSpans) s.kind})
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _spanColor(scheme, kind).withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text('$kind period', style: meta),
                  ],
                ),
            ],
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'Each point: that session\'s best estimated 1-rep max.',
          style: meta,
        ),
      ],
    );
  }
}

/// How the lift numbers are measured — the key explanations from the
/// retired Lifts sheet, as small text at the bottom of the lift page
/// (no info icon anywhere — user, 2026-10-02: "seems useless").
class LiftExplainer extends StatelessWidget {
  final ({DateTime start, DateTime end, String label})? bulkWindow;
  final double? currentBwLbs;

  const LiftExplainer({super.key, this.bulkWindow, this.currentBwLbs});

  @override
  Widget build(BuildContext context) {
    final meta = AppText.meta(context);
    final strong = meta.copyWith(fontWeight: FontWeight.w600);
    Widget note(String title, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$title  ', style: strong),
            TextSpan(text: text, style: meta),
          ],
        ),
      ),
    );
    final w = bulkWindow;
    final bw = currentBwLbs;
    return Padding(
      key: const ValueKey('lift-explainer'),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          note(
            'Recent estimated max',
            'Best estimated 1-rep max over the last 14 days of real work. '
                'Reps in reserve (10 − RPE) count as reps: 275×2 at RPE 8 '
                'scores like 275×4. Deload weeks and easy sets don\'t count.',
          ),
          if (w != null)
            note(
              'Last bulk best',
              'Heaviest weight actually lifted during the ${w.label} '
                  '(${DateFormat('MMM yyyy').format(w.start)} – '
                  '${DateFormat('MMM yyyy').format(w.end)}). Green: within '
                  '5%. Amber: 5–10% below. Red: more than 10% below.',
            ),
          note(
            'All-time best',
            'Heaviest weight you\'ve ever actually lifted (any reps; no '
                'estimates).',
          ),
          note(
            'Wilks points',
            'The weight scored against bodyweight — recent numbers at your '
                'current bodyweight'
                '${bw == null ? '' : ' (${bw.toStringAsFixed(1)} lb)'}, '
                'bests at the bodyweight of the month they were set.',
          ),
        ],
      ),
    );
  }
}
