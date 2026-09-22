/// Home-screen progress synthesis — PHASE hero + supporting cards.
///
/// PHASE HERO (top, full width): the declared phase's eigenvectors, per
/// `app/dashboards.yaml` `phases:` (services/phase_eigenvectors.dart).
/// coach/phase.yaml's current value selects the set — cut: weight_loss
/// + wilks_stability; bulk: gain_rate + strength_gain +
/// inputs_delivered. Each row: a big verdict chip (green agree / amber
/// drifting / red act), the one number that matters, and a mini
/// sparkline (7-day-avg bodyweight / weekly Wilks with reference+floor
/// guides). Row taps NAVIGATE: weight → Program, strength → the
/// strength domain screen, inputs → the status ledger.
///
/// CONDENSED GRID (below the hero — layout decision 2026-09-21): the
/// old 2x2 four-axis grid folds to STRENGTH + a full-width THIS WEEK
/// strip (EXECUTION and ENGINE merged; one merged detail sheet). The
/// BODY card is dropped in hero mode — the hero's weight row carries
/// its 7d avg + rate + target + verdict and taps through to the same
/// Program screen. BACK-COMPAT: no `phases:` section (or no declared
/// phase, or no GitHub config) → the pre-hero four-card grid renders
/// unchanged, including while the hero future is still loading.
///
/// The four axes (legacy grid):
///
///   BODY      bw 7-day avg + weekly rate vs the declared target + the
///             Program screen's declared-vs-observed verdict, condensed
///             to a chip.
///   STRENGTH  per lift, the three numbers the working-max spec §0 says
///             never to confuse — full labels + age tags (2026-09-22):
///             recent e1RM (best capped e1RM in the last 14 days of
///             real work — light weeks + sub-0.75-effort sets excluded,
///             window widens until it finds something and the age tag
///             tells the story; DISPLAY-ONLY — the §2.5 42-day
///             reference is unchanged internally), working max (the
///             controller setting percentages hang off) with its
///             4-week direction arrow, and the all-time best e1RM from
///             full strength history (cached per session). Every
///             number carries a "3d"/"2w"/"5mo" age tag. Pain caps
///             show as a labeled chip.
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
/// source is missing/offline — the dashboard NEVER blocks the HOME tab
/// (the tracker rows live on the LOG tab since the 4-tab shell). All
/// numeric synthesis lives in services/home_synthesis.dart (pure,
/// tested); this file is layout.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/domain_config.dart' show DomainConfigProvider;
import '../services/home_synthesis.dart';
import '../services/phase_eigenvectors.dart';
import '../services/program_current.dart';
import '../services/program_metrics.dart'
    show GradedSet, StrengthRow, WeightRow, anchorMondayOf, gradeSets;
import '../services/program_observed.dart';
import '../services/program_provider.dart';
import '../services/warehouse_connector.dart';
import '../services/weight_series.dart';
import '../services/wilks.dart' show WilksWeek, weeklyWilksSeries;
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

  /// climbing view (kaya_ascents) + its connector — feeds the LIVE
  /// this-week climb-session count (2026-09-22). Null → the strip's
  /// climb count falls back to the nightly status row.
  final ViewSchema? climbingView;
  final WarehouseConnector? climbingRepo;

  /// dashboards.yaml provider (shared 1 h cache) — feeds the hero's
  /// `phases:` eigenvector config. Null → no hero, legacy grid.
  final DomainConfigProvider? dashboards;

  final VoidCallback? onOpenProgram;
  final VoidCallback? onOpenWeekPlan;
  final VoidCallback? onOpenStatus;

  /// Hero strength-row tap target (the strength domain screen's Wilks
  /// dashboard). Null → falls back to [onOpenProgram].
  final VoidCallback? onOpenStrengthDomain;

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
    this.climbingView,
    this.climbingRepo,
    this.dashboards,
    this.onOpenProgram,
    this.onOpenWeekPlan,
    this.onOpenStatus,
    this.onOpenStrengthDomain,
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

  /// LIVE current-week counts from local rows (2026-09-22) — beats the
  /// nightly status row for the running week's quotas; null when no
  /// strength plumbing exists (quotas fall back to the row).
  final LiveWeekCounts? live;

  const _ExecData({required this.week, required this.targets, this.live});
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

/// STRENGTH card data: the spec-§0 trio per lift, each value paired
/// with the date it was set (→ age tags).
class _StrengthData {
  /// WM value + effective_from + 4-week direction + pain cap, per lift.
  final List<LiftTrend> trends;

  /// recent e1RM: best capped e1RM in the trailing 14 days of real
  /// work (light weeks + effort < 0.75 excluded; window widens until
  /// found), with the date of the set.
  final Map<String, ({double value, DateTime date})> recent;

  /// All-time best e1RM per lift + the date it was set (full history,
  /// session-cached).
  final Map<String, ({double value, DateTime date})> best;

  const _StrengthData({
    required this.trends,
    required this.recent,
    required this.best,
  });

  bool get isEmpty =>
      trends.every((t) => t.valueLb == null) && recent.isEmpty && best.isEmpty;
}

class HomeDashboardState extends State<HomeDashboard> {
  late final DateTime _today;

  /// All-time best e1RMs (+ the dates they were set) are computed from
  /// FULL strength history — once per app session (process-wide),
  /// busted by [reload].
  static Map<String, ({double value, DateTime date})>? _bestE1rmCache;

  /// Test hook.
  @visibleForTesting
  static void clearBestE1rmCache() => _bestE1rmCache = null;

  // Base futures — each swallows its own errors into null so one dead
  // source never poisons another card. Reassigned by [reload].
  late Future<WmSnapshot?> _wm;
  late Future<IntentDocs?> _docs;
  late Future<WeightSeriesResult?> _weights;
  late Future<List<Map<String, Object?>>?> _status;

  /// Mapped strength-ledger rows, shared by the STRENGTH card and the
  /// hero's Wilks eigenvectors (one ledger read per load).
  late Future<List<StrengthRow>> _strengthRows;

  /// Climbing (kaya_ascents) ascent dates — LIVE this-week sessions.
  late Future<List<DateTime>> _climbDates;

  /// LIVE current-week quota counts (2026-09-22): computed from local
  /// rows at render so the strip updates after logging + pull-to-
  /// refresh; the nightly status tab keeps owning completed weeks.
  late Future<LiveWeekCounts?> _live;

  // Derived per-card futures.
  late Future<PhaseHeroData?> _hero;
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
    // Not gated on analytics: loadDailyWeighIns falls back to a direct
    // ledger read when the airlayer path is unavailable or empty.
    _weights = _guard(
      () async => widget.weightView == null
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
    _strengthRows = _loadStrengthRows();
    _climbDates = _loadClimbDates();
    _live = _computeLive();
    _hero = _computeHero();
    _body = _computeBody();
    _strength = _computeStrength();
    _exec = _computeExec();
    _engine = _computeEngine();
  }

  /// Pull-to-refresh entry point (home_screen's RefreshIndicator).
  /// Busts every cache, refires the futures, and completes when the
  /// hero and all cards have their data (so the spinner reflects
  /// reality).
  Future<void> reload() async {
    setState(() => _startLoad(force: true));
    await Future.wait([_hero, _body, _strength, _exec, _engine, _live]);
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

  /// Strength ledger → mapped rows. Errors (ledger unreadable) degrade
  /// to an empty list — the WM column still renders.
  Future<List<StrengthRow>> _loadStrengthRows() async {
    if (widget.strengthRepo == null || widget.strengthView == null) {
      return const [];
    }
    try {
      final recs = await widget.strengthRepo!.list(widget.strengthView!);
      return [for (final r in recs) ?strengthRowFromRecord(r)];
    } catch (_) {
      return const [];
    }
  }

  /// Climbing ledger → ascent dates. Errors / missing plumbing degrade
  /// to an empty list (the strip's climb count falls back to the row).
  Future<List<DateTime>> _loadClimbDates() async {
    if (widget.climbingRepo == null || widget.climbingView == null) {
      return const [];
    }
    try {
      final recs = await widget.climbingRepo!.list(widget.climbingView!);
      final out = <DateTime>[];
      for (final r in recs) {
        final raw = r['date'];
        final d = raw is DateTime
            ? raw
            : DateTime.tryParse(raw?.toString() ?? '');
        if (d != null) out.add(d);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Accounting-week start day (program.yaml v7 `week_start` —
  /// saturday since 2026-09-22). Monday when docs are missing.
  Future<int> _weekStartDay() async =>
      weekStartDayOf(currentVersion((await _docs)?.program));

  /// LIVE current-week counts (sets / near-max / bench days / climb
  /// sessions) from local rows — §2.5 semantics over full history so
  /// the strip agrees with the nightly tab the morning after.
  Future<LiveWeekCounts?> _computeLive() async {
    if (widget.strengthRepo == null && widget.climbingRepo == null) {
      return null;
    }
    final rows = await _strengthRows;
    final climbs = await _climbDates;
    return liveWeekCounts(
      strengthRows: rows,
      climbingDates: climbs,
      today: _today,
      weekStartDay: await _weekStartDay(),
    );
  }

  /// PHASE hero: dashboards.yaml `phases:` config + declared phase +
  /// the shared observed inputs → verdict rows. Null (no config / no
  /// phase / fetch failure) keeps the legacy grid.
  Future<PhaseHeroData?> _computeHero() async {
    final raw = await _guard(() async => widget.dashboards?.loadRaw());
    final phases = parsePhaseEigenvectors(raw);
    if (phases == null) return null;
    final docs = await _docs;
    final phaseVersion = currentVersion(docs?.phase);
    final phase = phaseVersion?['value']?.toString();
    if (phase == null) return null;
    final daily = (await _weights)?.daily ?? const <WeightRow>[];
    final rows = await _strengthRows;
    final wsDay = await _weekStartDay();
    // Actual-max basis (weeklyWilksSeries' default since 2026-09-22) —
    // the hero's wilks_stability verdict grades real lifted numbers,
    // same basis as the strength domain's chart and stat.
    final wilksWeeks = rows.isEmpty || daily.isEmpty
        ? const <WilksWeek>[]
        : weeklyWilksSeries(rows, daily, through: _today, weekStartDay: wsDay);
    final status = await _status;
    final slice = _slice(docs);
    return buildPhaseHero(
      phases: phases,
      phaseValue: phase,
      targetRateLbWk: (phaseVersion?['target_rate_lb_per_week'] as num?)
          ?.toDouble(),
      slice: slice,
      stats: observedWeightStats(daily, _today),
      weightDaily: daily,
      wilksWeeks: wilksWeeks,
      statusWeek: latestStatusWeek(
        status ?? const [],
        _today,
        weekStartDay: wsDay,
      ),
      targets: slice?.targetsInForce ?? const {},
      today: _today,
      live: await _live,
    );
  }

  Future<_StrengthData?> _computeStrength() async {
    final snap = await _wm;
    final rows = await _strengthRows;
    if (snap == null && rows.isEmpty) return null;
    // recent e1RM (2026-09-22): 14-day best of REAL work — light
    // accounting weeks (program week_type via the anchor Monday) and
    // sub-0.75-effort sets excluded. DISPLAY-ONLY; the §2.5 42-day
    // reference feeding the controller/planner is untouched.
    final docs = await _docs;
    final program = docs?.program;
    final wsDay = weekStartDayOf(currentVersion(program));
    String? weekTypeOf(DateTime weekStart) => program == null
        ? null
        : programCurrent(
            program,
            docs?.phase,
            anchorMondayOf(weekStart),
          )?.weekType;
    final graded = rows.isEmpty ? const <GradedSet>[] : gradeSets(rows);
    final recent = <String, ({double value, DateTime date})>{};
    for (final lift in synthesisLifts) {
      final r = recentBestE1rm(
        graded,
        lift,
        _today,
        weekTypeOf: program == null ? null : weekTypeOf,
        weekStartDay: wsDay,
      );
      if (r != null) recent[lift] = r;
    }
    final best = rows.isEmpty
        ? const <String, ({double value, DateTime date})>{}
        : (_bestE1rmCache ??= allTimeBestE1rmsWithDates(rows));
    return _StrengthData(
      trends: liftTrends(snap, _today),
      recent: recent,
      best: best,
    );
  }

  Future<_ExecData?> _computeExec() async {
    final docs = await _docs;
    final status = await _status;
    final live = await _live;
    if (!_hasDocs(docs) && status == null && live == null) return null;
    return _ExecData(
      week: latestStatusWeek(
        status ?? const [],
        _today,
        weekStartDay: await _weekStartDay(),
      ),
      targets: _slice(docs)?.targetsInForce ?? const {},
      live: live,
    );
  }

  Future<_EngineData?> _computeEngine() async {
    final docs = await _docs;
    final status = await _status;
    if (!_hasDocs(docs) && status == null) return null;
    final slice = _slice(docs);
    final wsDay = await _weekStartDay();
    return _EngineData(
      week: latestStatusWeek(status ?? const [], _today, weekStartDay: wsDay),
      climbTarget: slice?.targetsInForce['climbing_sessions'],
      lastFourByFour: lastBike4x4(
        status ?? const [],
        _today,
        weekStartDay: wsDay,
      ),
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
      child: FutureBuilder<PhaseHeroData?>(
        future: _hero,
        builder: (context, snap) {
          final hero = snap.connectionState == ConnectionState.done
              ? snap.data
              : null;
          // No phases config / no declared phase / still loading → the
          // pre-hero four-card grid, unchanged.
          if (hero == null) return _legacyGrid(context);
          return _heroLayout(context, hero);
        },
      ),
    );
  }

  /// PHASE hero on top; the old grid condensed to STRENGTH + a merged
  /// THIS WEEK strip below it (see the library doc for the rationale).
  Widget _heroLayout(BuildContext context, PhaseHeroData hero) {
    return Column(
      children: [
        _HeroCard(hero: hero, onNav: _navigate),
        const SizedBox(height: 8),
        _strengthCard(context),
        const SizedBox(height: 8),
        _weekCard(context),
      ],
    );
  }

  Widget _legacyGrid(BuildContext context) {
    return Column(
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
    );
  }

  /// Hero row taps navigate straight to the owning screen.
  void _navigate(EigenNav nav) {
    switch (nav) {
      case EigenNav.program:
        widget.onOpenProgram?.call();
      case EigenNav.strength:
        (widget.onOpenStrengthDomain ?? widget.onOpenProgram)?.call();
      case EigenNav.status:
        widget.onOpenStatus?.call();
    }
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
    String liftLine(Map<String, ({double value, DateTime date})> m) => m.isEmpty
        ? '—'
        : synthesisLifts
              .where(m.containsKey)
              .map(
                (l) =>
                    '$l ${fmtLb(m[l]!.value.roundToDouble())} '
                    '(${fmtAge(m[l]!.date, _today)})',
              )
              .join(' · ');
    final wmLine = d == null
        ? '—'
        : [
            for (final t in d.trends)
              if (t.valueLb != null)
                '${t.lift} ${fmtLb(t.valueLb!)}'
                    '${t.asOf == null ? '' : ' (${fmtAge(t.asOf!, _today)})'}',
          ].join(' · ');
    final capped = [
      for (final t in d?.trends ?? const <LiftTrend>[])
        if (t.painCap) t.lift,
    ];
    await _showDetailSheet(
      title: 'Strength',
      entries: [
        _DetailEntry(
          label: 'recent e1RM',
          value: liftLine(d?.recent ?? const {}),
          explain:
              'What you\'ve actually shown recently: the best '
              'estimated 1RM over the last 14 days of real work — '
              'deload (light-week) sets and easy sets under 75% effort '
              'don\'t count. When there\'s no real work in the window '
              'it slides back to your newest qualifying set; the age '
              'tag tells you how current the number is.',
        ),
        _DetailEntry(
          label: 'working max',
          value: wmLine.isEmpty ? '—' : wmLine,
          explain:
              'The controller\'s setting that percentages hang off — '
              'not your measured max. Moves on top-set RPE readings, '
              'test singles, and manual overrides (working_max tab). '
              'Arrow = 4-week direction; age = when the current value '
              'took effect.',
        ),
        _DetailEntry(
          label: 'all-time best',
          value: liftLine(d?.best ?? const {}),
          explain:
              'Your best-ever estimated 1RM (Epley, reps capped at '
              '12) over the full strength history — the ceiling the '
              'other two numbers sit under; the age tag says when you '
              'set it.',
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
                  recent: d.recent[t.lift],
                  best: d.best[t.lift],
                  today: _today,
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
          final live = d?.live;
          if (d == null || (week == null && live == null)) {
            return const _Dim('no status data');
          }
          // LIVE current-week counts beat the (stale-all-day) nightly
          // row; the row remains the fallback + the flags source.
          final row = week?.row;
          final t = d.targets;
          double? fromRow(String key) => row == null ? null : asNum(row[key]);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (live == null && week != null && !week.isCurrentWeek)
                _WeekOfNote(week: week),
              _TargetRow(
                label: 'sets',
                done: live?.workingSets.toDouble() ?? fromRow('working_sets'),
                target: t['working_sets'],
              ),
              _TargetRow(
                label: 'near-max',
                done: live?.nearMaxSets.toDouble() ?? fromRow('near_max_sets'),
                target: t['near_max_sets'],
              ),
              _TargetRow(
                label: 'bench days',
                done: live?.benchDays.toDouble() ?? fromRow('bench_days'),
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

  // -------------------------------------------------------------------------
  // THIS WEEK — EXECUTION + ENGINE merged into one strip (hero layout)
  // -------------------------------------------------------------------------

  Future<void> _openWeekSheet() async {
    final d = await _exec;
    final e = await _engine;
    final row = d?.week?.row;
    final live = d?.live;
    final t = d?.targets ?? const <String, Object?>{};
    String fmt(num? v, Object? target) =>
        '${v == null ? '—' : fmtLb(v.toDouble())}/${targetText(target)}';
    String done(String key, Object? target) =>
        fmt(row == null ? null : asNum(row[key]), target);
    final liveClimb = widget.climbingRepo == null
        ? null
        : live?.climbingSessions;
    // Live counts (current accounting week, computed from local rows
    // at open) with the nightly row as fallback — matches the strip.
    const liveSource =
        'Counted LIVE from your logged rows for the current week '
        '(updates the moment you log; the nightly tab keeps history).';

    final flags = row?['flags']?.toString() ?? '';
    final ff = e?.lastFourByFour;
    await _showDetailSheet(
      title: 'This week',
      entries: [
        _DetailEntry(
          label: 'Sets',
          value: live != null
              ? fmt(live.workingSets, t['working_sets'])
              : done('working_sets', t['working_sets']),
          explain:
              'Working sets this week — sets at ≥ 80% of your '
              'reference e1RM. $liveSource The target is the program\'s '
              'targets-in-force (a cut has no volume floor).',
        ),
        _DetailEntry(
          label: 'Near-max',
          value: live != null
              ? fmt(live.nearMaxSets, t['near_max_sets'])
              : done('near_max_sets', t['near_max_sets']),
          explain:
              'Sets at ≥ 95% effort with reps ≤ 8 — the '
              'heavy quota (on the cut: one top single per lift).',
        ),
        _DetailEntry(
          label: 'Bench days',
          value: live != null
              ? fmt(live.benchDays, t['bench_days'])
              : done('bench_days', t['bench_days']),
          explain:
              'Distinct days with bench sets this week. Twice is '
              'the rule in every phase.',
        ),
        _DetailEntry(
          label: 'Climb',
          value: liveClimb != null
              ? fmt(liveClimb, e?.climbTarget)
              : done('climbing_sessions', e?.climbTarget),
          explain:
              'Climbing sessions this week vs the block\'s allowance '
              'from the program (kaya_ascents dates).',
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
          label: 'Flags',
          value: flags.trim().isEmpty ? 'none' : flags,
          explain:
              'Coach rules that fired for this week — evidence and '
              'actions live in the status ledger.',
        ),
        _DetailEntry(
          label: 'Today',
          value: e?.templateLine ?? 'rest / no program',
          explain:
              'Today\'s session from the program\'s weekly template '
              '(block-0 template while the cut runs).',
        ),
      ],
      actionLabel: widget.onOpenStatus == null ? null : 'Open status ledger',
      onAction: widget.onOpenStatus,
    );
  }

  /// Full-width compact strip: the week's four quotas side by side +
  /// today's template line. Replaces the EXECUTION and ENGINE cards in
  /// the hero layout; their explainer entries merge into one sheet.
  Widget _weekCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _SynthCard(
      label: 'This week',
      onTap: _openWeekSheet,
      trailingBuilder: (context) => FutureBuilder<_ExecData?>(
        future: _exec,
        builder: (context, snap) {
          final row = snap.data?.week?.row;
          if (row == null) return const SizedBox.shrink();
          return _FlagChip(count: flagCount(row['flags']));
        },
      ),
      child: FutureBuilder<List<Object?>>(
        future: Future.wait<Object?>([_exec, _engine]),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Dim('…');
          }
          final d = snap.data?[0] as _ExecData?;
          final e = snap.data?[1] as _EngineData?;
          final week = d?.week ?? e?.week;
          final live = d?.live;
          if (week == null && live == null) {
            return const _Dim('no status data');
          }
          // LIVE current-week counts (2026-09-22): the four quotas come
          // from local rows at render — they move the moment a set is
          // logged (reload/pull-to-refresh refires _live). The nightly
          // status row keeps owning completed weeks + the flags chip.
          final row = week?.row;
          final t = d?.targets ?? const <String, Object?>{};
          // Live climb count only when the climbing view is actually
          // plumbed — an unplumbed 0 would lie; fall back to the row.
          final liveClimb = widget.climbingRepo == null
              ? null
              : live?.climbingSessions;
          double? fromRow(String key) => row == null ? null : asNum(row[key]);
          Widget quota(String label, num? done, Object? target) => Expanded(
            child: _TargetRow(
              label: label,
              done: done?.toDouble(),
              target: target,
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (live == null && week != null && !week.isCurrentWeek)
                _WeekOfNote(week: week),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  quota(
                    'sets',
                    live?.workingSets ?? fromRow('working_sets'),
                    t['working_sets'],
                  ),
                  const SizedBox(width: 10),
                  quota(
                    'near-max',
                    live?.nearMaxSets ?? fromRow('near_max_sets'),
                    t['near_max_sets'],
                  ),
                  const SizedBox(width: 10),
                  quota(
                    'bench',
                    live?.benchDays ?? fromRow('bench_days'),
                    t['bench_days'],
                  ),
                  const SizedBox(width: 10),
                  quota(
                    'climb',
                    liveClimb ?? fromRow('climbing_sessions'),
                    e?.climbTarget,
                  ),
                ],
              ),
              if (e?.templateLine != null) ...[
                const SizedBox(height: 5),
                Text(
                  'Today: ${e!.templateLine}',
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

/// Column headers for the STRENGTH card's three spec-§0 numbers —
/// FULL labels (2026-09-22): the abbreviations ("e1RM"/"WM"/"best")
/// made the three numbers read as one.
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
            child: Text(
              'recent e1RM',
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          Expanded(
            child: Text(
              'working max',
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          Expanded(
            child: Text(
              'all-time best',
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// One lift's three numbers, aligned under the header's columns, each
/// with an age tag ("3d"/"2w"/"5mo") saying when it was set: recent
/// e1RM (14-day best of real work), working max (controller setting,
/// with its 4-week direction glyph; age = when it took effect),
/// all-time best e1RM.
class _LiftNumbersRow extends StatelessWidget {
  final LiftTrend trend;
  final ({double value, DateTime date})? recent;
  final ({double value, DateTime date})? best;
  final DateTime today;
  const _LiftNumbersRow({
    required this.trend,
    required this.recent,
    required this.best,
    required this.today,
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
    final ageStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontSize: 8.5,
      color: scheme.outline,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    String lb(double? v) => v == null ? '—' : fmtLb(v.roundToDouble());
    // Number + a small dim age tag ("315 3d"). The tag rides along on
    // EVERY number so a stale value can never masquerade as current.
    Widget cell(double? value, DateTime? date, {InlineSpan? suffix}) =>
        Expanded(
          child: Text.rich(
            TextSpan(
              text: lb(value),
              style: numStyle,
              children: [
                ?suffix,
                if (value != null && date != null)
                  TextSpan(text: ' ${fmtAge(date, today)}', style: ageStyle),
              ],
            ),
            textAlign: TextAlign.right,
            maxLines: 1,
          ),
        );
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
          cell(recent?.value, recent?.date),
          cell(
            trend.valueLb,
            trend.asOf,
            suffix: TextSpan(
              text: glyph,
              style: numStyle?.copyWith(color: color),
            ),
          ),
          cell(best?.value, best?.date),
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

// ---------------------------------------------------------------------------
// PHASE hero
// ---------------------------------------------------------------------------

/// Chip + accent colors per verdict (shared by the hero chip and the
/// hero card's border tint).
(Color bg, Color fg) _eigenColors(ColorScheme scheme, EigenVerdict v) =>
    switch (v) {
      EigenVerdict.agree => (
        Colors.green.withValues(alpha: 0.18),
        Colors.green.shade800,
      ),
      EigenVerdict.drifting => (
        Colors.amber.withValues(alpha: 0.25),
        Colors.orange.shade900,
      ),
      EigenVerdict.act => (scheme.errorContainer, scheme.onErrorContainer),
      EigenVerdict.unknown => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };

String _eigenChipText(EigenVerdict v) => switch (v) {
  EigenVerdict.agree => 'ON TRACK',
  EigenVerdict.drifting => 'DRIFTING',
  EigenVerdict.act => 'ACT',
  EigenVerdict.unknown => '—',
};

/// The PHASE hero card: phase + block header, then one tappable row per
/// eigenvector (verdict chip · the one number · sparkline · chevron).
class _HeroCard extends StatelessWidget {
  final PhaseHeroData hero;
  final void Function(EigenNav) onNav;

  const _HeroCard({required this.hero, required this.onNav});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (_, accent) = _eigenColors(scheme, hero.overall);
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 11, 10, 8),
        decoration: BoxDecoration(
          border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.2),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  hero.phaseTitle.toUpperCase(),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    [?hero.blockLine, ?hero.trajectory].join('   ·   '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final row in hero.rows)
              _EigenRowTile(row: row, onTap: () => onNav(row.nav)),
          ],
        ),
      ),
    );
  }
}

/// One eigenvector row inside the hero. Tap navigates to the owning
/// screen (Program / strength domain / status ledger).
class _EigenRowTile extends StatelessWidget {
  final EigenRowData row;
  final VoidCallback onTap;

  const _EigenRowTile({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (_, fg) = _eigenColors(scheme, row.verdict);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            _EigenChip(verdict: row.verdict),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.label.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    row.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // labelSmall so the full "x lb · rate · target" line
                    // fits beside the sparkline on a 360dp screen.
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            if (row.spark.length >= 2) ...[
              const SizedBox(width: 6),
              _Sparkline(
                points: row.spark,
                reference: row.sparkReference,
                floor: row.sparkFloor,
                color: fg,
              ),
            ],
            Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

/// The big verdict chip — fixed min width so the rows' numbers align.
class _EigenChip extends StatelessWidget {
  final EigenVerdict verdict;
  const _EigenChip({required this.verdict});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _eigenColors(Theme.of(context).colorScheme, verdict);
    return Container(
      constraints: const BoxConstraints(minWidth: 66),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _eigenChipText(verdict),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 9.5,
          letterSpacing: 0.6,
          color: fg,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Mini line chart: the eigenvector's series plus faint reference /
/// floor guide lines (Wilks). Pure paint — no interaction.
///
/// Deliberately EXCLUDED from the 2026-09-22 chart range selectors:
/// at 54×24 px there is no room for chip chrome, and the hero's fixed
/// window IS the signal (a glanceable recent-trend cue). The full-size
/// charts behind the chevron (domain Trends / Program) carry the
/// user-controllable ranges.
class _Sparkline extends StatelessWidget {
  final List<({DateTime day, double value})> points;
  final double? reference;
  final double? floor;
  final Color color;

  const _Sparkline({
    required this.points,
    this.reference,
    this.floor,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(54, 24),
      painter: _SparklinePainter(
        points: points,
        reference: reference,
        floor: floor,
        color: color,
        guideColor: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<({DateTime day, double value})> points;
  final double? reference;
  final double? floor;
  final Color color;
  final Color guideColor;

  const _SparklinePainter({
    required this.points,
    required this.reference,
    required this.floor,
    required this.color,
    required this.guideColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    var lo = points.first.value;
    var hi = lo;
    for (final p in points) {
      if (p.value < lo) lo = p.value;
      if (p.value > hi) hi = p.value;
    }
    for (final g in [reference, floor]) {
      if (g != null) {
        if (g < lo) lo = g;
        if (g > hi) hi = g;
      }
    }
    if (hi - lo < 1e-9) {
      lo -= 1;
      hi += 1;
    }
    final t0 = points.first.day.millisecondsSinceEpoch.toDouble();
    final t1 = points.last.day.millisecondsSinceEpoch.toDouble();
    final span = (t1 - t0) < 1 ? 1.0 : t1 - t0;
    double x(DateTime d) =>
        (d.millisecondsSinceEpoch - t0) / span * (size.width - 3) + 1.5;
    double y(double v) =>
        size.height - 2 - (v - lo) / (hi - lo) * (size.height - 4);

    final guide = Paint()
      ..color = guideColor
      ..strokeWidth = 1;
    for (final g in [reference, floor]) {
      if (g != null) {
        // Short dashes so the guides read as thresholds, not data.
        final gy = y(g);
        for (var gx = 0.0; gx < size.width; gx += 5) {
          canvas.drawLine(Offset(gx, gy), Offset(gx + 2.5, gy), guide);
        }
      }
    }

    final line = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(x(points.first.day), y(points.first.value));
    for (final p in points.skip(1)) {
      path.lineTo(x(p.day), y(p.value));
    }
    canvas.drawPath(path, line);
    canvas.drawCircle(
      Offset(x(points.last.day), y(points.last.value)),
      2,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.points != points ||
      old.reference != reference ||
      old.floor != floor ||
      old.color != color ||
      old.guideColor != guideColor;
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
