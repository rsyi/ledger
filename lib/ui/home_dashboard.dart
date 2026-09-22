/// Home-screen progress synthesis — four at-a-glance cards, one per
/// progress axis:
///
///   BODY      bw 7-day avg + weekly rate vs the declared target + the
///             Program screen's declared-vs-observed verdict, condensed
///             to a chip.
///   STRENGTH  per lift, the three numbers the working-max spec §0 says
///             never to confuse: est 1RM (42-day reference — the
///             measurement), WM (the controller setting percentages
///             hang off) with its 4-week direction arrow, and the
///             all-time best e1RM from full strength history (cached
///             per session). Pain caps show as a labeled chip.
///   EXECUTION this week's working / near-max / bench counts vs the
///             program targets, + fired-flag count. Data: the current
///             program_status row (read-only sheet path).
///   ENGINE    climbing sessions vs the block allowance, last measured
///             4x4 max HR, today's template one-liner.
///
/// TAP MODEL: every card opens a bottom-sheet DETAIL view first — each
/// number gets a one-line definition (what it is, where it comes from,
/// its current value) — and the sheet's "Open …" action navigates on
/// (Program / Week plan / status ledger).
///
/// REFRESH: the home screen's pull-to-refresh calls [HomeDashboardState.
/// reload], which busts the wm_store / program-doc / weight-mirror /
/// best-e1RM caches and refires every card future.
///
/// Every card loads independently and degrades to a placeholder when its
/// source is missing/offline — the dashboard NEVER blocks the tracker
/// list below it. All numeric synthesis lives in
/// services/home_synthesis.dart (pure, tested); this file is layout.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/home_synthesis.dart';
import '../services/program_current.dart';
import '../services/program_metrics.dart' show StrengthRow, liftReferencesAsOf;
import '../services/program_observed.dart';
import '../services/program_provider.dart';
import '../services/warehouse_connector.dart';
import '../services/weight_series.dart';
import '../services/wm_store.dart';
import '../services/wm_tabs.dart';

class HomeDashboard extends StatefulWidget {
  /// Working-max controller tabs (3-min cached). Null → STRENGTH renders
  /// its placeholder.
  final WmStore? wmStore;

  /// Intent docs (program/phase, 1 h cached). Null when the build has no
  /// GitHub config.
  final ProgramProvider? provider;

  /// Airlayer + weight view/repo for the BODY series (same path as the
  /// Program screen).
  final AnalyticsEngine? analytics;
  final ViewSchema? weightView;
  final WarehouseConnector? weightRepo;

  /// program_status read-only view + the direct-sheet repo it reads
  /// through (home_screen's readOnlyRepo).
  final ViewSchema? statusView;
  final WarehouseConnector? statusRepo;

  /// strength view + its ledger connector (local engine path) — feeds
  /// the STRENGTH card's est-1RM reference and all-time best e1RM.
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;

  final VoidCallback? onOpenProgram;
  final VoidCallback? onOpenWeekPlan;
  final VoidCallback? onOpenStatus;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  const HomeDashboard({
    super.key,
    this.wmStore,
    this.provider,
    this.analytics,
    this.weightView,
    this.weightRepo,
    this.statusView,
    this.statusRepo,
    this.strengthView,
    this.strengthRepo,
    this.onOpenProgram,
    this.onOpenWeekPlan,
    this.onOpenStatus,
    this.today,
  });

  @override
  State<HomeDashboard> createState() => HomeDashboardState();
}

// ---------------------------------------------------------------------------
// Per-card display models (computed off the shared base futures)
// ---------------------------------------------------------------------------

class _BodyData {
  final ObservedWeightStats stats;
  final double? targetRate;
  final PhaseVerdict? verdict;
  const _BodyData({
    required this.stats,
    required this.targetRate,
    required this.verdict,
  });
}

class _ExecData {
  final StatusWeek? week;
  final Map<String, Object?> targets;
  const _ExecData({required this.week, required this.targets});
}

class _EngineData {
  final StatusWeek? week;
  final Object? climbTarget;
  final ({DateTime weekMonday, double maxHr})? lastFourByFour;
  final String? templateLine;
  const _EngineData({
    required this.week,
    required this.climbTarget,
    required this.lastFourByFour,
    required this.templateLine,
  });
}

/// STRENGTH card data: the spec-§0 trio per lift.
class _StrengthData {
  /// WM value + 4-week direction + pain cap, per lift.
  final List<LiftTrend> trends;

  /// est 1RM: 42-day reference e1RM per lift (the measurement).
  final Map<String, double> est;

  /// All-time best e1RM per lift (full history, session-cached).
  final Map<String, double> best;

  const _StrengthData({
    required this.trends,
    required this.est,
    required this.best,
  });

  bool get isEmpty =>
      trends.every((t) => t.valueLb == null) && est.isEmpty && best.isEmpty;
}

class HomeDashboardState extends State<HomeDashboard> {
  late final DateTime _today;

  /// All-time best e1RMs are computed from FULL strength history —
  /// once per app session (process-wide), busted by [reload].
  static Map<String, double>? _bestE1rmCache;

  /// Test hook.
  @visibleForTesting
  static void clearBestE1rmCache() => _bestE1rmCache = null;

  // Base futures — each swallows its own errors into null so one dead
  // source never poisons another card. Reassigned by [reload].
  late Future<WmSnapshot?> _wm;
  late Future<IntentDocs?> _docs;
  late Future<WeightSeriesResult?> _weights;
  late Future<List<Map<String, Object?>>?> _status;

  // Derived per-card futures.
  late Future<_BodyData?> _body;
  late Future<_StrengthData?> _strength;
  late Future<_ExecData?> _exec;
  late Future<_EngineData?> _engine;

  @override
  void initState() {
    super.initState();
    _today = widget.today ?? DateTime.now();
    _startLoad(force: false);
  }

  /// (Re)fires every future. force=true busts the caches first:
  /// wm_store's 3-min snapshot, ProgramProvider's 1-h doc cache, the
  /// session-wide best-e1RM cache; the weight path re-syncs its local
  /// mirror from the sheet on every call already, and program_status is
  /// an uncached direct sheet read.
  void _startLoad({required bool force}) {
    if (force) {
      ProgramProvider.clearCache();
      _bestE1rmCache = null;
    }
    _wm = _guard(() async => widget.wmStore?.snapshot(force: force));
    _docs = _guard(() async => widget.provider?.load());
    _weights = _guard(
      () async => widget.analytics == null
          ? null
          : loadDailyWeighIns(
              analytics: widget.analytics,
              view: widget.weightView,
              repo: widget.weightRepo,
            ),
    );
    _status = _guard(
      () async => widget.statusRepo == null || widget.statusView == null
          ? null
          : widget.statusRepo!.list(widget.statusView!),
    );
    _body = _computeBody();
    _strength = _computeStrength();
    _exec = _computeExec();
    _engine = _computeEngine();
  }

  /// Pull-to-refresh entry point (home_screen's RefreshIndicator).
  /// Busts every cache, refires the futures, and completes when all
  /// four cards have their data (so the spinner reflects reality).
  Future<void> reload() async {
    setState(() => _startLoad(force: true));
    await Future.wait([_body, _strength, _exec, _engine]);
  }

  static Future<T?> _guard<T>(Future<T?> Function() fn) async {
    try {
      return await fn();
    } catch (_) {
      return null; // offline / missing tab → card placeholder
    }
  }

  ProgramSlice? _slice(IntentDocs? docs) => docs?.program == null
      ? null
      : programCurrent(docs!.program!, docs.phase, _today);

  /// ProgramProvider.load() swallows fetch errors into a record of
  /// nulls — "docs present" means at least one intent file parsed.
  static bool _hasDocs(IntentDocs? docs) =>
      docs?.program != null || docs?.phase != null;

  Future<_BodyData?> _computeBody() async {
    final docs = await _docs;
    final w = await _weights;
    if (!_hasDocs(docs) && (w == null || w.daily.isEmpty)) return null;
    final phaseVersion = currentVersion(docs?.phase);
    final targetRate = (phaseVersion?['target_rate_lb_per_week'] as num?)
        ?.toDouble();
    final stats = observedWeightStats(w?.daily ?? const [], _today);
    final phase = phaseVersion?['value']?.toString();
    final verdict = phase == null
        ? null
        : phaseVerdict(
            phase: phase,
            targetRateLbWk: targetRate,
            recentRates: stats.recentRates,
            bw3wkChange: stats.bw3wkChange,
          );
    return _BodyData(stats: stats, targetRate: targetRate, verdict: verdict);
  }

  Future<_StrengthData?> _computeStrength() async {
    final snap = await _wm;
    var rows = const <StrengthRow>[];
    if (widget.strengthRepo != null && widget.strengthView != null) {
      try {
        final recs = await widget.strengthRepo!.list(widget.strengthView!);
        rows = [for (final r in recs) ?strengthRowFromRecord(r)];
      } catch (_) {
        // Ledger unreadable — the WM column still renders.
      }
    }
    if (snap == null && rows.isEmpty) return null;
    final est = rows.isEmpty
        ? const <String, double>{}
        : liftReferencesAsOf(rows, _today);
    final best = rows.isEmpty
        ? const <String, double>{}
        : (_bestE1rmCache ??= allTimeBestE1rms(rows));
    return _StrengthData(
      trends: liftTrends(snap, _today),
      est: est,
      best: best,
    );
  }

  Future<_ExecData?> _computeExec() async {
    final docs = await _docs;
    final status = await _status;
    if (!_hasDocs(docs) && status == null) return null;
    return _ExecData(
      week: latestStatusWeek(status ?? const [], _today),
      targets: _slice(docs)?.targetsInForce ?? const {},
    );
  }

  Future<_EngineData?> _computeEngine() async {
    final docs = await _docs;
    final status = await _status;
    if (!_hasDocs(docs) && status == null) return null;
    final slice = _slice(docs);
    return _EngineData(
      week: latestStatusWeek(status ?? const [], _today),
      climbTarget: slice?.targetsInForce['climbing_sessions'],
      lastFourByFour: lastBike4x4(status ?? const [], _today),
      templateLine: templateOneLiner(slice),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Builds without any progress plumbing (other brands / kiosk-less
    // generic deploys) get no dashboard at all.
    if (widget.wmStore == null &&
        widget.provider == null &&
        widget.statusRepo == null &&
        widget.strengthRepo == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _bodyCard(context)),
                const SizedBox(width: 8),
                Expanded(child: _strengthCard(context)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _execCard(context)),
                const SizedBox(width: 8),
                Expanded(child: _engineCard(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Detail bottom sheets — every card explains its numbers here first;
  // the sheet's "Open …" action then navigates onward.
  // -------------------------------------------------------------------------

  Future<void> _showDetailSheet({
    required String title,
    required List<_DetailEntry> entries,
    String? actionLabel,
    VoidCallback? onAction,
  }) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  ctx,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [for (final e in entries) _DetailTile(entry: e)],
                  ),
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: Text(actionLabel),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      onAction();
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openBodySheet() async {
    final d = await _body;
    final avg = d?.stats.bw7dAvg;
    final rate = d?.stats.bwRateLbWk;
    await _showDetailSheet(
      title: 'Body',
      entries: [
        _DetailEntry(
          label: '7-day avg',
          value: avg == null ? '—' : '${avg.toStringAsFixed(1)} lb',
          explain:
              'Mean of your weigh-ins over the trailing 7 days. '
              'Source: the weight ledger (Withings sync + manual entries).',
        ),
        _DetailEntry(
          label: 'Weekly rate',
          value: rate == null ? '—' : '${_fmtSigned(rate)} lb/wk',
          explain:
              'This week\'s 7-day average minus last week\'s — '
              'lb per week, negative while losing.',
        ),
        _DetailEntry(
          label: 'Target rate',
          value: d?.targetRate == null
              ? '—'
              : '${_fmtSigned(d!.targetRate!)} lb/wk',
          explain:
              'The declared phase\'s target rate from coach/phase.yaml '
              '— what the weekly rate is supposed to be.',
        ),
        _DetailEntry(
          label: 'Verdict',
          value: d?.verdict == null ? '—' : verdictChipText(d!.verdict!.label),
          explain:
              'Declared phase vs what the scale actually did over '
              'recent weeks — drift/mismatch mirrors the coach\'s '
              'PHASE_MISMATCH rule.',
        ),
      ],
      actionLabel: widget.onOpenProgram == null ? null : 'Open Program',
      onAction: widget.onOpenProgram,
    );
  }

  Future<void> _openStrengthSheet() async {
    final d = await _strength;
    String liftLine(Map<String, double> m) => m.isEmpty
        ? '—'
        : synthesisLifts
              .where(m.containsKey)
              .map((l) => '$l ${fmtLb(m[l]!.roundToDouble())}')
              .join(' · ');
    final wmLine = d == null
        ? '—'
        : [
            for (final t in d.trends)
              if (t.valueLb != null) '${t.lift} ${fmtLb(t.valueLb!)}',
          ].join(' · ');
    final capped = [
      for (final t in d?.trends ?? const <LiftTrend>[])
        if (t.painCap) t.lift,
    ];
    await _showDetailSheet(
      title: 'Strength',
      entries: [
        _DetailEntry(
          label: 'est 1RM (e1RM)',
          value: liftLine(d?.est ?? const {}),
          explain:
              'The measurement: best Epley-estimated 1RM over '
              'qualifying sets (reps ≤ 8) in the trailing 42 days, '
              'from your logged strength rows.',
        ),
        _DetailEntry(
          label: 'WM (working max)',
          value: wmLine.isEmpty ? '—' : wmLine,
          explain:
              'The controller\'s setting that percentages hang off — '
              'not your measured max. Moves on top-set RPE readings, '
              'test singles, and manual overrides (working_max tab). '
              'Arrow = 4-week direction.',
        ),
        _DetailEntry(
          label: 'best (all-time e1RM)',
          value: liftLine(d?.best ?? const {}),
          explain:
              'Your best-ever estimated 1RM (Epley, reps capped at '
              '12) over the full strength history — the ceiling the '
              'other two numbers sit under.',
        ),
        if (capped.isNotEmpty)
          _DetailEntry(
            label: 'pain cap',
            value: capped.join(', '),
            explain:
                'The lift is frozen and top sets are capped at RPE 7 '
                'until two clean sessions.',
          ),
      ],
      // Program screen: its CONFIGURATION section is where WMs are
      // confirmed/overridden (moved out of Integrations 2026-09-21).
      actionLabel: widget.onOpenProgram == null ? null : 'Open Program',
      onAction: widget.onOpenProgram,
    );
  }

  Future<void> _openExecSheet() async {
    final d = await _exec;
    final row = d?.week?.row;
    final t = d?.targets ?? const <String, Object?>{};
    String done(String key, Object? target) {
      final v = row == null ? null : asNum(row[key]);
      return '${v == null ? '—' : fmtLb(v)}/${targetText(target)}';
    }

    final flags = row?['flags']?.toString() ?? '';
    await _showDetailSheet(
      title: 'Execution',
      entries: [
        _DetailEntry(
          label: 'Sets',
          value: done('working_sets', t['working_sets']),
          explain:
              'Working sets this week — sets at ≥ 80% of your '
              'reference e1RM. Source: the nightly program_status row; '
              'the target is the program\'s targets-in-force (a cut has '
              'no volume floor).',
        ),
        _DetailEntry(
          label: 'Near-max',
          value: done('near_max_sets', t['near_max_sets']),
          explain:
              'Sets at ≥ 95% effort with reps ≤ 8 — the '
              'heavy quota (on the cut: one top single per lift).',
        ),
        _DetailEntry(
          label: 'Bench days',
          value: done('bench_days', t['bench_days']),
          explain:
              'Distinct days with bench sets this week. Twice is '
              'the rule in every phase.',
        ),
        _DetailEntry(
          label: 'Flags',
          value: flags.trim().isEmpty ? 'none' : flags,
          explain:
              'Coach rules that fired for this week — evidence and '
              'actions live in the status ledger.',
        ),
      ],
      actionLabel: widget.onOpenStatus == null ? null : 'Open status ledger',
      onAction: widget.onOpenStatus,
    );
  }

  Future<void> _openEngineSheet() async {
    final d = await _engine;
    final week = d?.week;
    final ff = d?.lastFourByFour;
    final climb = week == null ? null : asNum(week.row['climbing_sessions']);
    await _showDetailSheet(
      title: 'Engine',
      entries: [
        _DetailEntry(
          label: 'Climb',
          value:
              '${climb == null ? '—' : fmtLb(climb)}/${targetText(d?.climbTarget)}',
          explain:
              'Climbing sessions this week vs the block\'s allowance '
              'from the program (kaya_ascents dates, nightly rollup).',
        ),
        _DetailEntry(
          label: '4x4 max HR',
          value: ff == null
              ? '—'
              : '${fmtLb(ff.maxHr)} · wk ${DateFormat('MMM d').format(ff.weekMonday)}',
          explain:
              'Highest heart rate hit in the most recent measured '
              '4x4 interval session — the engine\'s top-end output proxy.',
        ),
        _DetailEntry(
          label: 'Today',
          value: d?.templateLine ?? 'rest / no program',
          explain:
              'Today\'s session from the program\'s weekly template '
              '(block-0 template while the cut runs).',
        ),
      ],
      actionLabel: widget.onOpenStatus == null ? null : 'Open status ledger',
      onAction: widget.onOpenStatus,
    );
  }

  // -------------------------------------------------------------------------
  // BODY
  // -------------------------------------------------------------------------

  Widget _bodyCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _SynthCard(
      label: 'Body',
      onTap: _openBodySheet,
      child: FutureBuilder<_BodyData?>(
        future: _body,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Dim('…');
          }
          final d = snap.data;
          if (d == null) return const _Dim('no weigh-in data');
          final avg = d.stats.bw7dAvg;
          final rate = d.stats.bwRateLbWk;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _BigNumber(
                value: avg == null ? '—' : avg.toStringAsFixed(1),
                unit: ' lb',
              ),
              const SizedBox(height: 2),
              Text(
                [
                  rate == null ? '— /wk' : '${_fmtSigned(rate)}/wk',
                  if (d.targetRate != null)
                    'target ${_fmtSigned(d.targetRate!)}',
                ].join(' · '),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              if (d.verdict != null)
                _VerdictChip(verdict: d.verdict!)
              else
                const _Dim('no phase declared'),
            ],
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // STRENGTH
  // -------------------------------------------------------------------------

  Widget _strengthCard(BuildContext context) {
    return _SynthCard(
      label: 'Strength',
      onTap: _openStrengthSheet,
      child: FutureBuilder<_StrengthData?>(
        future: _strength,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Dim('…');
          }
          final d = snap.data;
          if (d == null || d.isEmpty) {
            return const _Dim('no strength data yet');
          }
          final capped = [
            for (final t in d.trends)
              if (t.painCap) t.lift,
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _LiftHeaderRow(),
              for (final t in d.trends)
                _LiftNumbersRow(
                  trend: t,
                  est: d.est[t.lift],
                  best: d.best[t.lift],
                ),
              if (capped.isNotEmpty) ...[
                const SizedBox(height: 4),
                _PainCapChip(lifts: capped),
              ],
            ],
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // EXECUTION
  // -------------------------------------------------------------------------

  Widget _execCard(BuildContext context) {
    return _SynthCard(
      label: 'Execution',
      onTap: _openExecSheet,
      trailingBuilder: (context) => FutureBuilder<_ExecData?>(
        future: _exec,
        builder: (context, snap) {
          final row = snap.data?.week?.row;
          if (row == null) return const SizedBox.shrink();
          return _FlagChip(count: flagCount(row['flags']));
        },
      ),
      child: FutureBuilder<_ExecData?>(
        future: _exec,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Dim('…');
          }
          final d = snap.data;
          final week = d?.week;
          if (d == null || week == null) {
            return const _Dim('no status data');
          }
          final row = week.row;
          final t = d.targets;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!week.isCurrentWeek) _WeekOfNote(week: week),
              _TargetRow(
                label: 'sets',
                done: asNum(row['working_sets']),
                target: t['working_sets'],
              ),
              _TargetRow(
                label: 'near-max',
                done: asNum(row['near_max_sets']),
                target: t['near_max_sets'],
              ),
              _TargetRow(
                label: 'bench days',
                done: asNum(row['bench_days']),
                target: t['bench_days'],
              ),
            ],
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // ENGINE
  // -------------------------------------------------------------------------

  Widget _engineCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _SynthCard(
      label: 'Engine',
      onTap: _openEngineSheet,
      child: FutureBuilder<_EngineData?>(
        future: _engine,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Dim('…');
          }
          final d = snap.data;
          if (d == null) return const _Dim('no status data');
          final week = d.week;
          final ff = d.lastFourByFour;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (week != null && !week.isCurrentWeek) _WeekOfNote(week: week),
              _TargetRow(
                label: 'climb',
                done: week == null
                    ? null
                    : asNum(week.row['climbing_sessions']),
                target: d.climbTarget,
              ),
              const SizedBox(height: 2),
              Text(
                ff == null
                    ? 'no 4x4 logged'
                    : '4x4 max HR ${fmtLb(ff.maxHr)} · wk '
                          '${DateFormat('MMM d').format(ff.weekMonday)}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (d.templateLine != null) ...[
                const SizedBox(height: 5),
                Text(
                  'Today: ${d.templateLine}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

String _fmtSigned(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)}';

// ---------------------------------------------------------------------------
// Shared card chrome + small display widgets
// ---------------------------------------------------------------------------

class _SynthCard extends StatelessWidget {
  final String label;
  final Widget child;
  final VoidCallback? onTap;
  final WidgetBuilder? trailingBuilder;

  const _SynthCard({
    required this.label,
    required this.child,
    this.onTap,
    this.trailingBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    label.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (trailingBuilder != null) trailingBuilder!(context),
                ],
              ),
              const SizedBox(height: 6),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Muted single-line placeholder ("no data", "…").
class _Dim extends StatelessWidget {
  final String text;
  const _Dim(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _BigNumber extends StatelessWidget {
  final String value;
  final String unit;
  const _BigNumber({required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        text: value,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        children: [
          TextSpan(
            text: unit,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _VerdictChip extends StatelessWidget {
  final PhaseVerdict verdict;
  const _VerdictChip({required this.verdict});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (verdict.state) {
      VerdictState.agree => (
        Colors.green.withValues(alpha: 0.18),
        Colors.green.shade800,
      ),
      VerdictState.drift => (
        Colors.amber.withValues(alpha: 0.25),
        Colors.orange.shade900,
      ),
      VerdictState.mismatch => (scheme.errorContainer, scheme.onErrorContainer),
      VerdictState.unknown => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        verdictChipText(verdict.label),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Column headers for the STRENGTH card's three spec-§0 numbers.
class _LiftHeaderRow extends StatelessWidget {
  const _LiftHeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.outline,
      fontSize: 9,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Row(
        children: [
          const SizedBox(width: 44),
          Expanded(
            child: Text('e1RM', textAlign: TextAlign.right, style: style),
          ),
          Expanded(
            child: Text('WM', textAlign: TextAlign.right, style: style),
          ),
          Expanded(
            child: Text('best', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }
}

/// One lift's three numbers: est 1RM (measurement), WM (controller
/// setting, with its 4-week direction glyph), all-time best e1RM.
class _LiftNumbersRow extends StatelessWidget {
  final LiftTrend trend;
  final double? est;
  final double? best;
  const _LiftNumbersRow({
    required this.trend,
    required this.est,
    required this.best,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (glyph, color) = switch (trend.direction) {
      TrendDirection.up => ('↑', Colors.green.shade700),
      TrendDirection.down => ('↓', scheme.error),
      TrendDirection.flat => ('→', scheme.onSurfaceVariant),
      TrendDirection.unknown => ('·', scheme.outline),
    };
    final numStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    String lb(double? v) => v == null ? '—' : fmtLb(v.roundToDouble());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              trend.lift,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(lb(est), textAlign: TextAlign.right, style: numStyle),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: lb(trend.valueLb),
                style: numStyle,
                children: [
                  TextSpan(
                    text: glyph,
                    style: numStyle?.copyWith(color: color),
                  ),
                ],
              ),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            child: Text(lb(best), textAlign: TextAlign.right, style: numStyle),
          ),
        ],
      ),
    );
  }
}

/// Labeled pain-cap chip ("pain cap: deadlift") — replaces the old bare
/// red icon. The detail sheet explains the semantics.
class _PainCapChip extends StatelessWidget {
  final List<String> lifts;
  const _PainCapChip({required this.lifts});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'pain cap: ${lifts.join(', ')}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onErrorContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail-sheet building blocks
// ---------------------------------------------------------------------------

/// One number's explainer: label + current value + one-line definition
/// (what it is and where it comes from).
class _DetailEntry {
  final String label;
  final String value;
  final String explain;
  const _DetailEntry({
    required this.label,
    required this.value,
    required this.explain,
  });
}

class _DetailTile extends StatelessWidget {
  final _DetailEntry entry;
  const _DetailTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                entry.label,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.value,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            entry.explain,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// "done/target" line with a hairline progress bar underneath.
class _TargetRow extends StatelessWidget {
  final String label;
  final double? done;
  final Object? target;

  const _TargetRow({
    required this.label,
    required this.done,
    required this.target,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = weekFraction(done, target);
    final met = fraction != null && fraction >= 1.0;
    final barColor = met ? Colors.green.shade600 : scheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                '${done == null ? '—' : fmtLb(done!)}/${targetText(target)}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction ?? 0,
              minHeight: 3,
              color: barColor,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

class _FlagChip extends StatelessWidget {
  final int count;
  const _FlagChip({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hot = count > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: hot
            ? scheme.errorContainer
            : Colors.green.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        hot ? '$count ⚑' : '0 ⚑',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: hot ? scheme.onErrorContainer : Colors.green.shade800,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// "wk of Sep 14" note shown when the nightly hasn't written the current
/// week's status row yet and the card falls back to the newest one.
class _WeekOfNote extends StatelessWidget {
  final StatusWeek week;
  const _WeekOfNote({required this.week});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        'wk of ${DateFormat('MMM d').format(week.weekMonday)}',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.tertiary,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}
