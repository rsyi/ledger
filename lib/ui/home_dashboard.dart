/// Home-screen progress synthesis — four at-a-glance cards, one per
/// progress axis:
///
///   BODY      bw 7-day avg + weekly rate vs the declared target + the
///             Program screen's declared-vs-observed verdict, condensed
///             to a chip. Tap → Program screen.
///   STRENGTH  the four working maxes with 4-week direction arrows from
///             the working_max tab history + pain-cap badges.
///             Tap → Week plan.
///   EXECUTION this week's working / near-max / bench counts vs the
///             program targets, + fired-flag count. Data: the current
///             program_status row (read-only sheet path).
///             Tap → program_status ledger.
///   ENGINE    climbing sessions vs the block allowance, last measured
///             4x4 max HR, today's template one-liner.
///             Tap → program_status ledger.
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
    this.onOpenProgram,
    this.onOpenWeekPlan,
    this.onOpenStatus,
    this.today,
  });

  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
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

class _HomeDashboardState extends State<HomeDashboard> {
  late final DateTime _today;

  // Base futures — each swallows its own errors into null so one dead
  // source never poisons another card.
  late final Future<WmSnapshot?> _wm;
  late final Future<IntentDocs?> _docs;
  late final Future<WeightSeriesResult?> _weights;
  late final Future<List<Map<String, Object?>>?> _status;

  // Derived per-card futures.
  late final Future<_BodyData?> _body;
  late final Future<_ExecData?> _exec;
  late final Future<_EngineData?> _engine;

  @override
  void initState() {
    super.initState();
    _today = widget.today ?? DateTime.now();
    _wm = _guard(() async => widget.wmStore?.snapshot());
    _docs = _guard(() async => widget.provider?.load());
    _weights = _guard(() async => widget.analytics == null
        ? null
        : loadDailyWeighIns(
            analytics: widget.analytics,
            view: widget.weightView,
            repo: widget.weightRepo,
          ));
    _status = _guard(() async =>
        widget.statusRepo == null || widget.statusView == null
            ? null
            : widget.statusRepo!.list(widget.statusView!));
    _body = _computeBody();
    _exec = _computeExec();
    _engine = _computeEngine();
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
    final targetRate =
        (phaseVersion?['target_rate_lb_per_week'] as num?)?.toDouble();
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
        widget.statusRepo == null) {
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
  // BODY
  // -------------------------------------------------------------------------

  Widget _bodyCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _SynthCard(
      label: 'Body',
      onTap: widget.onOpenProgram,
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
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
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
      onTap: widget.onOpenWeekPlan,
      child: FutureBuilder<WmSnapshot?>(
        future: _wm,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Dim('…');
          }
          final trends = liftTrends(snap.data, _today);
          if (snap.data == null ||
              trends.every((t) => t.valueLb == null)) {
            return const _Dim('no working maxes yet');
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final t in trends) _LiftRow(trend: t),
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
      onTap: widget.onOpenStatus,
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
      onTap: widget.onOpenStatus,
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
              if (week != null && !week.isCurrentWeek)
                _WeekOfNote(week: week),
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
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
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

String _fmtSigned(double v) =>
    '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)}';

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

class _LiftRow extends StatelessWidget {
  final LiftTrend trend;
  const _LiftRow({required this.trend});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (glyph, color) = switch (trend.direction) {
      TrendDirection.up => ('↑', Colors.green.shade700),
      TrendDirection.down => ('↓', scheme.error),
      TrendDirection.flat => ('→', scheme.onSurfaceVariant),
      TrendDirection.unknown => ('·', scheme.outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              trend.lift,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Text(
            trend.valueLb == null ? '—' : fmtLb(trend.valueLb!),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
          const SizedBox(width: 4),
          Text(
            glyph,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
          if (trend.painCap) ...[
            const SizedBox(width: 4),
            Icon(Icons.healing_outlined, size: 13, color: scheme.error),
          ],
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
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
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
