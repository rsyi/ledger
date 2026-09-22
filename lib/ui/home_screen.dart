import 'dart:async';

import 'package:airledger_engine/airledger_engine.dart'
    show EngineLedgerRepository;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/github_config.dart';
import '../models/model_config.dart';
import '../models/quickbooks_config.dart';
import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/app_config.dart';
import '../services/connector_registry.dart';
import '../services/engine.dart';
import '../services/engine_ledger_connector.dart';
import '../services/sync_scheduler.dart';
import '../services/engine_schema_adapter.dart';
import 'widgets/sync_status_button.dart';
import 'integrations_screen.dart';
import '../services/heart_rate_service.dart';
import '../services/integrations/gmail_gateway.dart';
import '../services/integrations/kaya_gmail.dart';
import '../services/integrations/macrofactor.dart';
import '../services/integrations/registry.dart';
import '../services/integrations/whoop.dart';
import '../services/integrations/withings.dart';
import '../services/coach_brain.dart';
import '../services/domain_config.dart';
import '../services/github_client.dart';
import '../services/icon_resolver.dart';
import '../services/llm_client.dart';
import '../services/llm_response_cache.dart';
import '../services/qbo_service.dart';
import '../services/schema_loader.dart';
import '../services/schema_sync.dart';
import '../services/sheets_repository.dart';
import '../services/transient_retry.dart';
import '../services/warehouse_connector.dart';
import '../services/program_provider.dart';
import '../services/week_planner.dart';
import '../services/wm_store.dart';
import 'chat_screen.dart';
import 'domain_screen.dart';
import 'program_screen.dart';
import 'coach_chat_screen.dart';
import 'coach_threads_screen.dart';
import 'home_dashboard.dart';
import 'timeline_screen.dart';
import 'week_plan_screen.dart';

/// The synced view that backs the coach chat. Hidden from the normal
/// tile list; surfaced only through the pinned Coach row + chat screen.
const kCoachChatViewName = 'coach_chat';

/// App entrypoint shell. Loads config + schemas, connects to the
/// warehouse, and presents a 4-tab NavigationBar (bottom-nav redesign
/// 2026-09-21 — the single scrolling home page had gotten too crowded):
///
///   HOME     the synthesis surface only: PHASE hero + STRENGTH card +
///            THIS WEEK strip (home_dashboard.dart) and the Coach
///            preview row. No lists.
///   LOG      the tracker rows, grouped by `app/dashboards.yaml` into
///            LOG (entry domains) and CONNECTED (integration domains —
///            read-only, read-friendly); unclaimed views still list
///            under LOG so nothing becomes unreachable; missing/bad
///            config falls back to the flat "Ledgers" section.
///            Integrations sits last — it is setup for the CONNECTED
///            sources above it.
///   COACH    the coach threads screen embedded as the tab root (the
///            old pinned-row → pushed-threads flow, minus the push);
///            opening a thread still pushes the chat.
///   PROGRAM  the program screen embedded (declared / configuration /
///            observed / verdict), Week plan via its app-bar action.
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

class _HomeScreenState extends State<HomeScreen> {
  late Future<_Bootstrap> _bootstrap;

  /// Background GitHub poller. The app runs in always-open kiosk mode, so
  /// schema changes can't ride in on a launch — this timer pulls them in
  /// while the app is live. Null until the first bootstrap wires it up.
  Timer? _syncTimer;

  /// Signature of the cache state the CURRENT UI was built from (recorded
  /// by [_initialize]). Distinct from the cache's own signature on disk: a
  /// poller refresh can land while the user is mid-form, leaving the cache
  /// newer than the UI. The poller compares the two and rebuilds once the
  /// user is back on the home screen — conflating them used to strand the
  /// UI on a stale view list until a manual sync.
  String? _appliedSig;

  /// Reentrancy guard so overlapping ticks (slow network) don't stack.
  bool _polling = false;

  /// Selected bottom-nav tab (0 home · 1 log · 2 coach · 3 program).
  /// Plain state field so it survives the poller's setState rebuilds.
  int _tab = 0;

  /// Handle on the progress dashboard so pull-to-refresh can bust its
  /// caches (wm_store / program docs / weight mirror / best-e1RM).
  final _dashboardKey = GlobalKey<HomeDashboardState>();

  /// Handle on the LOG/CONNECTED sections so pull-to-refresh re-pulls
  /// app/dashboards.yaml (1 h cache otherwise).
  final _domainsKey = GlobalKey<_DomainSectionsState>();

  /// Handle on the HOME tab's Coach preview row: switching back to HOME
  /// after reading threads refreshes its unread accent immediately
  /// (the row also refreshes itself when a background sync completes).
  final _coachRowKey = GlobalKey<_CoachRowState>();

  @override
  void initState() {
    super.initState();
    _bootstrap = _initialize();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  Future<_Bootstrap> _initialize() async {
    final assetConfig = await AppConfig.load();
    final packageInfo = await PackageInfo.fromPlatform();

    // Start the background poller once (guarded — _initialize re-runs on
    // every sync/reload).
    final github = assetConfig.github;
    if (_syncTimer == null && github != null && github.pollSeconds > 0) {
      _syncTimer = Timer.periodic(
        Duration(seconds: github.pollSeconds),
        (_) => _pollGithub(github),
      );
    }

    // Record the cache state this build reads from BEFORE loading: if a
    // refresh swaps the cache mid-load we'd rather re-render once too
    // often than record a signature newer than the views we show.
    _appliedSig = await SchemaSync.cachedSignature();
    final views = await SchemaLoader.loadAll();
    final keyJson = await rootBundle.loadString('assets/service-account.json');
    // Working-max controller tabs (WM-2). Cheap to construct — auth is
    // lazy (first snapshot()/append). Feeds the planner's v3 weights, the
    // Week Plan prescription blocks, and the Program screen's
    // CONFIGURATION card.
    final wmStore = WmStore(
      spreadsheetId: assetConfig.spreadsheetId,
      serviceAccountKeyJson: keyJson,
    );
    final repo = await retryTransient(
      () => connectSheetsConnector(
        defaultSpreadsheetId: assetConfig.spreadsheetId,
        serviceAccountKeyJson: keyJson,
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
      for (final v in views) {
        if (v.name == 'weight') weightView = v;
        if (v.name == 'meals') mealsView = v;
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
            store: ServiceAccountKayaTabStore(
              spreadsheetId: assetConfig.spreadsheetId,
              serviceAccountKeyJson: keyJson,
            ),
          ),
          WhoopIntegration(hr: hrService),
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
      for (final v in views) {
        if (v.name == 'strength') strengthView = v;
      }
      if (github != null && strengthView != null) {
        unawaited(
          WeekPlanner.ensureCurrentWeek(
            repo: repo.repo,
            connector: repo,
            provider: ProgramProvider(CoachBrain.githubFetcher(github)),
            strengthView: strengthView,
            wmSnapshotOf: wmStore.snapshot,
          ),
        );
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
        () => SheetsRepository.connectFromKey(
          defaultSpreadsheetId: assetConfig.spreadsheetId,
          serviceAccountKeyJson: keyJson,
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
      github: assetConfig.github,
      analytics: analytics,
      kioskView: assetConfig.kioskView,
      quickbooks: assetConfig.quickbooks,
      qboService: assetConfig.quickbooks == null
          ? null
          : QboService(assetConfig.quickbooks!),
      readOnlyRepo: readOnlyRepo,
      wmStore: wmStore,
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
  Future<void> _pollGithub(GithubConfig cfg) async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final cached = await SchemaSync(GithubClient(cfg)).ensureFresh();
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
  Future<void> _syncFromGithub(GithubConfig cfg) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Syncing schemas from GitHub…'),
        duration: Duration(seconds: 30),
      ),
    );
    try {
      final result = await SchemaSync(GithubClient(cfg)).refresh();
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
            'Synced ${result.fetched} file(s) from '
            '${cfg.repoFullName}@${cfg.defaultBranch}',
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
        final appName = snap.data?.appName ?? 'Airledger';
        final boot = snap.data;
        final github = boot?.github;
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
        return Scaffold(
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
                if (github != null)
                  IconButton(
                    icon: const Icon(Icons.cloud_download_outlined),
                    onPressed: () => _syncFromGithub(github),
                    tooltip: 'Sync schemas from GitHub',
                  ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => setState(() => _bootstrap = _initialize()),
                  tooltip: 'Reload',
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
              final readOnlyViews = data.readOnlyRepo == null
                  ? const <ViewSchema>[]
                  : data.views
                        .where((v) => v.hasInputOverlay && v.readOnly)
                        .toList();
              ViewSchema? coachView;
              for (final v in data.views) {
                if (v.name == kCoachChatViewName) coachView = v;
              }
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
                      fetchDoc: CoachBrain.githubFetcher(github),
                    );
              // Progress-dashboard plumbing. weight is a normal entry
              // view (BODY reads it through airlayer); program_status is
              // read-only (EXECUTION/ENGINE read it via readOnlyRepo);
              // strength feeds the STRENGTH card's e1RM columns through
              // its normal ledger connector.
              ViewSchema? weightView;
              ViewSchema? statusView;
              ViewSchema? dashStrengthView;
              for (final v in data.views) {
                if (v.name == 'weight') weightView = v;
                if (v.name == 'program_status') statusView = v;
                if (v.name == 'strength') dashStrengthView = v;
              }
              final programProvider = github == null
                  ? null
                  : ProgramProvider(CoachBrain.githubFetcher(github));
              // Shared dashboards.yaml provider (1 h doc cache): domain
              // sections + the home hero's `phases:` eigenvectors.
              final domainProvider = github == null
                  ? null
                  : DomainConfigProvider(CoachBrain.githubFetcher(github));
              // Program is a tab — hero taps / sheet actions select it
              // instead of pushing a duplicate screen.
              void openProgram() => setState(() => _tab = 3);

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

              void openWeekPlan() {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => WeekPlanScreen(
                      provider: programProvider!,
                      wmStore: data.wmStore,
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

              // ---- HOME: hero + STRENGTH + THIS WEEK + Coach preview.
              final homeTab = Scaffold(
                appBar: AppBar(title: Text(appName), actions: homeActions),
                body: RefreshIndicator(
                  // Busts the dashboard's caches (wm_store snapshot,
                  // program docs, weight mirror, best-e1RM) and refires
                  // its card futures + the Coach preview.
                  onRefresh: () async {
                    _coachRowKey.currentState?.refresh();
                    await _dashboardKey.currentState?.reload();
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      HomeDashboard(
                        key: _dashboardKey,
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
                      ),
                      if (coachView != null)
                        _CoachRow(
                          key: _coachRowKey,
                          view: coachView,
                          repository: data.registry.forView(coachView),
                          ledger: coachLedger,
                          onOpen: () => setState(() => _tab = 2),
                        ),
                    ],
                  ),
                ),
              );

              // ---- LOG: entry domains + CONNECTED, Integrations last
              // (it is setup for the CONNECTED sources above it).
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
                body: RefreshIndicator(
                  onRefresh: () async => _domainsKey.currentState?.reload(),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      _DomainSections(
                        key: _domainsKey,
                        provider: domainProvider,
                        entryViews: entryViews,
                        readOnlyViews: readOnlyViews,
                        onOpenDomain: openDomain,
                        onOpenView: openView,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.sync_alt),
                        title: const Text('Integrations'),
                        subtitle: const Text(
                          'Withings and other sources → ledger',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const IntegrationsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );

              // ---- COACH: threads screen as the tab root. Opening a
              // thread pushes the chat exactly as before; proposal
              // cards keep their timeline opener.
              final coachTab = coachView == null
                  ? Scaffold(
                      appBar: AppBar(title: const Text('Coach')),
                      body: const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Coach chat isn\'t available yet.\n'
                            'It appears after the next schema sync.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  : CoachThreadsScreen(
                      view: coachView,
                      repository: data.registry.forView(coachView),
                      ledger: coachLedger,
                      brain: coachBrain,
                      openTimeline: openCoachTimeline,
                    );

              // ---- PROGRAM: embedded program screen; Week plan rides
              // its app-bar action.
              final programTab = programProvider == null
                  ? Scaffold(
                      appBar: AppBar(title: const Text('Program')),
                      body: const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Program data unavailable — needs GitHub config.',
                          ),
                        ),
                      ),
                    )
                  : ProgramScreen(
                      provider: programProvider,
                      analytics: data.analytics,
                      weightView: weightView,
                      weightRepo: weightView == null
                          ? null
                          : data.registry.forView(weightView),
                      // OBSERVED Wilks block: strength rows + the
                      // wilks_series config from dashboards.yaml.
                      strengthView: dashStrengthView,
                      strengthRepo: dashStrengthView == null
                          ? null
                          : data.registry.forView(dashStrengthView),
                      dashboards: domainProvider,
                      wmStore: data.wmStore,
                      onOpenWeekPlan: openWeekPlan,
                    );

              // IndexedStack keeps every tab's state (scroll positions,
              // in-flight futures, the threads screen's poll) alive
              // across switches; the bootstrap swap above recreates all
              // four together.
              return IndexedStack(
                index: _tab,
                children: [homeTab, logTab, coachTab, programTab],
              );
            },
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) {
              if (i == _tab) return;
              setState(() => _tab = i);
              // Back to HOME after reading coach threads → refresh the
              // preview row's unread accent right away.
              if (i == 0) _coachRowKey.currentState?.refresh();
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.edit_note_outlined),
                selectedIcon: Icon(Icons.edit_note),
                label: 'Log',
              ),
              NavigationDestination(
                icon: Icon(Icons.smart_toy_outlined),
                selectedIcon: Icon(Icons.smart_toy),
                label: 'Coach',
              ),
              NavigationDestination(
                icon: Icon(Icons.track_changes_outlined),
                selectedIcon: Icon(Icons.track_changes),
                label: 'Program',
              ),
            ],
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

  /// GitHub config — drives schema sync + chat's repo tools. Null when
  /// the build has no github: in config.yml; UI hides the relevant
  /// buttons.
  final GithubConfig? github;

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

  _Bootstrap({
    required this.views,
    required this.repository,
    required this.registry,
    required this.appName,
    required this.llm,
    required this.llmCache,
    required this.models,
    required this.github,
    required this.analytics,
    this.kioskView,
    this.quickbooks,
    this.qboService,
    this.readOnlyRepo,
    this.wmStore,
  });
}

/// Coach preview row on the HOME tab. Tinted (primaryContainer) so it
/// reads as a different kind of row; shows a preview of the newest
/// coach message across all threads + relative time, and an accent dot
/// / stronger tint while ANY thread is unread (per-thread newest coach
/// `ts` vs its device-local read marker, with the legacy fallback for
/// `general`). Tap selects the COACH tab ([onOpen]); preview + unread
/// refresh when a background sync completes, on pull-to-refresh, and
/// when the shell switches back to HOME.
class _CoachRow extends StatefulWidget {
  final ViewSchema view;
  final WarehouseConnector repository;
  final EngineLedgerRepository? ledger;

  /// Tap handler — the shell selects the Coach tab.
  final VoidCallback onOpen;

  const _CoachRow({
    super.key,
    required this.view,
    required this.repository,
    this.ledger,
    required this.onOpen,
  });

  @override
  State<_CoachRow> createState() => _CoachRowState();
}

class _CoachRowState extends State<_CoachRow> {
  String? _preview;
  String? _relTime;
  bool _unread = false;
  ValueNotifier<bool>? _syncing;

  @override
  void initState() {
    super.initState();
    refresh();
    _syncing = SyncScheduler.instance?.syncing;
    _syncing?.addListener(_onSyncStateChanged);
  }

  @override
  void dispose() {
    _syncing?.removeListener(_onSyncStateChanged);
    super.dispose();
  }

  void _onSyncStateChanged() {
    // Refresh when a sync completes — a fresh coach message may have
    // just been pulled from the sheet.
    if (_syncing?.value == false) refresh();
  }

  /// Re-lists the coach view and recomputes preview + unread. Public-
  /// within-library: the shell calls it on tab return / pull-to-refresh.
  Future<void> refresh() async {
    try {
      final rows = await widget.repository.list(widget.view);
      // Newest coach message overall (preview) + newest coach `ts` per
      // thread (unread). ISO strings — lexicographic compare matches
      // chronological.
      Map<String, Object?>? newest;
      String? newestTs;
      final newestByThread = <String, String>{};
      for (final r in rows) {
        if (r['role']?.toString() != 'coach') continue;
        final ts = r['ts']?.toString();
        if (ts == null || ts.isEmpty) continue;
        if (newestTs == null || ts.compareTo(newestTs) > 0) {
          newestTs = ts;
          newest = r;
        }
        final thread = coachThreadOf(r);
        final prev = newestByThread[thread];
        if (prev == null || ts.compareTo(prev) > 0) {
          newestByThread[thread] = ts;
        }
      }
      // Unread when ANY thread's newest coach message postdates its
      // read marker. Missing/unreadable meta → unread (a coach message
      // exists the user has provably never opened on this device).
      var unread = false;
      for (final e in newestByThread.entries) {
        String? lastRead;
        if (widget.ledger != null) {
          try {
            lastRead = await coachThreadLastRead(widget.ledger!, e.key);
          } catch (_) {
            /* treat as missing */
          }
        }
        if (lastRead == null ||
            lastRead.isEmpty ||
            e.value.compareTo(lastRead) > 0) {
          unread = true;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _preview = newest == null
            ? null
            : _firstLine(newest['text']?.toString() ?? '');
        _relTime = _relativeTime(newestTs);
        _unread = unread;
      });
    } catch (_) {
      /* keep whatever the row currently shows */
    }
  }

  static String _firstLine(String text) {
    final stripped = stripMarkdownPreview(text);
    final line = stripped.trimLeft().split('\n').first.trim();
    return line.length > 80 ? '${line.substring(0, 80)}…' : line;
  }

  static String? _relativeTime(String? ts) {
    final dt = ts == null ? null : DateTime.tryParse(ts);
    if (dt == null) return null;
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = _preview == null
        ? null
        : [_preview!, ?_relTime].join(' · ');
    return Material(
      color: scheme.primaryContainer.withValues(alpha: _unread ? 1.0 : 0.45),
      child: ListTile(
        leading: IconResolver.resolve(
          'bot',
          size: 24,
          color: scheme.onPrimaryContainer,
        ),
        title: Text(
          'Coach',
          style: TextStyle(
            color: scheme.onPrimaryContainer,
            fontWeight: _unread ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                ),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_unread)
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            Icon(Icons.chevron_right, color: scheme.onPrimaryContainer),
          ],
        ),
        onTap: widget.onOpen,
      ),
    );
  }
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
    required this.entryViews,
    required this.readOnlyViews,
    required this.onOpenDomain,
    required this.onOpenView,
  });

  @override
  State<_DomainSections> createState() => _DomainSectionsState();
}

class _DomainSectionsState extends State<_DomainSections> {
  Future<List<DomainConfig>?>? _load;

  @override
  void initState() {
    super.initState();
    _load = widget.provider?.load();
  }

  /// Pull-to-refresh: bust the shared doc cache and refetch. (The home
  /// dashboard's reload busts the same cache — double-clearing is
  /// harmless.)
  Future<void> reload() async {
    final provider = widget.provider;
    if (provider == null) return;
    DomainConfigProvider.clearCache();
    final next = provider.load();
    setState(() => _load = next);
    await next;
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
    // Unclaimed views keep their old row shape under LOG.
    for (final v in [...widget.entryViews, ...widget.readOnlyViews]) {
      if (!claimed.contains(v.name)) log.add(_viewTile(context, v));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (log.isNotEmpty) ...[_sectionHeader(context, 'Log'), ...log],
        if (connected.isNotEmpty) ...[
          _sectionHeader(context, 'Connected'),
          ...connected,
        ],
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _domainTile(BuildContext context, DomainConfig d, ViewSchema view) {
    return ListTile(
      leading: IconResolver.resolve(
        d.icon ?? view.icon,
        size: 22,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(d.name),
      subtitle: view.description == null
          ? null
          : Text(
              view.description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => widget.onOpenDomain(d, view),
    );
  }

  /// Dense row for a view the config doesn't claim — same shape the
  /// Ledgers expandable used.
  Widget _viewTile(BuildContext context, ViewSchema view) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.only(left: 28, right: 16),
      leading: IconResolver.resolve(
        view.icon,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(view.name),
      subtitle: view.description == null
          ? null
          : Text(
              view.description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: const Icon(Icons.chevron_right),
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
        for (final view in widget.entryViews) _viewTile(context, view),
        if (widget.readOnlyViews.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 16, 2),
            child: Text(
              'Read-only',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
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
