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
import '../services/integrations/registry.dart';
import '../services/integrations/whoop.dart';
import '../services/integrations/withings.dart';
import '../services/coach_brain.dart';
import '../services/github_client.dart';
import '../services/icon_resolver.dart';
import '../services/llm_client.dart';
import '../services/llm_response_cache.dart';
import '../services/qbo_service.dart';
import '../services/schema_loader.dart';
import '../services/schema_sync.dart';
import '../services/transient_retry.dart';
import '../services/warehouse_connector.dart';
import 'apps_screen.dart';
import 'chat_screen.dart';
import 'coach_chat_screen.dart';
import 'coach_threads_screen.dart';
import 'timeline_screen.dart';
import 'today_dashboard.dart';

/// The synced view that backs the coach chat. Hidden from the normal
/// tile list; surfaced only through the pinned Coach row + chat screen.
const kCoachChatViewName = 'coach_chat';

/// App entrypoint screen. Loads config + schemas, connects to the
/// warehouse, and presents:
///
///   1. A compact "today" dashboard at the top showing per-view counts
///   2. The list of views
///   3. An "Apps" entry for `.app.yml` analytics
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

  /// Signature of the schema state currently applied. The poller compares
  /// the repo's signature against this to decide whether to re-sync.
  String? _knownSig;

  /// Reentrancy guard so overlapping ticks (slow network) don't stack.
  bool _polling = false;

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
    // every sync/reload). Seed _knownSig from the cache so a freshly
    // launched app that's already current doesn't immediately re-sync.
    final github = assetConfig.github;
    if (_syncTimer == null && github != null && github.pollSeconds > 0) {
      _knownSig = await SchemaSync.cachedSignature();
      _syncTimer = Timer.periodic(
        Duration(seconds: github.pollSeconds),
        (_) => _pollGithub(github),
      );
    }

    final views = await SchemaLoader.loadAll();
    final keyJson =
        await rootBundle.loadString('assets/service-account.json');
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
    // Skip analytics-only views (no .input.yml). Their dimensions are
    // SQL expressions (e.g. `CAST(date AS DATE)`), so passing them to
    // `ensureTable` would try to write those exprs as sheet column
    // headers — corrupts the underlying sheet and surfaces as a
    // "bad state: can't finalize a finalized request" mid-startup.
    for (final view in views.where((v) => v.hasInputOverlay)) {
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
      for (final v in views) {
        if (v.name == 'weight') weightView = v;
      }
      // _initialize() re-runs on schema reload; tear down the previous
      // service's BLE connection + retry timer before replacing it.
      await HeartRateService.instance?.disconnect();
      final hrService = HeartRateService(repo: repo.repo);
      HeartRateService.instance = hrService;
      await hrService.init();
      IntegrationRegistry.init(integrations: [
        if (weightView != null)
          WithingsIntegration(
            config: assetConfig.withings,
            repo: repo.repo,
            weightViewJson: viewSchemaToEngineJson(weightView),
          ),
        WhoopIntegration(hr: hrService),
        ComingSoonIntegration('Macrofactor', '→ meals (via Health Connect)'),
      ]);
      await SyncScheduler.init(
        ledger: repo,
        viewsJson: views
            .where((v) => v.hasInputOverlay && v.datasource == 'gsheets')
            .map(viewSchemaToEngineJson)
            .toList(),
      );
    }
    // disable_post_log in config.yml gates every piece of the LLM plumbing.
    // When set, we hand TimelineScreen `null` llm/cache so the post-log hook
    // is a no-op even for views that declare one — useful for builds (Poke
    // House) where we don't want any LLM behavior at all.
    final llm = assetConfig.disablePostLog
        ? null
        : LlmClient(assetConfig.models);
    final llmCache =
        assetConfig.disablePostLog ? null : LlmResponseCache();
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
    );
  }

  /// One poll tick: cheaply check whether the repo's schema state differs
  /// from what's applied, and if so pull + rebuild. Silent (no snackbars)
  /// — this runs unattended in kiosk mode. Skips entirely when the user
  /// has anything pushed on top of the home/timeline (a form, dialog,
  /// chat, app viewer): rebuilding then would tear down their in-progress
  /// work. We simply retry on the next tick.
  Future<void> _pollGithub(GithubConfig cfg) async {
    if (_polling || !mounted) return;
    if (Navigator.of(context).canPop()) return; // user is mid-task; defer
    _polling = true;
    try {
      final sync = SchemaSync(GithubClient(cfg));
      final remote = await sync.remoteSignature();
      if (remote == null) return; // network/API hiccup — try next tick
      if (remote == _knownSig) return; // nothing changed
      final result = await sync.refresh();
      if (!result.ok) return;
      _knownSig = result.signature;
      if (!mounted) return;
      // Re-check before rebuilding: the user may have opened a form during
      // the fetch. If so, the cache is already updated and the new schema
      // applies on the next natural rebuild; don't yank the UI now.
      if (Navigator.of(context).canPop()) return;
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
      _knownSig = result.signature;
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
        final chatModel =
            boot == null ? null : _chatModel(boot.models);
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
          appBar: AppBar(
            title: Text(appName),
            actions: [
              // Not const: a const instance is identical across parent
              // rebuilds, so Flutter would skip build() and freeze the
              // pre-bootstrap empty state (SyncScheduler.instance null).
              SyncStatusButton(),
              if (chatModel != null)
                IconButton(
                  icon: const Icon(Icons.smart_toy_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        model: chatModel,
                        github:
                            github == null ? null : GithubClient(github),
                        analytics: boot?.analytics,
                      ),
                    ),
                  ),
                  tooltip: 'Chat',
                ),
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
            ],
          ),
          body: Builder(
            builder: (context) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return _ErrorView(error: snap.error.toString());
              }
              final data = snap.data!;
              // Only show data-entry trackers (paired with .input.yml).
              // Analytics-only views still live in data.views for the
              // chat / apps screen to query. coach_chat is a chat, not
              // a tracker — excluded here, rendered as the pinned Coach
              // row instead.
              final entryViews = data.views
                  .where((v) =>
                      v.hasInputOverlay && v.name != kCoachChatViewName)
                  .toList();
              ViewSchema? coachView;
              for (final v in data.views) {
                if (v.name == kCoachChatViewName) coachView = v;
              }
              if (entryViews.isEmpty && coachView == null) {
                return const Center(child: Text('No views available.'));
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
                      llm: data.llm!,
                      modelName: chatModel.name,
                      repository: data.repository,
                      views: {for (final v in data.views) v.name: v},
                      fetchDoc: CoachBrain.githubFetcher(github),
                    );
              return Column(
                children: [
                  TodayDashboard(
                    views: entryViews,
                    registry: data.registry,
                    quickbooks: data.quickbooks,
                    qboService: data.qboService,
                  ),
                  if (coachView != null)
                    _CoachRow(
                      view: coachView,
                      repository: data.registry.forView(coachView),
                      ledger: coachLedger,
                      brain: coachBrain,
                    ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: entryViews.length + 2,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        if (i == entryViews.length + 1) {
                          return ListTile(
                            leading: const Icon(Icons.sync_alt),
                            title: const Text('Integrations'),
                            subtitle: const Text(
                                'Withings and other sources → ledger'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const IntegrationsScreen(),
                              ),
                            ),
                          );
                        }
                        if (i == entryViews.length) {
                          return ListTile(
                            leading: const Icon(Icons.bar_chart),
                            title: const Text('Apps'),
                            subtitle: const Text(
                                'Interactive analytics from .app.yml'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => AppsScreen(
                                  views: data.views,
                                  repository: data.repository,
                                ),
                              ),
                            ),
                          );
                        }
                        final view = entryViews[i];
                        return ListTile(
                          leading: IconResolver.resolve(
                            view.icon,
                            size: 22,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          title: Text(view.name),
                          subtitle: view.description == null
                              ? null
                              : Text(view.description!),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => TimelineScreen(
                                view: view,
                                repository: data.registry.forView(view),
                                llm: data.llm,
                                llmCache: data.llmCache,
                                chatModel: chatModel,
                                github: github == null
                                    ? null
                                    : GithubClient(github),
                                analytics: data.analytics,
                                qboSpec: data.quickbooks?.specFor(view.name),
                                qboService:
                                    data.quickbooks?.specFor(view.name) == null
                                        ? null
                                        : data.qboService,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
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
  });
}

/// Pinned Coach row above the tracker tiles. Tinted (primaryContainer)
/// so it reads as a different kind of row; shows a preview of the
/// newest coach message across all threads + relative time, and an
/// accent dot / stronger tint while ANY thread is unread (per-thread
/// newest coach `ts` vs its device-local read marker, with the legacy
/// fallback for `general`). Tap opens [CoachThreadsScreen]; preview +
/// unread refresh on return and when a background sync completes.
class _CoachRow extends StatefulWidget {
  final ViewSchema view;
  final WarehouseConnector repository;
  final EngineLedgerRepository? ledger;
  final CoachBrain? brain;

  const _CoachRow({
    required this.view,
    required this.repository,
    this.ledger,
    this.brain,
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
    _refresh();
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
    if (_syncing?.value == false) _refresh();
  }

  Future<void> _refresh() async {
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
          } catch (_) {/* treat as missing */}
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
    } catch (_) {/* keep whatever the row currently shows */}
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

  Future<void> _open() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CoachThreadsScreen(
          view: widget.view,
          repository: widget.repository,
          ledger: widget.ledger,
          brain: widget.brain,
        ),
      ),
    );
    // The chat screens mark their threads read (and the user may have
    // sent messages) — refresh the preview/unread state on return.
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = _preview == null
        ? null
        : [_preview!, ?_relTime].join(' · ');
    return Material(
      color: scheme.primaryContainer
          .withValues(alpha: _unread ? 1.0 : 0.45),
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
        onTap: _open,
      ),
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
