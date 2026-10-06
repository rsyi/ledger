import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../models/github_config.dart';
import '../models/model_config.dart';
import '../models/quickbooks_config.dart';
import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/app_config.dart';
import '../services/app_settings.dart';
import '../services/connector_registry.dart';
import '../services/engine.dart';
import '../services/engine_ledger_connector.dart';
import '../services/sync_scheduler.dart';
import '../services/engine_schema_adapter.dart';
import 'widgets/sync_status_button.dart';
import 'widgets/today_status_card.dart';
import 'widgets/log_list_row.dart';
import 'design/components.dart' show RowGroupCard, SectionHeader;
import 'design/tokens.dart' show AppSpace;
import '../services/display_names.dart';
import 'config_gate.dart' show loadBakedServiceAccountKey;
import 'settings_screen.dart';
import '../services/heart_rate_service.dart';
import '../services/integrations/gmail_gateway.dart';
import '../services/integrations/kaya_gmail.dart';
import '../services/video_attach.dart';
import '../services/video_file_store.dart';
import '../services/video_rpe.dart';
import '../services/integrations/macrofactor.dart';
import '../services/integrations/registry.dart';
import '../services/integrations/whoop.dart';
import '../services/integrations/whoop_api.dart';
import '../services/integrations/withings.dart';
import '../services/carryover_check.dart';
import '../services/coach_brain.dart';
import '../services/day_synthesis_service.dart';
import '../services/domain_config.dart';
import '../services/config_source/config_source.dart';
import '../services/config_source/config_source_registry.dart';
import '../services/config_source/github_config_source.dart';
import '../services/github_client.dart';
import '../services/log_event_bus.dart';
import '../services/llm_client.dart';
import '../services/llm_response_cache.dart';
import '../services/notification_service.dart';
import '../services/post_log_notifier.dart';
import '../services/qbo_service.dart';
import '../services/schema_loader.dart';
import '../services/schema_sync.dart';
import '../services/sheets_repository.dart';
import '../services/transient_retry.dart';
import '../services/warehouse_connector.dart';
import '../services/plan_store.dart';
import '../services/program_provider.dart';
import '../services/today_program_call.dart';
import '../services/today_thread.dart';
import '../services/week_planner.dart';
import '../services/forecast_meta_store.dart';
import '../services/google_auth/data_account.dart';
import '../services/google_auth/google_identity.dart';
import '../services/projection_snapshot_store.dart';
import '../services/projection_tracking.dart' show PhaseProjections;
import '../services/wm_store.dart';
import 'chat_screen.dart';
import 'coach_chat_screen.dart';
import 'domain_screen.dart';
import 'program_screen.dart';
import 'coach_threads_screen.dart';
import 'widgets/daily_progress_card.dart';
import 'widgets/program_day_card.dart';
import 'widgets/recovery_card.dart';
import 'home_dashboard.dart';
import 'goals_screen.dart';
import 'app_text.dart';
import 'timeline_screen.dart';
import 'home_tabs.dart';
import 'lift_screen.dart';
import 'plan_data.dart';
import 'phase_projection_screen.dart';
import 'strength_screen.dart';
import 'weight_screen.dart';

/// The synced view that backs the coach chat. Hidden from the normal
/// tile list; surfaced only through the pinned Coach row + chat screen.
const kCoachChatViewName = 'coach_chat';

/// App entrypoint shell. Loads config + schemas, connects to the
/// warehouse, and presents a 4-tab NavigationBar — Today · Log · Week ·
/// Progress (2026-10-02 order; indices are the `_tab*` constants). The
/// Plan tab folded into Progress the same day (IA restructure): the
/// block timeline sits on Progress, the forecast lives behind the
/// Weight / Strength rows, and each lift row opens its own page.
/// Progress/Goals split 2026-09-29 — the output-over-input principle
/// made literal: the old combined Home tab divided into an OUTPUT
/// surface and an INPUT surface (Goals is the Week tab):
///
///   PROGRESS outputs only — the PHASE hero (weight trajectory + the
///            body verdict) + the STRENGTH card (working-max / Wilks /
///            e1RM trends), home_dashboard.dart in progressOnly mode, and
///            the Coach preview row (cross-cutting, kept at the top). No
///            input/adherence content. Its app bar carries the settings
///            gear that opens Integrations (app setup, not logging).
///   GOALS    the phase's INPUT eigenvectors as plain-language rows with
///            a met / partial / unmet state (goals_screen.dart +
///            goals_service.dart): macros, calorie band vs phase, ~10
///            hard sets per main lift, climbing 2x, one 4x4. Declared in
///            app/dashboards.yaml `goals:`, phase-selected.
///   LOG      the tracker rows, grouped by `app/dashboards.yaml` into
///            LOG (entry domains) and CONNECTED (integration domains —
///            read-friendly record lists; rows arrive via sync, with a
///            manual escape hatch on writable views like weight);
///            unclaimed views still list
///            under LOG so nothing becomes unreachable; missing/bad
///            config falls back to the flat "Ledgers" section.
///   COACH    the coach threads screen embedded as the tab root (the
///            old pinned-row → pushed-threads flow, minus the push);
///            opening a thread still pushes the chat.
///   (PLAN    retired 2026-10-02 — phases → Progress' PHASE section;
///            forecast → the Weight / Strength pages; the ROUTINE
///            (Program screen) opens from Today's "Full week" action and
///            the Week tab's app-bar icon.)
///
/// Bootstrap stays at THIS level: one FutureBuilder feeds every tab, so
/// the SchemaSync poller's rebuild swaps all four bodies at once and
/// the selected tab (a plain State field) survives. Tab switches don't
/// push routes, so the poller's canPop() mid-task guard keeps working.
///
/// Database + schemas are baked into the APK at build time (via
/// `tool/brand.dart` resolving `config.yml` + `.env`). No in-app
/// settings page — what's bundled is what runs.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late Future<_Bootstrap> _bootstrap;

  /// Daily missed-work carryover check (in-app fallback for the nightly
  /// briefing). Set by build once the coach is available; run after the
  /// first bootstrap, on every app resume and on each home-poller tick
  /// (the check itself gates to once a day). Fire-and-forget — never blocks the UI.
  Future<void> Function()? _carryoverCheck;
  bool _carryoverKicked = false;

  /// Resume/poller throttle: until the day's check fires, each run re-reads the
  /// week's logs — at most one attempt per 10 minutes.
  DateTime? _carryoverLastRun;

  /// Background GitHub poller. The app runs in always-open kiosk mode, so
  /// schema changes can't ride in on a launch — this timer pulls them in
  /// while the app is live. Null until the first bootstrap wires it up.
  Timer? _syncTimer;

  /// Re-runs the week planner when a program_moves row is written or
  /// deleted (moves/skips change which days carry which work).
  StreamSubscription<LogEvent>? _movesSub;

  /// The week-planner run (set by bootstrap); also re-run on resume so
  /// moves that arrived by sync (coach, nightly) reach the plan.
  Future<void> Function()? _replan;

  /// Signature of the cache state the CURRENT UI was built from (recorded
  /// by [_initialize]). Distinct from the cache's own signature on disk: a
  /// poller refresh can land while the user is mid-form, leaving the cache
  /// newer than the UI. The poller compares the two and rebuilds once the
  /// user is back on the home screen — conflating them used to strand the
  /// UI on a stale view list until a manual sync.
  String? _appliedSig;

  /// Reentrancy guard so overlapping ticks (slow network) don't stack.
  bool _polling = false;

  /// Bottom-nav tab indices (2026-10-02 order: Log sits right after
  /// Today). Every tab switch goes through these names — never a bare
  /// index — so a reorder is a one-place change.
  static const int _tabToday = HomeTabs.today;
  static const int _tabLog = HomeTabs.log;
  static const int _tabWeek = HomeTabs.week;
  static const int _tabProgress = HomeTabs.progress;

  /// Selected bottom-nav tab (one of the `_tab*` constants). Plain state
  /// field so it survives the poller's setState rebuilds.
  int _tab = _tabToday;

  /// Visited-tab stack (excluding the current tab) so the system Back
  /// button returns to the previous tab instead of exiting the app.
  /// Capped so a long session can't grow it unbounded; older entries
  /// drop off the bottom.
  final List<int> _tabHistory = [];

  /// Switch tabs, recording the departed tab for Back. Collapses any
  /// existing occurrence of the target so history stays a simple
  /// most-recent-first trail without cycles.
  void _selectTab(int i) {
    if (i == _tab) return;
    setState(() {
      _tabHistory
        ..remove(_tab)
        ..add(_tab);
      if (_tabHistory.length > 8) _tabHistory.removeAt(0);
      _tabHistory.remove(i);
      _tab = i;
    });
    if (i == _tabToday) {
      _todayStatusKey.currentState?.refresh();
      _recoveryKey.currentState?.reload();
      _dailyProgressKey.currentState?.reload();
      _todayProgramKey.currentState?.reload();
    }
  }

  /// Handle on the progress dashboard so pull-to-refresh can bust its
  /// caches (wm_store / program docs / weight mirror / best-e1RM).
  final _dashboardKey = GlobalKey<HomeDashboardState>();

  /// Handle on the Goals tab so pull-to-refresh re-evaluates the goal
  /// rows (busts the shared dashboards-config cache).
  final _goalsKey = GlobalKey<GoalsScreenState>();

  /// Handle on the LOG/CONNECTED sections so pull-to-refresh re-pulls
  /// app/dashboards.yaml (1 h cache otherwise).
  final _domainsKey = GlobalKey<_DomainSectionsState>();

  /// Handle on the Today tab's today-vs-plan status card: switching
  /// back to Today after logging refreshes its food/training lines
  /// immediately (pull-to-refresh recomputes it too).
  final _todayStatusKey = GlobalKey<TodayStatusCardState>();

  /// Handle on the Today tab's daily-progress (calorie + macro bars) card,
  /// so pull-to-refresh re-reads meals/weight/targets alongside the status
  /// card.
  final _dailyProgressKey = GlobalKey<DailyProgressCardState>();

  /// Today tab's per-day cards — reloaded on the tab's pull-to-refresh
  /// (several also self-refresh on log events / day change via
  /// didUpdateWidget).
  final _todayProgramKey = GlobalKey<ProgramDayCardState>();
  final _recoveryKey = GlobalKey<RecoveryCardState>();

  /// The day the Today tab is showing (date-only). The top-of-tab day
  /// navigator shifts it; every card on the tab reflects it.
  DateTime _dayViewDate = _dateOnly(DateTime.now());

  void _shiftDay(int delta) => setState(
      () => _dayViewDate = _dayViewDate.add(Duration(days: delta)));

  bool get _dayViewIsToday {
    final t = _dateOnly(DateTime.now());
    return _dayViewDate == t;
  }

  /// Relative label for the day navigator ("Today"/"Tomorrow"/"Yesterday"
  /// or a weekday-date).
  String _dayViewLabel() {
    final diff = _dayViewDate.difference(_dateOnly(DateTime.now())).inDays;
    switch (diff) {
      case 0:
        return 'Today';
      case 1:
        return 'Tomorrow';
      case -1:
        return 'Yesterday';
      default:
        const months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        ];
        const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        return '${days[_dayViewDate.weekday - 1]} '
            '${months[_dayViewDate.month - 1]} ${_dayViewDate.day}';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSettings.weekStartSetting.addListener(_onWeekStartChanged);
    _bootstrap = _initialize();
  }

  /// The week start changed (Settings screen, or a refresh picked up a
  /// change made elsewhere): re-plan the week window and refresh every
  /// week-shaped surface (Week tab goals, Today cards, Progress).
  void _onWeekStartChanged() {
    final replan = _replan;
    if (replan != null) unawaited(replan().catchError((Object _) {}));
    if (!mounted) return;
    setState(() {});
    unawaited(_goalsKey.currentState?.reload());
    unawaited(_dashboardKey.currentState?.reload());
    _todayStatusKey.currentState?.refresh();
    _todayProgramKey.currentState?.reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppSettings.weekStartSetting.removeListener(_onWeekStartChanged);
    _syncTimer?.cancel();
    _movesSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _runCarryoverCheck();
      final replan = _replan;
      if (replan != null) unawaited(replan().catchError((Object _) {}));
    }
  }

  void _runCarryoverCheck() {
    final run = _carryoverCheck;
    if (run == null) return;
    final now = DateTime.now();
    final last = _carryoverLastRun;
    if (last != null && now.difference(last) < const Duration(minutes: 10)) {
      return;
    }
    _carryoverLastRun = now;
    unawaited(run().catchError((Object _) {}));
  }

  Future<_Bootstrap> _initialize() async {
    final assetConfig = await AppConfig.load();
    final packageInfo = await PackageInfo.fromPlatform();

    // Start the background poller once (guarded — _initialize re-runs on
    // every sync/reload).
    // The ACTIVE config source (multi-user sub-project 1): the baked repo
    // on the owner build, a user-connected repo otherwise (the app root
    // re-creates this screen when it changes).
    final source = ConfigSourceRegistry.active.value;
    final poll = source?.pollInterval;
    if (_syncTimer == null && source != null && poll != null) {
      _syncTimer = Timer.periodic(
        poll,
        (_) {
          _pollGithub(source);
          // Kiosk mode never resumes: the poller tick is the carryover
          // check's other trigger (same gates + 10-min throttle).
          _runCarryoverCheck();
        },
      );
    }

    // Record the cache state this build reads from BEFORE loading: if a
    // refresh swaps the cache mid-load we'd rather re-render once too
    // often than record a signature newer than the views we show.
    // A freshly connected (non-baked) source has no cache yet: pull it
    // before loading, or the bundled (owner's) schemas would render until
    // the first poll tick. Best-effort — a failure falls back as before.
    if (source != null &&
        source is! BakedGitHubSource &&
        !await SchemaSync.hasCachedSchemas()) {
      await SchemaSync(source).refresh();
    }
    _appliedSig = await SchemaSync.cachedSignature();
    final views = await SchemaLoader.loadAll();
    // DATA account (multi-user sub-project 2): the baked service account +
    // baked spreadsheet on the owner build (unchanged), else the user's
    // Google sign-in + their spreadsheet. Resolved by the ConfigGate; the
    // fallback covers a gate that skipped (unreadable assets config).
    final data = DataAccountRegistry.current.value ??
        await DataAccountRegistry.init(
          bakedKeyJson: await loadBakedServiceAccountKey(),
          bakedSpreadsheetId: assetConfig.spreadsheetId,
          google: GoogleSignInIdentity(
              serverClientId: assetConfig.googleServerClientId ?? ''),
        );
    final dataAuth = data.auth;
    final spreadsheetId = data.spreadsheetId;
    // Synced settings (app_settings tab): the cached week start loads
    // BEFORE anything plans a week; the tab re-read runs in the
    // background and notifies (→ _onWeekStartChanged) on a change.
    await AppSettings.init(
      spreadsheetId: spreadsheetId,
      auth: dataAuth,
    );
    unawaited(AppSettings.refresh());
    // Working-max controller tabs (WM-2). Cheap to construct — auth is
    // lazy (first snapshot()/append). Feeds the planner's v3 weights, the
    // Week Plan prescription blocks, and the Program screen's
    // CONFIGURATION card.
    final wmStore = WmStore(
      spreadsheetId: spreadsheetId,
      auth: dataAuth,
    );
    // Nightly forecast recalibration state (forecast_meta tab) — read
    // by the Plan tab's "model tracking" line; auth is lazy.
    final forecastMetaStore = ForecastMetaStore(
      spreadsheetId: spreadsheetId,
      auth: dataAuth,
    );
    // Frozen phase projections (append-only projection_snapshots tab) —
    // the Weight / Strength / Lift pages + the Progress phase timeline.
    final projectionStore = ProjectionSnapshotStore(
      spreadsheetId: spreadsheetId,
      auth: dataAuth,
    );
    final repo = await retryTransient(
      () => connectSheetsConnectorFor(
        defaultSpreadsheetId: spreadsheetId,
        auth: dataAuth,
      ),
    );
    final registry = await ConnectorRegistry.build(
      configs: const [],
      bundledSheets: repo,
    );
    // Skip analytics-only views (no .input.yml) and read-only views.
    // Analytics-only: their dimensions are SQL expressions (e.g.
    // `CAST(date AS DATE)`), so passing them to `ensureTable` would try
    // to write those exprs as sheet column headers — corrupts the
    // underlying sheet and surfaces as a "bad state: can't finalize a
    // finalized request" mid-startup.
    // Read-only: these views are backed by a direct sheet read and must
    // never touch the engine ledger or have their sheet tabs "ensured"
    // (that would rewrite headers on tabs like kaya_ascents that the app
    // doesn't own).
    for (final view in views.where((v) => v.hasInputOverlay && !v.readOnly)) {
      // Wrap the first network-touching calls: the engine's reqwest client
      // can hit a cold-start DNS failure on the first request after launch
      // (see retryTransient). A few short retries ride out the window that
      // a manual refresh would otherwise have to.
      await retryTransient(() => registry.forView(view).ensureTable(view));
    }
    // Local-first: hand the sync scheduler the gsheets entry views and
    // fire the app-start sync. (ensureTable above is a local no-op on
    // the ledger connector — the sheet tabs get ensured during sync.)
    if (repo is EngineLedgerConnector) {
      // Integrations first: the scheduler's app-start sync pulls due
      // sources before pushing the ledger.
      ViewSchema? weightView;
      ViewSchema? mealsView;
      ViewSchema? recoveryView;
      ViewSchema? whoopWorkoutsView;
      for (final v in views) {
        if (v.name == 'weight') weightView = v;
        if (v.name == 'meals') mealsView = v;
        if (v.name == 'recovery') recoveryView = v;
        if (v.name == 'whoop_workouts') whoopWorkoutsView = v;
      }
      // _initialize() re-runs on schema reload; tear down the previous
      // service's BLE connection + retry timer before replacing it.
      await HeartRateService.instance?.disconnect();
      final hrService = HeartRateService(repo: repo.repo);
      HeartRateService.instance = hrService;
      await hrService.init();
      IntegrationRegistry.init(
        integrations: [
          if (weightView != null)
            WithingsIntegration(
              config: assetConfig.withings,
              repo: repo.repo,
              weightViewJson: viewSchemaToEngineJson(weightView),
            ),
          // Kaya: climbing data lives in the kaya_ascents tab for the MCP
          // (user's choice — not synced into the ledger). The card's
          // guided Sync opens Kaya for its email export, watches Gmail
          // (gmail.readonly via Google sign-in), and replace-alls the tab.
          // The full KayaIntegration (API pull → ingest) is dormant in
          // kaya.dart.
          KayaGmailIntegration(
            config: assetConfig.kayaGmail,
            repo: repo.repo,
            gateway: GoogleSignInGmailGateway(
              serverClientId: assetConfig.kayaGmail?.serverClientId ?? '',
            ),
            store: SheetsKayaTabStore(
              spreadsheetId: spreadsheetId,
              auth: dataAuth,
            ),
          ),
          WhoopIntegration(hr: hrService),
          // Whoop developer API → the OWN `recovery` view (objective sleep
          // + recovery). Wholly distinct from the BLE live-HR
          // WhoopIntegration above: OAuth2 background pull mapping each
          // night's sleep + each day's recovery onto its own first-class
          // recovery tab (owns the objective device fields sleep_hours /
          // sleep_performance_pct / sleep_efficiency_pct /
          // sleep_consistency_pct / recovery_score / hrv_ms / resting_hr /
          // respiratory_rate; the free-text note stays user-owned).
          // daily_notes KEEPS its manual recovery subjectives — Whoop no
          // longer writes there (2026-09-30).
          if (recoveryView != null)
            WhoopApiIntegration(
              config: assetConfig.whoopApi,
              repo: repo.repo,
              recoveryViewJson: viewSchemaToEngineJson(recoveryView),
              // Whoop workouts (strain) → the own whoop_workouts tab,
              // row-grained by workout_id. Pulled on the same window as
              // sleep/recovery so the coach sees the day's workout(s)
              // alongside its recovery; the LLM joins a workout to a
              // logged session by date/time overlap. Null view (older
              // schema set) → the workouts pull is simply skipped.
              workoutsViewJson: whoopWorkoutsView == null
                  ? null
                  : viewSchemaToEngineJson(whoopWorkoutsView),
            ),
          // Macrofactor exports nutrition to Health Connect; the
          // integration reads HC nutrition records and ingests them as
          // meals rows keyed by hc_id (row-grained kaya pattern).
          if (mealsView != null)
            MacrofactorIntegration(
              repo: repo.repo,
              mealsViewJson: viewSchemaToEngineJson(mealsView),
            ),
        ],
      );
      await SyncScheduler.init(
        ledger: repo,
        viewsJson: views
            .where(
              (v) =>
                  v.hasInputOverlay && v.datasource == 'gsheets' && !v.readOnly,
            )
            .map(viewSchemaToEngineJson)
            .toList(),
      );
      // Weekly auto-planner: generate this week's planned strength rows
      // from coach/program.yaml. Fire-and-forget — ensureCurrentWeek is
      // idempotent per week (meta-keyed) and swallows its own errors
      // into the `week_planner_error` meta.
      ViewSchema? strengthView;
      ViewSchema? movesView;
      for (final v in views) {
        if (v.name == 'strength') strengthView = v;
        if (v.name == 'program_moves') movesView = v;
      }
      if (source != null && strengthView != null) {
        final sv = strengthView;
        final provider = ProgramProvider(source.docFetcher);
        // program_moves applied (plan_v9): a move/skip/undo re-plans the
        // affected days right away (LogEventBus fires on program_moves
        // create AND delete).
        Future<void> replan() => WeekPlanner.ensureCurrentWeek(
              repo: repo.repo,
              connector: repo,
              provider: provider,
              strengthView: sv,
              programMovesView: movesView,
              wmSnapshotOf: wmStore.snapshot,
            );
        _replan = replan;
        unawaited(replan());
        await _movesSub?.cancel();
        // A strength edit/delete re-checks the window too (a day whose
        // logged sets were all removed is no longer frozen mid-session).
        _movesSub = LogEventBus.instance.stream
            .where((e) =>
                e.view == 'program_moves' ||
                (e.view == 'strength' && !e.isCreate))
            .listen((_) => unawaited(replan()));
      }
    }
    // Read-only views: connect a direct SheetsRepository that bypasses the
    // engine ledger entirely. Only established when at least one loaded view
    // is read-only — avoids a superfluous auth round-trip on builds without
    // read-only views.
    WarehouseConnector? readOnlyRepo;
    final hasReadOnlyViews = views.any((v) => v.hasInputOverlay && v.readOnly);
    if (hasReadOnlyViews) {
      readOnlyRepo = await retryTransient(
        () => SheetsRepository.connectWithAuth(
          defaultSpreadsheetId: spreadsheetId,
          auth: dataAuth,
        ),
      );
    }

    // disable_post_log in config.yml gates every piece of the LLM plumbing.
    // When set, we hand TimelineScreen `null` llm/cache so the post-log hook
    // is a no-op even for views that declare one — useful for builds (Poke
    // House) where we don't want any LLM behavior at all.
    final llm = assetConfig.disablePostLog
        ? null
        : LlmClient(assetConfig.models);
    final llmCache = assetConfig.disablePostLog ? null : LlmResponseCache();
    // Video attach (strength form `widget: video`): the Android system
    // photo picker over LOCAL clips — no Google config or scopes needed,
    // so the service is always on (the retired Photos Picker API path
    // needed the Kaya web client id + a download that expired).
    final engineRepo = repo is EngineLedgerConnector ? repo.repo : null;
    VideoRpeService.instance = VideoRpeService(
      flow: VideoAttachFlow(cachePathFor: VideoFileStore.pathFor),
      llm: llm,
      modelName: llm?.visionModelName(),
      metaGet: engineRepo?.metaGet,
      metaSet: engineRepo?.metaSet,
    );
    // AnalyticsEngine = airlayer compiler + LocalDb SQLite cache. Used by
    // the chat's run_query tool. Best-effort: if the native lib fails to
    // load on this platform, the chat opens without run_query and the
    // rest of the app keeps working.
    AnalyticsEngine? analytics;
    try {
      analytics = await AnalyticsEngine.create();
    } catch (_) {
      analytics = null;
    }
    return _Bootstrap(
      views: views,
      repository: repo,
      registry: registry,
      appName: packageInfo.appName,
      llm: llm,
      llmCache: llmCache,
      models: assetConfig.models,
      configSource: source,
      analytics: analytics,
      kioskView: assetConfig.kioskView,
      quickbooks: assetConfig.quickbooks,
      qboService: assetConfig.quickbooks == null
          ? null
          : QboService(assetConfig.quickbooks!),
      readOnlyRepo: readOnlyRepo,
      wmStore: wmStore,
      forecastMetaStore: forecastMetaStore,
      projectionStore: projectionStore,
    );
  }

  /// One poll tick, two independent catch-ups. (1) Cache vs remote:
  /// [SchemaSync.ensureFresh] re-pulls when the repo changed — safe even
  /// while the user is mid-task, it only touches the disk cache. (2) UI vs
  /// cache: rebuild when the current UI was built from an older cache
  /// state, deferred (not dropped) while anything is pushed on top of the
  /// home screen — rebuilding then would tear down in-progress work, so we
  /// retry on the next tick until the user is back. Silent (no snackbars);
  /// this runs unattended in kiosk mode.
  Future<void> _pollGithub(ConfigSource cfg) async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final cached = await SchemaSync(cfg).ensureFresh();
      if (cached == null || cached == _appliedSig) return; // UI is current
      if (!mounted) return;
      if (Navigator.of(context).canPop()) return; // mid-task; retry later
      setState(() => _bootstrap = _initialize());
    } finally {
      _polling = false;
    }
  }

  /// Pulls schemas/templates from GitHub, then rebuilds the view list
  /// from the refreshed cache. Surfaces success/error via a snackbar.
  Future<void> _syncFromGithub(ConfigSource cfg) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Syncing schemas from GitHub…'),
        duration: Duration(seconds: 30),
      ),
    );
    try {
      final result = await SchemaSync(cfg).refresh();
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      if (!result.ok) {
        messenger.showSnackBar(
          SnackBar(content: Text('Sync failed: ${result.error}')),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Synced ${result.fetched} file(s) from ${cfg.displayName}',
          ),
        ),
      );
      setState(() => _bootstrap = _initialize());
    } catch (e) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Sync failed: $e')));
    }
  }

  /// Picks the first Anthropic model from config — chat only supports
  /// Anthropic right now (the tool-use loop is Anthropic-shaped).
  ModelConfig? _chatModel(List<ModelConfig> models) {
    for (final m in models) {
      if (m.vendor == ModelVendor.anthropic) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Bootstrap>(
      future: _bootstrap,
      builder: (context, snap) {
        final appName = snap.data?.appName ?? 'Ledger';
        final boot = snap.data;
        final github = boot?.github;
        final configSource = boot?.configSource;
        final chatModel = boot == null ? null : _chatModel(boot.models);
        // Kiosk short-circuit: when config.yml declares `kiosk_view:` and a
        // view by that name exists, the home screen never renders — the app
        // boots directly into the timeline for that view with all
        // admin/dev chrome (chat, sync, reload, back, view picker) hidden.
        // Built for fleet deploys (Poke House on iPads) where non-technical
        // employees should never see anything but the one tracker.
        if (boot != null && boot.kioskView != null) {
          ViewSchema? kioskView;
          for (final v in boot.views) {
            if (v.name == boot.kioskView) {
              kioskView = v;
              break;
            }
          }
          if (kioskView != null) {
            return TimelineScreen(
              view: kioskView,
              repository: boot.registry.forView(kioskView),
              llm: boot.llm,
              llmCache: boot.llmCache,
              chatModel: null,
              github: null,
              analytics: boot.analytics,
              kioskMode: true,
              qboSpec: boot.quickbooks?.specFor(kioskView.name),
              qboService: boot.quickbooks?.specFor(kioskView.name) == null
                  ? null
                  : boot.qboService,
            );
          }
        }
        return PopScope(
          // Back returns to the previously-visited tab; only the root
          // tab with no history lets the pop through (exits the app).
          canPop: _tabHistory.isEmpty,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || _tabHistory.isEmpty) return;
            final prev = _tabHistory.removeLast();
            setState(() => _tab = prev);
            if (prev == _tabToday) {
              _todayStatusKey.currentState?.refresh();
              _recoveryKey.currentState?.reload();
              _dailyProgressKey.currentState?.reload();
              _todayProgramKey.currentState?.reload();
            }
          },
          child: Scaffold(
          body: Builder(
            builder: (context) {
              // Admin actions for the HOME tab's app bar. The old
              // app-bar robot icon (generic analytics chat) is GONE:
              // with a dedicated Coach tab in the bottom nav a second
              // robot one row above it was redundant, and the analytics
              // chat it actually opened now lives in the LOG tab's
              // overflow menu (it's a data-questions tool — it belongs
              // with the data). Not const: a const SyncStatusButton is
              // identical across parent rebuilds, so Flutter would skip
              // build() and freeze the pre-bootstrap empty state
              // (SyncScheduler.instance null).
              final homeActions = <Widget>[
                SyncStatusButton(),
                if (configSource != null)
                  IconButton(
                    icon: const Icon(Icons.cloud_download_outlined),
                    onPressed: () => _syncFromGithub(configSource),
                    tooltip: 'Sync schemas from GitHub',
                  ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => setState(() => _bootstrap = _initialize()),
                  tooltip: 'Reload',
                ),
                // Settings gear (2026-10-03): app setup — "Week starts
                // on" + the Integrations (Withings, Whoop, Kaya…; moved
                // out of the LOG tab's list 2026-09-25 — it is app
                // setup, not logging).
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(
                        programProvider: configSource == null
                            ? null
                            : ProgramProvider(configSource.docFetcher),
                      ),
                    ),
                  ),
                  tooltip: 'Settings',
                ),
              ];
              if (snap.connectionState != ConnectionState.done) {
                return Scaffold(
                  appBar: AppBar(title: Text(appName)),
                  body: const Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                // Reload stays reachable on a failed bootstrap.
                return Scaffold(
                  appBar: AppBar(title: Text(appName), actions: homeActions),
                  body: _ErrorView(error: snap.error.toString()),
                );
              }
              final data = snap.data!;
              // Only show writable data-entry trackers (paired with
              // .input.yml, not read-only). Analytics-only views still
              // live in data.views for the chat to query.
              // coach_chat is a chat, not a tracker — excluded here,
              // rendered as the pinned Coach row instead.
              final entryViews = data.views
                  .where(
                    (v) =>
                        v.hasInputOverlay &&
                        !v.readOnly &&
                        v.name != kCoachChatViewName,
                  )
                  .toList();
              // Read-only views show in a separate "Read-only" section
              // backed by a direct sheet read (no ledger writes). Only
              // rendered when the bootstrap established a readOnlyRepo.
              // program_status is coach/dashboard plumbing (nightly-written
              // weekly metrics the Progress/Goals/Plan tabs + MCP read);
              // its raw rows have no purpose as a browsable Log ledger, so
              // it's excluded here. The dashboard still reads it via its
              // own statusView + direct-sheet repo.
              final readOnlyViews = data.readOnlyRepo == null
                  ? const <ViewSchema>[]
                  : data.views
                        .where((v) =>
                            v.hasInputOverlay &&
                            v.readOnly &&
                            v.name != 'program_status')
                        .toList();
              ViewSchema? coachView;
              // program_moves — where accepted coach moves proposals land.
              ViewSchema? programMovesView;
              for (final v in data.views) {
                if (v.name == kCoachChatViewName) coachView = v;
                if (v.name == 'program_moves') programMovesView = v;
              }
              final programMovesRepo = programMovesView == null
                  ? null
                  : data.registry.forView(programMovesView);
              if (entryViews.isEmpty &&
                  readOnlyViews.isEmpty &&
                  coachView == null) {
                return Scaffold(
                  appBar: AppBar(title: Text(appName), actions: homeActions),
                  body: const Center(child: Text('No views available.')),
                );
              }
              // Ledger meta access for the Coach row's unread marker.
              // Null on non-local-first builds — unread simply tracks
              // "any coach message exists".
              final coachLedger = data.repository is EngineLedgerConnector
                  ? (data.repository as EngineLedgerConnector).repo
                  : null;
              // In-app coach replies ride the same LLM plumbing as the
              // chat: same disable_post_log gate, same default Anthropic
              // model. Null → sends still work, no in-app reply.
              final coachBrain = data.llm == null || chatModel == null
                  ? null
                  : CoachBrain(
                      model: chatModel,
                      repository: data.repository,
                      views: {for (final v in data.views) v.name: v},
                      fetchDoc: configDocFetcher(configSource),
                      // Direct-sheet path for read-only dump views
                      // (climbing/kaya_ascents) the local engine never
                      // owns.
                      readOnlyRepo: data.readOnlyRepo,
                      // Video-RPE calibration section (AI estimate vs
                      // the rpe the user actually logged).
                      metaGet: coachLedger?.metaGet,
                    );
              // Progress-dashboard plumbing. weight is integration-
              // paradigm on the LOG tab (Withings-fed) but the VIEW
              // stays writable — the dashboard reads it through
              // airlayer and manual weigh-ins still work via the
              // domain screen's escape hatch; program_status is
              // read-only (EXECUTION/ENGINE read it via readOnlyRepo);
              // strength feeds the STRENGTH card's e1RM columns through
              // its normal ledger connector.
              ViewSchema? weightView;
              ViewSchema? statusView;
              ViewSchema? dashStrengthView;
              ViewSchema? dashClimbingView;
              ViewSchema? dashMealsView;
              ViewSchema? dashCardioView;
              ViewSchema? dashCalisthenicsView;
              ViewSchema? dashNotesView;
              ViewSchema? dashRecoveryView;
              ViewSchema? dashWorkoutsView;
              for (final v in data.views) {
                if (v.name == 'weight') weightView = v;
                if (v.name == 'program_status') statusView = v;
                if (v.name == 'strength') dashStrengthView = v;
                // kaya_ascents — the LIVE this-week climb count.
                if (v.name == 'climbing') dashClimbingView = v;
                // Driver checklist sources: protein floor + 4x4.
                if (v.name == 'meals') dashMealsView = v;
                if (v.name == 'cardio') dashCardioView = v;
                // Recomp one-screen rows (2026-09-27): SKILLS +
                // RECOVERY sources.
                if (v.name == 'calisthenics') dashCalisthenicsView = v;
                if (v.name == 'daily_notes') dashNotesView = v;
                // Objective recovery (Whoop API → recovery tab,
                // 2026-09-30): preferred over daily_notes subjectives for
                // the review's Recovery section.
                if (v.name == 'recovery') dashRecoveryView = v;
                // Whoop workouts (strain) → the recomp review's per-session
                // Whoop-workload readout.
                if (v.name == 'whoop_workouts') dashWorkoutsView = v;
              }
              final programProvider = configSource == null
                  ? null
                  : ProgramProvider(configSource.docFetcher);
              // Shared dashboards.yaml provider (1 h doc cache): domain
              // sections + the home hero's `phases:` eigenvectors.
              final domainProvider = configSource == null
                  ? null
                  : DomainConfigProvider(configSource.docFetcher);

              // Feature 1: AI day-synthesis service — assembles today's
              // meals/sets/4x4/climbing vs the routine + macro targets and
              // synthesizes a short read via the LLM. Disabled (→ the card
              // falls back to static lines) under disable_post_log / no
              // Anthropic model. Cheap to build; the LLM call is lazy.
              final synthesisService = DaySynthesisService(
                llm: data.llm,
                modelName: data.llm == null
                    ? null
                    : synthesisModelName(data.models),
                mealsView: dashMealsView,
                mealsRepo: dashboardRepoFor(
                  dashMealsView,
                  readOnlyRepo: data.readOnlyRepo,
                  forView: data.registry.forView,
                ),
                strengthView: dashStrengthView,
                strengthRepo: dashStrengthView == null
                    ? null
                    : data.registry.forView(dashStrengthView),
                cardioView: dashCardioView,
                cardioRepo: dashCardioView == null
                    ? null
                    : data.registry.forView(dashCardioView),
                climbingView: dashClimbingView,
                climbingRepo: dashboardRepoFor(
                  dashClimbingView,
                  readOnlyRepo: data.readOnlyRepo,
                  forView: data.registry.forView,
                ),
                // Recovery/sleep (Whoop → recovery tab): feeds readiness
                // into the synthesis ("recovery 80 — good to push").
                recoveryView: dashRecoveryView,
                recoveryRepo: dashboardRepoFor(
                  dashRecoveryView,
                  readOnlyRepo: data.readOnlyRepo,
                  forView: data.registry.forView,
                ),
                // Bodyweight prices the cut's per-lb protein band into an
                // absolute g/day target (7d avg, same as the GOALS tab).
                weightView: weightView,
                weightRepo: weightView == null
                    ? null
                    : data.registry.forView(weightView),
                analytics: data.analytics,
                // Whoop activity (climbs/runs/lifts) — a session Whoop
                // saw counts as done even if not logged.
                workoutsView: dashWorkoutsView,
                workoutsRepo: dashboardRepoFor(
                  dashWorkoutsView,
                  readOnlyRepo: data.readOnlyRepo,
                  forView: data.registry.forView,
                ),
                // Moved-in items count as today's program; moved-out
                // ones don't.
                programMovesView: programMovesView,
                programMovesRepo: programMovesRepo,
                // Calisthenics sets tick skill items (same as the card).
                calisthenicsView: dashCalisthenicsView,
                calisthenicsRepo: dashCalisthenicsView == null
                    ? null
                    : data.registry.forView(dashCalisthenicsView),
                provider: programProvider,
              );
              // Feature 3: post-log notification driver — one boot-time
              // singleton, listens on LogEventBus (never touches the form).
              if (synthesisService.enabled &&
                  PostLogNotifier.instance == null) {
                final notifier = PostLogNotifier(synthesis: synthesisService)
                  ..start();
                PostLogNotifier.instance = notifier;
                // Ask for the Android 13+ POST_NOTIFICATIONS grant once.
                unawaited(NotificationService.instance?.requestPermission());
              }
              // Daily missed-work carryover (in-app fallback for the
              // nightly briefing): needs the in-app coach, the coach_chat
              // view and ledger meta (the once-a-day guard). Skipped
              // under flutter test. Kicked once after bootstrap, then on
              // every resume + home-poller tick.
              final carryoverView = coachView;
              final carryoverBrain = coachBrain;
              final carryoverLedger = coachLedger;
              _carryoverCheck = carryoverView == null ||
                      carryoverBrain == null ||
                      carryoverLedger == null ||
                      Platform.environment.containsKey('FLUTTER_TEST')
                  ? null
                  : () async {
                      final chatRepo = data.registry.forView(carryoverView);
                      // resumeAt: coach_chat must come from a sync that
                      // finished AFTER this — else last night's briefing
                      // may not be local yet (→ duplicate proposal).
                      final now = DateTime.now();
                      await CarryoverCheck.maybeRun(
                        now: now,
                        metaGet: carryoverLedger.metaGet,
                        metaSet: carryoverLedger.metaSet,
                        freshSync: () async {
                          final sched = SyncScheduler.instance;
                          if (sched == null) return false;
                          return awaitFreshSync(
                            since: now,
                            syncing: sched.syncing,
                            lastSync: sched.lastSync,
                            chatFailed: () {
                              final bad = sched.lastErrorViews.value;
                              return bad.contains('*') ||
                                  bad.contains(carryoverView.name);
                            },
                            sync: () => sched.maybeSync(manual: true),
                          );
                        },
                        alreadyPlanned: () async => alreadyPlannedToday(
                            await chatRepo.list(carryoverView), now),
                        missed: () async => (await carryoverBrain
                                .weekStateLoader()
                                .load(now, withMissed: true))
                            ?.missed,
                        ask: (_) async {
                          await postCarryoverTurn(
                            view: carryoverView,
                            repository: chatRepo,
                            ask: (prompt, onProposal, onMoves) =>
                                carryoverBrain.ask(
                              prompt,
                              onProposal: onProposal,
                              onMovesProposal: onMoves,
                            ),
                            notify: (title, body) async {
                              await NotificationService.instance
                                  ?.showCoachUpdate(title, body);
                            },
                          );
                          unawaited(
                            SyncScheduler.instance?.maybeSync(manual: true),
                          );
                        },
                      );
                    };
              if (!_carryoverKicked && _carryoverCheck != null) {
                _carryoverKicked = true;
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _runCarryoverCheck());
              }
              // Shared timeline opener for tracker rows. Read-only views
              // ride the direct-sheet repo with no post-log hooks; entry
              // views get the full plumbing (LLM, QBO when mapped).
              void openView(ViewSchema view) {
                final readOnly = view.readOnly;
                final repo = readOnly
                    ? data.readOnlyRepo
                    : data.registry.forView(view);
                if (repo == null) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TimelineScreen(
                      view: view,
                      repository: repo,
                      llm: readOnly ? null : data.llm,
                      llmCache: readOnly ? null : data.llmCache,
                      chatModel: chatModel,
                      github: github == null ? null : GithubClient(github),
                      analytics: data.analytics,
                      qboSpec: readOnly
                          ? null
                          : data.quickbooks?.specFor(view.name),
                      qboService:
                          readOnly ||
                              data.quickbooks?.specFor(view.name) == null
                          ? null
                          : data.qboService,
                    ),
                  ),
                );
              }

              // Domain rows open the domain screen: dashboard header +
              // the view's timeline (read-only for integration
              // paradigm — DomainScreen handles that gating itself).
              void openDomain(DomainConfig domain, ViewSchema view) {
                final readOnly = view.readOnly;
                final repo = readOnly
                    ? data.readOnlyRepo
                    : data.registry.forView(view);
                if (repo == null) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DomainScreen(
                      domain: domain,
                      view: view,
                      repository: repo,
                      analytics: data.analytics,
                      llm: readOnly ? null : data.llm,
                      llmCache: readOnly ? null : data.llmCache,
                      chatModel: chatModel,
                      github: github == null ? null : GithubClient(github),
                      qboSpec: readOnly
                          ? null
                          : data.quickbooks?.specFor(view.name),
                      qboService:
                          readOnly ||
                              data.quickbooks?.specFor(view.name) == null
                          ? null
                          : data.qboService,
                      // Bodyweight reference for cross-domain metrics
                      // (meals' protein goal band scales by current bw).
                      weightView: weightView,
                      weightRepository: weightView == null
                          ? null
                          : data.registry.forView(weightView),
                      // Accounting-week keying for the weekly Wilks
                      // stat (program.yaml v7 week_start).
                      programProvider: programProvider,
                    ),
                  ),
                );
              }

              // Hero strength row → the strength domain screen (Wilks
              // stat + monthly series live there). Falls back silently
              // when the config/view is missing — the caller passes
              // onOpenProgram as the dashboard-side fallback.
              Future<void> openStrengthDomain() async {
                final view = dashStrengthView;
                if (domainProvider == null || view == null) return;
                List<DomainConfig>? domains;
                try {
                  domains = await domainProvider.load();
                } catch (_) {
                  return;
                }
                DomainConfig? strengthDomain;
                for (final d in domains ?? const <DomainConfig>[]) {
                  if (d.views.contains(view.name)) strengthDomain = d;
                }
                if (strengthDomain == null || !context.mounted) return;
                openDomain(strengthDomain, view);
              }

              // The ROUTINE surface (tab split 2026-09-28): the Program
              // screen absorbed the old Week Plan screen — this opener
              // stays as the deep-link alias for every old week-plan
              // entry point (coach proposals, dashboard rows).
              void openWeekPlan() {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ProgramScreen(
                      provider: programProvider!,
                      wmStore: data.wmStore,
                      strengthRepo: dashStrengthView == null
                          ? null
                          : data.registry.forView(dashStrengthView),
                      strengthView: dashStrengthView,
                      programMovesView: programMovesView,
                      programMovesRepo: programMovesRepo,
                    ),
                  ),
                );
              }

              // Every old "Plan"/"Program" deep link (hero rows, sheet
              // actions) opens the Program screen directly — the Plan tab
              // is gone (IA restructure 2026-10-02).
              void openProgram() => openWeekPlan();

              // Forecast pages (the old Plan tab's content): one sources
              // bundle shared by Weight / Strength / per-lift pages.
              final planSources = programProvider == null
                  ? null
                  : PlanSources(
                      provider: programProvider,
                      analytics: data.analytics,
                      weightView: weightView,
                      weightRepo: weightView == null
                          ? null
                          : data.registry.forView(weightView),
                      strengthView: dashStrengthView,
                      strengthRepo: dashStrengthView == null
                          ? null
                          : data.registry.forView(dashStrengthView),
                      // kaya_ascents is read-only → direct-sheet repo.
                      climbingView: dashClimbingView,
                      climbingRepo: dashboardRepoFor(
                        dashClimbingView,
                        readOnlyRepo: data.readOnlyRepo,
                        forView: data.registry.forView,
                      ),
                      mealsView: dashMealsView,
                      mealsRepo: dashboardRepoFor(
                        dashMealsView,
                        readOnlyRepo: data.readOnlyRepo,
                        forView: data.registry.forView,
                      ),
                      metaStore: data.forecastMetaStore,
                      projectionStore: data.projectionStore,
                    );

              void openWeight() => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => WeightScreen(sources: planSources!),
                ),
              );

              void openStrength() => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => StrengthScreen(sources: planSources!),
                ),
              );

              void openLift(String lift, LiftSummary summary) =>
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LiftScreen(
                        lift: lift,
                        summary: summary,
                        sources: planSources,
                        wmSnapshot: data.wmStore?.snapshot,
                      ),
                    ),
                  );

              void openBlockProjection(int block, PhaseProjections p) {
                final snapshot = p.byBlock[block];
                if (snapshot == null) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PhaseProjectionScreen(
                      snapshot: snapshot,
                      projections: p,
                    ),
                  ),
                );
              }

              void openStatusLedger() {
                final view = statusView;
                final repo = data.readOnlyRepo;
                if (view == null || repo == null) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TimelineScreen(
                      view: view,
                      repository: repo,
                      // Read-only ledger: no post-log hooks.
                      llm: null,
                      llmCache: null,
                      chatModel: chatModel,
                      github: github == null ? null : GithubClient(github),
                      analytics: data.analytics,
                    ),
                  ),
                );
              }

              // Coach-proposal timeline opener: pushed chat screens
              // call this to open the target view's timeline with the
              // scheduled entries highlighted — unchanged behavior,
              // now shared by the Coach tab.
              void openCoachTimeline(
                BuildContext ctx,
                String viewName,
                DateTime date,
                Set<String> highlight,
              ) {
                final view = data.views
                    .where((v) => v.name == viewName)
                    .firstOrNull;
                if (view == null) return;
                Navigator.of(ctx).push(
                  MaterialPageRoute(
                    builder: (_) => TimelineScreen(
                      view: view,
                      repository: data.registry.forView(view),
                      llm: data.llm,
                      llmCache: data.llmCache,
                      chatModel: chatModel,
                      github: github == null ? null : GithubClient(github),
                      analytics: data.analytics,
                      qboSpec: data.quickbooks?.specFor(view.name),
                      qboService: data.quickbooks?.specFor(view.name) == null
                          ? null
                          : data.qboService,
                      initialDate: date,
                      highlightKeys: highlight,
                    ),
                  ),
                );
              }

              // Today-synthesis → Coach: tap the card's AI read to
              // continue the day's synthesis as a normal coach thread.
              // Coach is no longer a bottom-nav tab (2026-09-30) — the
              // chat PUSHES over the Today tab. If a coach_chat view is
              // synced, seeds today's `today-YYYY-MM-DD` thread with the
              // synthesis text — idempotent (shouldSeedTodayThread skips
              // when a coach opener already exists) — and pushes its
              // chat. seedText null (disabled synthesis) → nothing to do
              // when coach isn't synced. Best-effort: a seed-write
              // failure still opens the thread.
              Future<void> openTodayCoachThread({String? seedText}) async {
                final view = coachView;
                if (view == null) return; // coach not synced → no-op
                final repo = data.registry.forView(view);
                final day = DateTime.now();
                final threadId = todaySynthesisThreadId(day);
                final title = todaySynthesisThreadTitle(day);
                if (seedText != null && seedText.trim().isNotEmpty) {
                  try {
                    final all = await repo.list(view);
                    final existing = todayThreadRows(all, threadId);
                    if (shouldSeedTodayThread(existing)) {
                      final now = DateTime.now();
                      await repo.create(view, <String, Object?>{
                        'id': const Uuid().v4(),
                        'date': DateTime(now.year, now.month, now.day),
                        'ts': now.toIso8601String(),
                        'role': 'coach',
                        'kind': 'reply',
                        'thread': threadId,
                        'text': seedText.trim(),
                      });
                      unawaited(
                        SyncScheduler.instance?.maybeSync(manual: true),
                      );
                    }
                  } catch (_) {/* open the thread anyway */}
                }
                if (!context.mounted) return;
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CoachChatScreen(
                      view: view,
                      repository: repo,
                      threadId: threadId,
                      title: title,
                      ledger: coachLedger,
                      brain: coachBrain,
                      openTimeline: openCoachTimeline,
                      programMovesView: programMovesView,
                      programMovesRepository: programMovesRepo,
                    ),
                  ),
                );
              }

              // Coach threads list — the former Coach tab, now PUSHED
              // from the Today tab's app-bar icon (2026-09-30: coach left
              // the bottom nav; its entrypoint stays at the top of Today).
              void openCoachThreads() {
                final view = coachView;
                if (view == null) return;
                // The threads screen owns its app bar (back + "+") —
                // no wrapping Scaffold (that drew a double "Coach" bar).
                Navigator.of(context).push(
                  coachThreadsRoute(
                    CoachThreadsScreen(
                      view: view,
                      repository: data.registry.forView(view),
                      ledger: coachLedger,
                      brain: coachBrain,
                      openTimeline: openCoachTimeline,
                      programMovesView: programMovesView,
                      programMovesRepository: programMovesRepo,
                    ),
                  ),
                );
              }

              // ---- TODAY (home, idx 0): the day-scale surface. The AI
              // synthesis (how the day is going vs plan — food + training)
              // leads, then today/tomorrow's planned INPUTS. Input metrics
              // are only legible on a day-to-week scale, so they lead the
              // app; Week holds the week-scale inputs and Progress the
              // outputs. Coach left the bottom nav 2026-09-30 — its
              // entrypoint is the app-bar icon here + tapping the card.
              final todayTab = Scaffold(
                appBar: AppBar(
                  title: Text(appName),
                  actions: [
                    if (coachView != null)
                      IconButton(
                        icon: const Icon(Icons.smart_toy_outlined),
                        tooltip: 'Coach',
                        onPressed: openCoachThreads,
                      ),
                    ...homeActions,
                  ],
                ),
                body: RefreshIndicator(
                  // Gated sync (via the coach card) + a re-read of every
                  // per-day card for the selected day.
                  onRefresh: () async {
                    _todayStatusKey.currentState?.refresh();
                    _recoveryKey.currentState?.reload();
                    _dailyProgressKey.currentState?.reload();
                    _todayProgramKey.currentState?.reload();
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      // DAY NAVIGATOR — shift the whole tab across days
                      // (‹ yesterday · today · tomorrow ›). Tap the label
                      // to jump back to today.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.chevron_left),
                              onPressed: () => _shiftDay(-1),
                              tooltip: 'Previous day',
                            ),
                            Expanded(
                              child: InkWell(
                                onTap: _dayViewIsToday
                                    ? null
                                    : () => setState(() => _dayViewDate =
                                        _dateOnly(DateTime.now())),
                                child: Column(
                                  children: [
                                    Text(
                                      _dayViewLabel(),
                                      textAlign: TextAlign.center,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.w700),
                                    ),
                                    if (!_dayViewIsToday)
                                      Text(
                                        'tap to return to today',
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.chevron_right),
                              onPressed: () => _shiftDay(1),
                              tooltip: 'Next day',
                            ),
                          ],
                        ),
                      ),
                      // 1. Readiness: Whoop recovery + hours slept.
                      RecoveryCard(
                        key: _recoveryKey,
                        recoveryView: dashRecoveryView,
                        recoveryRepo: dashboardRepoFor(
                          dashRecoveryView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        date: _dayViewDate,
                      ),
                      // 2. Coach's read (today only) — the ONLY AI
                      // commentary; the plan below is template-driven.
                      if (_dayViewIsToday)
                        TodayStatusCard(
                          key: _todayStatusKey,
                          mealsView: dashMealsView,
                          mealsRepo: dashboardRepoFor(
                            dashMealsView,
                            readOnlyRepo: data.readOnlyRepo,
                            forView: data.registry.forView,
                          ),
                          strengthView: dashStrengthView,
                          strengthRepo: dashStrengthView == null
                              ? null
                              : data.registry.forView(dashStrengthView),
                          provider: programProvider,
                          synthesis: synthesisService,
                          registry: IntegrationRegistry.instance,
                          onOpen: () => _selectTab(_tabLog),
                          onOpenCoachThread: openTodayCoachThread,
                        ),
                      // 3. Macro progress.
                      DailyProgressCard(
                        key: _dailyProgressKey,
                        provider: programProvider,
                        dashboards: domainProvider,
                        analytics: data.analytics,
                        mealsView: dashMealsView,
                        mealsRepo: dashboardRepoFor(
                          dashMealsView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        weightView: weightView,
                        weightRepo: weightView == null
                            ? null
                            : data.registry.forView(weightView),
                        date: _dayViewDate,
                      ),
                      // 4. The PROGRAM for the selected day — the ONE
                      // training surface: each item ticks green with what
                      // was achieved + its clips inline; unmatched work
                      // lands in "Also logged" (UI redesign phase 3).
                      ProgramDayCard(
                        key: _todayProgramKey,
                        provider: programProvider,
                        label: _dayViewLabel(),
                        date: _dayViewDate,
                        strengthView: dashStrengthView,
                        strengthRepo: dashStrengthView == null
                            ? null
                            : data.registry.forView(dashStrengthView),
                        workoutsView: dashWorkoutsView,
                        calisthenicsView: dashCalisthenicsView,
                        calisthenicsRepo: dashCalisthenicsView == null
                            ? null
                            : data.registry.forView(dashCalisthenicsView),
                        workoutsRepo: dashboardRepoFor(
                          dashWorkoutsView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        programMovesView: programMovesView,
                        programMovesRepo: programMovesRepo,
                        wmSnapshot: data.wmStore?.snapshot,
                        cardioView: dashCardioView,
                        cardioRepo: dashboardRepoFor(
                          dashCardioView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        climbingView: dashClimbingView,
                        climbingRepo: dashboardRepoFor(
                          dashClimbingView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        // The Program screen's entry point now that the
                        // Plan tab is gone.
                        onOpenWeek:
                            programProvider == null ? null : openWeekPlan,
                      ),
                    ],
                  ),
                ),
              );

              // ---- PROGRESS (idx 2): outputs only — PHASE hero (weight
              // trajectory + verdict) + STRENGTH card + output trends.
              // The today-vs-plan card moved to the Today tab; the THIS
              // WEEK input strip is dropped here (progressOnly) — it lives
              // on the Week tab.
              final progressTab = Scaffold(
                appBar: AppBar(
                  title: const Text('Progress'),
                  actions: [SyncStatusButton()],
                ),
                body: RefreshIndicator(
                  // Busts the dashboard's caches (wm_store snapshot,
                  // program docs, weight mirror, best-e1RM) and refires
                  // its card futures.
                  onRefresh: () async {
                    await _dashboardKey.currentState?.reload();
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      HomeDashboard(
                        key: _dashboardKey,
                        progressOnly: true,
                        wmStore: data.wmStore,
                        provider: programProvider,
                        analytics: data.analytics,
                        weightView: weightView,
                        weightRepo: weightView == null
                            ? null
                            : data.registry.forView(weightView),
                        statusView: statusView,
                        statusRepo: data.readOnlyRepo,
                        strengthView: dashStrengthView,
                        strengthRepo: dashStrengthView == null
                            ? null
                            : data.registry.forView(dashStrengthView),
                        climbingView: dashClimbingView,
                        // climbing is read_only (kaya_ascents direct
                        // read) — dashboardRepoFor routes it to the
                        // readOnlyRepo; the registry's ledger connector
                        // has no climbing rows (fix 2026-09-22).
                        climbingRepo: dashboardRepoFor(
                          dashClimbingView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        mealsView: dashMealsView,
                        mealsRepo: dashboardRepoFor(
                          dashMealsView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        cardioView: dashCardioView,
                        cardioRepo: dashboardRepoFor(
                          dashCardioView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        calisthenicsView: dashCalisthenicsView,
                        calisthenicsRepo: dashboardRepoFor(
                          dashCalisthenicsView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        notesView: dashNotesView,
                        notesRepo: dashboardRepoFor(
                          dashNotesView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        recoveryView: dashRecoveryView,
                        recoveryRepo: dashboardRepoFor(
                          dashRecoveryView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        workoutsView: dashWorkoutsView,
                        workoutsRepo: dashboardRepoFor(
                          dashWorkoutsView,
                          readOnlyRepo: data.readOnlyRepo,
                          forView: data.registry.forView,
                        ),
                        dashboards: domainProvider,
                        onOpenProgram: programProvider == null
                            ? null
                            : openProgram,
                        onOpenWeekPlan: programProvider == null
                            ? null
                            : openWeekPlan,
                        onOpenStatus:
                            statusView == null || data.readOnlyRepo == null
                            ? null
                            : openStatusLedger,
                        onOpenStrengthDomain:
                            domainProvider == null || dashStrengthView == null
                            ? null
                            : openStrengthDomain,
                        // IA restructure 2026-10-02: Weight / Strength
                        // rows open the forecast pages; lift rows open
                        // the per-lift page.
                        onOpenWeight: planSources == null ? null : openWeight,
                        onOpenStrength:
                            planSources == null ? null : openStrength,
                        onOpenLift: openLift,
                        // Frozen phase projections: timeline tracking +
                        // past-block results; rows open the block view.
                        loadProjections: planSources == null
                            ? null
                            : () => loadPhaseProjections(planSources),
                        onOpenBlockProjection: openBlockProjection,
                      ),
                    ],
                  ),
                ),
              );

              // ---- GOALS: the phase's input eigenvectors as
              // plain-language rows (goals_screen.dart). Same data
              // sources as the retired THIS WEEK strip; declared in
              // app/dashboards.yaml `goals:`, phase-selected.
              final goalsTab = Scaffold(
                appBar: AppBar(
                  // Labelled "Week" (idx 1): the week-scale input
                  // eigenvectors, one zoom level out from Today.
                  title: const Text('Week'),
                  actions: [
                    // The full-week routine (Program screen) — one of
                    // its two entry points since the Plan tab left.
                    if (programProvider != null)
                      IconButton(
                        icon: const Icon(Icons.fitness_center_outlined),
                        tooltip: 'Program — full week',
                        onPressed: openWeekPlan,
                      ),
                    SyncStatusButton(),
                  ],
                ),
                body: RefreshIndicator(
                  onRefresh: () async => _goalsKey.currentState?.reload(),
                  child: GoalsScreen(
                    key: _goalsKey,
                    provider: programProvider,
                    dashboards: domainProvider,
                    analytics: data.analytics,
                    weightView: weightView,
                    weightRepo: weightView == null
                        ? null
                        : data.registry.forView(weightView),
                    strengthView: dashStrengthView,
                    strengthRepo: dashStrengthView == null
                        ? null
                        : data.registry.forView(dashStrengthView),
                    climbingView: dashClimbingView,
                    climbingRepo: dashboardRepoFor(
                      dashClimbingView,
                      readOnlyRepo: data.readOnlyRepo,
                      forView: data.registry.forView,
                    ),
                    mealsView: dashMealsView,
                    mealsRepo: dashboardRepoFor(
                      dashMealsView,
                      readOnlyRepo: data.readOnlyRepo,
                      forView: data.registry.forView,
                    ),
                    cardioView: dashCardioView,
                    cardioRepo: dashboardRepoFor(
                      dashCardioView,
                      readOnlyRepo: data.readOnlyRepo,
                      forView: data.registry.forView,
                    ),
                    workoutsView: dashWorkoutsView,
                    workoutsRepo: dashboardRepoFor(
                      dashWorkoutsView,
                      readOnlyRepo: data.readOnlyRepo,
                      forView: data.registry.forView,
                    ),
                    programMovesView: programMovesView,
                    programMovesRepo: programMovesRepo,
                    calisthenicsView: dashCalisthenicsView,
                    calisthenicsRepo: dashCalisthenicsView == null
                        ? null
                        : data.registry.forView(dashCalisthenicsView),
                  ),
                ),
              );

              // ---- LOG: entry domains + CONNECTED. (Integrations
              // moved to the HOME app bar's gear 2026-09-25 — it is
              // app setup, not logging.)
              final logTab = Scaffold(
                appBar: AppBar(
                  title: const Text('Log'),
                  actions: [
                    SyncStatusButton(),
                    // Generic analytics chat (run_query over the
                    // ledger), demoted from the home app bar's robot
                    // icon — unobtrusive but still reachable.
                    if (chatModel != null)
                      PopupMenuButton<String>(
                        tooltip: 'More',
                        onSelected: (v) {
                          if (v == 'chat') {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(
                                  model: chatModel,
                                  github: github == null
                                      ? null
                                      : GithubClient(github),
                                  analytics: data.analytics,
                                ),
                              ),
                            );
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'chat',
                            child: Text('Analytics chat'),
                          ),
                        ],
                      ),
                  ],
                ),
                // The Log tab is just the LOG / CONNECTED domain lists —
                // today's program lives on Today (2026-10-02: one place).
                body: RefreshIndicator(
                  onRefresh: () async {
                    await _domainsKey.currentState?.reload();
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      _DomainSections(
                        key: _domainsKey,
                        provider: domainProvider,
                        programProvider: programProvider,
                        entryViews: entryViews,
                        readOnlyViews: readOnlyViews,
                        onOpenDomain: openDomain,
                        onOpenView: openView,
                      ),
                    ],
                  ),
                ),
              );

              // (Coach left the bottom nav 2026-09-30 — reached via the
              // Today tab's app-bar icon → openCoachThreads.)

              // IndexedStack keeps every tab's state (scroll positions,
              // in-flight futures) alive across switches; the bootstrap
              // swap above recreates all four together. Order matches the
              // NavigationBar and the `_tab*` constants: Today · Log ·
              // Week · Progress.
              final tabsByIndex = <int, Widget>{
                _tabToday: todayTab,
                _tabLog: logTab,
                _tabWeek: goalsTab,
                _tabProgress: progressTab,
              };
              return IndexedStack(
                index: _tab,
                // Fill the body between app bar and nav bar. Without this
                // the stack sizes to the loosest child and can keep a
                // stale (half-height) constraint after a keyboard/tab
                // change — the "cut off halfway, only a restart fixes it"
                // bug (2026-10-01).
                sizing: StackFit.expand,
                // Placed by the `_tab*` constants (one source of order).
                children: [
                  for (var i = 0; i < tabsByIndex.length; i++) tabsByIndex[i]!,
                ],
              );
            },
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _selectTab,
            // Today (day inputs + AI synthesis) · Log (right beside it —
            // the two daily surfaces, 2026-10-02) · then zooming out:
            // Week (week inputs) · Progress (outputs; the old Plan tab folded
            // in 2026-10-02). Coach left
            // the bar 2026-09-30 (top of Today instead). Indices = the
            // `_tab*` constants.
            destinations: homeNavDestinations,
          ),
          ),
        );
      },
    );
  }
}

class _Bootstrap {
  final List<ViewSchema> views;
  final WarehouseConnector repository;
  final ConnectorRegistry registry;
  final LlmClient? llm;
  final LlmResponseCache? llmCache;

  /// OS-level app label (from strings.xml, which brand.dart writes per
  /// `app_name:` in the schemas repo's `ledger.yaml`).
  final String appName;

  /// Full models list — chat picks an Anthropic entry; post-log hook
  /// uses by-name lookup. Both share the same models: block in config.yml.
  final List<ModelConfig> models;

  /// The active config source — drives schema sync + every config doc
  /// read (program/phase/strategy, dashboards.yaml, coach docs). Null
  /// when nothing is connected; UI hides the relevant buttons.
  final ConfigSource? configSource;

  /// GitHub repo behind [configSource] (when it is one) — the chat's
  /// branch/PR tools are GitHub-specific.
  GithubConfig? get github {
    final s = configSource;
    return s is GitHubConfigSource ? s.config : null;
  }

  /// Airlayer + LocalDb wrapper. Drives the chat's run_query tool.
  /// Null when the native lib can't load on this platform.
  final AnalyticsEngine? analytics;

  /// When non-null, the home screen short-circuits to a TimelineScreen
  /// for the matching view and hides app-bar chrome. See
  /// [AppConfig.kioskView].
  final String? kioskView;

  /// QuickBooks config + shared push service. Null when the build has no
  /// `quickbooks:` block. A view gets the "Update" button only when
  /// [quickbooks] has a `specFor(view.name)`.
  final QuickBooksConfig? quickbooks;
  final QboService? qboService;

  /// Direct SheetsRepository for read-only views. Null when no loaded view
  /// is read-only (avoids the auth round-trip on builds that don't use the
  /// feature). The home screen's Read-only section renders only when
  /// non-null.
  final WarehouseConnector? readOnlyRepo;

  /// Working-max controller tab store (WM-2): Week Plan prescription
  /// blocks + the Program screen's CONFIGURATION "Working maxes" card.
  final WmStore? wmStore;

  /// Forecast recalibration state reader (forecast_meta tab) — the
  /// Plan tab's "model tracking" line + guarded refit application.
  final ForecastMetaStore? forecastMetaStore;

  /// Frozen phase projections reader (projection_snapshots tab).
  final ProjectionSnapshotStore? projectionStore;

  _Bootstrap({
    required this.views,
    required this.repository,
    required this.registry,
    required this.appName,
    required this.llm,
    required this.llmCache,
    required this.models,
    required this.configSource,
    required this.analytics,
    this.kioskView,
    this.quickbooks,
    this.qboService,
    this.readOnlyRepo,
    this.wmStore,
    this.forecastMetaStore,
    this.projectionStore,
  });
}

/// Tracker rows grouped by `app/dashboards.yaml` (see
/// services/domain_config.dart):
///
///   LOG        entry-paradigm domains (tap → domain screen with the
///              full timeline affordances), followed by any loaded view
///              the config doesn't claim — nothing becomes unreachable.
///   CONNECTED  integration-paradigm domains (read-only, read-friendly).
///
/// The config is fetched from GitHub with the shared 1 h cache;
/// [reload] (pull-to-refresh) busts it. While loading, and whenever the
/// config is missing/malformed, the widget renders the pre-redesign
/// "Ledgers" ExpansionTile fallback so a bad push can never hide the
/// trackers.
class _DomainSections extends StatefulWidget {
  /// Null when the build has no `github:` config — fallback only.
  final DomainConfigProvider? provider;

  /// Program source for the "today:" domain badges. Null → no badges
  /// (the list still renders).
  final ProgramProvider? programProvider;

  /// Writable trackers (input overlay, not read-only, not coach_chat).
  final List<ViewSchema> entryViews;

  /// Read-only trackers (rendered only when readOnlyRepo exists).
  final List<ViewSchema> readOnlyViews;

  /// Tap on a domain row — [view] is the domain's primary view.
  final void Function(DomainConfig domain, ViewSchema view) onOpenDomain;

  /// Tap on an unclaimed view row (and every fallback row).
  final void Function(ViewSchema view) onOpenView;

  const _DomainSections({
    super.key,
    required this.provider,
    required this.programProvider,
    required this.entryViews,
    required this.readOnlyViews,
    required this.onOpenDomain,
    required this.onOpenView,
  });

  @override
  State<_DomainSections> createState() => _DomainSectionsState();
}

/// What today's program calls for, per view name, plus which of those
/// views already have today's planned rows sitting in PlanStore (the
/// "waiting to log" state).
class _TodayCalls {
  final Map<String, String> byView;
  final Set<String> waiting;
  const _TodayCalls(this.byView, this.waiting);
  static const empty = _TodayCalls({}, {});
}

class _DomainSectionsState extends State<_DomainSections> {
  Future<List<DomainConfig>?>? _load;
  _TodayCalls _today = _TodayCalls.empty;

  @override
  void initState() {
    super.initState();
    _load = widget.provider?.load();
    _loadToday();
  }

  /// Loads today's per-domain program call (program.yaml is 1 h cached,
  /// so this is cheap) and marks the views that already have today's
  /// planned rows. Best-effort: any failure leaves the badges off.
  Future<void> _loadToday() async {
    final provider = widget.programProvider;
    if (provider == null) return;
    try {
      final docs = await provider.load();
      final program = docs.program;
      if (program == null) return;
      final today = DateTime.now();
      final byView = todayProgramCallByView(program, docs.phase, today);
      // Which of those views already have today's planned rows?
      final viewByName = {for (final v in widget.entryViews) v.name: v};
      final waiting = <String>{};
      for (final name in byView.keys) {
        final view = viewByName[name];
        if (view == null) continue;
        final planned = await PlanStore.loadForDate(view, today);
        if (planned.isNotEmpty) waiting.add(name);
      }
      if (!mounted) return;
      setState(() => _today = _TodayCalls(byView, waiting));
    } catch (_) {
      // No badges on failure — the list still works.
    }
  }

  /// Pull-to-refresh: bust the shared doc cache and refetch. (The home
  /// dashboard's reload busts the same cache — double-clearing is
  /// harmless.)
  Future<void> reload() async {
    final provider = widget.provider;
    if (provider == null) {
      await _loadToday();
      return;
    }
    DomainConfigProvider.clearCache();
    final next = provider.load();
    setState(() => _load = next);
    await Future.wait([next, _loadToday()]);
  }

  @override
  Widget build(BuildContext context) {
    final load = _load;
    if (load == null) return _fallback(context);
    return FutureBuilder<List<DomainConfig>?>(
      future: load,
      builder: (context, snap) {
        final domains = snap.data;
        // Loading OR missing/bad config → the flat Ledgers section.
        if (snap.connectionState != ConnectionState.done ||
            domains == null ||
            domains.isEmpty) {
          return _fallback(context);
        }
        return _sections(context, domains);
      },
    );
  }

  Widget _sections(BuildContext context, List<DomainConfig> domains) {
    final byName = {
      for (final v in widget.entryViews) v.name: v,
      for (final v in widget.readOnlyViews) v.name: v,
    };
    // Every view any domain mentions counts as claimed even when the
    // domain's primary view is missing on this build — a half-loaded
    // domain shouldn't duplicate rows.
    final claimed = <String>{
      for (final d in domains) ...d.views.where(byName.containsKey),
    };
    final log = <Widget>[];
    final connected = <Widget>[];
    for (final d in domains) {
      final view = byName[d.primaryView];
      if (view == null) continue; // view absent on this build
      final tile = _domainTile(context, d, view);
      (d.paradigm == DomainParadigm.integration ? connected : log).add(tile);
    }
    // Unclaimed views get the same row under LOG — except internal
    // plumbing (program_moves is edited via the program card).
    for (final v in [...widget.entryViews, ...widget.readOnlyViews]) {
      if (claimed.contains(v.name) || kHiddenLogViews.contains(v.name)) {
        continue;
      }
      log.add(_viewTile(context, v));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Each section's rows grouped in one card, hairline-divided —
        // the same rows-in-a-card pattern as Progress / Week.
        if (log.isNotEmpty) ...[
          const SectionHeader(label: 'Log'),
          RowGroupCard(rows: log),
        ],
        if (connected.isNotEmpty) ...[
          const SectionHeader(label: 'Connected'),
          RowGroupCard(rows: connected),
        ],
        const SizedBox(height: AppSpace.sectionGap),
      ],
    );
  }

  Widget _domainTile(BuildContext context, DomainConfig d, ViewSchema view) {
    // Today's program call for this domain (accent subtitle), keyed by
    // the domain's primary view name.
    return LogListRow(
      label: d.displayName,
      icon: d.icon ?? view.icon,
      todayCall: _today.byView[view.name],
      waiting: _today.waiting.contains(view.name),
      summary: d.description,
      description: view.description,
      onTap: () => widget.onOpenDomain(d, view),
    );
  }

  /// Row for a view the config doesn't claim (and every fallback row).
  Widget _viewTile(BuildContext context, ViewSchema view) {
    return LogListRow(
      label: viewLabel(view.name),
      icon: view.icon,
      description: view.description,
      onTap: () => widget.onOpenView(view),
    );
  }

  /// Pre-redesign flat list: the "Ledgers" ExpansionTile with read-only
  /// views nested at the bottom.
  Widget _fallback(BuildContext context) {
    return ExpansionTile(
      leading: Icon(
        Icons.view_list_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: const Text('Ledgers'),
      subtitle: Text(
        '${widget.entryViews.length} trackers'
        '${widget.readOnlyViews.isNotEmpty ? ' · ${widget.readOnlyViews.length} read-only' : ''}',
      ),
      shape: const Border(),
      collapsedShape: const Border(),
      children: [
        for (final view in widget.entryViews)
          if (!kHiddenLogViews.contains(view.name)) _viewTile(context, view),
        if (widget.readOnlyViews.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 16, 2),
            child: Text('Read-only', style: AppText.tag(context)),
          ),
          for (final view in widget.readOnlyViews) _viewTile(context, view),
        ],
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Startup error',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SelectableText(
              error,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}
