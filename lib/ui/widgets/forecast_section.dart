/// FORECAST section for the Program tab (design doc
/// `airledger/docs/superpowers/specs/2026-09-25-sim-design.md` §9, W3):
/// the observed weight chart anchors a dashed simulated trajectory with
/// tinted phase bands and a ±noise band; below it the strength forecast
/// (per-lift e1RM toggle chips + the derived Wilks line), the climbing
/// p75 forecast (OFFSET-ANCHORED to the observed p75 — validated slope,
/// honest anchor), the lever row (instant synchronous re-sim), and the
/// milestone list at every phase boundary.
///
/// Honesty rules carried in the UI:
///   * bands are the declared fit MAEs (per-driver, world_model.yaml) —
///     calibration quality is first-class, never hidden;
///   * the climbing model's raw level is captioned next to the anchored
///     curve, not silently replaced;
///   * the press caveat (observed cut decline the maintain model does
///     not predict; exposure floor unmodeled) is surfaced where press
///     is shown;
///   * Wilks is intentionally non-monotone in the bulk lever — the
///     summary reports what the sim says, nothing is smoothed away.
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/forecast_tab.dart' show gradeAnchorOffset;
import '../../services/program_metrics.dart' show WeightRow;
import '../../services/program_observed.dart'
    show ObservedWeightStats, sevenDayAvgSeries;
import '../../services/sim_core.dart';
import '../../services/sim_fit.dart'
    show SimCoefficients, simBlockWeeks, simLifts, simSbdLifts;
import '../../services/world_model.dart';
import '../app_text.dart';
import 'chart_bottom_axis.dart';

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// Everything the section needs, assembled by the Program screen.
class ForecastInputs {
  final SimInitialState initial;
  final SimProgram program;

  /// Drift-guarded coefficients (refit where sane, declared otherwise).
  final SimCoefficients coefficients;
  final SimRules rules;

  /// Coefficients that tripped the ±50% drift guard (design §8) — shown
  /// as a "model drift" tag; the declared values are in force for them.
  final List<String> drifted;

  /// Per-lift forecast band (lb): the declared fit's velocity MAE ×
  /// the 4-week fit-block length ≈ the study's held-out level MAE.
  final Map<String, double> strengthMaeLb;

  /// Climbing level-fit MAE (V), the grade band.
  final double? gradeMaeV;

  /// Observed daily weigh-ins (full history; the chart windows it).
  final List<WeightRow> observedDaily;
  final ObservedWeightStats stats;

  /// Observed rolling p75 (latest) — the climbing anchor.
  final double? observedP75;

  const ForecastInputs({
    required this.initial,
    required this.program,
    required this.coefficients,
    required this.rules,
    this.drifted = const [],
    this.strengthMaeLb = const {},
    this.gradeMaeV,
    this.observedDaily = const [],
    this.stats = const ObservedWeightStats(
      bw7dAvg: null,
      bwRateLbWk: null,
      bw3wkChange: null,
      recentRates: [],
      lastWeighIn: null,
    ),
    this.observedP75,
  });
}

/// Builds [ForecastInputs.strengthMaeLb] from the declared drivers:
/// `fit.mae_lb_wk` × [simBlockWeeks] (velocity MAE over a fit block ≈
/// held-out level MAE — squat 20, bench 15.6, deadlift 22.4, press 8.7
/// from the shipped file, matching the study's gate-table bands).
Map<String, double> strengthMaeFromModel(WorldModel model) {
  final out = <String, double>{};
  for (final l in simLifts) {
    for (final d in model.driversOf('e1rm_$l')) {
      final mae = d.fit['mae_lb_wk'];
      if (mae is num) out[l] = mae.toDouble() * simBlockWeeks;
    }
  }
  return out;
}

/// The grade band from the declared level fit's `mae_v`.
double? gradeMaeFromModel(WorldModel model) {
  for (final d in model.driversOf('grade_p75')) {
    final mae = d.fit['mae_v'];
    if (mae is num) return mae.toDouble();
  }
  return null;
}

/// Daily-scatter noise band for the bw chart: mean absolute deviation
/// of the last [windowDays] weigh-ins from their trailing 7-day
/// average. This is measurement/adherence noise (bw itself is a
/// scripted input, not a fitted response). Fallback 1.0 lb.
double bwNoiseBand(List<WeightRow> daily, DateTime asOf,
    {int windowDays = 56}) {
  if (daily.isEmpty) return 1.0;
  final avgByDay = {for (final w in sevenDayAvgSeries(daily)) w.date: w};
  var sum = 0.0;
  var n = 0;
  for (final w in daily) {
    if (asOf.difference(w.date).inDays > windowDays) continue;
    final avg = avgByDay[w.date];
    if (avg == null) continue;
    sum += (w.weightLbs - avg.weightLbs).abs();
    n++;
  }
  return n == 0 ? 1.0 : sum / n;
}

// ---------------------------------------------------------------------------
// The section
// ---------------------------------------------------------------------------

class ForecastSection extends StatefulWidget {
  final ForecastInputs inputs;
  final DateTime today;

  const ForecastSection({super.key, required this.inputs, required this.today});

  @override
  State<ForecastSection> createState() => _ForecastSectionState();
}

class _ForecastSectionState extends State<ForecastSection> {
  static const _defaultLevers = SimLevers();

  SimLevers _levers = _defaultLevers;
  late SimResult _result;

  /// Strength-chart series toggles (lifts + wilks). Defaults: all on.
  late final Set<String> _series = {
    for (final l in simLifts)
      if (widget.inputs.initial.e1rm.containsKey(l)) l,
    'wilks',
  };

  @override
  void initState() {
    super.initState();
    _result = _run(_levers);
  }

  SimResult _run(SimLevers levers) => simulate(
        initial: widget.inputs.initial,
        coefficients: widget.inputs.coefficients,
        rules: widget.inputs.rules,
        program: widget.inputs.program,
        levers: levers,
      );

  void _setLevers(SimLevers levers) {
    // Sync re-sim on every lever change — ~10 ms for hundreds of weeks,
    // safe on slider drag (W2 contract).
    setState(() {
      _levers = levers;
      _result = _run(levers);
    });
  }

  bool get _leversAtDefaults =>
      _levers.bulkRateLbWk == null &&
      _levers.cutRateLbWk == _defaultLevers.cutRateLbWk &&
      _levers.climbFrequency == _defaultLevers.climbFrequency &&
      _levers.horizonYears == _defaultLevers.horizonYears;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inputs = widget.inputs;
    final gradeOffset = gradeAnchorOffset(
      observedP75: inputs.observedP75,
      modelP75: _result.weeks.isEmpty ? null : _result.weeks.first.gradeP75,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryLine(
          key: const ValueKey('forecast-summary'),
          result: _result,
          program: inputs.program,
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('BODYWEIGHT — OBSERVED + FORECAST',
                    style: AppText.title(context)),
                const SizedBox(height: 6),
                _BwForecastChart(
                  key: const ValueKey('forecast-bw-chart'),
                  result: _result,
                  daily: inputs.observedDaily,
                  today: widget.today,
                  band: bwNoiseBand(inputs.observedDaily, widget.today),
                ),
                const SizedBox(height: 8),
                _StatsRow(stats: inputs.stats),
                const SizedBox(height: 4),
                Text(
                  'observed solid · forecast dashed · bands: phases + '
                  '±daily scatter',
                  style: AppText.micro(context),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _LeverCard(
          levers: _levers,
          ranges: inputs.rules.levers,
          atDefaults: _leversAtDefaults,
          onChanged: _setLevers,
          onReset: () => _setLevers(_defaultLevers),
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('STRENGTH FORECAST — e1RM + WILKS',
                    style: AppText.title(context)),
                const SizedBox(height: 6),
                _SeriesChips(
                  available: [
                    for (final l in simLifts)
                      if (inputs.initial.e1rm.containsKey(l)) l,
                    'wilks',
                  ],
                  selected: _series,
                  onToggle: (s) => setState(() {
                    if (!_series.remove(s)) _series.add(s);
                  }),
                ),
                const SizedBox(height: 4),
                _StrengthForecastChart(
                  key: const ValueKey('forecast-strength-chart'),
                  result: _result,
                  series: _series,
                  maeByLift: inputs.strengthMaeLb,
                ),
                if (_series.contains('press')) ...[
                  const SizedBox(height: 4),
                  Text(
                    'press: the current cut shows a decline the maintain '
                    'model does not predict (held-out MAE ~50 lb model and '
                    'flat) — no exposure floor is modeled.',
                    style: AppText.micro(context),
                  ),
                ],
                if (inputs.drifted.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _DriftTag(drifted: inputs.drifted),
                ],
              ],
            ),
          ),
        ),
        if (_result.weeks.isNotEmpty &&
            _result.weeks.first.gradeP75 != null) ...[
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CLIMBING — GRADE p75 FORECAST',
                      style: AppText.title(context)),
                  const SizedBox(height: 6),
                  _ClimbForecastChart(
                    key: const ValueKey('forecast-climb-chart'),
                    result: _result,
                    offset: gradeOffset,
                    band: inputs.gradeMaeV ?? 0.5,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'anchored to observed p75 '
                    'V${inputs.observedP75?.toStringAsFixed(1) ?? '?'} — the '
                    'model\'s raw level is '
                    'V${_result.weeks.first.gradeP75!.toStringAsFixed(1)} at '
                    'current bw (slope validated, level offset '
                    '${gradeOffset >= 0 ? '+' : ''}${gradeOffset.toStringAsFixed(1)}).',
                    style: AppText.micro(context),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        _MilestoneList(result: _result),
        const SizedBox(height: 6),
        Text(
          'model: e1RM velocity responds to the bw rate, damped near the '
          'all-time peak; grade tracks bw level; bands = declared fit '
          'MAEs; refit from local history on refresh (±50% drift guard).',
          style: AppText.micro(context),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Summary line ("On these levers: …")
// ---------------------------------------------------------------------------

class _SummaryLine extends StatelessWidget {
  final SimResult result;
  final SimProgram program;

  const _SummaryLine({super.key, required this.result, required this.program});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <String>[];

    // Cut end: the first cut segment's last week.
    for (final s in result.segments) {
      if (s.phase == 'cut') {
        parts.add('${program.cutTargetLb.toStringAsFixed(0)} by '
            '${DateFormat('MMM d').format(s.end)}');
        break;
      }
    }
    // Wilks plateau: the max over the horizon + the year it is reached.
    if (result.weeks.isNotEmpty) {
      var maxW = result.weeks.first.wilks;
      for (final w in result.weeks) {
        maxW = math.max(maxW, w.wilks);
      }
      for (final w in result.weeks) {
        if (w.wilks >= maxW - 0.5) {
          parts.add('Wilks ${maxW.round()} by ${w.monday.year}');
          break;
        }
      }
      // Deadlift: the best e1RM over the horizon, floored to a 10.
      var maxDl = 0.0;
      for (final w in result.weeks) {
        maxDl = math.max(maxDl, w.e1rm['deadlift'] ?? 0);
      }
      if (maxDl > 0) {
        parts.add('deadlift ${(maxDl ~/ 10) * 10}+');
      }
    }
    if (parts.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          'On these levers: ${parts.join(' · ')}',
          style: AppText.value(context),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared chart plumbing
// ---------------------------------------------------------------------------

double _x(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

Color _phaseColor(ColorScheme scheme, String phase) => switch (phase) {
      'cut' => scheme.error,
      'reverse' => scheme.tertiary,
      'bulk' => scheme.primary,
      _ => scheme.outline, // maintain
    };

/// Tinted vertical spans, one per phase segment.
List<VerticalRangeAnnotation> _phaseBands(
  ColorScheme scheme,
  SimResult result,
) =>
    [
      for (final s in result.segments)
        VerticalRangeAnnotation(
          x1: _x(s.start),
          x2: _x(s.end) + 7,
          color: _phaseColor(scheme, s.phase).withValues(alpha: 0.07),
        ),
    ];

FlTitlesData _titles({
  required double xMin,
  required double xMax,
  required double plotWidth,
  int yDecimals = 0,
}) =>
    FlTitlesData(
      rightTitles: const AxisTitles(),
      topTitles: const AxisTitles(),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 40,
          getTitlesWidget: (value, meta) => Text(
            value.toStringAsFixed(yDecimals),
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ),
      bottomTitles: AxisTitles(
        sideTitles: dateBottomTitles(
          minX: xMin,
          maxX: xMax,
          plotWidth: plotWidth,
          style: const TextStyle(fontSize: 11),
          reservedSize: 28,
        ),
      ),
    );

LineChartBarData _invisible(List<FlSpot> spots) => LineChartBarData(
      spots: spots,
      isCurved: false,
      barWidth: 0,
      color: Colors.transparent,
      dotData: const FlDotData(show: false),
    );

// ---------------------------------------------------------------------------
// 1. Bodyweight: observed + forecast
// ---------------------------------------------------------------------------

class _BwForecastChart extends StatelessWidget {
  final SimResult result;
  final List<WeightRow> daily;
  final DateTime today;
  final double band;

  /// Observed history shown before t0.
  static const _observedDays = 91;

  const _BwForecastChart({
    super.key,
    required this.result,
    required this.daily,
    required this.today,
    required this.band,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final weeks = result.weeks;
    if (weeks.isEmpty) return const SizedBox.shrink();
    final t0 = weeks.first.monday;
    final windowStart = t0.subtract(const Duration(days: _observedDays));
    final xMin = _x(windowStart);
    final xMax = _x(weeks.last.monday) + 7;

    final visibleDaily = [
      for (final w in daily)
        if (!w.date.isBefore(windowStart) && !w.date.isAfter(today)) w,
    ];
    final avg = [
      for (final w in sevenDayAvgSeries(daily))
        if (!w.date.isBefore(windowStart) && !w.date.isAfter(today)) w,
    ];

    final dailySpots = [
      for (final w in visibleDaily) FlSpot(_x(w.date), w.weightLbs),
    ];
    final avgSpots = [for (final w in avg) FlSpot(_x(w.date), w.weightLbs)];
    final forecastSpots = [
      for (final w in weeks) FlSpot(_x(w.monday), w.bw),
    ];
    final upper = [
      for (final w in weeks) FlSpot(_x(w.monday), w.bw + band),
    ];
    final lower = [
      for (final w in weeks) FlSpot(_x(w.monday), w.bw - band),
    ];

    final ys = [
      for (final s in dailySpots) s.y,
      for (final s in avgSpots) s.y,
      for (final s in upper) s.y,
      for (final s in lower) s.y,
    ];
    final yMin = ys.reduce(math.min);
    final yMax = ys.reduce(math.max);
    final yPad = ((yMax - yMin).abs() * 0.08).clamp(0.5, 5.0);

    final bars = <LineChartBarData>[
      _invisible(upper), // 0
      _invisible(lower), // 1
      if (dailySpots.isNotEmpty)
        LineChartBarData(
          spots: dailySpots,
          isCurved: false,
          barWidth: 1,
          color: scheme.primary.withValues(alpha: 0.25),
          dotData: FlDotData(
            show: true,
            getDotPainter: (spot, pct, bar, i) => FlDotCirclePainter(
              radius: 1.8,
              color: scheme.primary.withValues(alpha: 0.35),
              strokeWidth: 0,
            ),
          ),
        ),
      if (avgSpots.isNotEmpty)
        LineChartBarData(
          spots: avgSpots,
          isCurved: false,
          barWidth: 2.5,
          color: scheme.primary,
          dotData: const FlDotData(show: false),
        ),
      LineChartBarData(
        spots: forecastSpots,
        isCurved: false,
        barWidth: 2,
        color: scheme.primary,
        dashArray: [6, 4],
        dotData: const FlDotData(show: false),
      ),
    ];

    return SizedBox(
      height: 220,
      child: LayoutBuilder(
        builder: (context, constraints) => LineChart(
          LineChartData(
            minX: xMin,
            maxX: xMax,
            minY: yMin - yPad,
            maxY: yMax + yPad,
            clipData: const FlClipData.all(),
            gridData: const FlGridData(show: true, drawVerticalLine: false),
            borderData: FlBorderData(show: false),
            rangeAnnotations: RangeAnnotations(
              verticalRangeAnnotations: _phaseBands(scheme, result),
            ),
            titlesData: _titles(
              xMin: xMin,
              xMax: xMax,
              plotWidth: (constraints.maxWidth - 40).clamp(1, 10000),
            ),
            betweenBarsData: [
              BetweenBarsData(
                fromIndex: 0,
                toIndex: 1,
                color: scheme.primary.withValues(alpha: 0.10),
              ),
            ],
            lineBarsData: bars,
            lineTouchData: const LineTouchData(enabled: false),
          ),
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final ObservedWeightStats stats;

  const _StatsRow({required this.stats});

  @override
  Widget build(BuildContext context) {
    String signed(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)}';
    Widget stat(String label, String value) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: AppText.value(context)),
              Text(label, style: AppText.micro(context)),
            ],
          ),
        );
    return Row(
      children: [
        stat(
          '7-day avg',
          stats.bw7dAvg == null
              ? '—'
              : '${stats.bw7dAvg!.toStringAsFixed(1)} lb',
        ),
        stat(
          'rate / wk',
          stats.bwRateLbWk == null ? '—' : '${signed(stats.bwRateLbWk!)} lb',
        ),
        stat(
          '3-wk change',
          stats.bw3wkChange == null ? '—' : '${signed(stats.bw3wkChange!)} lb',
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Levers
// ---------------------------------------------------------------------------

class _LeverCard extends StatelessWidget {
  final SimLevers levers;
  final LeverRanges ranges;
  final bool atDefaults;
  final ValueChanged<SimLevers> onChanged;
  final VoidCallback onReset;

  const _LeverCard({
    required this.levers,
    required this.ranges,
    required this.atDefaults,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bulk = levers.bulkRateLbWk;

    Widget slider({
      required Key key,
      required String label,
      required String valueText,
      required double value,
      required double min,
      required double max,
      required ValueChanged<double> onValue,
    }) {
      final divisions = ((max - min) / 0.05).round();
      return Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(label, style: AppText.tag(context)),
          ),
          Expanded(
            child: Slider(
              key: key,
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions <= 0 ? null : divisions,
              onChanged: onValue,
            ),
          ),
          SizedBox(
            width: 78,
            child: Text(
              valueText,
              textAlign: TextAlign.right,
              style: AppText.value(context),
            ),
          ),
        ],
      );
    }

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('LEVERS', style: AppText.title(context)),
                ),
                if (!atDefaults)
                  ActionChip(
                    key: const ValueKey('forecast-reset'),
                    label: const Text('Reset to program'),
                    visualDensity: VisualDensity.compact,
                    onPressed: onReset,
                  ),
              ],
            ),
            slider(
              key: const ValueKey('forecast-bulk-slider'),
              label: 'bulk lb/wk',
              // Null lever = the program's declared block rates
              // (0.4 / 0.2); the slider parks at 0.4 until touched.
              valueText: bulk == null ? 'blocks' : bulk.toStringAsFixed(2),
              value: bulk ?? 0.4,
              min: ranges.bulkRateLbWk.min,
              max: ranges.bulkRateLbWk.max,
              onValue: (v) => onChanged(SimLevers(
                bulkRateLbWk: v,
                cutRateLbWk: levers.cutRateLbWk,
                climbFrequency: levers.climbFrequency,
                horizonYears: levers.horizonYears,
              )),
            ),
            slider(
              key: const ValueKey('forecast-cut-slider'),
              label: 'cut lb/wk',
              valueText: levers.cutRateLbWk.toStringAsFixed(2),
              value: levers.cutRateLbWk,
              min: ranges.cutRateLbWk.min,
              max: ranges.cutRateLbWk.max,
              onValue: (v) => onChanged(SimLevers(
                bulkRateLbWk: bulk,
                cutRateLbWk: v,
                climbFrequency: levers.climbFrequency,
                horizonYears: levers.horizonYears,
              )),
            ),
            const SizedBox(height: 4),
            // Two labeled chip rows (not one) so 360dp reflows instead
            // of overflowing.
            Row(
              children: [
                SizedBox(
                  width: 86,
                  child: Text('climb /wk', style: AppText.tag(context)),
                ),
                for (final f in ranges.climbFrequency) ...[
                  ChoiceChip(
                    key: ValueKey('forecast-freq-$f'),
                    label: Text('$f'),
                    visualDensity: VisualDensity.compact,
                    selected: levers.climbFrequency == f,
                    onSelected: (_) => onChanged(SimLevers(
                      bulkRateLbWk: bulk,
                      cutRateLbWk: levers.cutRateLbWk,
                      climbFrequency: f,
                      horizonYears: levers.horizonYears,
                    )),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                SizedBox(
                  width: 86,
                  child: Text('horizon', style: AppText.tag(context)),
                ),
                for (final y in const [1, 3, 5]) ...[
                  ChoiceChip(
                    key: ValueKey('forecast-horizon-$y'),
                    label: Text('${y}y'),
                    visualDensity: VisualDensity.compact,
                    selected: levers.horizonYears == y,
                    onSelected: (_) => onChanged(SimLevers(
                      bulkRateLbWk: bulk,
                      cutRateLbWk: levers.cutRateLbWk,
                      climbFrequency: levers.climbFrequency,
                      horizonYears: y,
                    )),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Strength forecast
// ---------------------------------------------------------------------------

class _SeriesChips extends StatelessWidget {
  final List<String> available;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  const _SeriesChips({
    required this.available,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: -6,
      children: [
        for (final s in available)
          FilterChip(
            key: ValueKey('forecast-series-$s'),
            label: Text(s),
            visualDensity: VisualDensity.compact,
            selected: selected.contains(s),
            onSelected: (_) => onToggle(s),
          ),
      ],
    );
  }
}

class _StrengthForecastChart extends StatelessWidget {
  final SimResult result;
  final Set<String> series;
  final Map<String, double> maeByLift;

  const _StrengthForecastChart({
    super.key,
    required this.result,
    required this.series,
    required this.maeByLift,
  });

  static Color _seriesColor(ColorScheme scheme, String s) => switch (s) {
        'squat' => scheme.primary,
        'bench' => scheme.tertiary,
        'deadlift' => Colors.teal,
        'press' => Colors.orange.shade800,
        _ => scheme.onSurfaceVariant, // wilks
      };

  /// The Wilks band: Wilks points are linear in the total at fixed bw,
  /// so wilks · (1 ± ΣSBD-MAE / ΣSBD-e1RM) is exact per week.
  double _wilksBand(SimWeek w) {
    var total = 0.0;
    var band = 0.0;
    for (final l in simSbdLifts) {
      total += w.e1rm[l] ?? 0;
      band += maeByLift[l] ?? 0;
    }
    return total <= 0 ? 0 : w.wilks * band / total;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final weeks = result.weeks;
    if (weeks.isEmpty || series.isEmpty) {
      return const SizedBox(
        height: 60,
        child: Center(child: Text('(no series selected)')),
      );
    }
    final xMin = _x(weeks.first.monday);
    final xMax = _x(weeks.last.monday) + 7;

    double? valueOf(SimWeek w, String s) =>
        s == 'wilks' ? w.wilks : w.e1rm[s];
    double bandOf(SimWeek w, String s) =>
        s == 'wilks' ? _wilksBand(w) : (maeByLift[s] ?? 0);

    final bars = <LineChartBarData>[];
    final between = <BetweenBarsData>[];
    final ys = <double>[];
    for (final s in series) {
      final color = _seriesColor(scheme, s);
      final spots = <FlSpot>[];
      final upper = <FlSpot>[];
      final lower = <FlSpot>[];
      for (final w in weeks) {
        final v = valueOf(w, s);
        if (v == null) continue;
        final b = bandOf(w, s);
        final x = _x(w.monday);
        spots.add(FlSpot(x, v));
        upper.add(FlSpot(x, v + b));
        lower.add(FlSpot(x, v - b));
        ys
          ..add(v + b)
          ..add(v - b);
      }
      if (spots.isEmpty) continue;
      bars.add(_invisible(upper));
      bars.add(_invisible(lower));
      between.add(BetweenBarsData(
        fromIndex: bars.length - 2,
        toIndex: bars.length - 1,
        color: color.withValues(alpha: 0.08),
      ));
      bars.add(LineChartBarData(
        spots: spots,
        isCurved: false,
        barWidth: s == 'wilks' ? 2.5 : 2,
        color: color,
        dashArray: [6, 4],
        dotData: const FlDotData(show: false),
      ));
    }
    if (ys.isEmpty) {
      return const SizedBox(
        height: 60,
        child: Center(child: Text('(no data for selection)')),
      );
    }
    final yMin = ys.reduce(math.min);
    final yMax = ys.reduce(math.max);
    final yPad = ((yMax - yMin).abs() * 0.08).clamp(1.0, 20.0);

    return SizedBox(
      height: 220,
      child: LayoutBuilder(
        builder: (context, constraints) => LineChart(
          LineChartData(
            minX: xMin,
            maxX: xMax,
            minY: yMin - yPad,
            maxY: yMax + yPad,
            clipData: const FlClipData.all(),
            gridData: const FlGridData(show: true, drawVerticalLine: false),
            borderData: FlBorderData(show: false),
            rangeAnnotations: RangeAnnotations(
              verticalRangeAnnotations: _phaseBands(scheme, result),
            ),
            titlesData: _titles(
              xMin: xMin,
              xMax: xMax,
              plotWidth: (constraints.maxWidth - 40).clamp(1, 10000),
            ),
            betweenBarsData: between,
            lineBarsData: bars,
            lineTouchData: const LineTouchData(enabled: false),
          ),
        ),
      ),
    );
  }
}

class _DriftTag extends StatelessWidget {
  final List<String> drifted;

  const _DriftTag({required this.drifted});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'model drift: ${drifted.join(', ')} — refit left ±50% of the '
        'declared fit; the declared value is in force.',
        style: AppText.micro(context)?.copyWith(color: scheme.onErrorContainer),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Climbing forecast (offset-anchored)
// ---------------------------------------------------------------------------

class _ClimbForecastChart extends StatelessWidget {
  final SimResult result;
  final double offset;
  final double band;

  const _ClimbForecastChart({
    super.key,
    required this.result,
    required this.offset,
    required this.band,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final weeks = [
      for (final w in result.weeks)
        if (w.gradeP75 != null) w,
    ];
    if (weeks.isEmpty) return const SizedBox.shrink();
    final xMin = _x(weeks.first.monday);
    final xMax = _x(weeks.last.monday) + 7;

    final spots = <FlSpot>[];
    final upper = <FlSpot>[];
    final lower = <FlSpot>[];
    for (final w in weeks) {
      final v = w.gradeP75! + offset;
      final x = _x(w.monday);
      spots.add(FlSpot(x, v));
      upper.add(FlSpot(x, v + band));
      lower.add(FlSpot(x, v - band));
    }
    final ys = [for (final s in upper) s.y, for (final s in lower) s.y];
    final yMin = ys.reduce(math.min);
    final yMax = ys.reduce(math.max);
    final yPad = ((yMax - yMin).abs() * 0.1).clamp(0.2, 1.0);

    return SizedBox(
      height: 160,
      child: LayoutBuilder(
        builder: (context, constraints) => LineChart(
          LineChartData(
            minX: xMin,
            maxX: xMax,
            minY: yMin - yPad,
            maxY: yMax + yPad,
            clipData: const FlClipData.all(),
            gridData: const FlGridData(show: true, drawVerticalLine: false),
            borderData: FlBorderData(show: false),
            rangeAnnotations: RangeAnnotations(
              verticalRangeAnnotations: _phaseBands(scheme, result),
            ),
            titlesData: _titles(
              xMin: xMin,
              xMax: xMax,
              plotWidth: (constraints.maxWidth - 40).clamp(1, 10000),
              yDecimals: 1,
            ),
            betweenBarsData: [
              BetweenBarsData(
                fromIndex: 0,
                toIndex: 1,
                color: scheme.secondary.withValues(alpha: 0.10),
              ),
            ],
            lineBarsData: [
              _invisible(upper),
              _invisible(lower),
              LineChartBarData(
                spots: spots,
                isCurved: false,
                barWidth: 2,
                color: scheme.secondary,
                dashArray: [6, 4],
                dotData: const FlDotData(show: false),
              ),
            ],
            lineTouchData: const LineTouchData(enabled: false),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Milestones (phase boundaries)
// ---------------------------------------------------------------------------

class _MilestoneList extends StatelessWidget {
  final SimResult result;

  const _MilestoneList({required this.result});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final segments = result.segments;
    if (segments.isEmpty) return const SizedBox.shrink();

    String lb(double? v) => v == null ? '—' : v.toStringAsFixed(0);

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MILESTONES — PHASE BOUNDARIES', style: AppText.title(context)),
            const SizedBox(height: 6),
            for (final s in segments)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 64,
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      decoration: BoxDecoration(
                        color: _phaseColor(scheme, s.phase)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        s.phase,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: _phaseColor(scheme, s.phase),
                            ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'ends ${DateFormat("MMM d ''yy").format(s.end)} · '
                            '${s.last.bw.toStringAsFixed(1)} lb · Wilks '
                            '${s.last.wilks.toStringAsFixed(1)}',
                            style: AppText.tag(context),
                          ),
                          Text(
                            'S ${lb(s.last.e1rm['squat'])} · '
                            'B ${lb(s.last.e1rm['bench'])} · '
                            'D ${lb(s.last.e1rm['deadlift'])} · '
                            'P ${lb(s.last.e1rm['press'])}',
                            style: AppText.micro(context),
                          ),
                        ],
                      ),
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
