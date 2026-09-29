/// FORECAST section for the Program tab — training simulator v2.1
/// (spec `airledger/docs/superpowers/specs/2026-09-26-training-simulator-spec.md`
/// §8 + §9.5, fit report §6). SUPERSEDES the v1 sim (sim_core/world_model)
/// section; the chart/layout patterns are kept, the model layer is
/// lib/services/sim2_model.dart + sim2_harness.dart.
///
/// Surfaces, top to bottom:
///   * summary line (horizon numbers, baseline + scenario);
///   * §8 preset chips (Climb more / Lift more / Cardio up / Cardio off /
///     Drop calisthenics / Fast bulk / Stay light);
///   * the dials row (N, W, K, K_lim, H, Z, Z2, Q, r, P) as GLOBAL
///     overrides — per-block overrides are a later wave;
///   * expressed-strength chart: the app-INDEX line AND the true
///     expressed line (the attempt-gate lag is the point — the index
///     catching up is measurement, not physiology), optional capacity
///     line, baseline next to the scenario;
///   * body composition (observed + forecast bw; BF% with the §5 μ
///     branch toggle, pending the Nov DEXA);
///   * climbing C with P(V8) from the §7 Monte Carlo (200 paths OFF the
///     UI thread; the deterministic line shows while it computes);
///   * VO2; fatigue F with over-budget weeks RED-FLAGGED (spec §8:
///     "the model's confidence collapses there");
///   * baseline-vs-scenario horizon table (§8: always report the
///     baseline next to the scenario);
///   * §9.5 parameter sheet: every constant with value + provenance tag
///     ([fit]/[log]/[lit]/[assume]) + prior, editable; §3-§6 are priors
///     (the log only calibrates strength + the budget); eDep carries
///     the replay-pinned caveat (edits are NOT re-validated in-app).
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

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

/// Everything the section needs, assembled by the Program screen.
class ForecastInputs {
  /// Block calendar from coach/program.yaml (sim2BlocksFromProgramDocs).
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

  /// One-year EXPECTATION ranges (program.yaml v10 `expectations_1yr`,
  /// final post-cut spec) — rendered as a faint band next to the sim
  /// trajectory, labeled "expectation range, not target". Null pre-v10.
  final Sim2Expectations? expectations;

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
  });
}

/// One queued Monte Carlo request (the injectable runner keeps widget
/// tests synchronous; the default runs 200 paths in an isolate).
class Sim2McJob {
  final Sim2Params params;
  final List<Sim2Block> blocks;
  final DateTime start;
  final String presetId;
  final Sim2DialOverrides overrides;
  final double? muDeficit;
  final double? observedBw;
  final double? observedIndexTotal;

  const Sim2McJob({
    required this.params,
    required this.blocks,
    required this.start,
    required this.presetId,
    required this.overrides,
    required this.muDeficit,
    required this.observedBw,
    required this.observedIndexTotal,
  });
}

typedef Sim2McRunner = Future<Sim2McSummary> Function(Sim2McJob job);

Future<Sim2McSummary> _isolateMcRunner(Sim2McJob j) => sim2MonteCarloInIsolate(
  params: j.params,
  blocks: j.blocks,
  start: j.start,
  presetId: j.presetId,
  overrides: j.overrides,
  muDeficit: j.muDeficit,
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

  /// Decluttered mode (the Plan tab, 2026-09-28 tab split): the default
  /// view is the summary line + the ONE combined progress chart
  /// (expressed + capacity, capacity ON by default during cuts);
  /// scenarios/levers, body comp, climbing, VO2 and the fatigue budget
  /// fold into expandable sections. False = the original flat layout
  /// (widget tests exercise every control there).
  final bool compact;

  const ForecastSection({
    super.key,
    required this.inputs,
    required this.today,
    this.mcRunner = _isolateMcRunner,
    this.compact = false,
  });

  @override
  State<ForecastSection> createState() => _ForecastSectionState();
}

class _ForecastSectionState extends State<ForecastSection> {
  late Sim2Params _params;
  String _preset = 'baseline';
  Sim2DialOverrides _overrides = const Sim2DialOverrides();

  /// §5 deficit μ branch: null = the §5 rule (μ=0.30 at the cut's
  /// r=−0.75), 0.0 = the spec's own 13%-at-154 anchor. Pending Nov DEXA.
  double? _mu;

  bool _showCapacity = false;

  late DateTime _start;
  late Sim2Run _base;
  late Sim2Run _scen;
  Sim2McSummary? _mcBase;
  Sim2McSummary? _mcScen;
  int _mcToken = 0;

  bool get _isBaseline => _preset == 'baseline' && _overrides.isEmpty;

  @override
  void initState() {
    super.initState();
    _params = Sim2Params.fitted();
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

  Sim2Run _run({required String presetId, required Sim2DialOverrides ov}) =>
      sim2Run(
        params: _params,
        blocks: widget.inputs.blocks,
        start: _start,
        presetId: presetId,
        overrides: ov,
        muDeficit: _mu,
        observedBw: widget.inputs.observedBw,
        observedIndexTotal: widget.inputs.observedIndexTotal,
      );

  void _recompute() {
    // Deterministic runs are synchronous — ~120 weekly steps, safe on
    // slider drag (the W2 contract carried over from v1).
    _base = _run(presetId: 'baseline', ov: const Sim2DialOverrides());
    _scen = _isBaseline ? _base : _run(presetId: _preset, ov: _overrides);
    _kickMc();
  }

  /// 200-path MC off the UI thread; deterministic lines render
  /// immediately, the P(V8)/median chips fill in when it lands.
  void _kickMc() {
    final token = ++_mcToken;
    _mcBase = null;
    _mcScen = null;
    Sim2McJob job(String presetId, Sim2DialOverrides ov) => Sim2McJob(
      params: _params.copy(),
      blocks: widget.inputs.blocks,
      start: _start,
      presetId: presetId,
      overrides: ov,
      muDeficit: _mu,
      observedBw: widget.inputs.observedBw,
      observedIndexTotal: widget.inputs.observedIndexTotal,
    );
    widget.mcRunner(job('baseline', const Sim2DialOverrides())).then((s) {
      if (mounted && token == _mcToken) setState(() => _mcBase = s);
    });
    if (_isBaseline) return; // scenario == baseline, one run is enough
    widget.mcRunner(job(_preset, _overrides)).then((s) {
      if (mounted && token == _mcToken) setState(() => _mcScen = s);
    });
  }

  Sim2McSummary? get _mcForScenario => _isBaseline ? _mcBase : _mcScen;

  void _setPreset(String id) => setState(() {
    _preset = id;
    _recompute();
  });

  void _setOverrides(Sim2DialOverrides ov) => setState(() {
    _overrides = ov;
    _recompute();
  });

  void _setMu(double? mu) => setState(() {
    _mu = mu;
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
    final fitted = Sim2Params.fitted();
    return sim2ParamDefs.any((d) => d.get(_params) != d.get(fitted));
  }

  @override
  Widget build(BuildContext context) {
    final horizonLabel = DateFormat(
      "MMM d ''yy",
    ).format(widget.inputs.blocks.last.end);

    final summary = _SummaryLine(
      key: const ValueKey('sim2-summary'),
      base: _base,
      scen: _scen,
      isBaseline: _isBaseline,
      presetLabel: sim2PresetById(_preset).label,
      mc: _mcForScenario,
      horizonLabel: horizonLabel,
    );
    final strengthCard = _card(
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
    );
    final paramSheet = _ParamSheet(
      params: _params,
      edited: _paramsEdited,
      onEdit: _editParam,
      onReset: () => setState(() {
        _params = Sim2Params.fitted();
        _recompute();
      }),
    );
    final footer = Text(
      'sim2 (two-layer §2: S_obs = capacity × expression). The log '
      'calibrates strength + the recovery budget; §3-§6 (climbing, '
      'VO2, body comp, calisthenics) are PRIORS, labeled so. Dial '
      'overrides are global (per-block overrides: later wave). State '
      'seeded from the Sep 2026 RPE readings [log]'
      '${widget.inputs.observedBw != null ? '; bw + index refreshed '
                'from local history' : ''}.',
      style: AppText.micro(context),
    );

    if (widget.compact) {
      // Plan-tab declutter: summary + THE progress chart up front;
      // everything else folds.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          summary,
          const SizedBox(height: 8),
          strengthCard,
          const SizedBox(height: 8),
          _foldout(
            context,
            key: 'sim2-fold-scenarios',
            title: 'SCENARIOS & LEVERS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PresetChips(selected: _preset, onSelect: _setPreset),
                const SizedBox(height: 8),
                _DialsCard(overrides: _overrides, onChanged: _setOverrides),
                if (!_isBaseline) ...[
                  const SizedBox(height: 8),
                  _CompareCard(
                    key: const ValueKey('sim2-compare'),
                    base: _base,
                    scen: _scen,
                    mcBase: _mcBase,
                    mcScen: _mcScen,
                    presetLabel: sim2PresetById(_preset).label,
                    overridden: !_overrides.isEmpty,
                  ),
                ],
              ],
            ),
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
          paramSheet,
          const SizedBox(height: 6),
          footer,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        summary,
        const SizedBox(height: 8),
        _PresetChips(selected: _preset, onSelect: _setPreset),
        const SizedBox(height: 8),
        _DialsCard(overrides: _overrides, onChanged: _setOverrides),
        const SizedBox(height: 8),
        strengthCard,
        const SizedBox(height: 8),
        _card(
          context,
          title: 'BODY COMPOSITION — OBSERVED + FORECAST',
          child: _bodyCompBody(context),
        ),
        const SizedBox(height: 8),
        _card(
          context,
          title: 'CLIMBING — CONTINUOUS V GRADE',
          child: _climbBody(context, horizonLabel),
        ),
        const SizedBox(height: 8),
        _card(context, title: 'VO2 MAX', child: _vo2Body(context)),
        const SizedBox(height: 8),
        _card(
          context,
          title: 'FATIGUE F — BUDGET RED FLAGS',
          child: _fatigueBody(context),
        ),
        if (!_isBaseline) ...[
          const SizedBox(height: 8),
          _CompareCard(
            key: const ValueKey('sim2-compare'),
            base: _base,
            scen: _scen,
            mcBase: _mcBase,
            mcScen: _mcScen,
            presetLabel: sim2PresetById(_preset).label,
            overridden: !_overrides.isEmpty,
          ),
        ],
        const SizedBox(height: 8),
        paramSheet,
        const SizedBox(height: 6),
        footer,
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
          run: _scen,
          expectationBand: widget.inputs.expectations?.sbdTotalLb,
          series: [
            if (!_isBaseline)
              _ChartSeries(
                [for (final w in _base.weeks) (w.monday, w.sTrue)],
                scheme.outline.withValues(alpha: 0.6),
                width: 1.4,
              ),
            if (_showCapacity)
              _ChartSeries(
                [for (final w in _scen.weeks) (w.monday, w.sCap)],
                scheme.tertiary,
                width: 1.6,
                dash: const [2, 4],
              ),
            _ChartSeries(
              [for (final w in _scen.weeks) (w.monday, w.sIdx)],
              scheme.primary.withValues(alpha: 0.65),
              width: 1.8,
              dash: const [6, 4],
            ),
            _ChartSeries(
              [for (final w in _scen.weeks) (w.monday, w.sTrue)],
              scheme.primary,
              width: 2.5,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'true expressed (solid) ${_lb(_scen.last.sTrue)} vs app '
          'index (dashed) ${_lb(_scen.last.sIdx)} — the index lags '
          'through the attempt gate; the catch-up is measurement, '
          'not physiology${_showCapacity ? ' · capacity (dotted) '
                    '${_lb(_scen.last.sCap)}' : ''}'
          '${_isBaseline ? '' : ' · baseline in grey'}',
          style: AppText.micro(context),
        ),
        const SizedBox(height: 2),
        Text(
          'S ${_lb(_scen.last.squat)} · B ${_lb(_scen.last.bench)} · '
          'D ${_lb(_scen.last.deadlift)} · P ${_lb(_scen.last.press)} '
          'at $horizonLabel',
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
          base: _base,
          scen: _scen,
          isBaseline: _isBaseline,
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
          run: _scen,
          height: 130,
          yDecimals: 1,
          expectationBand: widget.inputs.expectations?.bfPct,
          series: [
            if (!_isBaseline)
              _ChartSeries(
                [for (final w in _base.weeks) (w.monday, w.bfPct)],
                scheme.outline.withValues(alpha: 0.6),
                width: 1.4,
              ),
            _ChartSeries(
              [for (final w in _scen.weeks) (w.monday, w.bfPct)],
              scheme.tertiary,
              width: 2.2,
              dash: const [6, 4],
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Wrap, not Row — the two branch chips overflow at 360dp.
        Wrap(
          spacing: 6,
          runSpacing: -6,
          children: [
            ChoiceChip(
              key: const ValueKey('sim2-mu-rule'),
              label: const Text('μ=0.30 (§5 rule)'),
              visualDensity: VisualDensity.compact,
              selected: _mu == null,
              onSelected: (_) => _setMu(null),
            ),
            ChoiceChip(
              key: const ValueKey('sim2-mu-zero'),
              label: const Text('μ≈0 (13%@154 anchor)'),
              visualDensity: VisualDensity.compact,
              selected: _mu != null,
              onSelected: (_) => _setMu(0.0),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'deficit lean-loss branch — the two readings of §5, '
          'unresolved until the Nov DEXA · horizon BF '
          '${_scen.last.bfPct.toStringAsFixed(1)}% at '
          '${_scen.last.bw.toStringAsFixed(1)} lb',
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
          run: _scen,
          height: 150,
          yDecimals: 1,
          series: [
            if (!_isBaseline)
              _ChartSeries(
                [for (final w in _base.weeks) (w.monday, w.c)],
                scheme.outline.withValues(alpha: 0.6),
                width: 1.4,
              ),
            _ChartSeries(
              [for (final w in _scen.weeks) (w.monday, w.c)],
              scheme.secondary,
              width: 2.2,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          key: const ValueKey('sim2-pv8'),
          _mcForScenario == null
              ? 'C ${_scen.last.c.toStringAsFixed(1)} at horizon · '
                    'P(V8) computing (200 MC paths, off-thread) — '
                    'deterministic line shown'
              : 'C ${_scen.last.c.toStringAsFixed(1)} at horizon · '
                    'P(V8 sent by $horizonLabel) '
                    '${(_mcForScenario!.pV8Sent * 100).round()}% '
                    '(MC ${_mcForScenario!.paths} paths, +'
                    '${_params.sendMargin.toStringAsFixed(1)} send '
                    'margin [log]) · C p20 '
                    '${_mcForScenario!.p20C.toStringAsFixed(1)}',
          style: AppText.micro(context),
        ),
      ],
    );
  }

  Widget _vo2Body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Sim2Chart(
          key: const ValueKey('sim2-vo2-chart'),
          run: _scen,
          height: 130,
          series: [
            if (!_isBaseline)
              _ChartSeries(
                [for (final w in _base.weeks) (w.monday, w.vo2)],
                scheme.outline.withValues(alpha: 0.6),
                width: 1.4,
              ),
            _ChartSeries(
              [for (final w in _scen.weeks) (w.monday, w.vo2)],
              Colors.teal,
              width: 2.2,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'score = Vabs / bw — the bulk lowers it on its own; '
          '${_scen.last.vo2.toStringAsFixed(1)} at horizon '
          '(§4 priors; Cardio up holds ~52)',
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
          run: _scen,
          height: 130,
          yDecimals: 1,
          redFlagAlpha: 0.16,
          series: [
            if (!_isBaseline)
              _ChartSeries(
                [for (final w in _base.weeks) (w.monday, w.f)],
                scheme.outline.withValues(alpha: 0.6),
                width: 1.4,
              ),
            _ChartSeries(
              [for (final w in _scen.weeks) (w.monday, w.f)],
              scheme.error,
              width: 2.2,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'over-budget weeks: ${_scen.overBudgetWeeks}'
          '${_isBaseline ? '' : ' (baseline ${_base.overBudgetWeeks})'}'
          ' — red spans are L > L_cap: the model\'s confidence '
          'collapses there (it is extrapolating into the pattern '
          'that failed).',
          style: AppText.micro(context)?.copyWith(color: scheme.error),
        ),
      ],
    );
  }

  /// One collapsed expandable section (the Plan-tab compact mode).
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

// ---------------------------------------------------------------------------
// Summary line
// ---------------------------------------------------------------------------

class _SummaryLine extends StatelessWidget {
  final Sim2Run base, scen;
  final bool isBaseline;
  final String presetLabel;
  final Sim2McSummary? mc;
  final String horizonLabel;

  const _SummaryLine({
    super.key,
    required this.base,
    required this.scen,
    required this.isBaseline,
    required this.presetLabel,
    required this.mc,
    required this.horizonLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String line(Sim2Run r) =>
        'total ${_lb(r.last.sTrue)} (index ${_lb(r.last.sIdx)}) · '
        '${r.last.bw.toStringAsFixed(0)} lb · '
        'C ${r.last.c.toStringAsFixed(1)} · '
        'VO2 ${r.last.vo2.toStringAsFixed(0)}';
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
              '${isBaseline ? 'Baseline' : presetLabel} → $horizonLabel: '
              '${line(scen)}'
              '${mc != null ? ' · P(V8) ${(mc!.pV8Sent * 100).round()}%' : ''}',
              style: AppText.value(context),
            ),
            if (!isBaseline)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'baseline: ${line(base)}',
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
// Preset chips (§8 table)
// ---------------------------------------------------------------------------

class _PresetChips extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;

  const _PresetChips({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: -6,
      children: [
        for (final p in sim2Presets)
          ChoiceChip(
            key: ValueKey('sim2-preset-${p.id}'),
            label: Text(p.label),
            visualDensity: VisualDensity.compact,
            selected: selected == p.id,
            tooltip: p.blurb,
            onSelected: (_) => onSelect(p.id),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Dials row (global overrides)
// ---------------------------------------------------------------------------

class _DialsCard extends StatelessWidget {
  final Sim2DialOverrides overrides;
  final ValueChanged<Sim2DialOverrides> onChanged;

  const _DialsCard({required this.overrides, required this.onChanged});

  Sim2DialOverrides _with({
    Object? n = _keep,
    Object? w = _keep,
    Object? k = _keep,
    Object? kLim = _keep,
    Object? h = _keep,
    Object? z = _keep,
    Object? z2 = _keep,
    Object? q = _keep,
    Object? r = _keep,
    Object? p = _keep,
  }) {
    double? pick(Object? v, double? cur) =>
        identical(v, _keep) ? cur : v as double?;
    final o = overrides;
    return Sim2DialOverrides(
      n: pick(n, o.n),
      w: pick(w, o.w),
      k: pick(k, o.k),
      kLim: pick(kLim, o.kLim),
      h: pick(h, o.h),
      z: pick(z, o.z),
      z2: pick(z2, o.z2),
      q: pick(q, o.q),
      r: pick(r, o.r),
      p: pick(p, o.p),
    );
  }

  static const Object _keep = Object();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final o = overrides;

    Widget slider({
      required Key key,
      required String label,
      required double? value,
      required double park,
      required double min,
      required double max,
      required double step,
      required ValueChanged<double> onValue,
      String Function(double)? fmt,
    }) {
      final f =
          fmt ?? (v) => v.toStringAsFixed(step < 0.1 ? 2 : (step < 1 ? 1 : 0));
      return Row(
        children: [
          SizedBox(width: 56, child: Text(label, style: AppText.tag(context))),
          Expanded(
            child: Slider(
              key: key,
              value: (value ?? park).clamp(min, max),
              min: min,
              max: max,
              divisions: ((max - min) / step).round(),
              onChanged: onValue,
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              value == null ? 'blocks' : f(value),
              textAlign: TextAlign.right,
              style: AppText.value(context),
            ),
          ),
        ],
      );
    }

    Widget chipRow({
      required String label,
      required String keyPrefix,
      required List<double> values,
      required double? current,
      required ValueChanged<double?> onValue,
      String Function(double)? fmt,
    }) {
      final f = fmt ?? (v) => v.toStringAsFixed(0);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(label, style: AppText.tag(context)),
            ),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: -8,
                children: [
                  for (final v in values)
                    ChoiceChip(
                      key: ValueKey('$keyPrefix-${f(v)}'),
                      label: Text(f(v)),
                      visualDensity: VisualDensity.compact,
                      selected: current == v,
                      // Tapping the selected chip clears back to blocks.
                      onSelected: (_) => onValue(current == v ? null : v),
                    ),
                ],
              ),
            ),
          ],
        ),
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
                  child: Text(
                    'DIALS — GLOBAL OVERRIDES',
                    style: AppText.title(context),
                  ),
                ),
                if (!o.isEmpty)
                  ActionChip(
                    key: const ValueKey('sim2-dials-reset'),
                    label: const Text('Reset to blocks'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onChanged(const Sim2DialOverrides()),
                  ),
              ],
            ),
            slider(
              key: const ValueKey('sim2-dial-n'),
              label: 'N /wk',
              value: o.n,
              park: 6,
              min: 0,
              max: 12,
              step: 1,
              onValue: (v) => onChanged(_with(n: v)),
            ),
            slider(
              key: const ValueKey('sim2-dial-w'),
              label: 'W /wk',
              value: o.w,
              park: 28,
              min: 0,
              max: 40,
              step: 2,
              onValue: (v) => onChanged(_with(w: v)),
            ),
            slider(
              key: const ValueKey('sim2-dial-r'),
              label: 'r lb/wk',
              value: o.r,
              park: 0.4,
              min: -1.0,
              max: 1.0,
              step: 0.05,
              onValue: (v) => onChanged(_with(r: v)),
            ),
            slider(
              key: const ValueKey('sim2-dial-p'),
              label: 'P g/lb',
              value: o.p,
              park: 0.9,
              min: 0.5,
              max: 1.2,
              step: 0.05,
              onValue: (v) => onChanged(_with(p: v)),
            ),
            slider(
              key: const ValueKey('sim2-dial-z2'),
              label: 'Z2 min',
              value: o.z2,
              park: 0,
              min: 0,
              max: 180,
              step: 15,
              onValue: (v) => onChanged(_with(z2: v)),
            ),
            chipRow(
              label: 'K /wk',
              keyPrefix: 'sim2-dial-k',
              values: const [0, 1, 2, 3, 4],
              current: o.k,
              onValue: (v) => onChanged(_with(k: v)),
            ),
            chipRow(
              label: 'K_lim',
              keyPrefix: 'sim2-dial-klim',
              values: const [0, 1, 2],
              current: o.kLim,
              onValue: (v) => onChanged(_with(kLim: v)),
            ),
            chipRow(
              label: 'H',
              keyPrefix: 'sim2-dial-h',
              values: const [0, 1],
              current: o.h,
              onValue: (v) => onChanged(_with(h: v)),
            ),
            chipRow(
              label: 'Z /wk',
              keyPrefix: 'sim2-dial-z',
              values: const [0, 1, 2, 3],
              current: o.z,
              onValue: (v) => onChanged(_with(z: v)),
            ),
            chipRow(
              label: 'Q /wk',
              keyPrefix: 'sim2-dial-q',
              values: const [0, 1, 2, 3],
              current: o.q,
              onValue: (v) => onChanged(_with(q: v)),
            ),
            const SizedBox(height: 2),
            Text(
              '"blocks" = the per-block baseline dials; an override '
              'applies to EVERY week (per-block overrides: later wave). '
              'Tap a selected chip to clear it.',
              style: AppText.micro(context),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared chart plumbing (patterns carried from v1)
// ---------------------------------------------------------------------------

double _x(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch / 86400000;

Color _emphasisColor(ColorScheme scheme, String emphasis) => switch (emphasis) {
  'cut' => scheme.error,
  'reverse' => scheme.tertiary,
  'climbing' => scheme.secondary,
  _ => scheme.primary, // lifting
};

/// Tinted block bands + RED over-budget spans (§8: flag L > L_cap weeks
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
/// the given line series (scenario on top, baseline muted underneath).
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
// Bodyweight: observed + forecast (v1 pattern kept)
// ---------------------------------------------------------------------------

class _BwChart extends StatelessWidget {
  final Sim2Run base, scen;
  final bool isBaseline;
  final List<WeightRow> daily;
  final DateTime today;

  /// Faint expectation band [lo, hi] lb ("range, not target").
  final List<double>? expectationBand;

  /// Observed history shown before t0.
  static const _observedDays = 91;

  const _BwChart({
    super.key,
    required this.base,
    required this.scen,
    required this.isBaseline,
    required this.daily,
    required this.today,
    this.expectationBand,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final weeks = scen.weeks;
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
      if (!isBaseline)
        for (final w in base.weeks) w.bw,
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
              verticalRangeAnnotations: _annotations(scheme, scen),
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
              if (!isBaseline)
                LineChartBarData(
                  spots: [
                    for (final w in base.weeks) FlSpot(_x(w.monday), w.bw),
                  ],
                  isCurved: false,
                  barWidth: 1.4,
                  color: scheme.outline.withValues(alpha: 0.6),
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
// Baseline vs scenario (§8: always report the baseline next to it)
// ---------------------------------------------------------------------------

class _CompareCard extends StatelessWidget {
  final Sim2Run base, scen;
  final Sim2McSummary? mcBase, mcScen;
  final String presetLabel;
  final bool overridden;

  const _CompareCard({
    super.key,
    required this.base,
    required this.scen,
    required this.mcBase,
    required this.mcScen,
    required this.presetLabel,
    required this.overridden,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String pv8(Sim2McSummary? mc) =>
        mc == null ? '…' : '${(mc.pV8Sent * 100).round()}%';

    final rows = <(String, String, String)>[
      ('expressed total', _lb(base.last.sTrue), _lb(scen.last.sTrue)),
      ('capacity', _lb(base.last.sCap), _lb(scen.last.sCap)),
      (
        'BW / BF%',
        '${base.last.bw.toStringAsFixed(0)} / '
            '${base.last.bfPct.toStringAsFixed(1)}',
        '${scen.last.bw.toStringAsFixed(0)} / '
            '${scen.last.bfPct.toStringAsFixed(1)}',
      ),
      ('C', base.last.c.toStringAsFixed(1), scen.last.c.toStringAsFixed(1)),
      ('P(V8 sent)', pv8(mcBase), pv8(mcScen)),
      (
        'VO2',
        base.last.vo2.toStringAsFixed(1),
        scen.last.vo2.toStringAsFixed(1),
      ),
      (
        'muscle-ups M',
        base.last.m.toStringAsFixed(1),
        scen.last.m.toStringAsFixed(1),
      ),
      ('F end', base.last.f.toStringAsFixed(2), scen.last.f.toStringAsFixed(2)),
      ('over-budget wks', '${base.overBudgetWeeks}', '${scen.overBudgetWeeks}'),
    ];

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'BASELINE VS ${presetLabel.toUpperCase()}'
              '${overridden ? ' + DIALS' : ''}',
              style: AppText.title(context),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Expanded(flex: 5, child: SizedBox()),
                Expanded(
                  flex: 3,
                  child: Text(
                    'baseline',
                    textAlign: TextAlign.right,
                    style: AppText.micro(context),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    'scenario',
                    textAlign: TextAlign.right,
                    style: AppText.micro(context),
                  ),
                ),
              ],
            ),
            for (final (label, b, s) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(label, style: AppText.tag(context)),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        b,
                        textAlign: TextAlign.right,
                        style: AppText.tag(context),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Text(
                        s,
                        textAlign: TextAlign.right,
                        style: AppText.value(context),
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

// ---------------------------------------------------------------------------
// §9.5 parameter sheet
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
            'Tap a row to edit — the horizon re-runs instantly. [fit] = '
            'two-pass fit on the calibration CSVs; [log]/[lit]/[assume] '
            '= anchors, not fits (§3-§6 are all priors). eDep is pinned '
            'by the §9.2 replay checkpoints, NOT the window fit (the '
            'window likelihood is flat in it) — editing it here moves '
            'the horizon but is not re-validated against the log; the '
            'replay harness lives in tool/sim2_replay.dart.',
            style: AppText.micro(context),
          ),
        ],
      ),
    );
  }
}
