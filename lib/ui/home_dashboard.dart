/// Home-screen progress synthesis — PHASE hero + supporting cards.
///
/// PHASE HERO (top, full width): the declared phase's eigenvectors, per
/// `app/dashboards.yaml` `phases:` (services/phase_eigenvectors.dart).
/// coach/phase.yaml's current value selects the set — cut: weight_loss
/// + wilks_stability; bulk: gain_rate + strength_gain +
/// inputs_delivered. Each row: a big verdict chip (green agree / amber
/// drifting / red act), the one number that matters, and a mini
/// sparkline (7-day-avg bodyweight / weekly Wilks with reference+floor
/// guides). Row taps: weight → Program, inputs → the status ledger
/// (direct navigation); the STRENGTH row opens its DETAIL SHEET first
/// (2026-09-25 — tap-model parity with the cards): the weekly
/// actual-max Wilks DECOMPOSED into its three constituent lifts
/// (actual weight or a dated "carried from" tag, per-lift kg×coeff
/// points,
/// an exact sum line matching the stat) plus the basis note that
/// reconciles it against the STRENGTH card's 14-day e1RM estimates —
/// the user tried to sum the card's per-lift ·w tags into the hero
/// number and couldn't (e1RM-vs-actual + 14d-vs-weekly, both by
/// design). The sheet's "Open Strength" action navigates on to the
/// strength domain screen.
///
/// CONDENSED GRID (below the hero — layout decision 2026-09-21): the
/// old 2x2 four-axis grid folds to STRENGTH + a full-width THIS WEEK
/// strip (EXECUTION and ENGINE merged; one merged detail sheet).
///
/// THIS WEEK (redesign 2026-09-22, output>>input principle): when
/// dashboards.yaml declares `weekly_drivers:` for the current phase,
/// the strip renders the DRIVER CHECKLIST (services/week_drivers.dart)
/// — the phase's causal inputs, each tied to a named outcome — instead
/// of activity tallies; `sets`/`near-max` quotas are gone from the
/// surface (working_sets stays a program_status/flags concern). The
/// SINGLES driver is READINGS-BASED + PARITY-AWARE since 2026-09-25
/// (user: "a heavy single every two weeks, a lighter stimulus on
/// alternate weeks"): a lift ticks when a working-max top-set reading
/// (tab rows ∪ live extraction, light_week excluded) exists this
/// accounting week; squat/deadlift ticks wear the planned_alternation
/// (H)/(L) tag, and the heavy-single recency line under the pills
/// tracks the two-week heavy rule (config heavy_single_max_days). The
/// climb driver carries the kaya-snapshot honesty tag ("as of …")
/// when the import predates the accounting week. The strip's
/// fired-flag chip is GONE (2026-09-25, output>>input — the user
/// couldn't act on "5 ⚑"): flags stay in the program_status ledger /
/// coach context / briefings, and the strip's sheet points at
/// Program → status. No weekly_drivers →
/// the pre-redesign quota strip renders unchanged. The
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
///   STRENGTH  per lift, TWO columns (rebuild 2026-09-22, twice —
///             user: "just show my numbers from my last bulk here"
///             and "relegate all-time to the click-in view"): recent
///             e1RM (best capped e1RM in the last 14 days of real work
///             — light weeks + sub-0.75-effort sets excluded, window
///             widens until it finds something and the age tag tells
///             the story; DISPLAY-ONLY — the §2.5 42-day reference is
///             unchanged internally) vs the LAST-BULK top — the
///             heaviest weight ACTUALLY lifted inside dashboards.yaml
///             `last_bulk` (any reps ≥ 1, a 405×2 counts as 405 —
///             domain_metrics bestWeightsInWindow; window start
///             derived from the weigh-in trough, services/
///             bulk_window.dart, but explicit + user-editable in the
///             config; NO window → the column is omitted). The
///             ALL-TIME top (allTimeBestWeights, session-cached, same
///             actual convention) moved to the DETAIL SHEET — per-lift
///             lines above the explainer copy. Each value carries its
///             per-lift Wilks points (wilksPointsLb): recent priced at
///             CURRENT bodyweight (7-day avg), the historical tops at
///             the CONTEMPORANEOUS bodyweight — the monthly mean as of
///             the PR's month — which is what makes an old fat-bulk PR
///             comparable. When-tags: recent wears an age ("3d"/"2w"),
///             the bulk/all-time tops wear their PR MONTH ("Jun '25" —
///             clearer for year-old data; the Wilks benchmark's
///             vocabulary). The WORKING MAX column moved OFF this card
///             (it lives on the Program tab's Configuration card; the
///             detail sheet says so). The card is tagged "bulk:
///             actual" (the recent column header already says e1RM;
///             the sheet's basis entry spells out "recent: e1RM ·
///             bulk & top: actual") — two bases on one card, and only
///             the actual tops share the Wilks trend chart's
///             actual-max basis.
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
/// best-weight caches and refires every card future.
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
import '../services/domain_config.dart'
    show DomainConfigProvider, parseLastBulkWindow;
import '../services/domain_metrics.dart'
    show allTimeBestWeights, bestWeightsInWindow;
import '../services/home_synthesis.dart';
import '../services/phase_eigenvectors.dart';
import '../services/program_current.dart';
import '../services/program_metrics.dart'
    show
        GradedSet,
        StrengthRow,
        WeightRow,
        anchorMondayOf,
        gradeSets,
        mondayOf,
        weekStartOf;
import '../services/program_observed.dart';
import '../services/program_provider.dart';
import '../services/recomp_review.dart';
import '../services/warehouse_connector.dart';
import '../services/week_drivers.dart';
import '../services/weight_series.dart';
import '../services/working_max.dart' show extractReadings;
import '../services/wilks.dart'
    show
        WilksLiftPart,
        WilksWeek,
        contemporaneousBodyweightLbs,
        weeklyWilksSeries,
        wilksPointsLb,
        wilksWeekDecomposition;
import '../services/wm_store.dart';
import '../services/wm_tabs.dart';
import 'app_text.dart';

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

  /// meals view + ledger connector — feeds the driver checklist's
  /// protein floor (daily-avg g/lb). Null → that driver stays pending.
  final ViewSchema? mealsView;
  final WarehouseConnector? mealsRepo;

  /// cardio view + ledger connector — feeds the driver checklist's
  /// 4x4 cadence. Null → that driver stays pending.
  final ViewSchema? cardioView;
  final WarehouseConnector? cardioRepo;

  /// calisthenics view + ledger connector — feeds the recomp SKILLS
  /// row (sessions + bests). Null → honest "no data".
  final ViewSchema? calisthenicsView;
  final WarehouseConnector? calisthenicsRepo;

  /// daily_notes view + ledger connector — feeds the recomp RECOVERY
  /// row (sleep/fatigue/soreness/pain subjectives, 2026-09-27 schema).
  final ViewSchema? notesView;
  final WarehouseConnector? notesRepo;

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
    this.mealsView,
    this.mealsRepo,
    this.cardioView,
    this.cardioRepo,
    this.calisthenicsView,
    this.calisthenicsRepo,
    this.notesView,
    this.notesRepo,
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

/// One STRENGTH-card value: pounds + the date it was set (→ age tag) +
/// its per-lift Wilks points (null when no bodyweight covers the date).
typedef _LiftValue = ({double value, DateTime date, double? wilks});

/// STRENGTH card data (rebuild 2026-09-22, twice): recent e1RM vs
/// LAST-BULK top per lift on the card (user: "just show my numbers
/// from my last bulk here"), the all-time top relegated to the detail
/// sheet. The working-max COLUMN moved to the Program tab's
/// Configuration card; the pain-cap chip was removed 2026-09-25
/// (user: "I don't know what 'pain cap: deadlift' means").
class _StrengthData {
  /// recent e1RM (RPE-adjusted since 2026-09-25 — the airlayer
  /// `max_e1rm_rpe` basis): best RPE-adjusted capped e1RM in the
  /// trailing 14 days of real work (light weeks + effort < 0.75
  /// excluded; window widens until found). Wilks priced at CURRENT
  /// bodyweight ([currentBwLbs]).
  final Map<String, _LiftValue> recent;

  /// All-time top per lift: the heaviest weight ACTUALLY lifted (any
  /// reps ≥ 1 — a 405×2 counts as 405; NOT an e1RM) over full history,
  /// session-cached. Wilks priced at the CONTEMPORANEOUS bodyweight —
  /// the monthly mean as of the month the PR was set. DETAIL-SHEET
  /// ONLY since the last-bulk column took its card slot.
  final Map<String, _LiftValue> best;

  /// Last-bulk top per lift: the heaviest weight ACTUALLY lifted
  /// inside [bulkWindow] — same conventions and contemporaneous-bw
  /// Wilks pricing as [best], different window. Empty when
  /// [bulkWindow] is null.
  final Map<String, _LiftValue> lastBulk;

  /// dashboards.yaml `last_bulk:` window (start derived from the
  /// weigh-in trough, user-editable). Null → the card omits the
  /// last-bulk column and shows only recent e1RM.
  final ({DateTime start, DateTime end, String label})? bulkWindow;

  /// The bodyweight (lb) the recent column's Wilks is priced at:
  /// 7-day average, falling back to the current month's mean. Null →
  /// no wilks on the recent column.
  final double? currentBwLbs;

  const _StrengthData({
    required this.recent,
    required this.best,
    required this.lastBulk,
    required this.bulkWindow,
    required this.currentBwLbs,
  });

  bool get isEmpty => recent.isEmpty && best.isEmpty && lastBulk.isEmpty;
}

/// Recomp one-screen status data: the live weekly review + the latest
/// scale body-fat reading (display context for the BODY row until a
/// DEXA source exists).
class _RecompData {
  final WeeklyReview review;
  final double? latestBfPct;

  const _RecompData({required this.review, this.latestBfPct});
}

class HomeDashboardState extends State<HomeDashboard> {
  late final DateTime _today;

  /// All-time top ACTUAL weights (+ the dates they were set —
  /// domain_metrics allTimeBestWeights) are computed from FULL strength
  /// history — once per app session (process-wide), busted by [reload].
  static Map<String, ({double value, DateTime date})>? _bestWeightCache;

  /// Test hook.
  @visibleForTesting
  static void clearBestWeightCache() => _bestWeightCache = null;

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

  /// Per-phase driver checklist (output>>input redesign 2026-09-22):
  /// dashboards.yaml `weekly_drivers:` evaluated against local rows.
  /// Null → no drivers declared for the phase; the old quota strip
  /// renders unchanged.
  late Future<List<DriverEval>?> _drivers;

  /// Recomp one-screen status (tracking spec 2026-09-27): the weekly
  /// review computed live from local rows for the current Mon-Sun week.
  /// Non-null ONLY when the effective phase is recomp — every other
  /// phase keeps the driver checklist strip untouched.
  late Future<_RecompData?> _recomp;

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
  /// session-wide best-weight cache; the weight path re-syncs its local
  /// mirror from the sheet on every call already, and program_status is
  /// an uncached direct sheet read.
  void _startLoad({required bool force}) {
    if (force) {
      ProgramProvider.clearCache();
      _bestWeightCache = null;
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
    _drivers = _computeDrivers();
    _recomp = _guard(_computeRecomp);
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
    await Future.wait([
      _hero, _body, _strength, _exec, _engine, _live, _drivers, _recomp, //
    ]);
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

  /// 4x4 cardio session dates. Mirrors the nightly rollup's type
  /// filter (tool/program_status_update.dart): treadmill / bike /
  /// stairmaster (or untyped legacy rows) count; other modalities
  /// (outdoor running) don't. Errors degrade to empty → pending.
  Future<List<DateTime>> _loadCardioDates() async {
    if (widget.cardioRepo == null || widget.cardioView == null) {
      return const [];
    }
    const fourByFourTypes = {'treadmill', 'bike', 'stairmaster'};
    try {
      final recs = await widget.cardioRepo!.list(widget.cardioView!);
      final out = <DateTime>[];
      for (final r in recs) {
        final type = r['type']?.toString().trim().toLowerCase() ?? '';
        if (type.isNotEmpty && !fourByFourTypes.contains(type)) continue;
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

  /// Meals → calendar day → total protein grams. Errors degrade to
  /// empty → the protein driver stays pending, never lies.
  Future<Map<DateTime, double>> _loadProteinByDay() async {
    if (widget.mealsRepo == null || widget.mealsView == null) {
      return const {};
    }
    try {
      final recs = await widget.mealsRepo!.list(widget.mealsView!);
      final out = <DateTime, double>{};
      for (final r in recs) {
        final raw = r['eaten_at'];
        final s = raw?.toString() ?? '';
        final d = raw is DateTime
            ? raw
            : DateTime.tryParse(s) ??
                  DateTime.tryParse(s.split(' ').first);
        final g = asNum(r['protein_g']);
        if (d == null || g == null) continue;
        final day = DateTime(d.year, d.month, d.day);
        out[day] = (out[day] ?? 0) + g;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Top-set readings for the singles driver (readings-based tick,
  /// 2026-09-25): the stored `readings` tab rows (the working-max
  /// controller's ground truth) UNIONed with a LIVE extraction from
  /// local strength rows for days the nightly hasn't evaluated yet —
  /// per lift, dates strictly after its newest stored reading, same
  /// candidate rule as runWmChain — so the tick moves the moment the
  /// top set is logged and an empty tab still reads honestly. Live
  /// rows only carry the tick-relevant kind (light_week / test via the
  /// program's week type, else heavy_top); the nightly chain remains
  /// the owner of the full kind taxonomy. Null only when the WM
  /// snapshot itself is unavailable → the evaluator falls back to the
  /// legacy §2.5 near-max tick.
  Future<List<TopSetReading>?> _loadTopSetReadings() async {
    final snap = await _wm;
    if (snap == null) return null;
    final out = <TopSetReading>[
      for (final r in snap.readings)
        TopSetReading(
          date: r.date,
          lift: r.lift,
          kind: r.kind,
          reps: r.reps,
          rpe: r.rpe,
        ),
    ];
    final rows = await _strengthRows;
    if (rows.isEmpty) return out;
    final docs = await _docs;
    final program = docs?.program;
    final wsDay = await _weekStartDay();
    String liveKind(DateTime date, String lift) {
      final wt = program == null
          ? null
          : programCurrent(
              program,
              docs?.phase,
              anchorMondayOf(weekStartOf(date, wsDay)),
            )?.weekType;
      return wt == 'light'
          ? 'light_week'
          : wt == 'test'
              ? 'test'
              : 'heavy_top';
    }

    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    final today = day(_today);
    final lastStored = <String, DateTime>{};
    for (final r in snap.readings) {
      final d = day(r.date);
      final cur = lastStored[r.lift];
      if (cur == null || d.isAfter(cur)) lastStored[r.lift] = d;
    }
    for (final r in extractReadings(rows, kindOf: liveKind)) {
      final d = day(r.date);
      if (d.isAfter(today)) continue; // planned rows never count
      final last = lastStored[r.lift];
      if (last != null && !d.isAfter(last)) continue; // nightly owns it
      out.add(
        TopSetReading(
          date: r.date,
          lift: r.lift,
          kind: r.kind,
          reps: r.reps,
          rpe: r.rpe,
        ),
      );
    }
    return out;
  }

  /// planned_alternation's anchor Monday from the program version —
  /// feeds the singles ticks' (H)/(L) parity tags.
  static DateTime? _alternationAnchor(Map<Object?, Object?>? version) {
    final alt = version?['planned_alternation'];
    if (alt is! Map) return null;
    return DateTime.tryParse(alt['anchor_monday']?.toString() ?? '');
  }

  /// Driver checklist (output>>input principle): dashboards.yaml
  /// `weekly_drivers:` for the declared phase, evaluated live against
  /// the working-max readings (top singles), strength (frequency),
  /// meals (protein), the kaya snapshot (climb, with staleness
  /// honesty) and cardio (4x4) over the current accounting week.
  /// Null → old quota strip.
  Future<List<DriverEval>?> _computeDrivers() async {
    final raw = await _guard(() async => widget.dashboards?.loadRaw());
    final byPhase = parseWeeklyDrivers(raw);
    if (byPhase == null) return null;
    final docs = await _docs;
    final phase = currentVersion(docs?.phase)?['value']?.toString();
    // Program-variant selection (v8): recomposition redirects a
    // declared bulk phase to the recomp driver set when one exists.
    final phaseKey = phase == null
        ? null
        : effectivePhaseKey(
            phase,
            variant:
                currentVersion(docs?.program)?['variant']?.toString(),
            available: byPhase.keys,
          );
    final configs = phaseKey == null ? null : byPhase[phaseKey];
    if (configs == null || configs.isEmpty) return null;
    final rows = await _strengthRows;
    final daily = (await _weights)?.daily ?? const <WeightRow>[];
    final bw =
        observedWeightStats(daily, _today).bw7dAvg ??
        contemporaneousBodyweightLbs(daily, _today);
    final programVersion = currentVersion(docs?.program);
    return evaluateWeekDrivers(
      configs: configs,
      inputs: WeekDriverInputs(
        graded: rows.isEmpty ? const [] : gradeSets(rows),
        readings: await _loadTopSetReadings(),
        alternationAnchorMonday: _alternationAnchor(programVersion),
        climbingDates: await _climbDates,
        cardioDates: await _loadCardioDates(),
        proteinByDay: await _loadProteinByDay(),
        bodyweightLb: bw,
        // v9 hypertrophy counting: every logged strength set (name +
        // reps — accessories/calisthenics included) against the
        // program's declared exercise_muscle_map.
        strengthSets: [
          for (final r in rows)
            LoggedSet(date: r.date, exercise: r.exercise, reps: r.reps),
        ],
        muscleMap: parseExerciseMuscleMap(programVersion),
      ),
      today: _today,
      weekStartDay: await _weekStartDay(),
    );
  }

  // -------------------------------------------------------------------------
  // Recomp one-screen status (tracking spec 2026-09-27)
  // -------------------------------------------------------------------------

  static DateTime? _recDate(Object? raw) => raw is DateTime
      ? raw
      : DateTime.tryParse(raw?.toString() ?? '') ??
          DateTime.tryParse((raw?.toString() ?? '').split(' ').first);

  static String? _recText(Object? raw) {
    final s = raw?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  /// The recomp weekly review, live from local rows, for the CURRENT
  /// Mon-Sun week (the review's own week shape — recomp_review.dart
  /// documents why it differs from the Saturday accounting week). Null
  /// unless the effective phase is recomp; every load degrades to
  /// empty → honest "no data" rows, never fabricated zeros.
  Future<_RecompData?> _computeRecomp() async {
    final docs = await _docs;
    final phase = currentVersion(docs?.phase)?['value']?.toString();
    if (phase == null) return null;
    final version = currentVersion(docs?.program);
    final key = effectivePhaseKey(
      phase,
      variant: version?['variant']?.toString(),
      available: const ['recomp'],
    );
    if (key != 'recomp') return null;

    Future<List<Map<String, Object?>>> rows(
      WarehouseConnector? repo,
      ViewSchema? view,
    ) async {
      if (repo == null || view == null) return const [];
      try {
        return await repo.list(view);
      } catch (_) {
        return const [];
      }
    }

    final meals = [
      for (final r in await rows(widget.mealsRepo, widget.mealsView))
        if (_recDate(r['eaten_at']) case final d?)
          MealRow(
            eatenAt: d,
            calories: asNum(r['calories'])?.toDouble(),
            proteinG: asNum(r['protein_g'])?.toDouble(),
            carbsG: asNum(r['carbs_g'])?.toDouble(),
            fatG: asNum(r['fat_g'])?.toDouble(),
          ),
    ];

    // Raw strength records (not _strengthRows): the review needs the
    // set_type tag StrengthRow doesn't carry.
    final strength = [
      for (final r
          in await rows(widget.strengthRepo, widget.strengthView))
        if (_recDate(r['date']) case final d?)
          if (_recText(r['exercise']) case final ex?)
            ReviewSet(
              date: d,
              exercise: ex,
              reps: asNum(r['reps'])?.round() ?? 0,
              weight: asNum(r['weight'])?.toDouble() ?? 0,
              rpe: asNum(r['rpe'])?.toDouble(),
              setType: _recText(r['set_type']),
            ),
    ];

    final climbs = [
      for (final r
          in await rows(widget.climbingRepo, widget.climbingView))
        if (_recDate(r['date']) case final d?)
          ClimbRow(
            date: d,
            grade: _recText(r['grade']) ?? '',
            ascentType: _recText(r['ascent_type']) ?? '',
          ),
    ];

    final cali = [
      for (final r in await rows(
        widget.calisthenicsRepo,
        widget.calisthenicsView,
      ))
        if (_recDate(r['date']) case final d?)
          if (_recText(r['skill']) case final skill?)
            CalisthenicsRow(
              date: d,
              skill: skill,
              variation: _recText(r['variation']),
              sets: asNum(r['sets'])?.round(),
              reps: asNum(r['reps'])?.round(),
              holdSeconds: asNum(r['hold_seconds'])?.toDouble(),
              clean: r['clean'] is bool ? r['clean'] as bool : null,
              rpe: asNum(r['rpe'])?.toDouble(),
            ),
    ];

    const fourByFourTypes = {'treadmill', 'bike', 'stairmaster'};
    final cardio = <Cardio4x4Row>[];
    for (final r in await rows(widget.cardioRepo, widget.cardioView)) {
      final type = r['type']?.toString().trim().toLowerCase() ?? '';
      if (type.isNotEmpty && !fourByFourTypes.contains(type)) continue;
      final d = _recDate(r['date']);
      if (d == null) continue;
      cardio.add(Cardio4x4Row(
        date: d,
        speed: (asNum(r['treadmill_speed']) ??
                asNum(r['stairmaster_speed']))
            ?.toDouble(),
        incline: asNum(r['incline'])?.toDouble(),
        maxHr: asNum(r['max_hr'])?.toDouble(),
        completedIntervals: asNum(r['completed_intervals'])?.toDouble(),
      ));
    }

    final recovery = [
      for (final r in await rows(widget.notesRepo, widget.notesView))
        if (_recDate(r['date']) case final d?)
          RecoveryRow(
            date: d,
            sleepHours: asNum(r['sleep_hours'])?.toDouble(),
            sleepQuality: asNum(r['sleep_quality'])?.toDouble(),
            fatigue: asNum(r['fatigue'])?.toDouble(),
            soreness: asNum(r['soreness'])?.toDouble(),
            readiness: asNum(r['readiness'])?.toDouble(),
            pain: _recText(r['pain']),
            note: _recText(r['note']),
          ),
    ];

    final body = <BodyRow>[];
    double? latestBf;
    DateTime? latestBfDate;
    for (final r in await rows(widget.weightRepo, widget.weightView)) {
      final d = _recDate(r['date']);
      if (d == null) continue;
      body.add(BodyRow(
        date: d,
        weightLbs: asNum(r['weight_lbs'])?.toDouble(),
        waistIn: asNum(r['waist_in'])?.toDouble(),
      ));
      final bf = (asNum(r['body_fat_withing']) ??
              asNum(r['body_fat_omron']) ??
              asNum(r['body_fat_caliper']))
          ?.toDouble();
      if (bf != null && (latestBfDate == null || d.isAfter(latestBfDate))) {
        latestBf = bf;
        latestBfDate = d;
      }
    }

    final slice = _slice(docs);
    final review = buildWeeklyReview(
      weekStart: mondayOf(_today),
      inputs: RecompInputs(
        meals: meals,
        strengthSets: strength,
        readings: await _loadTopSetReadings() ?? const [],
        climbs: climbs,
        calisthenics: cali,
        cardio: cardio,
        recovery: recovery,
        body: body,
      ),
      targets: recompTargetsFromProgram(
        version,
        parseExerciseMuscleMap(version),
        targetsInForce: slice?.targetsInForce,
      ),
    );
    return _RecompData(review: review, latestBfPct: latestBf);
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
    final declaredPhase = phaseVersion?['value']?.toString();
    if (declaredPhase == null) return null;
    // Program-variant selection (v8): recomposition redirects a
    // declared bulk phase to the recomp eigenvector set when one
    // exists (dashboards.yaml `recomp:`); the bulk set stays defined
    // but unselected while the variant is active.
    final phase = effectivePhaseKey(
      declaredPhase,
      variant: currentVersion(docs?.program)?['variant']?.toString(),
      available: phases.keys,
    );
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
    // recent e1RM (2026-09-22; RPE-adjusted 2026-09-25): 14-day best
    // of REAL work — light accounting weeks (program week_type via the
    // anchor Monday) and sub-0.75-effort sets excluded — valued on the
    // RPE-adjusted capped e1RM (`max_e1rm_rpe`: RIR counts as reps).
    // DISPLAY-ONLY; the §2.5 42-day reference feeding the
    // controller/planner is untouched and stays plain Epley.
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
    // Wilks pricing (2026-09-22): recent column at CURRENT bodyweight
    // (7-day avg, same "current bodyweight" as the BODY/hero rows;
    // month-mean fallback when the last weigh-in is stale), all-time
    // column at the CONTEMPORANEOUS bodyweight — the monthly mean as
    // of the PR's month (contemporaneousBodyweightLbs) — so an old
    // fat-bulk PR is priced at the body that lifted it.
    final daily = (await _weights)?.daily ?? const <WeightRow>[];
    final currentBw =
        observedWeightStats(daily, _today).bw7dAvg ??
        contemporaneousBodyweightLbs(daily, _today);
    final recent = <String, _LiftValue>{};
    for (final lift in synthesisLifts) {
      final r = recentBestE1rm(
        graded,
        lift,
        _today,
        weekTypeOf: program == null ? null : weekTypeOf,
        weekStartDay: wsDay,
        rpeAdjusted: true,
      );
      if (r != null) {
        recent[lift] = (
          value: r.value,
          date: r.date,
          wilks: currentBw == null ? null : wilksPointsLb(r.value, currentBw),
        );
      }
    }
    // Actual-weight tops (any reps ≥ 1, 405×2 → 405 — the Wilks chart
    // benchmark's convention), each priced at CONTEMPORANEOUS bw.
    Map<String, _LiftValue> priced(
      Map<String, ({double value, DateTime date})> raw,
    ) => {
      for (final e in raw.entries)
        e.key: (
          value: e.value.value,
          date: e.value.date,
          wilks: switch (contemporaneousBodyweightLbs(daily, e.value.date)) {
            null => null,
            final bw => wilksPointsLb(e.value.value, bw),
          },
        ),
    };
    // All-time top = heaviest weight ACTUALLY lifted (2026-09-22 —
    // user: "the all-time top should be based on my actual 1RM not my
    // e1RM") — detail-sheet only since the last-bulk column took its
    // card slot (same day: "relegate all-time to the click-in view").
    final best = priced(
      rows.isEmpty
          ? const {}
          : (_bestWeightCache ??= allTimeBestWeights(rows, _today)),
    );
    // Last-bulk top: same actual-weight convention bounded to the
    // dashboards.yaml `last_bulk` window (start derived from the
    // weigh-in trough — services/bulk_window.dart — but explicit and
    // user-editable in the config). No window → no column, gracefully.
    final window = parseLastBulkWindow(
      await _guard(() async => widget.dashboards?.loadRaw()),
    );
    final lastBulk = window == null || rows.isEmpty
        ? const <String, _LiftValue>{}
        : priced(
            bestWeightsInWindow(rows, start: window.start, end: window.end),
          );
    return _StrengthData(
      recent: recent,
      best: best,
      lastBulk: lastBulk,
      bulkWindow: window,
      currentBwLbs: currentBw,
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
        _HeroCard(hero: hero, onRowTap: _onHeroRowTap),
        const SizedBox(height: 8),
        _strengthCard(context),
        const SizedBox(height: 8),
        _weekCard(context),
      ],
    );
  }

  // Top-aligned rows (readability pass 2026-09-25): the old
  // IntrinsicHeight equal-stretch is incompatible with the STRENGTH
  // card's LayoutBuilder reflow (LayoutBuilder can't answer intrinsic
  // sizing), and with the stacked narrow layout the cards' heights
  // diverge by design anyway.
  Widget _legacyGrid(BuildContext context) {
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _bodyCard(context)),
            const SizedBox(width: 8),
            Expanded(child: _strengthCard(context)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _execCard(context)),
            const SizedBox(width: 8),
            Expanded(child: _engineCard(context)),
          ],
        ),
      ],
    );
  }

  /// Hero row taps: the Wilks rows (wilks_stability / strength_gain)
  /// open their detail sheet first — the weekly decomposition is the
  /// whole point of the tap (2026-09-25); everything else navigates
  /// straight to the owning screen as before.
  void _onHeroRowTap(EigenRowData row) {
    if (row.id == 'wilks_stability' || row.id == 'strength_gain') {
      _openHeroWilksSheet(row);
      return;
    }
    _navigate(row.nav);
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
    // One line per lift so the wilks tag stays attached to its number:
    // "squat 315 · 121.4w (2d)" / "(Jun '25)" — age tags for the
    // recent column, PR-month tags for the historical tops (the card
    // columns' own when-vocabulary).
    String liftLines(
      Map<String, _LiftValue> m,
      String Function(DateTime) when,
    ) => m.isEmpty
        ? '—'
        : synthesisLifts
              .where(m.containsKey)
              .map(
                (l) =>
                    '$l ${fmtLb(m[l]!.value.roundToDouble())}'
                    '${m[l]!.wilks == null ? '' : ' · ${m[l]!.wilks!.toStringAsFixed(1)}w'}'
                    ' (${when(m[l]!.date)})',
              )
              .join('\n');
    String age(DateTime dt) => fmtAge(dt, _today);
    final bw = d?.currentBwLbs;
    final window = d?.bulkWindow;
    await _showDetailSheet(
      title: 'Strength',
      entries: [
        _DetailEntry(
          label: 'recent e1RM (RPE-adj)',
          value: liftLines(d?.recent ?? const {}, age),
          explain:
              'What you\'ve actually shown recently: the best '
              'RPE-ADJUSTED estimated 1RM over the last 14 days of '
              'real work. RPE says how many reps were left in reserve '
              '(RIR = 10 − RPE), and those count as reps you did: a '
              '275×2 @ RPE 8 is scored like 275×4 (Epley, total reps '
              'capped at 12) — because you don\'t train to failure, '
              'this reads your strength better than the raw set. Sets '
              'without an RPE score as-is (treated as at-failure). '
              'Deload (light-week) sets and easy sets under 75% '
              'effort don\'t count. When there\'s no real work in the '
              'window it slides back to your newest qualifying set; '
              'the age tag tells you how current the number is. The '
              '·w number is the lift\'s Wilks points at your current '
              'bodyweight'
              '${bw == null ? '' : ' (${bw.toStringAsFixed(1)} lb)'}.',
        ),
        if (window != null)
          _DetailEntry(
            label: 'last bulk',
            value: liftLines(d?.lastBulk ?? const {}, fmtMonthTag),
            explain:
                'The heaviest weight you ACTUALLY lifted per lift '
                'during the ${window.label} '
                '(${DateFormat('MMM d yyyy').format(window.start)} – '
                '${DateFormat('MMM d yyyy').format(window.end)}) — the '
                'high-water mark the cut is defending. The window '
                'comes from dashboards.yaml `last_bulk`: the end is '
                'the declared cut, the start was derived from the '
                'bodyweight trough before the bulk\'s run-up (edit the '
                'dates there if it looks off). Wilks points use the '
                'bodyweight you carried the month each top was set.',
          ),
        _DetailEntry(
          label: 'all-time top',
          value: liftLines(d?.best ?? const {}, fmtMonthTag),
          explain:
              'The heaviest weight you\'ve ACTUALLY lifted (any reps '
              '≥ 1 — a 405×2 counts as 405; no Epley, no estimates) '
              'over the full strength history — your actual 1RM '
              'ceiling, on the same actual-max convention as the '
              'Wilks trend chart\'s benchmark. Lives here rather than '
              'on the card since the last-bulk column took its slot '
              '(2026-09-22). Its Wilks points use the bodyweight you '
              'carried THE MONTH the top was set (contemporaneous, '
              'from the monthly weigh-in means) — that\'s what makes '
              'an old bulk-weight top comparable to today\'s cut '
              'numbers. No weigh-in history covering that month → the '
              'wilks tag is omitted.',
        ),
        _DetailEntry(
          label: 'basis',
          value: 'recent: RPE-adj e1RM · bulk & top: actual',
          explain:
              'Two bases here: the recent column is an ESTIMATED 1RM '
              '(Epley over effective reps = reps + RIR, capped at 12 '
              '— the airlayer max_e1rm_rpe measure) — what you\'ve '
              'shown lately; the last-bulk and all-time tops are '
              'ACTUAL weight lifted — the same actual-max basis as '
              'the Wilks trend chart and its best-ever benchmark. A '
              'recent e1RM can sit above an actual top without you '
              'ever having lifted it.',
        ),
        _DetailEntry(
          label: 'working max',
          value: 'Program › Configuration',
          explain:
              'No longer shown on this card. The working max is the '
              'controller\'s setting that session percentages hang off '
              '— not a measured max. It lives on the Program tab\'s '
              'Configuration card, where you confirm or override it.',
        ),
      ],
      // Program screen: its CONFIGURATION section is where WMs are
      // confirmed/overridden (moved out of Integrations 2026-09-21).
      actionLabel: widget.onOpenProgram == null ? null : 'Open Program',
      onAction: widget.onOpenProgram,
    );
  }

  /// The hero STRENGTH row's detail sheet (2026-09-25): the weekly
  /// actual-max Wilks stat decomposed into its three constituent lifts
  /// + the basis note vs the STRENGTH card. Same series computation as
  /// [_computeHero] (rows/weights/week-start all off the shared
  /// futures), so the sum line and the hero stat can never disagree.
  /// No computable week → fall back to the row's direct navigation.
  Future<void> _openHeroWilksSheet(EigenRowData row) async {
    final rows = await _strengthRows;
    final daily = (await _weights)?.daily ?? const <WeightRow>[];
    final wsDay = await _weekStartDay();
    final weeks = rows.isEmpty || daily.isEmpty
        ? const <WilksWeek>[]
        : weeklyWilksSeries(rows, daily, through: _today, weekStartDay: wsDay);
    final parts = weeks.isEmpty
        ? const <WilksLiftPart>[]
        : wilksWeekDecomposition(weeks.last);
    if (parts.isEmpty) {
      _navigate(row.nav); // nothing to decompose — old tap behavior
      return;
    }
    final week = weeks.last;
    String liftLine(WilksLiftPart p) =>
        '${p.lift} ${fmtLb(p.weightLbs.roundToDouble())}'
        '${p.carriedFrom == null ? '' : ' (carried from ${DateFormat('MMM d').format(p.carriedFrom!)})'}'
        ' → ${p.displayPoints.toStringAsFixed(1)}w';
    final nav = widget.onOpenStrengthDomain ?? widget.onOpenProgram;
    await _showDetailSheet(
      title: 'Strength — weekly Wilks',
      entries: [
        _DetailEntry(
          label: 'this week',
          value: row.detail,
          explain:
              'Weekly ACTUAL-max Wilks: per lift, the heaviest weight '
              'you actually lifted this accounting week (any reps ≥ 1 '
              '— no Epley, no estimates; untrained lifts carry the '
              'last trained week\'s weight), summed and priced at the '
              'week\'s average bodyweight '
              '(${week.bodyweightLbs.toStringAsFixed(1)} lb). The '
              'floor hangs off the phase-start reference.',
        ),
        _DetailEntry(
          label: 'decomposition',
          value: [
            for (final p in parts) liftLine(p),
            '= ${week.wilks.toStringAsFixed(1)}',
          ].join('\n'),
          explain:
              'The three lifts the stat sums — each line is the '
              'lift\'s weight_kg × the WILKS-2020 coefficient at this '
              'week\'s bodyweight. "carried from" = not trained this '
              'week. The lines sum to the stat exactly.',
        ),
        const _DetailEntry(
          label: 'vs the STRENGTH card',
          value: 'card: e1RM · this stat: actual',
          explain:
              'The STRENGTH card\'s per-lift numbers are 14-day best '
              'e1RM ESTIMATES (always ≥ actual) — they will not sum '
              'to this weekly actual-lift total.',
        ),
      ],
      actionLabel: nav == null ? null : 'Open Strength',
      onAction: nav == null ? null : () => _navigate(row.nav),
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
                style: AppText.tag(context),
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
      // Subtle basis tag (2026-09-22: two bases on one card): the
      // "recent e1RM" column header already names its basis, so the
      // tag carries the other half — the last-bulk top is the
      // heaviest weight ACTUALLY lifted in the window, the Wilks
      // trend chart's actual-max basis. Kept short: anything longer
      // overflows the half-width card (the sheet's basis entry spells
      // it out). No bulk column configured → no tag to carry.
      trailingBuilder: (context) => FutureBuilder<_StrengthData?>(
        future: _strength,
        builder: (context, snap) {
          if (snap.data?.bulkWindow == null) return const SizedBox.shrink();
          return Text(
            'bulk: actual',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.tag(context),
          );
        },
      ),
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
          // Second column only when dashboards.yaml declares the
          // last-bulk window (absent → single recent column; the
          // all-time top lives in the detail sheet either way).
          final hasBulk = d.bulkWindow != null;
          return LayoutBuilder(
            builder: (context, constraints) {
              // Readability pass 2026-09-25: 16sp values don't fit the
              // half-width legacy grid's two-column layout — reflow to
              // full-width per-lift blocks (name line + value lines)
              // instead of shrinking or ellipsizing.
              final stacked = constraints.maxWidth < 250;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!stacked)
                    _LiftHeaderRow(second: hasBulk ? 'last bulk' : null),
                  for (final lift in synthesisLifts)
                    stacked
                        ? _LiftStackedRows(
                            lift: lift,
                            recent: d.recent[lift],
                            bulk: hasBulk ? d.lastBulk[lift] : null,
                            showBulk: hasBulk,
                            today: _today,
                          )
                        : _LiftNumbersRow(
                            lift: lift,
                            recent: d.recent[lift],
                            bulk: hasBulk ? d.lastBulk[lift] : null,
                            showBulk: hasBulk,
                            today: _today,
                          ),
                ],
              );
            },
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
                style: AppText.tag(context),
              ),
              if (d.templateLine != null) ...[
                const SizedBox(height: 5),
                Text(
                  'Today: ${d.templateLine}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.tag(
                    context,
                  )?.copyWith(fontStyle: FontStyle.italic),
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
    final recomp = await _recomp;
    if (recomp != null) {
      await _openRecompSheet(recomp);
      return;
    }
    final d = await _exec;
    final e = await _engine;
    final drivers = await _drivers;
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

    final ff = e?.lastFourByFour;
    // Driver mode (output>>input redesign): one entry per driver with
    // its causal story. The old quota entries only render when no
    // weekly_drivers are declared (back-compat).
    final quotaEntries = drivers != null && drivers.isNotEmpty
        ? [for (final dr in drivers) _driverEntry(dr)]
        : [
            _DetailEntry(
              label: 'Sets',
              value: live != null
                  ? fmt(live.workingSets, t['working_sets'])
                  : done('working_sets', t['working_sets']),
              explain:
                  'Working sets this week — sets at ≥ 80% of your '
                  'reference e1RM. $liveSource The target is the '
                  'program\'s targets-in-force (a cut has no volume '
                  'floor).',
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
                  'Climbing sessions this week vs the block\'s '
                  'allowance from the program (kaya_ascents dates).',
            ),
          ];
    await _showDetailSheet(
      title: 'This week',
      entries: [
        ...quotaEntries,
        _DetailEntry(
          label: '4x4 max HR',
          value: ff == null
              ? '—'
              : '${fmtLb(ff.maxHr)} · wk ${DateFormat('MMM d').format(ff.weekMonday)}',
          explain:
              'Highest heart rate hit in the most recent measured '
              '4x4 interval session — the engine\'s top-end output proxy.',
        ),
        const _DetailEntry(
          label: 'Coach signals',
          value: 'Program › status',
          explain:
              'The coach\'s weekly rule flags no longer appear on this '
              'strip — the checklist above and the hero verdicts carry '
              'the actionable content; the full signal history lives '
              'in the status ledger.',
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

  /// One driver's detail-sheet entry: value (+ per-lift ticks, + the
  /// staleness tag, + the heavy-single recency line) and the one-line
  /// causal story. The singles driver additionally explains its parity
  /// and two-week-heavy mechanics (2026-09-25).
  _DetailEntry _driverEntry(DriverEval d) {
    // Muscle-volume driver (clarity pass 2026-09-29): the sheet gets a
    // readable summary plus one line per muscle group — full name,
    // sets, and a clear under / in range / over state.
    if (d.config.id == 'hypertrophy_volume' && d.ticks.isNotEmpty) {
      final (summary, lines) = hypertrophyLines(d);
      return _DetailEntry(
        label: d.label,
        value: summary,
        explain:
            'Why this matters: ${d.config.why ?? '—'} '
            'Drives: ${d.config.outcome ?? '—'}.\n'
            'This week per muscle group:\n${lines.join('\n')}\n'
            'Under mid-week is normal — counts fill in as sets are '
            'logged. Over the top of the range is the warning state.',
      );
    }
    final ticks = d.ticks.isEmpty
        ? ''
        : '\n${d.ticks.map(_tickText).join(' · ')}';
    final stale = d.staleAsOf == null
        ? ''
        : ' · as of ${DateFormat('MMM d').format(d.staleAsOf!)}';
    final staleExplain = d.staleAsOf == null
        ? ''
        : ' The Kaya snapshot\'s newest ascent predates this week — '
              'this count can\'t see newer climbs until you re-export '
              '(Integrations → Kaya → Sync).';
    final heavyLine = heavyRecencyText(d);
    final heavy = heavyLine == null ? '' : '\n$heavyLine';
    // The singles rule, mechanically: how a tick is earned, what the
    // heavy/light week tags mean, and how the two-week heavy rule is
    // tracked. The user's own phrasing lives in the config's `why`.
    final singlesExplain = d.config.id != 'top_single_per_lift'
        ? ''
        : ' A tick = a top-set reading for that lift this accounting '
              'week — the working-max controller\'s day-top RPE set, '
              'heavy or light, any reps (deload-week readings don\'t '
              'count).'
              '${d.ticks.any((t) => t.parity != null) ? ' "Heavy week"/"light week" on squat and deadlift '
                    'is this week\'s side of their alternation — a '
                    'lighter top set still ticks on its light week.' : ''}'
              '${d.config.heavySingleMaxDays == null ? '' : ' The heavy-single line tracks the every-two-weeks '
                    'rule: the newest set of 1-2 reps at RPE 7.5 or '
                    'harder per lift — amber past '
                    '${d.config.heavySingleMaxDays} days, red a week '
                    'later.'}';
    return _DetailEntry(
      label: d.label,
      value: '${d.value}$ticks$stale$heavy',
      explain:
          'Why this matters: ${d.config.why ?? '—'} '
          'Drives: ${d.config.outcome ?? '—'}.$singlesExplain$staleExplain',
    );
  }

  /// Plain display name for a lift or muscle group key
  /// ("hamstrings_glutes" → "hamstrings and glutes"). Clarity pass
  /// 2026-09-29 (user: single-letter compressions were unreadable —
  /// two groups even shared a letter): full words everywhere, more
  /// vertical space over cryptic density.
  static String plainName(String key) =>
      key.isEmpty ? '?' : key.replaceAll('_', ' and ');

  static String _tickText(DriverTick t) {
    final name = plainName(t.lift);
    final base = t.target > 1
        ? '$name ${t.count}/${t.target}'
        : '$name ${t.done ? '✓' : '—'}';
    // Alternation tag (2026-09-25): this week's EXPECTED side of the
    // squat/deadlift heavy↔light swap — display only, a light top set
    // still ticks. Spelled out since 2026-09-29 ((H)/(L) needed
    // decoding).
    return switch (t.parity) {
      'heavy' => '$base (heavy week)',
      'light' => '$base (light week)',
      _ => base,
    };
  }

  /// "Heavy single: squat 4 days ago · deadlift none yet — overdue" —
  /// the every-two-weeks heavy rule's secondary line (null when the
  /// eval carries none).
  static String? heavyRecencyText(DriverEval d) {
    if (d.heavyRecency.isEmpty) return null;
    String part(HeavySingleRecency h) {
      final name = plainName(h.lift);
      final age = h.daysAgo == null
          ? 'none yet'
          : h.daysAgo == 0
              ? 'today'
              : h.daysAgo == 1
                  ? '1 day ago'
                  : '${h.daysAgo} days ago';
      return h.band == HeavySingleBand.fresh
          ? '$name $age'
          : '$name $age — overdue';
    }

    return 'Heavy single: ${d.heavyRecency.map(part).join(' · ')}';
  }

  /// The muscle-volume driver's readable summary ("3 of 7 groups in
  /// range") + per-group states, computed against the config's band
  /// (a group can be under, in, or over the range — "over" is the red
  /// state, the excess-pulling caution).
  static (String, List<String>) hypertrophyLines(DriverEval d) {
    final band = d.config.band ?? const [8.0, 12.0];
    final lo = band[0] <= band[1] ? band[0] : band[1];
    final hi = band[0] <= band[1] ? band[1] : band[0];
    final bandText = '${lo.round()}-${hi.round()}';
    var inRange = 0;
    final lines = <String>[];
    for (final t in d.ticks) {
      final state = t.count > hi
          ? 'over the range'
          : t.count >= lo
              ? 'in range'
              : 'under';
      if (t.count >= lo && t.count <= hi) inRange++;
      lines.add(
        '${plainName(t.lift)} — ${t.count} '
        '${t.count == 1 ? 'set' : 'sets'} ($state)',
      );
    }
    final summary = d.ticks.isEmpty
        ? d.value
        : '$inRange of ${d.ticks.length} groups in the '
            '$bandText-set range';
    return (summary, lines);
  }

  /// Full-width compact strip: the week's four quotas side by side +
  /// today's template line. Replaces the EXECUTION and ENGINE cards in
  /// the hero layout; their explainer entries merge into one sheet.
  /// The fired-flag chip was REMOVED from this strip 2026-09-25
  /// (output>>input: the driver checklist + hero verdicts carry the
  /// actionable content; the coach's signal history stays in the
  /// program_status ledger, coach context and briefings — Program →
  /// status). The legacy EXECUTION card keeps its chip.
  Widget _weekCard(BuildContext context) {
    return _SynthCard(
      label: 'This week',
      onTap: _openWeekSheet,
      child: FutureBuilder<List<Object?>>(
        future: Future.wait<Object?>([_exec, _engine, _drivers, _recomp]),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Dim('…');
          }
          final d = snap.data?[0] as _ExecData?;
          final e = snap.data?[1] as _EngineData?;
          // RECOMP ONE-SCREEN STATUS (tracking spec 2026-09-27): in the
          // recomp phase the strip becomes the spec's compact
          // BODY/NUTRITION/HYPERTROPHY/STRENGTH/SKILLS/CARDIO/RECOVERY
          // rows (live weekly review) — the driver checklist's content
          // is subsumed; every other phase is untouched.
          final recomp = snap.data?[3] as _RecompData?;
          if (recomp != null) {
            return _recompSection(context, recomp, e?.templateLine);
          }
          // DRIVER CHECKLIST (output>>input redesign 2026-09-22): when
          // the phase declares weekly_drivers, the strip renders the
          // causal inputs — activity tallies (sets / near-max) are
          // gone; working_sets stays a program_status/flags concern.
          final drivers = snap.data?[2] as List<DriverEval>?;
          if (drivers != null && drivers.isNotEmpty) {
            return _driverChecklist(context, drivers, e?.templateLine);
          }
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
                  style: AppText.tag(
                    context,
                  )?.copyWith(fontStyle: FontStyle.italic),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// The driver checklist: one pill per driver (label + tick/progress,
  /// tinted met/pending/violated), today's template line kept below.
  Widget _driverChecklist(
    BuildContext context,
    List<DriverEval> drivers,
    String? templateLine,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final d in drivers) _DriverPill(eval: d)],
        ),
        // The every-two-weeks heavy-single rule, under the singles
        // pills (2026-09-25): amber past heavy_single_max_days, red a
        // week past that.
        for (final d in drivers)
          if (d.heavyRecency.isNotEmpty) ...[
            const SizedBox(height: 4),
            _HeavySingleLine(eval: d),
          ],
        if (templateLine != null) ...[
          const SizedBox(height: 6),
          Text(
            'Today: $templateLine',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.tag(
              context,
            )?.copyWith(fontStyle: FontStyle.italic),
          ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Recomp one-screen rows (tracking spec 2026-09-27). Compact label +
  // value per spec section; graceful placeholders until waist / DEXA /
  // recovery / calisthenics data flows; the detail sheet carries the
  // spec's closing question.
  // -------------------------------------------------------------------------

  static String _n1(double v) => v.toStringAsFixed(1);
  static String _n0(double v) => v.round().toString();
  static String _sgn(double v) => '${v >= 0 ? '+' : ''}${_n1(v)}';

  /// The seven row values, shared by the strip and the detail sheet.
  static List<({String label, String value, String explain})> _recompRows(
    _RecompData data,
  ) {
    final r = data.review;
    final b = r.body;
    final n = r.nutrition;

    final bodyBits = <String>[
      b.avg7d == null ? 'no weigh-ins' : '${_n1(b.avg7d!)} lb 7d',
      if (b.change7d != null) '${_sgn(b.change7d!)}/wk',
      b.waistIn != null ? 'waist ${_n1(b.waistIn!)}"' : 'waist —',
      data.latestBfPct != null
          ? 'body fat ${_n1(data.latestBfPct!)}% (scale)'
          : 'DEXA —',
    ];

    final inBand = r.muscleSets.entries
        .where(
          (e) => e.value >= r.hypBand[0] && e.value <= r.hypBand[1],
        )
        .length;
    final over = [
      for (final e in r.muscleSets.entries)
        if (e.value > r.hypBand[1]) e.key,
    ];
    final under = [
      for (final e in r.muscleSets.entries)
        if (e.value < r.hypBand[0]) e.key,
    ];

    final heavyDone =
        r.heavyExposures.values.where((v) => v > 0).length;
    // Clarity pass 2026-09-29: full lift names, no letter ticks.
    String liftTick(String lift) =>
        '$lift ${(r.heavyExposures[lift] ?? 0) > 0 ? '✓' : '—'}';

    final cal = r.calisthenics;
    final skillsBits = <String>[
      'climb ${r.climbing.sessions}'
          '${r.climbing.newV5PlusSends > 0 ? ' (V5+ ×${r.climbing.newV5PlusSends})' : ''}',
      cal.sessions > 0
          ? 'calisthenics ${cal.sessions}'
          : 'calisthenics —',
    ];

    final cw = r.cardio;
    final cardioBits = <String>[
      '4x4 ${cw.sessions}/1',
      if (cw.completedAllFour == false) 'incomplete',
      if (cw.workloadTrendPct != null)
        '${cw.workloadTrendPct! >= 0 ? '+' : ''}${_n1(cw.workloadTrendPct!)}% workload',
    ];

    final rec = r.recovery;
    final recBits = rec.daysReported == 0 && rec.painDays.isEmpty
        ? <String>['log sleep/fatigue in daily notes']
        : <String>[
            if (rec.avgSleepHours != null)
              'sleep ${_n1(rec.avgSleepHours!)}h',
            if (rec.avgFatigue != null)
              'fatigue ${_n1(rec.avgFatigue!)}/5',
            if (rec.avgSoreness != null)
              'soreness ${_n1(rec.avgSoreness!)}/5',
            if (rec.painDays.isNotEmpty)
              'PAIN ×${rec.painDays.length}',
          ];

    return [
      (
        label: 'BODY',
        value: bodyBits.join(' · '),
        explain:
            '7-day average weight + weekly change (never react to a '
            'single day), the weekly navel waist measurement, and the '
            'latest body-fat reading (scale until a DEXA lands — '
            'periodic DEXA every 3-4 months is the spec cadence).',
      ),
      (
        label: 'NUTRITION',
        value: n == null
            ? 'no meals logged this week'
            : '${_n0(n.avgKcal)} kcal · protein ${_n0(n.avgProteinG)} · '
                'carbs ${_n0(n.avgCarbsG)} · fat ${_n0(n.avgFatG)}'
                '${n.proteinDaysMet != null ? ' · target met ${n.proteinDaysMet}/${n.daysLogged} days' : ''}',
        explain:
            'Daily averages over logged days + protein-target adherence '
            '(160-175 g/day once the recomp targets are in force). '
            'Calories vs maintenance appears after block 1 records the '
            'maintenance estimate.',
      ),
      (
        label: 'HYPERTROPHY',
        value: r.muscleSets.isEmpty
            ? 'no muscle map in program'
            : '$inBand of ${r.muscleSets.length} muscle groups in range'
                '${r.avgRir != null ? ' · ~${_n1(r.avgRir!)} reps in reserve' : ''}'
                '${over.isNotEmpty ? ' · over: ${over.map(HomeDashboardState.plainName).join(', ')}' : ''}',
        explain:
            'Productive sets per muscle group vs the 8-12 band, '
            'overlap-counted (climbing sessions credit back/biceps/'
            'forearms via the program map; warmup/skill/rehab set_type '
            'excluded; untagged legacy rows effort-inferred). Reps in '
            'reserve = 10 - RPE — how far productive sets stop short '
            'of failure.'
            '${under.isNotEmpty ? ' Under the range: ${under.map(HomeDashboardState.plainName).join(', ')}.' : ''}',
      ),
      (
        label: 'STRENGTH',
        value:
            'heavy $heavyDone/4 · ${['squat', 'bench', 'deadlift', 'press'].map(liftTick).join(' · ')}',
        explain:
            'One heavy top-set exposure per main lift per week (the '
            'working-max controller\'s readings are the ground truth). '
            'Trends live in the hero\'s strength row and the Program '
            'screen — one missing session is not strength loss.',
      ),
      (
        label: 'SKILLS',
        value: skillsBits.join(' · '),
        explain:
            'Climbing sessions (kaya snapshot — freshness bounded by '
            'the last import) with first-time V5+ sends, and '
            'calisthenics skill sessions (log them in the calisthenics '
            'view: skill quality over fatigue).',
      ),
      (
        label: 'CARDIO',
        value: cardioBits.join(' · '),
        explain:
            'The weekly 4x4 — never dropped. Progress = more EXTERNAL '
            'workload (speed × incline) at comparable heart rate, not '
            'a higher HR; the trend compares against the last session '
            'within ±5 bpm.',
      ),
      (
        label: 'RECOVERY',
        value: recBits.join(' · '),
        explain:
            'Daily subjectives from daily notes (sleep hours, fatigue, '
            'soreness, readiness 1-5). PAIN OUTRANKS every numeric '
            'target — any pain flag turns this row red and leads the '
            'weekly coaching decision.',
      ),
    ];
  }

  /// The one-screen strip: seven compact label+value rows.
  Widget _recompSection(
    BuildContext context,
    _RecompData data,
    String? templateLine,
  ) {
    final rows = _recompRows(data);
    final pain = data.review.recovery.painDays.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 96,
                  child: Text(row.label, style: AppText.tag(context)),
                ),
                Expanded(
                  child: Text(
                    row.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.micro(context)?.copyWith(
                      color: row.label == 'RECOVERY' && pain
                          ? scheme.error
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (templateLine != null) ...[
          const SizedBox(height: 6),
          Text(
            'Today: $templateLine',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.tag(
              context,
            )?.copyWith(fontStyle: FontStyle.italic),
          ),
        ],
      ],
    );
  }

  /// Recomp detail sheet: each row explained + the spec's closing
  /// question as the anchor entry.
  Future<void> _openRecompSheet(_RecompData data) async {
    final e = await _engine;
    await _showDetailSheet(
      title: 'This week — recomp',
      entries: [
        for (final row in _recompRows(data))
          _DetailEntry(
            label: row.label.toLowerCase(),
            value: row.value,
            explain: row.explain,
          ),
        _DetailEntry(
          label: 'Today',
          value: e?.templateLine ?? 'rest / no program',
          explain:
              'Today\'s session from the program\'s weekly template.',
        ),
        const _DetailEntry(
          label: 'The question',
          value: 'stimulus · nutrition · recovery',
          explain:
              'Am I consistently providing the stimulus, nutrition, and '
              'recovery required to gain muscle and strength while '
              'remaining ~13% body fat? That is the only thing this '
              'screen answers — the Sunday weekly review (coach chat / '
              'get_weekly_review) carries the full 10-question decision.',
        ),
      ],
      actionLabel: widget.onOpenStatus == null ? null : 'Open status ledger',
      onAction: widget.onOpenStatus,
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
                  // Expanded title + Flexible trailing: on very narrow
                  // cards the header degrades gracefully (title yields
                  // first, then the tag) instead of overflowing.
                  Expanded(
                    child: Text(
                      label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.title(context),
                    ),
                  ),
                  if (trailingBuilder != null)
                    Flexible(child: trailingBuilder!(context)),
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
      child: Text(text, style: AppText.tag(context)),
    );
  }
}

class _BigNumber extends StatelessWidget {
  final String value;
  final String unit;
  const _BigNumber({required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: value,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        children: [TextSpan(text: unit, style: AppText.tag(context))],
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
        style: AppText.tag(
          context,
        )?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Column headers for the STRENGTH card's two columns. Readability
/// pass 2026-09-25: AppText.tag (12sp floor) in onSurfaceVariant —
/// the old 9sp outline-colored tags were illegible on the dark theme.
class _LiftHeaderRow extends StatelessWidget {
  /// Second column label ('last bulk') — null renders the single
  /// recent-e1RM column (no `last_bulk:` window configured).
  final String? second;
  const _LiftHeaderRow({this.second});

  @override
  Widget build(BuildContext context) {
    final style = AppText.tag(
      context,
    )?.copyWith(fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          const SizedBox(width: 64),
          Expanded(
            child: Text(
              // RPE-adjusted basis since 2026-09-25 (max_e1rm_rpe);
              // wraps to a second line at narrow widths — reflow.
              'recent e1RM (RPE-adj)',
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          if (second != null)
            Expanded(
              child: Text(second!, textAlign: TextAlign.right, style: style),
            ),
        ],
      ),
    );
  }
}

/// One lift's columns, aligned under the header: recent e1RM (14-day
/// best of real work) vs the LAST-BULK top (2026-09-22 — the all-time
/// top moved to the detail sheet), each `315 · 121.4w · <when>` —
/// pounds, per-lift Wilks points (current bw for recent,
/// contemporaneous bw for the bulk top), and a WHEN tag: age ("2d")
/// for the recent number, the PR month ("Jun '25") for the bulk top —
/// a year-old date reads better as a month than as "15mo", and it
/// matches the Wilks benchmark's "best ever … · May '24" vocabulary
/// (the sheet's all-time lines use the same month tags). Readability
/// pass 2026-09-25 (user: "fonts are too small on the homepage"):
/// numbers at AppText.value (16sp w700), Wilks + when tags at
/// AppText.tag (12sp floor, onSurfaceVariant) — and the size increase
/// is absorbed by LAYOUT, not ellipsis: cells soft-wrap to a second
/// line when the tags don't fit beside the number.
class _LiftNumbersRow extends StatelessWidget {
  final String lift;
  final _LiftValue? recent;
  final _LiftValue? bulk;

  /// Whether the bulk column exists at all — a lift with no bulk-window
  /// history still needs its '—' placeholder to keep the grid aligned,
  /// but an unconfigured window renders no second column anywhere.
  final bool showBulk;
  final DateTime today;
  const _LiftNumbersRow({
    required this.lift,
    required this.recent,
    required this.bulk,
    required this.showBulk,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final numStyle = AppText.value(context);
    final tagStyle = AppText.tag(context);
    Widget cell(_LiftValue? v, String Function(DateTime) when) => Expanded(
      child: v == null
          ? Text('—', textAlign: TextAlign.right, style: tagStyle)
          : Text.rich(
              TextSpan(
                text: fmtLb(v.value.roundToDouble()),
                style: numStyle,
                children: [
                  if (v.wilks != null)
                    TextSpan(
                      text: ' · ${v.wilks!.toStringAsFixed(1)}w',
                      style: tagStyle,
                    ),
                  TextSpan(text: ' · ${when(v.date)}', style: tagStyle),
                ],
              ),
              textAlign: TextAlign.right,
              // Reflow, don't shrink: the tags wrap under the number
              // when the column is narrow (16sp numbers need room).
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Padding(
              // Optically aligns the 12sp label with the 16sp numbers.
              padding: const EdgeInsets.only(top: 2),
              child: Text(lift, style: tagStyle),
            ),
          ),
          cell(recent, (d) => fmtAge(d, today)),
          if (showBulk) cell(bulk, fmtMonthTag),
        ],
      ),
    );
  }
}

/// Narrow-width STRENGTH reflow (readability pass 2026-09-25): when the
/// legacy half-width grid can't hold 16sp two-column cells, each lift
/// becomes a full-width block — name line + one value line per basis
/// ("e1RM 310 · 120.0w · 2d" / "bulk 315 · 113.8w · Jun '25") — layout
/// absorbs the bigger type instead of ellipsis. The wide layout keeps
/// the aligned columns (_LiftHeaderRow + _LiftNumbersRow).
class _LiftStackedRows extends StatelessWidget {
  final String lift;
  final _LiftValue? recent;
  final _LiftValue? bulk;
  final bool showBulk;
  final DateTime today;
  const _LiftStackedRows({
    required this.lift,
    required this.recent,
    required this.bulk,
    required this.showBulk,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final numStyle = AppText.value(context);
    final tagStyle = AppText.tag(context);
    final basisStyle = tagStyle?.copyWith(fontWeight: FontWeight.w600);
    Widget line(String basis, _LiftValue? v, String Function(DateTime) when) =>
        Text.rich(
          TextSpan(
            text: '$basis  ',
            style: basisStyle,
            children: [
              if (v == null)
                TextSpan(text: '—', style: tagStyle)
              else ...[
                TextSpan(text: fmtLb(v.value.roundToDouble()), style: numStyle),
                if (v.wilks != null)
                  TextSpan(
                    text: ' · ${v.wilks!.toStringAsFixed(1)}w',
                    style: tagStyle,
                  ),
                TextSpan(text: ' · ${when(v.date)}', style: tagStyle),
              ],
            ],
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lift, style: basisStyle),
          line('e1RM (RPE-adj)', recent, (d) => fmtAge(d, today)),
          if (showBulk) line('bulk', bulk, fmtMonthTag),
        ],
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
          // Readability pass 2026-09-22: explainer copy at bodyMedium
          // (14sp) — bodySmall read as fine print on the dark theme.
          Text(
            entry.explain,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
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
          // Readability pass 2026-09-25: label stacked ABOVE the value
          // — the 16sp count and a 12sp label don't share a narrow
          // quota column's width, so the layout gives each its own line.
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.tag(context),
          ),
          Text(
            '${done == null ? '—' : fmtLb(done!)}/${targetText(target)}',
            style: AppText.value(context),
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
        style: AppText.tag(context)?.copyWith(
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

  /// Row-tap handler — the state decides sheet-vs-navigate per row id
  /// (the Wilks rows open the decomposition sheet, 2026-09-25).
  final void Function(EigenRowData) onRowTap;

  const _HeroCard({required this.hero, required this.onRowTap});

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
                    style: AppText.tag(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final row in hero.rows)
              _EigenRowTile(row: row, onTap: () => onRowTap(row)),
          ],
        ),
      ),
    );
  }
}

/// One eigenvector row inside the hero. Tap behavior is the state's
/// call: the Wilks rows open the decomposition sheet, the rest
/// navigate to the owning screen (Program / status ledger).
class _EigenRowTile extends StatelessWidget {
  final EigenRowData row;
  final VoidCallback onTap;

  const _EigenRowTile({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (_, fg) = _eigenColors(scheme, row.verdict);
    // Readability pass 2026-09-25: the detail line's leading value
    // ("178.4 lb", "Wilks 327.5") renders at AppText.value (16sp
    // w700); the ' · rate · target' context that follows stays a 12sp
    // tag. Placeholder details ("no Wilks history yet") have no digits
    // and stay tags. maxLines 2 — the line WRAPS instead of
    // ellipsizing when the bigger type needs the room.
    final split = row.detail.indexOf(' · ');
    final head = split < 0 ? row.detail : row.detail.substring(0, split);
    final rest = split < 0 ? null : row.detail.substring(split);
    final headIsValue = RegExp(r'\d').hasMatch(head);
    final detail = Text.rich(
      TextSpan(
        text: head,
        style: headIsValue ? AppText.value(context) : AppText.tag(context),
        children: [
          if (rest != null)
            TextSpan(text: rest, style: AppText.tag(context)),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final hasSpark = row.spark.length >= 2;
            // Reflow, don't shrink: on narrow rows (360dp-class
            // screens) the sparkline stacks BELOW the numbers instead
            // of squeezing the 16sp value into ellipsis.
            final sideBySide = hasSpark && constraints.maxWidth >= 340;
            final spark = hasSpark
                ? _Sparkline(
                    points: row.spark,
                    reference: row.sparkReference,
                    floor: row.sparkFloor,
                    color: fg,
                  )
                : null;
            return Row(
              children: [
                _EigenChip(verdict: row.verdict),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.label.toUpperCase(),
                        style: AppText.title(context),
                      ),
                      detail,
                      if (spark != null && !sideBySide) ...[
                        const SizedBox(height: 4),
                        spark,
                      ],
                    ],
                  ),
                ),
                if (spark != null && sideBySide) ...[
                  const SizedBox(width: 6),
                  spark,
                ],
                Icon(Icons.chevron_right, size: 18, color: scheme.outline),
              ],
            );
          },
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
      constraints: const BoxConstraints(minWidth: 74),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      // Readability pass 2026-09-25: the old hand-set 9.5sp is gone —
      // AppText.chip sits on the 12sp floor; the row reflows (spark
      // below the numbers) to give the wider chip its room.
      child: Text(_eigenChipText(verdict), style: AppText.chip(context, color: fg)),
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
/// One driver pill: label + tick/progress, tinted by status — green
/// met, neutral pending, error-tinted violated (a breached cap/floor).
/// Per-lift drivers spell the lifts out ("squat ✓ · bench —" /
/// "squat 1/2 …" — clarity pass 2026-09-29, no more single-letter
/// ticks); the muscle-volume driver shows a summary ("3 of 7 groups in
/// the 8-12-set range" — the per-group list is one tap away in the
/// detail sheet); the stale climb count wears its "as of `last
/// import`" tag.
class _DriverPill extends StatelessWidget {
  final DriverEval eval;
  const _DriverPill({required this.eval});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (eval.status) {
      DriverStatus.met => (
        Colors.green.withValues(alpha: 0.18),
        Colors.green.shade800,
      ),
      DriverStatus.pending => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      DriverStatus.violated => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
    };
    final detail = eval.config.id == 'hypertrophy_volume' &&
            eval.ticks.isNotEmpty
        ? HomeDashboardState.hypertrophyLines(eval).$1
        : eval.ticks.isNotEmpty
        ? eval.ticks.map(HomeDashboardState._tickText).join(' · ')
        : eval.staleAsOf != null
        ? '${eval.value} · as of '
              '${DateFormat('MMM d').format(eval.staleAsOf!)}'
        : eval.value;
    // Readability pass 2026-09-25: AppText.tag (12sp floor) — the
    // pills' Wrap parent already reflows them onto extra rows.
    final style = AppText.tag(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text.rich(
        TextSpan(
          text: '${eval.label} ',
          style: style?.copyWith(color: scheme.onSurfaceVariant),
          children: [
            TextSpan(
              text: detail,
              style: style?.copyWith(color: fg, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// The singles driver's heavy-single recency line ("heavy single:
/// S 4d · D 16d — overdue"), colored by the WORST band: normal tag
/// color while fresh, amber once any lift is past
/// `heavy_single_max_days`, error red a week past that.
class _HeavySingleLine extends StatelessWidget {
  final DriverEval eval;
  const _HeavySingleLine({required this.eval});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final worst = eval.heavyRecency
        .map((h) => h.band.index)
        .fold(0, (a, b) => a > b ? a : b);
    final color = switch (HeavySingleBand.values[worst]) {
      HeavySingleBand.fresh => scheme.onSurfaceVariant,
      HeavySingleBand.overdue => Colors.orange.shade900,
      HeavySingleBand.stale => scheme.error,
    };
    return Text(
      HomeDashboardState.heavyRecencyText(eval)!,
      style: AppText.tag(context)?.copyWith(
        color: color,
        fontWeight: worst > 0 ? FontWeight.w600 : null,
      ),
    );
  }
}

class _WeekOfNote extends StatelessWidget {
  final StatusWeek week;
  const _WeekOfNote({required this.week});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        'wk of ${DateFormat('MMM d').format(week.weekMonday)}',
        style: AppText.tag(context)?.copyWith(
          color: Theme.of(context).colorScheme.tertiary,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}
