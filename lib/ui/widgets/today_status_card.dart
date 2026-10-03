import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../models/view_schema.dart';
import '../../services/day_synthesis.dart' show DaySynthesisContext;
import '../../services/day_synthesis_service.dart';
import '../../services/integrations/integration.dart';
import '../../services/integrations/registry.dart';
import '../../services/log_event_bus.dart';
import '../../services/plan_store.dart';
import '../../services/program_current.dart';
import '../../services/program_provider.dart';
import '../../services/sync_scheduler.dart';
import '../../services/today_program_call.dart' show shouldPromptKayaSync;
import '../../services/today_status.dart';
import '../../services/warehouse_connector.dart';
import '../design/design.dart';
import 'skeleton.dart';

/// IDs of the quiet background integrations the gated refresh force-pulls
/// on "Sync & update" — all three are OAuth/Health-Connect pulls that
/// need no user interaction (unlike Kaya, which opens its app).
const _kQuietSyncIds = ['withings', 'macrofactor', 'whoop_api'];

/// Dialog-1 outcome for the gated refresh.
enum _RefreshChoice { syncAndUpdate, justUpdate }

/// Progress-tab header card: a plain-language read on how today is going
/// against the plan — FOOD (Macrofactor meals vs macro targets) + TRAINING
/// (logged strength sets vs today's planned sets). Replaced the Coach
/// preview row; the coach stays reachable on its own tab.
///
/// Loads its own data (meals + strength rows, planned strength entries,
/// the day's macro targets) and degrades to honest "no data" lines on any
/// failure — never throws, never blocks the tab.
class TodayStatusCard extends StatefulWidget {
  final ViewSchema? mealsView;
  final WarehouseConnector? mealsRepo;
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;

  /// Intent-docs provider — supplies today's macro targets. Null when the
  /// build has no GitHub config; the food line then shows what was eaten
  /// without a target.
  final ProgramProvider? provider;

  /// AI day-synthesis (Feature 1). When present + enabled, the card leads
  /// with a short unprompted read on how the day is going against the plan
  /// (climbing-to-come aware, macro-timing aware). Null / disabled →
  /// falls back to the two static lines. Never blocks the tab.
  final DaySynthesisService? synthesis;

  /// Integration registry — the gated refresh force-pulls the quiet
  /// background sources (Withings/Macrofactor/Whoop) and, on a climb day,
  /// runs the Kaya guided sync through it. Null → refresh just
  /// regenerates (no sync offer), preserving the old behavior.
  final IntegrationRegistry? registry;

  /// Tap handler — the shell selects the Log tab.
  final VoidCallback onOpen;

  /// Tap-the-AI-read handler — the shell switches to the Coach tab and
  /// opens today's synthesis thread, seeded with [seedText] (the current
  /// synthesis) so the user can keep talking from it. When the synthesis
  /// is disabled/null, [seedText] is null → the shell just opens Coach
  /// with no seed. Null → the AI region isn't tappable (no shell wiring).
  final void Function({String? seedText})? onOpenCoachThread;

  const TodayStatusCard({
    super.key,
    required this.mealsView,
    required this.mealsRepo,
    required this.strengthView,
    required this.strengthRepo,
    required this.provider,
    this.synthesis,
    this.registry,
    required this.onOpen,
    this.onOpenCoachThread,
  });

  @override
  State<TodayStatusCard> createState() => TodayStatusCardState();
}

class TodayStatusCardState extends State<TodayStatusCard> {
  TodayStatus? _status;

  // --- AI synthesis (Feature 1) ---
  DaySynthesisResult? _synthesis;
  bool _synthesizing = false;

  /// A quiet fingerprint check is in flight ([regenerateSynthesis]).
  bool _checking = false;
  StreamSubscription<LogEvent>? _logSub;
  Timer? _synthDebounce;

  /// The sync scheduler whose `lastSync` we listen to — integration pulls
  /// (Whoop / Macrofactor / Withings) ingest without a LogEvent, so a
  /// finished sync is the signal that their rows may have changed.
  SyncScheduler? _sched;

  // --- gated sync (Feature: refresh → sync-first) ---
  // Non-null while a refresh-triggered integration sync runs; shown on
  // the card in place of the refresh affordance ("Syncing…").
  String? _syncStatus;

  bool get _synthEnabled => widget.synthesis?.enabled == true;

  @override
  void initState() {
    super.initState();
    refresh();
    _loadCachedSynthesis();
    // Re-check the synthesis when new data lands — a log event (set,
    // calisthenics, meal, move, skip) or a finished sync (Whoop /
    // Macrofactor pulls). Debounced, and FINGERPRINT-gated: the LLM runs
    // only when the context actually changed. Never blocks the tab.
    _logSub = LogEventBus.instance.stream.listen((_) => _scheduleSynthesis());
    _sched = SyncScheduler.instance;
    _sched?.lastSync.addListener(_scheduleSynthesis);
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _sched?.lastSync.removeListener(_scheduleSynthesis);
    _synthDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadCachedSynthesis() async {
    final svc = widget.synthesis;
    if (svc == null || !svc.enabled) return;
    final cached = await svc.cached();
    if (!mounted) return;
    if (cached != null) setState(() => _synthesis = cached);
    // Show the stored read immediately, then re-check it against the live
    // context: anything that changed since it was written (a Whoop sync,
    // a set, a move…) regenerates it. No read yet today → generates.
    unawaited(regenerateSynthesis(onlyIfStale: true));
  }

  void _scheduleSynthesis() {
    if (!_synthEnabled) return;
    _synthDebounce?.cancel();
    _synthDebounce = Timer(
      const Duration(seconds: 4),
      () => unawaited(regenerateSynthesis(onlyIfStale: true)),
    );
  }

  /// (Re)runs the LLM synthesis. Shows a refreshing state; on failure keeps
  /// the last synthesis. Also refreshes the static lines. [onlyIfStale]
  /// skips the LLM when the stored read's context fingerprint still
  /// matches (the manual refresh always regenerates).
  Future<void> regenerateSynthesis({bool onlyIfStale = false}) async {
    final svc = widget.synthesis;
    if (svc == null || !svc.enabled || _synthesizing || _checking) return;
    DaySynthesisContext? ctx;
    if (onlyIfStale) {
      // Quiet freshness check first — no refreshing state unless the
      // read actually needs regenerating.
      _checking = true;
      try {
        ctx = await svc.buildContext();
        if (await svc.isFresh(ctx)) return;
      } catch (_) {
        return;
      } finally {
        _checking = false;
      }
    }
    if (mounted) setState(() => _synthesizing = true);
    DaySynthesisResult? result;
    try {
      result = await svc.generate(context: ctx);
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    setState(() {
      if (result != null) _synthesis = result;
      _synthesizing = false;
    });
    // Keep the summary lines in step.
    unawaited(refresh());
  }

  /// The refresh-button handler: offer to sync the latest integration
  /// data FIRST, then regenerate the synthesis from the now-fresh rows.
  ///
  /// Flow (USER-APPROVED):
  ///   Dialog 1 "Sync latest first?" → [Sync & update] / [Just update].
  ///     "Just update"  → regenerate only (old behavior).
  ///     "Sync & update" → force-pull Withings/Macrofactor/Whoop (quiet,
  ///       no user interaction; tolerant — a failed pull surfaces nothing
  ///       fatal), THEN Dialog 2 (only on a climb day with no climb yet).
  ///   Dialog 2 "Climbed today? Sync Kaya too?" → [Sync Kaya] / [Skip].
  ///     "Sync Kaya" → the KayaGmailIntegration guided flow (opens Kaya,
  ///       polls Gmail). This is the intrusive one, so it's separately
  ///       gated + program-conditional.
  ///   After syncs settle → regenerate.
  ///
  /// With no registry (or disabled synthesis) it degrades to a plain
  /// regenerate — no sync offer.
  Future<void> onRefreshPressed(BuildContext context) async {
    if (_syncStatus != null) return; // already syncing
    final registry = widget.registry;
    if (registry == null) {
      await regenerateSynthesis();
      return;
    }

    final choice = await showDialog<_RefreshChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sync latest first?'),
        content: const Text(
          'Pull the latest weight (Withings), meals (Macrofactor) and '
          'recovery (Whoop) before updating today\'s read?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _RefreshChoice.justUpdate),
            child: const Text('Just update'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _RefreshChoice.syncAndUpdate),
            child: const Text('Sync & update'),
          ),
        ],
      ),
    );
    if (choice == null) return; // dismissed — no-op
    if (choice == _RefreshChoice.justUpdate) {
      await regenerateSynthesis();
      return;
    }

    // --- Sync & update ---
    if (mounted) setState(() => _syncStatus = 'Syncing…');
    try {
      await registry.pullNow(_kQuietSyncIds);
    } catch (_) {/* pulls never throw; belt-and-suspenders */}

    // Dialog 2: Kaya — only on a climb day with no climb logged yet.
    if (context.mounted) {
      await _maybePromptKaya(context, registry);
    }

    if (mounted) setState(() => _syncStatus = null);
    await regenerateSynthesis();
  }

  /// Program-conditional Kaya prompt. Uses the synthesis context's climb
  /// info (today's program call + logged climb count) via the pure
  /// [shouldPromptKayaSync]. Skips silently when the climb state can't be
  /// determined (no synthesis service) or Kaya isn't a guided integration.
  Future<void> _maybePromptKaya(
    BuildContext context,
    IntegrationRegistry registry,
  ) async {
    final kaya = registry.byId('kaya_gmail');
    if (kaya is! GuidedSyncIntegration || !kaya.isConfigured) return;
    if (!await kaya.isConnected) return;

    DaySynthesisContext? sctx;
    try {
      sctx = await widget.synthesis?.buildContext();
    } catch (_) {
      sctx = null;
    }
    if (sctx == null) return; // can't tell if a climb is expected
    final prompt = shouldPromptKayaSync(
      programCall: {
        if (sctx.climbPrescribed) 'climbing': 'climb',
      },
      loggedClimbCount: sctx.logged.climbCount,
    );
    if (!prompt) return;

    if (!context.mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Climbed today?'),
        content: const Text(
          'Today\'s plan has a climbing session. Sync Kaya too? '
          '(opens Kaya to export your logbook)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sync Kaya'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    if (mounted) setState(() => _syncStatus = 'Syncing Kaya…');
    try {
      await kaya.guidedSync(context);
    } catch (_) {/* guided sync surfaces its own snackbars */}
  }

  /// Recomputes the status + training overview from live rows + the day's
  /// targets. Public-within-library: the shell calls it on pull-to-refresh.
  Future<void> refresh() async {
    final status = await _compute();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<TodayStatus> _compute() async {
    final today = DateTime.now();
    final dayStart = DateTime(today.year, today.month, today.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    // --- meals eaten today (Macrofactor + hand-entered) ---
    final meals = <TodayMeal>[];
    final mv = widget.mealsView;
    final mr = widget.mealsRepo;
    if (mv != null && mr != null) {
      try {
        for (final r in await mr.list(mv)) {
          final eaten = _date(r['eaten_at']);
          if (eaten == null) continue;
          if (eaten.isBefore(dayStart) || !eaten.isBefore(dayEnd)) continue;
          meals.add(TodayMeal(
            calories: _num(r['calories']),
            proteinG: _num(r['protein_g']),
            carbsG: _num(r['carbs_g']),
            fatG: _num(r['fat_g']),
          ));
        }
      } catch (_) {/* honest empty */}
    }

    // --- strength logged today (names for the fallback status line) ---
    final logged = <TodaySet>[];
    final sv = widget.strengthView;
    final sr = widget.strengthRepo;
    if (sv != null && sr != null) {
      try {
        for (final r in await sr.list(sv)) {
          final d = _date(r['date']);
          if (d == null) continue;
          if (d.year != dayStart.year ||
              d.month != dayStart.month ||
              d.day != dayStart.day) {
            continue;
          }
          final ex = r['exercise']?.toString().trim();
          if (ex == null || ex.isEmpty) continue;
          logged.add(TodaySet(exercise: ex));
        }
      } catch (_) {/* honest empty */}
    }

    // --- strength planned today (local PlanStore) ---
    final planned = <TodaySet>[];
    if (sv != null) {
      try {
        for (final e in await PlanStore.loadForDate(sv, today)) {
          final ex = e.values['exercise']?.toString().trim();
          if (ex == null || ex.isEmpty) continue;
          planned.add(TodaySet(exercise: ex));
        }
      } catch (_) {/* honest empty */}
    }

    // --- today's macro targets (from the program slice) ---
    var targets = const TodayTargets();
    final provider = widget.provider;
    if (provider != null) {
      try {
        final docs = await provider.load();
        final slice = docs.program == null
            ? null
            : programCurrent(docs.program!, docs.phase, today);
        if (slice != null) {
          targets = TodayTargets(
            proteinGDay: _pair(slice.targetsInForce['protein_g_day']),
            carbsGDay: _pair(slice.targetsInForce['carbs_g_day']),
            fatGDayMin: _num(slice.targetsInForce['fat_g_day_min']),
          );
        }
      } catch (_) {/* no target → still shows what was eaten */}
    }

    final status = buildTodayStatus(
      meals: meals,
      loggedSets: logged,
      plannedSets: planned,
      targets: targets,
      today: dayStart,
    );
    return status;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_synthEnabled) return _buildSynthesis(context, scheme);

    // Fallback: the original two static lines (disable_post_log / no LLM).
    final status = _status;
    return AppCard(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      onTap: widget.onOpen,
      child: Row(
        children: [
          Expanded(
            child: status == null
                ? Text('Today', style: AppText.section(context))
                : _line(context, status.exerciseText, status.exerciseState),
          ),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }

  /// Feature 1 (reworked 2026-09-30): the AI day-synthesis card. Layout,
  /// top → bottom:
  ///   1. header row — "Today" + a refresh affordance (or a sync/synth
  ///      spinner),
  ///   2. the ALWAYS-ON food + training summary lines (met/behind color
  ///      states; tap → Log),
  ///   3. a divider,
  ///   4. the AI read — rendered as markdown (bold/lists), TAPPABLE: tap
  ///      opens today's coach thread seeded with the synthesis so the
  ///      user keeps talking from it (onOpenCoachThread).
  ///
  /// The old tap-to-expand toggle is gone — the summary lines are always
  /// shown and the tap gesture now opens the coach.
  Widget _buildSynthesis(BuildContext context, ColorScheme scheme) {
    final synth = _synthesis;
    return AppCard(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- header: ✨ COACH'S READ + the refresh affordance ---
          SizedBox(
            height: 36,
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 14, color: scheme.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text("COACH'S READ", style: AppText.section(context)),
                ),
                if (_syncStatus != null) ...[
                  Text(_syncStatus!, style: AppText.meta(context)),
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ] else if (_synthesizing)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    icon: Icon(Icons.refresh,
                        size: 18, color: scheme.onSurfaceVariant),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(onRefreshPressed(context)),
                    tooltip: 'Refresh',
                  ),
              ],
            ),
          ),
          // --- AI read: markdown, tap → continue in Coach. This card is
          // the coach's read only — macros and the program are their own
          // cards on the Today tab. ---
          _buildAiRead(context, scheme, synth),
        ],
      ),
    );
  }

  /// The AI synthesis block: an ✨ "Today" header + the markdown read,
  /// wrapped in an InkWell that opens today's coach thread seeded with
  /// the synthesis. Tapping while the read is still generating (or with
  /// synthesis disabled) opens Coach without a seed.
  Widget _buildAiRead(
    BuildContext context,
    ColorScheme scheme,
    DaySynthesisResult? synth,
  ) {
    final open = widget.onOpenCoachThread;
    Widget body;
    if (synth != null) {
      body = MarkdownBody(
        data: synth.text,
        // The card tap (not text selection) drives the gesture — keep the
        // markdown non-selectable so the whole block routes to the InkWell.
        selectable: false,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: _readStyle(context),
          strong: _readStyle(context).copyWith(fontWeight: FontWeight.w600),
          em: _readStyle(context).copyWith(fontStyle: FontStyle.italic),
          listBullet: _readStyle(context),
        ),
      );
    } else if (_synthesizing) {
      // Consistent with the progress cards' skeletons: greyed,
      // fixed-height, pulsing text-shaped bars.
      body = const CardSkeleton(bars: [
        (width: double.infinity, height: 12),
        (width: 220, height: 12),
      ]);
    } else {
      body = Text(
        'Not enough logged yet — log a meal or a set.',
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 14,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        body,
        if (open != null && synth != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Ask the coach',
                  style: AppText.meta(context).copyWith(
                    color: scheme.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.chevron_right, size: 16, color: scheme.tertiary),
              ],
            ),
          ),
      ],
    );

    if (open == null) return content;
    return InkWell(
      // Disabled/null synthesis → open Coach with no seed. With a read →
      // seed today's thread with its text.
      onTap: () => open(seedText: synth?.text),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: content,
      ),
    );
  }

  /// The read's body text: the row role at regular weight, airier.
  static TextStyle _readStyle(BuildContext context) =>
      AppText.row(context).copyWith(fontWeight: FontWeight.w400, height: 1.4);

  Widget _line(BuildContext context, String text, TodayState state) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (state) {
      TodayState.done => (Icons.check_circle, scheme.primary),
      TodayState.onTrack => (Icons.trending_up, scheme.onSurface),
      TodayState.behind => (Icons.error_outline, scheme.error),
      TodayState.rest => (Icons.bedtime_outlined, scheme.onSurfaceVariant),
      TodayState.none => (Icons.radio_button_unchecked, scheme.onSurfaceVariant),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 8),
          child: Icon(icon, size: 16, color: color),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: scheme.onSurface, fontSize: 14),
          ),
        ),
      ],
    );
  }

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static List<double>? _pair(Object? v) {
    if (v is List && v.length >= 2) {
      final a = _num(v[0]);
      final b = _num(v[1]);
      if (a != null && b != null) return [a, b];
    }
    return null;
  }
}
