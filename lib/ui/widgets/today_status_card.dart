import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/view_schema.dart';
import '../../services/day_synthesis.dart' show DaySynthesisContext;
import '../../services/day_synthesis_service.dart';
import '../../services/integrations/integration.dart';
import '../../services/integrations/registry.dart';
import '../../services/log_event_bus.dart';
import '../../services/plan_store.dart';
import '../../services/program_current.dart';
import '../../services/program_provider.dart';
import '../../services/today_program_call.dart' show shouldPromptKayaSync;
import '../../services/today_status.dart';
import '../../services/warehouse_connector.dart';
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
  });

  @override
  State<TodayStatusCard> createState() => TodayStatusCardState();
}

class TodayStatusCardState extends State<TodayStatusCard> {
  TodayStatus? _status;

  // --- AI synthesis (Feature 1) ---
  DaySynthesisResult? _synthesis;
  bool _synthesizing = false;
  bool _expanded = false;
  StreamSubscription<LogEvent>? _logSub;
  Timer? _synthDebounce;

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
    // Auto-refresh the synthesis when new data is logged (debounced so a
    // batch of set logs = one regeneration). Never blocks the tab.
    _logSub = LogEventBus.instance.stream.listen((_) => _scheduleSynthesis());
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _synthDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadCachedSynthesis() async {
    final svc = widget.synthesis;
    if (svc == null || !svc.enabled) return;
    final cached = await svc.cached();
    if (!mounted) return;
    if (cached != null) {
      setState(() => _synthesis = cached);
    } else {
      // No synthesis yet today — generate one in the background.
      unawaited(regenerateSynthesis());
    }
  }

  void _scheduleSynthesis() {
    if (!_synthEnabled) return;
    _synthDebounce?.cancel();
    _synthDebounce = Timer(
      const Duration(seconds: 4),
      () => unawaited(regenerateSynthesis()),
    );
  }

  /// (Re)runs the LLM synthesis. Shows a refreshing state; on failure keeps
  /// the last synthesis. Also refreshes the static lines.
  Future<void> regenerateSynthesis() async {
    final svc = widget.synthesis;
    if (svc == null || !svc.enabled || _synthesizing) return;
    if (mounted) setState(() => _synthesizing = true);
    DaySynthesisResult? result;
    try {
      result = await svc.generate();
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
        if (sctx.program.climbCall != null) 'climbing': sctx.program.climbCall!,
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

  /// Recomputes the two lines from live rows + the day's targets.
  /// Public-within-library: the shell calls it on pull-to-refresh.
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

    // --- strength logged today ---
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

    return buildTodayStatus(
      meals: meals,
      loggedSets: logged,
      plannedSets: planned,
      targets: targets,
      today: dayStart,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_synthEnabled) return _buildSynthesis(context, scheme);

    // Fallback: the original two static lines (disable_post_log / no LLM).
    final status = _status;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: InkWell(
        onTap: widget.onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Expanded(
                child: status == null
                    ? Text(
                        'Today',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _line(context, status.foodText, status.foodState),
                          const SizedBox(height: 4),
                          _line(
                            context,
                            status.exerciseText,
                            status.exerciseState,
                          ),
                        ],
                      ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  /// Feature 1: the AI day-synthesis card. Leads with the short synthesis;
  /// tap toggles the detailed two-line summary. A refresh icon regenerates.
  Widget _buildSynthesis(BuildContext context, ColorScheme scheme) {
    final synth = _synthesis;
    final status = _status;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome, size: 16, color: scheme.tertiary),
                  const SizedBox(width: 8),
                  Text(
                    'Today',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const Spacer(),
                  if (_syncStatus != null) ...[
                    Text(
                      _syncStatus!,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
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
                      icon: const Icon(Icons.refresh, size: 18),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => unawaited(onRefreshPressed(context)),
                      tooltip: 'Refresh',
                    ),
                  const SizedBox(width: 8),
                ],
              ),
              const SizedBox(height: 6),
              if (synth != null)
                Text(
                  synth.text,
                  style: TextStyle(color: scheme.onSurface, fontSize: 14),
                )
              else if (_synthesizing)
                // Consistent with the progress cards' skeletons: greyed,
                // fixed-height, pulsing text-shaped bars instead of a
                // bare "Reading your day…" that then reflows into the read.
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 2),
                  child: CardSkeleton(bars: [
                    (width: double.infinity, height: 12),
                    (width: 220, height: 12),
                  ]),
                )
              else
                Text(
                  'Not enough logged yet — log a meal or a set.',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              if (_expanded && status != null) ...[
                const SizedBox(height: 12),
                Divider(height: 1, color: scheme.outlineVariant),
                const SizedBox(height: 12),
                _line(context, status.foodText, status.foodState),
                const SizedBox(height: 4),
                _line(context, status.exerciseText, status.exerciseState),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: widget.onOpen,
                    child: const Text('Open Log'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

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
