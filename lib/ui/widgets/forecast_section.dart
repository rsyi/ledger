/// FORECAST section for the Plan tab — the SINGLE-TRAJECTORY program
/// forecast (user directive 2026-09-28: "remove this whole lever-based
/// computation… I want to just stick with this program long-term …
/// the only lever really be based on my caloric intake").
///
/// What changed from the scenario simulator (sim2 §8 UI):
///   * NO levers — the preset chips, the global dials row, the
///     baseline-vs-scenario compare card and the §5 μ branch toggle are
///     REMOVED. The sim runs ONE trajectory: the declared program
///     calendar, extended past its last block as a flat recomp
///     steady-state (sim2ExtendSteadyState — no auto-generated
///     bulk/cut cycles).
///   * NUTRITION IS THE INPUT: the sim's bodyweight rate r and protein
///     dial P come from actual Macrofactor logging (nutrition_model:
///     adaptive maintenance from intake vs the weigh-in trend; r =
///     (14d intake − maintenance)/3500 × 7). The NUTRITION card on top
///     shows 7/14d averages, the maintenance estimate ± band and the
///     implied rate — and carries the ONE what-if lever: a calorie
///     delta stepper (projection only; protein/carbs scale
///     proportionally). No nutrition data → the block-declared rates
///     with an honest note.
///   * MODEL TRACKING: the nightly recalibration (forecast_calibration
///     via the forecast_meta tab) surfaces as "model tracking: on /
///     adjusted `<date>` (`<what moved>`)"; its guarded scales/offset are
///     applied to the local run so app and nightly agree.
///   * The §9.5 parameter sheet STAYS behind its expandable — it is
///     PROVENANCE (every constant with value/prior/source), not a
///     lever; edits remain possible for inspection but there is no
///     scenario machinery around them.
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/forecast_calibration.dart' show ForecastMeta;
import '../../services/nutrition_model.dart';
import '../../services/program_metrics.dart' show WeightRow;
import '../../services/program_observed.dart'
    show ObservedWeightStats, sevenDayAvgSeries;
import '../../services/sim2_harness.dart';
import '../../services/sim2_model.dart';
import '../app_text.dart';
import 'chart_bottom_axis.dart';

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// Everything the section needs, assembled by the Plan screen.
class ForecastInputs {
  /// Block calendar from coach/program.yaml (sim2BlocksFromProgramDocs).
  /// The section extends it with the steady-state continuation.
  final List<Sim2Block> blocks;

  /// Observed daily weigh-ins (full history; the chart windows it).
  final List<WeightRow> observedDaily;
  final ObservedWeightStats stats;

  /// The live 7-day-average bodyweight — moves the sim's starting bw
  /// (the capacity seed stays anchored to the Sep-2026 RPE readings).
  final double? observedBw;

  /// The app's current Epley index (SBD e1RM sum) — the INDEX line's
  /// starting point; null falls back to the [log] seed (878).
  final double? observedIndexTotal;

  /// One-year EXPECTATION ranges (program.yaml v10 `expectations_1yr`)
  /// — faint band, "range, not target". Null pre-v10.
  final Sim2Expectations? expectations;

  /// Nutrition summary from local Macrofactor meals (nutrition_model).
  /// Null/empty → projection falls back to the declared block rates.
  final NutritionForecast? nutrition;

  /// Nightly recalibration state (forecast_meta tab). Null → tracking
  /// simply reads "on".
  final ForecastMeta? meta;

  const ForecastInputs({
    required this.blocks,
    this.observedDaily = const [],
    this.stats = const ObservedWeightStats(
      bw7dAvg: null,
      bwRateLbWk: null,
      bw3wkChange: null,
      recentRates: [],
      lastWeighIn: null,
    ),
    this.observedBw,
    this.observedIndexTotal,
    this.expectations,
    this.nutrition,
    this.meta,
  });
}

/// One queued Monte Carlo request (the injectable runner keeps widget
/// tests synchronous; the default runs 200 paths in an isolate).
class Sim2McJob {
  final Sim2Params params;
  final List<Sim2Block> blocks;
  final DateTime start;
  final Map<int, Sim2DialOverrides> blockOverrides;
  final double? observedBw;
  final double? observedIndexTotal;

  const Sim2McJob({
    required this.params,
    required this.blocks,
    required this.start,
    required this.blockOverrides,
    required this.observedBw,
    required this.observedIndexTotal,
  });
}

typedef Sim2McRunner = Future<Sim2McSummary> Function(Sim2McJob job);

Future<Sim2McSummary> _isolateMcRunner(Sim2McJob j) => sim2MonteCarloInIsolate(
  params: j.params,
  blocks: j.blocks,
  start: j.start,
  blockOverrides: j.blockOverrides,
  observedBw: j.observedBw,
  observedIndexTotal: j.observedIndexTotal,
);

// ---------------------------------------------------------------------------
// The section
// ---------------------------------------------------------------------------

class ForecastSection extends StatefulWidget {
  final ForecastInputs inputs;
  final DateTime today;

  /// Injectable MC runner (tests pass a synchronous one); default runs
  /// the 200 paths via Isolate.run — never on the UI thread.
  final Sim2McRunner mcRunner;

  /// Weeks of flat recomp continuation appended after the declared
  /// calendar ("stick with this program long-term").
  final int steadyStateWeeks;

  const ForecastSection({
    super.key,
    required this.inputs,
    required this.today,
    this.mcRunner = _isolateMcRunner,
    this.steadyStateWeeks = 52,
  });

  @override
  State<ForecastSection> createState() => _ForecastSectionState();
}

class _ForecastSectionState extends State<ForecastSection> {
  late Sim2Params _params;
  late List<Sim2Block> _blocks;
  bool _showCapacity = false;

  /// The ONE lever: kcal/day what-if on the projection.
  double _calorieDelta = 0;
  static const _deltaStepKcal = 100.0;

  late DateTime _start;
  late Sim2Run _run;
  Sim2McSummary? _mc;
  int _mcToken = 0;

  /// Fitted params with the nightly recalibration scales applied —
  /// the baseline the param sheet's EDITED marker compares against.
  Sim2Params _recalibratedFitted() {
    final p = Sim2Params.fitted();
    final meta = widget.inputs.meta;
    if (meta != null) {
      p.a *= meta.aScale;
      p.b *= meta.bScale;
    }
    return p;
  }

  /// Nutrition with the nightly maintenance offset + the local delta.
  NutritionForecast? get _nutrition {
    final n = widget.inputs.nutrition;
    if (n == null) return null;
    return n
        .withMaintenanceOffset(widget.inputs.meta?.maintenanceOffsetKcal ?? 0)
        .withDelta(_calorieDelta);
  }

  /// The nutrition-derived dial overrides (r + P), scoped to the
  /// CURRENT block only — later blocks keep the declared calendar
  /// rates ("phase declarations stay": today's eating predicts the
  /// current phase, it doesn't rewrite next year's plan). Empty when
  /// the data can't project (declared block rates apply throughout).
  Map<int, Sim2DialOverrides> get _blockOverrides {
    final n = _nutrition;
    if (n == null || !n.canProject) return const {};
    final bw =
        widget.inputs.observedBw ?? widget.inputs.stats.bw7dAvg ?? sim2SeedBw;
    final currentN =
        sim2CurrentBlockN(_blocks, widget.today) ?? _blocks.first.n;
    return {
      currentN: Sim2DialOverrides(
        r: n.rProjectedLbWk,
        p: n.proteinGPerLb(bw),
      ),
    };
  }

  bool get _nutritionDriven => _blockOverrides.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _params = _recalibratedFitted();
    _blocks = sim2ExtendSteadyState(
      widget.inputs.blocks,
      extraWeeks: widget.steadyStateWeeks,
    );
    _start = sim2StartMonday(widget.today);
    // During a cut the EXPRESSED line sags by design (deficit +
    // attempt-gate); the capacity line is the honest progress signal —
    // show it by default there (user request, 2026-09-28).
    final day = DateTime.utc(
      widget.today.year,
      widget.today.month,
      widget.today.day,
    );
    _showCapacity = widget.inputs.blocks.any(
      (b) =>
          b.emphasis == 'cut' && !day.isBefore(b.start) && !day.isAfter(b.end),
    );
    _recompute();
  }

  void _recompute() {
    // Deterministic runs are synchronous — ~170 weekly steps, safe on
    // stepper taps.
    _run = sim2Run(
      params: _params,
      blocks: _blocks,
      start: _start,
      blockOverrides: _blockOverrides,
      observedBw: widget.inputs.observedBw,
      observedIndexTotal: widget.inputs.observedIndexTotal,
    );
    _kickMc();
  }

  /// 200-path MC off the UI thread; deterministic lines render
  /// immediately, the P(V8) chip fills in when it lands.
  void _kickMc() {
    final token = ++_mcToken;
    _mc = null;
    widget
        .mcRunner(
          Sim2McJob(
            params: _params.copy(),
            blocks: _blocks,
            start: _start,
            blockOverrides: _blockOverrides,
            observedBw: widget.inputs.observedBw,
            observedIndexTotal: widget.inputs.observedIndexTotal,
          ),
        )
        .then((s) {
          if (mounted && token == _mcToken) setState(() => _mc = s);
        });
  }

  void _setDelta(double delta) => setState(() {
    _calorieDelta = delta.clamp(-1000, 1000);
    _recompute();
  });

  void _editParam(Sim2ParamDef def) async {
    final controller = TextEditingController(text: _fmtParam(def.get(_params)));
    final applied = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(def.label, style: Theme.of(ctx).textTheme.titleSmall),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: InputDecoration(
                labelText: 'value [${def.tag}] — prior ${_fmtParam(def.prior)}',
              ),
            ),
            if (def.note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(def.note, style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, double.tryParse(controller.text.trim())),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (applied != null) {
      setState(() {
        def.set(_params, applied);
        _recompute();
      });
    }
  }

  bool get _paramsEdited {
    final base = _recalibratedFitted();
    return sim2ParamDefs.any((d) => d.get(_params) != d.get(base));
  }

  @override
  Widget build(BuildContext context) {
    final horizonLabel = DateFormat("MMM d ''yy").format(_blocks.last.end);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NutritionCard(
          key: const ValueKey('nutrition-card'),
          nutrition: _nutrition,
          delta: _calorieDelta,
          onDelta: _setDelta,
          stepKcal: _deltaStepKcal,
        ),
        const SizedBox(height: 8),
        _SummaryLine(
          key: const ValueKey('sim2-summary'),
          run: _run,
          mc: _mc,
          horizonLabel: horizonLabel,
          meta: widget.inputs.meta,
          nutritionDriven: _nutritionDriven,
        ),
        const SizedBox(height: 8),
        _card(
          context,
          title: 'STRENGTH — EXPRESSED TOTAL',
          trailing: FilterChip(
            key: const ValueKey('sim2-capacity-toggle'),
            label: const Text('capacity'),
            visualDensity: VisualDensity.compact,
            selected: _showCapacity,
            onSelected: (v) => setState(() => _showCapacity = v),
          ),
          child: _strengthBody(context, horizonLabel),
        ),
        const SizedBox(height: 8),
        _foldout(
          context,
          key: 'sim2-fold-body',
          title: 'BODY COMPOSITION',
          child: _bodyCompBody(context),
        ),
        const SizedBox(height: 8),
        _foldout(
          context,
          key: 'sim2-fold-climb',
          title: 'CLIMBING',
          child: _climbBody(context, horizonLabel),
        ),
        const SizedBox(height: 8),
        _foldout(
          context,
          key: 'sim2-fold-vo2',
          title: 'VO2 MAX',
          child: _vo2Body(context),
        ),
        const SizedBox(height: 8),
        _foldout(
          context,
          key: 'sim2-fold-fatigue',
          title: 'FATIGUE BUDGET',
          child: _fatigueBody(context),
        ),
        const SizedBox(height: 8),
        _ParamSheet(
          params: _params,
          edited: _paramsEdited,
          onEdit: _editParam,
          onReset: () => setState(() {
            _params = _recalibratedFitted();
            _recompute();
          }),
        ),
        const SizedBox(height: 6),
        Text(
          'ONE trajectory: the declared program calendar, then a flat '
          'recomp steady-state (no auto bulk/cut cycles). '
          '${_nutritionDriven ? 'r and protein come from logged '
                    'Macrofactor intake (adaptive maintenance); the calorie '
                    'delta above is the only lever.' : 'No projectable '
                    'nutrition data yet — running the declared block rates.'} '
          'sim2 two-layer §2 (S_obs = capacity × expression); the log '
          'calibrates strength + the recovery budget, §3-§6 are priors. '
          'Nightly tracking recalibrates within ±50% (guarded).',
          style: AppText.micro(context),
        ),
      ],
    );
  }

  Widget _strengthBody(BuildContext context, String horizonLabel) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Sim2Chart(
          key: const ValueKey('sim2-expressed-chart'),
          run: _run,
          expectationBand: widget.inputs.expectations?.sbdTotalLb,
          series: [
            if (_showCapacity)
              _ChartSeries(
                [for (final w in _run.weeks) (w.monday, w.sCap)],
                scheme.tertiary,
                width: 1.6,
                dash: const [2, 4],
              ),
            _ChartSeries(
              [for (final w in _run.weeks) (w.monday, w.sIdx)],
              scheme.primary.withValues(alpha: 0.65),
              width: 1.8,
              dash: const [6, 4],
            ),
            _ChartSeries(
              [for (final w in _run.weeks) (w.monday, w.sTrue)],
              scheme.primary,
              width: 2.5,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'true expressed (solid) ${_lb(_run.last.sTrue)} vs app '
          'index (dashed) ${_lb(_run.last.sIdx)} — the index lags '
          'through the attempt gate; the catch-up is measurement, '
          'not physiology${_showCapacity ? ' · capacity (dotted) '
                    '${_lb(_run.last.sCap)}' : ''}',
          style: AppText.micro(context),
        ),
        const SizedBox(height: 2),
        Text(
          'Squat ${_lb(_run.last.squat)} · Bench ${_lb(_run.last.bench)} · '
          'Deadlift ${_lb(_run.last.deadlift)} · '
          'Press ${_lb(_run.last.press)} at $horizonLabel',
          style: AppText.tag(context),
        ),
        if (widget.inputs.expectations?.sbdTotalLb != null)
          Text(
            key: const ValueKey('sim2-expectation-strength'),
            'shaded: SBD '
            '${_lb(widget.inputs.expectations!.sbdTotalLb![0])}–'
            '${_lb(widget.inputs.expectations!.sbdTotalLb![1])}'
            '${widget.inputs.expectations!.ohpLb != null ? ' · OHP '
                      '${_lb(widget.inputs.expectations!.ohpLb![0])}–'
                      '${_lb(widget.inputs.expectations!.ohpLb![1])}' : ''}'
            ' — expectation range, not target',
            style: AppText.micro(context),
          ),
      ],
    );
  }

  Widget _bodyCompBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BwChart(
          key: const ValueKey('sim2-bw-chart'),
          run: _run,
          daily: widget.inputs.observedDaily,
          today: widget.today,
          expectationBand: widget.inputs.expectations?.bodyweightLb,
        ),
        const SizedBox(height: 6),
        if (widget.inputs.expectations?.bodyweightLb != null)
          Text(
            key: const ValueKey('sim2-expectation-bw'),
            'shaded: '
            '${widget.inputs.expectations!.bodyweightLb![0].toStringAsFixed(0)}–'
            '${widget.inputs.expectations!.bodyweightLb![1].toStringAsFixed(0)} lb'
            ' — expectation range, not target',
            style: AppText.micro(context),
          ),
        _StatsRow(stats: widget.inputs.stats),
        const SizedBox(height: 10),
        Text('BF%', style: AppText.tag(context)),
        _Sim2Chart(
          key: const ValueKey('sim2-bf-chart'),
          run: _run,
          height: 130,
          yDecimals: 1,
          expectationBand: widget.inputs.expectations?.bfPct,
          series: [
            _ChartSeries(
              [for (final w in _run.weeks) (w.monday, w.bfPct)],
              scheme.tertiary,
              width: 2.2,
              dash: const [6, 4],
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'deficit lean-loss per the §5 rule (μ=0.30 at the cut rate; '
          'branch resolution waits on the Nov DEXA) · horizon BF '
          '${_run.last.bfPct.toStringAsFixed(1)}% at '
          '${_run.last.bw.toStringAsFixed(1)} lb',
          style: AppText.micro(context),
        ),
      ],
    );
  }

  Widget _climbBody(BuildContext context, String horizonLabel) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Sim2Chart(
          key: const ValueKey('sim2-climb-chart'),
          run: _run,
          height: 150,
          yDecimals: 1,
          series: [
            _ChartSeries(
              [for (final w in _run.weeks) (w.monday, w.c)],
              scheme.secondary,
              width: 2.2,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          key: const ValueKey('sim2-pv8'),
          _mc == null
              ? 'C ${_run.last.c.toStringAsFixed(1)} at horizon · '
                    'P(V8) computing (200 MC paths, off-thread) — '
                    'deterministic line shown'
              : 'C ${_run.last.c.toStringAsFixed(1)} at horizon · '
                    'P(V8 sent by $horizonLabel) '
                    '${(_mc!.pV8Sent * 100).round()}% '
                    '(MC ${_mc!.paths} paths, +'
                    '${_params.sendMargin.toStringAsFixed(1)} send '
                    'margin [log]) · C p20 '
                    '${_mc!.p20C.toStringAsFixed(1)}',
          style: AppText.micro(context),
        ),
      ],
    );
  }

  Widget _vo2Body(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Sim2Chart(
          key: const ValueKey('sim2-vo2-chart'),
          run: _run,
          height: 130,
          series: [
            _ChartSeries(
              [for (final w in _run.weeks) (w.monday, w.vo2)],
              Colors.teal,
              width: 2.2,
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Steady-routine honesty (2026-09-29): the 4x4 stays at one
        // session per week in every block, forever — in the model that
        // holds absolute aerobic capacity level, so the projected score
        // is driven by body weight alone. Observed workload gains at
        // the same heart rate live in the weekly review (tracking
        // layer), deliberately NOT in this projection.
        Text(
          'The plan keeps the 4x4 at one session per week, always — '
          'that holds absolute aerobic capacity level in this model, '
          'so the projected score '
          '(${_run.last.vo2.toStringAsFixed(1)} at the horizon) moves '
          'with body weight alone. Doing more work at the same heart '
          'rate is real progress the weekly review tracks — this '
          'projection does not claim it.',
          style: AppText.micro(context),
        ),
      ],
    );
  }

  Widget _fatigueBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Sim2Chart(
          key: const ValueKey('sim2-f-chart'),
          run: _run,
          height: 130,
          yDecimals: 1,
          redFlagAlpha: 0.16,
          series: [
            _ChartSeries(
              [for (final w in _run.weeks) (w.monday, w.f)],
              scheme.error,
              width: 2.2,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'over-budget weeks: ${_run.overBudgetWeeks}'
          ' — red spans are L > L_cap: the model\'s confidence '
          'collapses there (it is extrapolating into the pattern '
          'that failed).',
          style: AppText.micro(context)?.copyWith(color: scheme.error),
        ),
      ],
    );
  }

  /// One collapsed expandable section.
  Widget _foldout(
    BuildContext context, {
    required String key,
    required String title,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: ValueKey(key),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Text(title, style: AppText.title(context)),
          children: [child],
        ),
      ),
    );
  }

  Widget _card(
    BuildContext context, {
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: AppText.title(context))),
                ?trailing,
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

String _lb(double v) => v.toStringAsFixed(0);
String _fmtParam(double v) {
  if (v == v.roundToDouble() && v.abs() >= 1) return v.toStringAsFixed(0);
  var s = v.toStringAsFixed(4);
  while (s.contains('.') && (s.endsWith('0'))) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

String _signed(double v, {int decimals = 2}) =>
    '${v > 0 ? '+' : ''}${v.toStringAsFixed(decimals)}';

// ---------------------------------------------------------------------------
// Nutrition card — the input surface + the ONE lever
// ---------------------------------------------------------------------------

class _NutritionCard extends StatelessWidget {
  final NutritionForecast? nutrition;
  final double delta;
  final ValueChanged<double> onDelta;
  final double stepKcal;

  const _NutritionCard({
    super.key,
    required this.nutrition,
    required this.delta,
    required this.onDelta,
    required this.stepKcal,
  });

  String _avg(NutritionAvg? a) => a == null
      ? '—'
      : '${a.kcal.round()} kcal · protein ${a.proteinG.round()} · '
            'carbs ${a.carbsG.round()} (${a.loggedDays}d logged)';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = nutrition;
    final m = n?.maintenance;

    Widget row(String label, String value, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 92, child: Text(label, style: AppText.tag(context))),
          Expanded(child: Text(value, key: key, style: AppText.value(context))),
        ],
      ),
    );

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'NUTRITION — THE INPUT (MACROFACTOR)',
              style: AppText.title(context),
            ),
            const SizedBox(height: 6),
            if (n == null || (n.avg7 == null && n.avg14 == null))
              Text(
                'No logged nutrition yet — the projection runs the '
                'program\'s declared block rates until Macrofactor '
                'days land in meals.',
                key: const ValueKey('nutrition-empty'),
                style: AppText.micro(context),
              )
            else ...[
              row('7d avg', _avg(n.avg7)),
              row('14d avg', _avg(n.avg14)),
              row(
                'maintenance',
                m == null
                    ? 'not enough paired days yet (needs $minPairedDays '
                          'logged days with weigh-ins)'
                    : '~${n.effectiveMaintenanceKcal!.round()} ± '
                          '${m.bandKcal.round()} kcal '
                          '(${m.method == 'regression' ? 'regression' : 'energy balance'}, '
                          '${m.pairedDays}d'
                          '${n.maintenanceOffsetKcal != 0 ? ', recal '
                                    '${_signed(n.maintenanceOffsetKcal, decimals: 0)}' : ''})',
                key: const ValueKey('nutrition-maintenance'),
              ),
              row(
                'implied rate',
                n.rCurrentLbWk == null
                    ? '—'
                    : '${_signed(n.rCurrentLbWk!)} lb/wk at current intake',
                key: const ValueKey('nutrition-rate'),
              ),
              const SizedBox(height: 6),
              // The ONE what-if lever: calorie delta on the projection.
              // Wrap, not Row — the reset chip overflows at 360dp.
              Wrap(
                spacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('what-if', style: AppText.tag(context)),
                  const SizedBox(width: 8),
                  IconButton(
                    key: const ValueKey('nutrition-delta-minus'),
                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onDelta(delta - stepKcal),
                  ),
                  Text(
                    '${_signed(delta, decimals: 0)} kcal/day',
                    key: const ValueKey('nutrition-delta-value'),
                    style: AppText.value(context),
                  ),
                  IconButton(
                    key: const ValueKey('nutrition-delta-plus'),
                    icon: const Icon(Icons.add_circle_outline, size: 20),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onDelta(delta + stepKcal),
                  ),
                  if (delta != 0)
                    ActionChip(
                      key: const ValueKey('nutrition-delta-reset'),
                      label: const Text('reset'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onDelta(0),
                    ),
                ],
              ),
              if (delta != 0 && n.canProject)
                Text(
                  'projection at ${n.projectedIntakeKcal!.round()} kcal: '
                  '${_signed(n.rProjectedLbWk!)} lb/wk · '
                  'protein ${n.projectedProteinG!.round()} g · '
                  'carbs ${n.projectedCarbsG!.round()} g '
                  '(macros scaled proportionally)',
                  key: const ValueKey('nutrition-whatif'),
                  style: AppText.micro(context),
                ),
              if (!n.canProject)
                Text(
                  'Projection still runs the declared block rates — the '
                  'maintenance estimate needs more paired days.',
                  key: const ValueKey('nutrition-fallback'),
                  style: AppText.micro(context),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Summary line + model-tracking status
// ---------------------------------------------------------------------------

class _SummaryLine extends StatelessWidget {
  final Sim2Run run;
  final Sim2McSummary? mc;
  final String horizonLabel;
  final ForecastMeta? meta;
  final bool nutritionDriven;

  const _SummaryLine({
    super.key,
    required this.run,
    required this.mc,
    required this.horizonLabel,
    required this.meta,
    required this.nutritionDriven,
  });

  String _tracking() {
    final m = meta;
    if (m == null || !m.adjusted || m.lastEvent == null) {
      return 'model tracking: on';
    }
    final e = m.lastEvent!;
    return 'model tracking: adjusted '
        '${DateFormat('MMM d').format(e.date)} (${e.what})';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Program → $horizonLabel: '
              'total ${_lb(run.last.sTrue)} (index ${_lb(run.last.sIdx)}) · '
              '${run.last.bw.toStringAsFixed(0)} lb · '
              'C ${run.last.c.toStringAsFixed(1)} · '
              'VO2 ${run.last.vo2.toStringAsFixed(0)}'
              '${mc != null ? ' · P(V8) ${(mc!.pV8Sent * 100).round()}%' : ''}',
              style: AppText.value(context),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${_tracking()}'
                '${nutritionDriven ? ' · rate from logged intake' : ' · declared rates (no nutrition data)'}',
                key: const ValueKey('forecast-tracking'),
                style: AppText.tag(context),
              ),
            ),
          ],
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

Color _emphasisColor(ColorScheme scheme, String emphasis) => switch (emphasis) {
  'cut' => scheme.error,
  'reverse' => scheme.tertiary,
  'climbing' => scheme.secondary,
  _ => scheme.primary, // lifting
};

/// Tinted block bands + RED over-budget spans (flag L > L_cap weeks
/// in red). Consecutive red weeks merge into one span.
List<VerticalRangeAnnotation> _annotations(
  ColorScheme scheme,
  Sim2Run run, {
  double redFlagAlpha = 0.08,
}) {
  final out = <VerticalRangeAnnotation>[];
  // block bands
  DateTime? bandStart;
  int? bandBlock;
  String bandEmphasis = '';
  void closeBand(DateTime end) {
    final s = bandStart;
    if (s == null) return;
    out.add(
      VerticalRangeAnnotation(
        x1: _x(s),
        x2: _x(end),
        color: _emphasisColor(scheme, bandEmphasis).withValues(alpha: 0.05),
      ),
    );
  }

  for (final w in run.weeks) {
    if (bandBlock != w.blockN) {
      closeBand(w.monday);
      bandStart = w.monday;
      bandBlock = w.blockN;
      bandEmphasis = w.emphasis;
    }
  }
  if (run.weeks.isNotEmpty) {
    closeBand(run.weeks.last.monday.add(const Duration(days: 7)));
  }
  // red over-budget spans
  DateTime? redStart;
  DateTime? redEnd;
  void closeRed() {
    final s = redStart, e = redEnd;
    if (s == null || e == null) return;
    out.add(
      VerticalRangeAnnotation(
        x1: _x(s),
        x2: _x(e),
        color: scheme.error.withValues(alpha: redFlagAlpha),
      ),
    );
    redStart = null;
  }

  for (final w in run.weeks) {
    if (w.overBudget) {
      redStart ??= w.monday;
      redEnd = w.monday.add(const Duration(days: 7));
    } else {
      closeRed();
    }
  }
  closeRed();
  return out;
}

FlTitlesData _titles({
  required double xMin,
  required double xMax,
  required double plotWidth,
  int yDecimals = 0,
}) => FlTitlesData(
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

class _ChartSeries {
  final List<(DateTime, double)> points;
  final Color color;
  final double width;
  final List<int>? dash;

  const _ChartSeries(this.points, this.color, {this.width = 2, this.dash});
}

/// One weekly-trajectory chart: block bands, red over-budget spans, and
/// the given line series.
class _Sim2Chart extends StatelessWidget {
  final Sim2Run run;
  final List<_ChartSeries> series;
  final double height;
  final int yDecimals;
  final double redFlagAlpha;

  /// Faint horizontal EXPECTATION band ([lo, hi] — program.yaml v10
  /// expectations_1yr; "range, not target"). Included in the y-window.
  final List<double>? expectationBand;

  const _Sim2Chart({
    super.key,
    required this.run,
    required this.series,
    this.height = 200,
    this.yDecimals = 0,
    this.redFlagAlpha = 0.08,
    this.expectationBand,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (run.weeks.isEmpty) return const SizedBox.shrink();
    final xMin = _x(run.weeks.first.monday);
    final xMax = _x(run.weeks.last.monday) + 7;

    final ys = <double>[
      for (final s in series)
        for (final p in s.points) p.$2,
      ...?expectationBand,
    ];
    final yMin = ys.reduce(math.min);
    final yMax = ys.reduce(math.max);
    final yPad = ((yMax - yMin).abs() * 0.08).clamp(0.05, 20.0);

    return SizedBox(
      height: height,
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
              verticalRangeAnnotations: _annotations(
                scheme,
                run,
                redFlagAlpha: redFlagAlpha,
              ),
              horizontalRangeAnnotations: [
                if (expectationBand != null)
                  HorizontalRangeAnnotation(
                    y1: expectationBand![0],
                    y2: expectationBand![1],
                    color: scheme.tertiary.withValues(alpha: 0.09),
                  ),
              ],
            ),
            titlesData: _titles(
              xMin: xMin,
              xMax: xMax,
              plotWidth: (constraints.maxWidth - 40).clamp(1, 10000),
              yDecimals: yDecimals,
            ),
            lineBarsData: [
              for (final s in series)
                LineChartBarData(
                  spots: [for (final p in s.points) FlSpot(_x(p.$1), p.$2)],
                  isCurved: false,
                  barWidth: s.width,
                  color: s.color,
                  dashArray: s.dash,
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
// Bodyweight: observed + forecast
// ---------------------------------------------------------------------------

class _BwChart extends StatelessWidget {
  final Sim2Run run;
  final List<WeightRow> daily;
  final DateTime today;

  /// Faint expectation band [lo, hi] lb ("range, not target").
  final List<double>? expectationBand;

  /// Observed history shown before t0.
  static const _observedDays = 91;

  const _BwChart({
    super.key,
    required this.run,
    required this.daily,
    required this.today,
    this.expectationBand,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final weeks = run.weeks;
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

    final ys = <double>[
      for (final w in visibleDaily) w.weightLbs,
      for (final w in avg) w.weightLbs,
      for (final w in weeks) w.bw,
      ...?expectationBand,
    ];
    final yMin = ys.reduce(math.min);
    final yMax = ys.reduce(math.max);
    final yPad = ((yMax - yMin).abs() * 0.08).clamp(0.5, 5.0);

    return SizedBox(
      height: 200,
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
              verticalRangeAnnotations: _annotations(scheme, run),
              horizontalRangeAnnotations: [
                if (expectationBand != null)
                  HorizontalRangeAnnotation(
                    y1: expectationBand![0],
                    y2: expectationBand![1],
                    color: scheme.tertiary.withValues(alpha: 0.09),
                  ),
              ],
            ),
            titlesData: _titles(
              xMin: xMin,
              xMax: xMax,
              plotWidth: (constraints.maxWidth - 40).clamp(1, 10000),
            ),
            lineBarsData: [
              if (visibleDaily.isNotEmpty)
                LineChartBarData(
                  spots: [
                    for (final w in visibleDaily)
                      FlSpot(_x(w.date), w.weightLbs),
                  ],
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
              if (avg.isNotEmpty)
                LineChartBarData(
                  spots: [for (final w in avg) FlSpot(_x(w.date), w.weightLbs)],
                  isCurved: false,
                  barWidth: 2.5,
                  color: scheme.primary,
                  dotData: const FlDotData(show: false),
                ),
              LineChartBarData(
                spots: [for (final w in weeks) FlSpot(_x(w.monday), w.bw)],
                isCurved: false,
                barWidth: 2,
                color: scheme.primary,
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

class _StatsRow extends StatelessWidget {
  final ObservedWeightStats stats;

  const _StatsRow({required this.stats});

  @override
  Widget build(BuildContext context) {
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
          stats.bwRateLbWk == null ? '—' : '${_signed(stats.bwRateLbWk!)} lb',
        ),
        stat(
          '3-wk change',
          stats.bw3wkChange == null ? '—' : '${_signed(stats.bw3wkChange!)} lb',
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// §9.5 parameter sheet — PROVENANCE, not a lever (kept per directive:
// every constant with value + prior + source tag stays inspectable).
// ---------------------------------------------------------------------------

class _ParamSheet extends StatelessWidget {
  final Sim2Params params;
  final bool edited;
  final ValueChanged<Sim2ParamDef> onEdit;
  final VoidCallback onReset;

  const _ParamSheet({
    required this.params,
    required this.edited,
    required this.onEdit,
    required this.onReset,
  });

  static Color _tagColor(ColorScheme scheme, String tag) => switch (tag) {
    'fit' => scheme.primary,
    'log' => scheme.tertiary,
    'lit' => Colors.teal,
    _ => scheme.outline, // assume
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = <String, List<Sim2ParamDef>>{};
    for (final d in sim2ParamDefs) {
      groups.putIfAbsent(d.group, () => []).add(d);
    }

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey('sim2-params-tile'),
        shape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Text(
          'MODEL PARAMETERS (§9.5)${edited ? ' — EDITED' : ''}',
          style: AppText.title(context),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        children: [
          if (edited)
            Align(
              alignment: Alignment.centerRight,
              child: ActionChip(
                key: const ValueKey('sim2-params-reset'),
                label: const Text('Reset to fitted'),
                visualDensity: VisualDensity.compact,
                onPressed: onReset,
              ),
            ),
          for (final e in groups.entries) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Text(e.key.toUpperCase(), style: AppText.micro(context)),
              ),
            ),
            for (final d in e.value)
              InkWell(
                key: ValueKey('sim2-param-${d.id}'),
                onTap: () => onEdit(d),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(d.label, style: AppText.tag(context)),
                      ),
                      if (d.get(params) != d.prior)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            'prior ${_fmtParam(d.prior)}',
                            style: AppText.micro(context),
                          ),
                        ),
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: _tagColor(
                            scheme,
                            d.tag,
                          ).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          d.tag,
                          style: AppText.micro(context)?.copyWith(
                            color: _tagColor(scheme, d.tag),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        _fmtParam(d.get(params)),
                        style: AppText.value(context),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          const SizedBox(height: 8),
          Text(
            'PROVENANCE sheet, not levers. Tap a row to edit for '
            'inspection — the horizon re-runs instantly; "fitted" here '
            'includes any nightly recalibration scales (guarded ±50%). '
            '[fit] = two-pass fit on the calibration CSVs; '
            '[log]/[lit]/[assume] = anchors, not fits (§3-§6 are all '
            'priors). eDep is pinned by the §9.2 replay checkpoints, '
            'NOT the window fit — editing it moves the horizon but is '
            'not re-validated in-app (tool/sim2_replay.dart).',
            style: AppText.micro(context),
          ),
        ],
      ),
    );
  }
}
