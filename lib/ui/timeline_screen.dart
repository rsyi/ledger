import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';

import 'package:jinja/jinja.dart' hide Template;

import '../models/model_config.dart';
import '../models/planned_entry.dart';
import '../models/quickbooks_config.dart';
import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/day_best.dart';
import '../services/derive.dart';
import '../services/display_names.dart';
import '../services/qbo_push_store.dart';
import '../services/qbo_service.dart';
import '../services/row_cache.dart';
import '../services/github_client.dart';
import '../services/list_display_render.dart';
import '../services/llm_client.dart';
import '../services/llm_response_cache.dart';
import '../services/log_now.dart';
import '../services/plan_store.dart';
import '../services/planned_slots.dart';
import '../services/sheets_repository.dart';
import '../services/warehouse_connector.dart';
import '../services/working_sets.dart' show warmupIndices;
import '../services/week_planner.dart' show WeekPlanner;
import 'chat_screen.dart';
import 'design/design.dart';
import 'form_screen.dart';
import '../services/video_rpe.dart' show mediaIdFieldFor;
import 'widgets/history_panel.dart';
import 'widgets/rest_timer_sheet.dart';
import 'widgets/video_preview.dart';

/// One row in the timeline. Three flavors:
/// - `_Item.planned`  — from PlanStore, not in sheet yet
/// - `_Item.logged`   — single row from the sheet
/// - `_Item.batch`    — multiple sheet rows sharing one
///   `repeat_group.group_key` value, rendered as one tile
class _Item {
  final Record? logged;
  final PlannedEntry? planned;

  /// Non-null when this item represents a batch — multiple rows in the
  /// sheet sharing one `repeat_group.group_key` value. The timeline
  /// renders one tile per batch; edit re-opens all rows in the
  /// FormScreen; delete drops every row in the list.
  final List<Record>? batchRows;

  /// The shared `group_key` value when [batchRows] is non-null. Doubles
  /// as the [keyString] for the batch — stable across reloads so
  /// selection survives.
  final String? batchKey;

  _Item.logged(this.logged)
      : planned = null,
        batchRows = null,
        batchKey = null;
  _Item.planned(this.planned)
      : logged = null,
        batchRows = null,
        batchKey = null;
  _Item.batch(this.batchRows, this.batchKey)
      : logged = null,
        planned = null;

  /// True when the item is a multi-row batch.
  bool get isBatch => batchRows != null;

  /// True only for items that haven't been written to the sheet yet.
  bool get isPlanned =>
      planned != null && logged == null && batchRows == null;

  /// True for batches and single logged rows — anything that's
  /// persisted in the sheet.
  bool get isLogged => logged != null || batchRows != null;

  /// Template association (used for grouping). Persists across the log-now
  /// transition for the current session.
  String? get templateName => planned?.templateName;

  /// Values to show / edit. For batches, the first row is the source of
  /// shared-field values (date, sauce, batch_qty, ...). For singletons,
  /// the row itself.
  Map<String, Object?> get values =>
      batchRows?.first ?? logged ?? planned!.values;

  String get keyString {
    if (batchKey != null) return 'batch-$batchKey';
    return planned?.localId ??
        logged?['id']?.toString() ??
        '${identityHashCode(this)}';
  }
}

/// Date-filtered list of records for a single view. Merges:
///   - logged rows from the sheet (filtered to selected date)
///   - planned rows from local plan store (filtered to selected date)
/// Planned rows appear at the top so they're easy to act on during a workout.
class TimelineScreen extends StatefulWidget {
  final ViewSchema view;
  final WarehouseConnector repository;
  final LlmClient? llm;
  final LlmResponseCache? llmCache;

  /// Anthropic model + GitHub client passed through so the chat icon in
  /// the app bar can launch ChatScreen with this view auto-attached as
  /// screen context. Both optional — the icon hides if no chat model is
  /// configured.
  final ModelConfig? chatModel;
  final GithubClient? github;

  /// AnalyticsEngine for the chat's run_query tool. Null when airlayer
  /// failed to load.
  final AnalyticsEngine? analytics;

  /// Initially selected date (defaults to today). Set when arriving
  /// from a coach proposal so the plan's day is already showing.
  final DateTime? initialDate;

  /// Planned-entry localIds to accent on arrival (coach "Schedule"
  /// hand-off). The accent fades a few seconds after first build.
  final Set<String> highlightKeys;

  /// True for fleet-deploy / single-purpose builds (Poke House). Suppresses
  /// app-bar chrome that doesn't belong in a kiosk context: the chat icon
  /// is hidden regardless of [chatModel], and the back button is gone
  /// because the timeline IS the root.
  final bool kioskMode;

  /// When non-null, this view pushes its transactions to QuickBooks as
  /// inventory-quantity changes. Drives the app-bar "Update" button and the
  /// per-row push-status badges. Both null together (the feature is inert
  /// unless config.yml declares a `quickbooks:` mapping for this view).
  final QboPushSpec? qboSpec;
  final QboService? qboService;

  /// Rendered above the date bar — the domain screen's dashboard header
  /// (stat chips + series charts). Null everywhere else.
  final Widget? header;

  /// Treat this timeline as read-only even when the VIEW isn't
  /// (integration-paradigm domains like meals: rows are ledger-synced,
  /// but the domain screen is a read surface). Same gating as
  /// `view.readOnly`: no FAB, no edit/move/delete/select, no planned
  /// rows, no swipe.
  final bool forceReadOnly;

  const TimelineScreen({
    super.key,
    required this.view,
    required this.repository,
    this.llm,
    this.llmCache,
    this.chatModel,
    this.github,
    this.analytics,
    this.initialDate,
    this.highlightKeys = const {},
    this.kioskMode = false,
    this.qboSpec,
    this.qboService,
    this.header,
    this.forceReadOnly = false,
  });

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  /// Effective read-only state: the view's own declaration OR the
  /// caller's override (integration-paradigm domain screens).
  bool get _readOnly => widget.forceReadOnly || widget.view.readOnly;

  // Intentionally not updated in didUpdateWidget — the screen is always
  // pushed fresh, so initialDate can't change under a live state.
  late DateTime _selectedDate = widget.initialDate ?? _today();
  late Future<List<_Item>> _items;

  /// Live highlight set — starts as widget.highlightKeys, cleared by a
  /// one-shot timer so the accent reads as "here's what just landed".
  late final Set<String> _highlightKeys = {...widget.highlightKeys};
  Timer? _highlightTimer;
  // date_keys with an in-flight background revalidation, so rapid date
  // toggling doesn't stack redundant network reads.
  final Set<String> _revalidating = {};
  // Multiselect state — populated only while selection mode is active. We key
  // by `_Item.keyString` so the set survives _reload() (where _Item instances
  // are rebuilt) for any items that still exist.
  final Set<String> _selectedKeys = {};
  bool _bulkDeleting = false;

  /// Planned-item localIds currently mid-`_logNow`. Guards against double-tap
  /// of the "log now" circle firing two concurrent writes for the same item,
  /// which has surfaced as "bad state: can't finalize a finalized request"
  /// in the auth client when the second request hits during a token refresh.
  final Set<String> _logNowInFlight = {};

  /// This session's log-nows (rowId → the planned entry), recorded
  /// optimistically so a row's ✓ / the group's n/N update before the
  /// undo mapping is persisted. Only counted while the row is on screen.
  final Map<String, PlannedEntry> _optimisticDone = {};

  /// Warm-up rows expanded to individual chips (date|slot key).
  final Set<String> _expandedWarmups = {};

  /// Set of dates that have at least one logged row for this view.
  /// Populated lazily — fed into the date-bar calendar so the user can see
  /// which days have data at a glance. Null while loading; empty if the
  /// fetch failed (calendar simply has no markers).
  Set<DateTime>? _loggedDates;

  /// True when a batch finish button is mid-flight. Gates duplicate taps
  /// + disables the button visually.
  bool _producing = false;

  /// keyStrings of logged tiles currently expanded inline. Tap toggles;
  /// expanded view shows the row's full field values plus an Edit
  /// button. Kept on the state (not the section widget) so it survives
  /// timeline rebuilds (LLM cache update, etc.).
  final Set<String> _expandedLoggedKeys = {};

  /// Undo-logging mappings for this view: logged rowId → the planned
  /// entry it was promoted from (see [PlanStore.undoMappings]). Drives
  /// the Log-now snackbar's UNDO action and the "Revert to plan" button
  /// on a logged row's expanded panel. Refreshed on every [_assemble].
  Map<String, PlannedEntry> _undoMappings = {};

  /// Per-transaction QuickBooks push status, keyed by row `id`. Empty
  /// (and unused) unless this view has a [TimelineScreen.qboSpec]. An id
  /// absent from the map renders as pending. Refreshed after each load and
  /// after a push.
  Map<String, QboPushRecord> _qboStatus = {};

  /// True while an Update (push-to-QBO) drain is running — gates the button.
  bool _qboPushing = false;

  bool get _qboEnabled =>
      widget.qboSpec != null && widget.qboService != null;

  void _toggleExpand(String key) {
    setState(() {
      if (!_expandedLoggedKeys.add(key)) _expandedLoggedKeys.remove(key);
    });
  }

  bool get _selectionMode => _selectedKeys.isNotEmpty;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void initState() {
    super.initState();
    _items = _fetch();
    _loadLoggedDates();
    _loadQboStatuses();
    widget.llmCache?.addListener(_onLlmUpdate);
    if (_highlightKeys.isNotEmpty) {
      // Fade only after the tiles are actually visible — the 4 s window
      // should start from render, not from a possibly-slow load.
      _highlightTimer = Timer(const Duration(seconds: 4), () {
        _items.then((_) {
          if (mounted) setState(_highlightKeys.clear);
        });
      });
    }
  }

  /// Flash the just-logged row(s) with the fade highlight instead of a
  /// snackbar (2026-10-01): instant confirmation that stays put and needs
  /// no dismissal. Restarts the one-shot fade.
  void _flash(Iterable<String> keys) {
    _highlightTimer?.cancel();
    setState(() => _highlightKeys.addAll(keys));
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(_highlightKeys.clear);
    });
  }

  /// Refreshes [_qboStatus] for the logged rows currently in [_items].
  /// No-op when the view isn't QBO-mapped. Best-effort + silent.
  Future<void> _loadQboStatuses() async {
    if (!_qboEnabled) return;
    try {
      final items = await _items;
      final ids = <String>[
        for (final it in items)
          if (it.isLogged)
            for (final r in it.batchRows ?? [it.logged!])
              if (r['id'] != null) r['id'].toString(),
      ];
      if (ids.isEmpty) return;
      final statuses =
          await widget.qboService!.statusesFor(widget.view.name, ids);
      if (!mounted) return;
      setState(() => _qboStatus = statuses);
    } catch (_) {/* badges just stay as-is */}
  }

  /// Pushes every not-yet-pushed transaction for this view to QuickBooks as
  /// an inventory-quantity change. Surfaces a summary via snackbar and
  /// refreshes the per-row badges. Serialized in the service layer.
  Future<void> _pushToQbo() async {
    if (!_qboEnabled || _qboPushing) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _qboPushing = true);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Pushing to QuickBooks…'),
        duration: Duration(seconds: 30),
      ),
    );
    try {
      // Push across all dates for the view, not just the selected day — the
      // ledger is the source of pending transactions.
      final rows = await widget.repository.list(widget.view);
      final summary =
          await widget.qboService!.pushPending(widget.view, widget.qboSpec!, rows);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'QuickBooks: ${summary.pushed} pushed'
            '${summary.failed > 0 ? ', ${summary.failed} failed' : ''}'
            '${summary.skipped > 0 ? ', ${summary.skipped} skipped' : ''}',
          ),
        ),
      );
      await _loadQboStatuses();
    } catch (e) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Push failed: $e')));
    } finally {
      if (mounted) setState(() => _qboPushing = false);
    }
  }

  /// Retry a single failed/pending transaction (tapping its badge).
  Future<void> _retryQbo(Record row) async {
    if (!_qboEnabled || _qboPushing) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _qboPushing = true);
    try {
      final ok =
          await widget.qboService!.pushOne(widget.view, widget.qboSpec!, row);
      await _loadQboStatuses();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(ok ? 'Pushed to QuickBooks' : 'Push failed'),
        duration: const Duration(milliseconds: 1200),
      ));
    } finally {
      if (mounted) setState(() => _qboPushing = false);
    }
  }

  /// One-tap finish: stamp end_time on every row in the batch.
  Future<void> _finishProduction(_Item item) async {
    if (_producing || !item.isBatch || _readOnly) return;
    setState(() => _producing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final stamp = DateFormat('h:mm:ss a').format(DateTime.now());
      for (final row in item.batchRows!) {
        final updated = Map<String, Object?>.from(row);
        updated['end_time'] = stamp;
        await widget.repository.update(widget.view, updated);
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Finished at $stamp'),
          duration: const Duration(milliseconds: 800),
        ),
      );
      _reload(fresh: true);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Finish failed: $e')));
    } finally {
      if (mounted) setState(() => _producing = false);
    }
  }

  /// Logged batches whose end_time is still blank — surfaced as a
  /// banner with a big Stop button. One banner per active batch.
  List<_Item> _activeBatches(List<_Item> items) {
    return items.where((it) {
      if (!it.isBatch) return false;
      return it.batchRows!.any((r) {
        final v = r['end_time']?.toString();
        return v == null || v.trim().isEmpty;
      });
    }).toList();
  }

  /// Best-effort fetch of every distinct date the view has data for. Drives
  /// the calendar markers. Re-run after any write so freshly-logged days
  /// appear. Silent on failure — the calendar just shows no markers.
  ///
  /// Cache-first: paint markers instantly from the cached all-rows bucket,
  /// then refresh it from the sheet in the background. This is a full-table
  /// scan, so serving the cache first keeps it off the open/reload path.
  Future<void> _loadLoggedDates() async {
    if (widget.view.dateField == null) return;
    final cached = await RowCache.get(widget.view, RowCache.allDatesKey);
    if (cached != null) _applyLoggedDates(cached);
    try {
      final rows = await widget.repository.list(widget.view);
      await RowCache.put(widget.view, RowCache.allDatesKey, rows);
      if (!mounted) return;
      _applyLoggedDates(rows);
    } catch (_) {
      if (!mounted || cached != null) return;
      setState(() => _loggedDates = const {});
    }
  }

  void _applyLoggedDates(List<Record> rows) {
    final dates = <DateTime>{};
    for (final r in rows) {
      final v = r[widget.view.dateField];
      DateTime? dt;
      if (v is DateTime) dt = v;
      if (v is String) dt = DateTime.tryParse(v);
      if (dt != null) {
        dates.add(DateTime(dt.year, dt.month, dt.day));
      }
    }
    if (!mounted) return;
    setState(() => _loggedDates = dates);
  }

  @override
  void dispose() {
    widget.llmCache?.removeListener(_onLlmUpdate);
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _onLlmUpdate() {
    if (mounted) setState(() {});
  }

  /// Cache key for the current view+date. Date-scoped views key by the
  /// selected day; dateless views share the single all-rows bucket.
  String _dateKey() => widget.view.dateField == null
      ? RowCache.allDatesKey
      : DateFormat('yyyy-MM-dd').format(_selectedDate);

  /// Live read of the logged rows from the warehouse for the current date.
  Future<List<Record>> _listFromSheet() => widget.view.dateField == null
      ? widget.repository.list(widget.view)
      : widget.repository.list(widget.view, onDate: _selectedDate);

  /// Loads the timeline items. Stale-while-revalidate by default: if the
  /// row cache has this date, assemble + return it immediately and kick
  /// off a background refresh ([_revalidate]) that updates the UI only if
  /// the sheet differs. [forceFresh] skips the cache entirely — used after
  /// writes and on explicit Refresh so you always see confirmed state.
  Future<List<_Item>> _fetch({bool forceFresh = false}) async {
    final dateKey = _dateKey();
    if (!forceFresh) {
      final cached = await RowCache.get(widget.view, dateKey);
      if (cached != null) {
        unawaited(_revalidate(dateKey));
        return _assemble(cached);
      }
    }
    final fresh = await _listFromSheet();
    await RowCache.put(widget.view, dateKey, fresh);
    return _assemble(fresh);
  }

  /// Background refresh behind a cache hit: re-fetch from the sheet, update
  /// the cache, and rebuild the timeline only if the rows actually changed
  /// (so a no-op refresh doesn't reset scroll/expansion). Failures keep the
  /// already-shown cached data — the sheet just isn't reachable right now.
  Future<void> _revalidate(String dateKey) async {
    if (!_revalidating.add(dateKey)) return;
    try {
      final before = await RowCache.get(widget.view, dateKey);
      final fresh = await _listFromSheet();
      await RowCache.put(widget.view, dateKey, fresh);
      if (!mounted || dateKey != _dateKey()) return;
      final changed = before == null ||
          RowCache.signature(widget.view, before) !=
              RowCache.signature(widget.view, fresh);
      if (!changed) return;
      final items = await _assemble(fresh);
      if (!mounted || dateKey != _dateKey()) return;
      setState(() {
        _items = Future.value(items);
      });
    } catch (_) {
      // keep serving cached data
    } finally {
      _revalidating.remove(dateKey);
    }
  }

  /// Merges planned (local) entries with logged (sheet) rows and folds
  /// repeat-group batches. Pure assembly over an already-fetched row list.
  /// Read-only views skip the PlanStore load entirely — planned items don't
  /// apply to browse-only content.
  Future<List<_Item>> _assemble(List<Record> logged) async {
    final planned = _readOnly
        ? const <PlannedEntry>[]
        : await PlanStore.loadForDate(widget.view, _selectedDate);
    // Refresh the undo-logging mappings alongside — cheap prefs read, and
    // this also applies the store's lazy 14-day prune.
    _undoMappings = _readOnly
        ? {}
        : await PlanStore.undoMappings(widget.view);

    // Batch grouping: when the view declares a repeat_group with a
    // group_key, fold contiguous-rows-sharing-a-group_key into single
    // _Item.batch entries. Rows missing/blank group_key stay singletons.
    final groupKey = widget.view.repeatGroup?.groupKey;
    final loggedItems = <_Item>[];
    if (groupKey != null) {
      final byKey = <String, List<Record>>{};
      final orderedKeys = <String>[];
      for (final r in logged) {
        final k = r[groupKey]?.toString();
        if (k == null || k.isEmpty) {
          loggedItems.add(_Item.logged(r));
          continue;
        }
        if (!byKey.containsKey(k)) {
          byKey[k] = [];
          orderedKeys.add(k);
        }
        byKey[k]!.add(r);
      }
      for (final k in orderedKeys) {
        loggedItems.add(_Item.batch(byKey[k]!, k));
      }
    } else {
      loggedItems.addAll(logged.map(_Item.logged));
    }

    return [
      ...planned.map(_Item.planned),
      ...loggedItems,
    ];
  }

  /// Reloads the timeline. [fresh] forces a cache-bypassing fetch (after
  /// writes / explicit Refresh); default is cache-first stale-while-
  /// revalidate (screen open, date navigation).
  void _reload({bool fresh = false}) {
    setState(() {
      _items = _fetch(forceFresh: fresh);
    });
    _loadLoggedDates();
    _loadQboStatuses();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back button exits selection mode instead of the screen when active.
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _selectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
        body: Column(
          children: [
            // Domain-dashboard header (domain_screen.dart) — metric
            // chips + series charts above the date bar.
            if (widget.header != null) widget.header!,
            if (widget.view.dateField != null)
              _DateBar(
                selected: _selectedDate,
                loggedDates: _loggedDates,
                onChanged: (d) {
                  setState(() => _selectedDate = d);
                  _reload();
                },
              ),
            // In-progress banner for batched (repeat_group) views: any
            // logged batch whose end_time is still blank gets a Stop &
            // finish button that stamps end_time on every row.
            if (widget.view.repeatGroup != null)
              FutureBuilder<List<_Item>>(
                future: _items,
                builder: (context, snap) {
                  final items = snap.data ?? const <_Item>[];
                  final active = _activeBatches(items);
                  return Column(
                    children: [
                      for (final it in active)
                        _InProgressBanner(
                          view: widget.view,
                          item: it,
                          disabled: _producing,
                          onFinish: () => _finishProduction(it),
                        ),
                    ],
                  );
                },
              ),
            Expanded(
              child: FutureBuilder<List<_Item>>(
                future: _items,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return _ErrorView(error: snap.error.toString());
                  }
                  final items = snap.data ?? [];
                  if (items.isEmpty) {
                    // Say what to do next — read-only surfaces can only
                    // browse dates, writable ones can add.
                    final dated = widget.view.dateField != null;
                    return Center(
                      child: Text(
                        _readOnly
                            ? (dated
                                  ? 'Nothing logged on this day.\n'
                                        'Browse other dates with the bar above.'
                                  : 'Nothing here yet.')
                            : 'Nothing logged ${dated ? 'on this day ' : ''}yet.'
                                  '\nTap + to add an entry.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  // Split into logged vs planned. Logged go in a compact,
                  // collapsible "completed" section at the top so the user
                  // can see what's done at a glance without it crowding out
                  // the planned items (which are the actionable ones).
                  final logged = items.where((it) => it.isLogged).toList();
                  final planned = items.where((it) => !it.isLogged).toList();
                  return ListView(
                    children: [
                      if (logged.isNotEmpty)
                        _CompletedSection(
                          view: widget.view,
                          items: logged,
                          selectedKeys: _selectedKeys,
                          selectionMode: _selectionMode,
                          expandedKeys: _expandedLoggedKeys,
                          repository: widget.repository,
                          // Read-only views: tap toggles inline expand
                          // only (no edit/delete entry points). Long-
                          // press and delete are no-ops so selection
                          // mode can never start.
                          onTap: (item) => _readOnly
                              ? _toggleExpand(item.keyString)
                              : (_selectionMode
                                  ? _toggleSelect(item)
                                  : _toggleExpand(item.keyString)),
                          onEdit: _readOnly
                              ? (_) {}
                              : _edit,
                          onMove: _readOnly
                              ? (_) {}
                              : _moveToDate,
                          onLongPress: _readOnly
                              ? (_) {}
                              : _toggleSelect,
                          onDelete: _readOnly
                              ? (_) {}
                              : _delete,
                          // "Revert to plan": only rows with a live
                          // undo-logging mapping show the button.
                          revertibleIds: _readOnly
                              ? const {}
                              : _undoMappings.keys.toSet(),
                          onRevert: (item) => _revertToPlan(item.logged!),
                          readOnly: _readOnly,
                          trailingFor: _loggedTrailing,
                        ),
                      ..._buildPlanned(planned, logged),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        floatingActionButton: (_selectionMode || _readOnly)
            ? null
            : FloatingActionButton(
                onPressed: _create,
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Planned work — ONE ROW PER EXERCISE+SLOT (UI redesign phase 2).
  // planned_slots.dart groups the per-set planned entries; each set is a
  // SetChip whose tap is exactly the old per-row log circle (_logNow on
  // that single entry) and whose long-press is the old row tap (_edit).
  // ---------------------------------------------------------------------

  /// Sets logged from the plan on the selected day, (values, group) in log
  /// order: the persisted undo-logging mappings plus this session's
  /// optimistic log-nows, kept only while their logged row is on screen
  /// (a reverted / deleted / failed row drops out by itself).
  List<(Map<String, Object?>, String?)> _doneFromPlan(List<_Item> logged) {
    final ids = <String>{
      for (final it in logged)
        for (final r in it.batchRows ?? [it.logged!])
          if (r['id'] != null) r['id'].toString(),
    };
    final day = _selectedDate;
    return [
      for (final e in {..._undoMappings, ..._optimisticDone}.entries)
        if (ids.contains(e.key) &&
            e.value.date.year == day.year &&
            e.value.date.month == day.month &&
            e.value.date.day == day.day)
          (e.value.values, e.value.templateName),
    ];
  }

  List<Widget> _buildPlanned(List<_Item> planned, List<_Item> logged) {
    if (_readOnly) return const [];
    final blocks = groupPlannedSlots<_Item>(
      pending: [
        for (final it in planned)
          PlannedSetIn(it, it.planned!.values, it.templateName),
      ],
      done: _doneFromPlan(logged),
    );
    final out = <Widget>[];
    for (final b in blocks) {
      final name = b.name;
      if (name != null) {
        final allDone = b.pendingCount == 0;
        out.add(SectionHeader(
          key: ValueKey('plan-header-$name'),
          // The auto-planner's group reads as a plain label; coach-
          // proposed / other groups keep their own name.
          label: name == WeekPlanner.templateLabel ? 'From your program' : name,
          upperCase: name == WeekPlanner.templateLabel,
          count: '${b.doneCount} / ${b.totalCount}${allDone ? ' ✓' : ''}',
          actions: [
            // One-tap "log the whole group now" — hidden once everything
            // in the group is already logged.
            if (!allDone && !_selectionMode)
              IconButton(
                icon: const Icon(Icons.done_all, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: () => _logAllTemplateGroup(name),
                tooltip: 'Log all',
              ),
            if (!allDone && !_selectionMode)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: () => _deleteTemplateGroup(name),
                tooltip: 'Remove group',
              ),
          ],
        ));
        // A finished group collapses to its header (N / N ✓) — the
        // logged section above already lists every set.
        if (allDone) continue;
      }
      for (final slot in b.slots) {
        out.add(_plannedSlotRow(slot));
      }
    }
    if (out.isNotEmpty) out.add(const SizedBox(height: 88)); // FAB clearance
    return out;
  }

  /// Key for a slot's UI state (warm-up expansion), stable across reloads.
  String _slotUiKey(PlannedSlot<_Item> slot) =>
      '${DateFormat('yyyy-MM-dd').format(_selectedDate)}|${slot.key}';

  Widget _plannedSlotRow(PlannedSlot<_Item> slot) {
    final scheme = Theme.of(context).colorScheme;
    final keys = [for (final p in slot.pending) p.ref.keyString];
    final allSelected =
        keys.isNotEmpty && keys.every(_selectedKeys.contains);
    final warmupOpen = _expandedWarmups.contains(_slotUiKey(slot));
    final showChips = !slot.warmup || warmupOpen || _selectionMode;
    final status = slot.isDone
        ? ItemStatus.done
        : (slot.isPartial
            ? ItemStatus.partial
            : (slot.warmup ? ItemStatus.muted : ItemStatus.pending));
    final name = slot.warmup
        ? 'Warm-up'
        : (slot.exercise ?? _titleFor(widget.view, slot.pending.isNotEmpty
            ? slot.pending.first.values
            : slot.done.first));
    final meta = slot.exercise == null && slot.pending.isNotEmpty
        ? _subtitleFor(widget.view, slot.pending.first.values)
        : slot.meta;
    Widget row = ExerciseRow(
      key: ValueKey('plan-slot-${slot.key}'),
      name: name,
      meta: meta,
      status: status,
      muted: slot.warmup,
      leading: _selectionMode && keys.isNotEmpty
          ? Icon(
              allSelected ? Icons.check_box : Icons.check_box_outline_blank,
              size: 20,
              color: allSelected ? scheme.secondary : scheme.outlineVariant,
            )
          : null,
      selected: allSelected,
      highlighted: keys.any(_highlightKeys.contains),
      chips: !showChips
          ? const []
          : [
              for (final p in slot.pending)
                SetChip(
                  key: ValueKey('chip-${p.ref.keyString}'),
                  label: slot.chipLabel(p),
                  muted: slot.warmup,
                  selected: _selectedKeys.contains(p.ref.keyString),
                  // Tap = the old row's log circle; long-press = the old
                  // row tap (edit). In selection mode both toggle.
                  onTap: _selectionMode
                      ? () => _toggleSelect(p.ref)
                      : () => _logNow(p.ref),
                  onLongPress: _selectionMode
                      ? () => _toggleSelect(p.ref)
                      : () => _edit(p.ref),
                ),
            ],
      trailing: keys.isEmpty || _selectionMode
          ? null
          : (slot.warmup
              ? Icon(
                  warmupOpen ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                )
              : IconButton(
                  icon: const Icon(Icons.more_vert, size: 20),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Options',
                  onPressed: () => _slotMenu(slot),
                )),
      onTap: keys.isEmpty
          ? null
          : (_selectionMode
              ? () => _toggleSelectAll(keys)
              : (slot.warmup
                  ? () => setState(() {
                        final k = _slotUiKey(slot);
                        if (!_expandedWarmups.add(k)) {
                          _expandedWarmups.remove(k);
                        }
                      })
                  : () => _slotMenu(slot))),
      onLongPress: keys.isEmpty ? null : () => _slotMenu(slot),
    );
    // Swipe-to-delete removes the row's remaining planned sets (confirm
    // first). Off in selection mode, like the logged tiles.
    if (keys.isEmpty || _selectionMode) return row;
    return Dismissible(
      key: ValueKey('dismiss-${slot.key}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        await _removeSlot(slot);
        return false;
      },
      child: row,
    );
  }

  /// Row menu (long-press / ⋮ / tap): log, edit, history, select, remove.
  Future<void> _slotMenu(PlannedSlot<_Item> slot) async {
    if (slot.pending.isEmpty) return;
    final first = slot.pending.first.ref;
    final n = slot.pending.length;
    ({Dimension dim, String value})? history;
    for (final d in widget.view.dimensions) {
      if (!(d.input?.history ?? false)) continue;
      final v = first.values[d.name]?.toString().trim();
      if (v == null || v.isEmpty) continue;
      history = (dim: d, value: v);
      break;
    }
    await showDetailSheet(
      context: context,
      title: slot.warmup
          ? '${slot.exercise ?? ''} warm-up'.trim()
          : (slot.exercise ?? _titleFor(widget.view, first.values)),
      subtitle: slot.exercise == null
          ? _subtitleFor(widget.view, first.values)
          : (n == slot.total ? slot.meta : '${slot.meta} · $n left'),
      actions: [
        DetailAction(
          icon: Icons.check_circle_outline,
          label: 'Log next set',
          onTap: () => _logNow(first),
        ),
        if (n > 1)
          DetailAction(
            icon: Icons.done_all,
            label: 'Log all $n sets',
            onTap: () => _logSlot(slot),
          ),
        DetailAction(
          icon: Icons.edit_outlined,
          label: 'Edit next set…',
          onTap: () => _edit(first),
        ),
        if (history != null)
          DetailAction(
            icon: Icons.history,
            label: 'History',
            onTap: () => showHistorySheet(
              context: context,
              view: widget.view,
              dim: history!.dim,
              value: history.value,
              repository: widget.repository,
            ),
          ),
        DetailAction(
          icon: Icons.check_box_outlined,
          label: 'Select',
          onTap: () => setState(() => _selectedKeys.addAll(
                [for (final p in slot.pending) p.ref.keyString],
              )),
        ),
        DetailAction(
          icon: Icons.delete_outline,
          label: n == 1 ? 'Remove planned set' : 'Remove $n planned sets',
          destructive: true,
          onTap: () => _removeSlot(slot),
        ),
      ],
    );
  }

  /// Logs every remaining set of a slot through the same per-entry path.
  Future<void> _logSlot(PlannedSlot<_Item> slot) async {
    for (final p in [...slot.pending]) {
      if (_logNowInFlight.contains(p.ref.planned!.localId)) continue;
      await _logNow(p.ref);
    }
  }

  /// Confirm, then drop a slot's remaining planned sets.
  Future<void> _removeSlot(PlannedSlot<_Item> slot) async {
    if (slot.pending.length == 1) {
      await _delete(slot.pending.single.ref);
      return;
    }
    final n = slot.pending.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $n planned sets?'),
        content: Text(
            '${slot.warmup ? 'Warm-up' : (slot.exercise ?? '')} · ${slot.meta}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _deleteOptimistic({for (final p in slot.pending) p.ref.keyString});
  }

  void _toggleSelectAll(List<String> keys) {
    setState(() {
      if (keys.every(_selectedKeys.contains)) {
        _selectedKeys.removeAll(keys);
      } else {
        _selectedKeys.addAll(keys);
      }
    });
  }

  /// Trailing extras on a compact logged row: the attached clip's inline
  /// thumbnail (tap plays) and the QuickBooks push badge. Both lived on
  /// the old per-row tile, which after the logged/planned split only
  /// ever rendered PLANNED rows (no id, no clip) — so they never showed;
  /// the logged row is where they belong.
  Widget? _loggedTrailing(_Item item) {
    if (item.isBatch || item.logged == null) return null;
    final values = item.logged!;
    Widget? video;
    for (final d in widget.view.dimensions) {
      if (d.input?.widget != WidgetType.video) continue;
      final url = values[d.name]?.toString().trim();
      if (url == null || url.isEmpty) continue;
      final mid = values[mediaIdFieldFor(d.name)]?.toString().trim();
      video = Padding(
        padding: const EdgeInsets.only(left: 6),
        child: VideoThumb(
          url: url,
          mediaId: (mid == null || mid.isEmpty) ? null : mid,
          size: 28,
        ),
      );
      break;
    }
    Widget? badge;
    final id = values['id']?.toString();
    final qbo = _qboEnabled && id != null ? _qboStatus[id] : null;
    if (qbo != null) {
      final scheme = Theme.of(context).colorScheme;
      final (IconData icon, Color color, String tip, bool retry) =
          switch (qbo.status) {
        QboPushStatus.pushed =>
          (Icons.cloud_done, Colors.green, 'Pushed to QuickBooks', false),
        QboPushStatus.pushing =>
          (Icons.cloud_upload, scheme.outline, 'Pushing…', false),
        QboPushStatus.failed => (
            Icons.error_outline,
            scheme.error,
            qbo.error ?? 'Push failed — tap to retry',
            true,
          ),
        QboPushStatus.pending =>
          (Icons.cloud_queue, scheme.outline, 'Not pushed yet — tap to push', true),
      };
      badge = Tooltip(
        message: tip,
        child: InkWell(
          onTap: retry ? () => _retryQbo(values) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      );
    }
    if (video == null && badge == null) return null;
    return Row(mainAxisSize: MainAxisSize.min, children: [?video, ?badge]);
  }

  AppBar _buildNormalAppBar() {
    return AppBar(
      title: Text(viewLabel(widget.view.name)),
      // Kiosk mode: timeline is the root screen, no back button.
      automaticallyImplyLeading: !widget.kioskMode,
      actions: [
        // Kiosk mode suppresses the chat affordance even if a model is
        // configured — non-technical employees shouldn't see it.
        if (!widget.kioskMode && widget.chatModel != null)
          IconButton(
            icon: const Icon(Icons.smart_toy_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    model: widget.chatModel!,
                    github: widget.github,
                    view: widget.view,
                    repository: widget.repository,
                    analytics: widget.analytics,
                    selectedDate: _selectedDate,
                  ),
                ),
              );
              // The chat's add_planned_entry tool mutates PlanStore;
              // refresh the timeline on return so any new planned
              // entries show up.
              if (mounted) _reload();
            },
            tooltip: 'Chat about this view',
          ),
        // Rest timer — a between-sets affordance on the strength log. A
        // launch point that doesn't touch the entry form: a small sheet
        // with 3/5-min presets that notifies on completion.
        if (!_readOnly && widget.view.name == 'strength')
          IconButton(
            icon: const Icon(Icons.timer_outlined),
            onPressed: () => showRestTimer(context),
            tooltip: 'Rest timer',
          ),
        // "Update": push not-yet-pushed transactions to QuickBooks as
        // inventory changes. Only shown when this view is QBO-mapped.
        if (_qboEnabled)
          IconButton(
            icon: _qboPushing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload_outlined),
            onPressed: _qboPushing ? null : _pushToQbo,
            tooltip: 'Update QuickBooks',
          ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () => _reload(fresh: true),
          tooltip: 'Refresh',
        ),
      ],
    );
  }

  AppBar _buildSelectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
        tooltip: 'Clear selection',
      ),
      title: Text('${_selectedKeys.length} selected'),
      actions: [
        IconButton(
          icon: _bulkDeleting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                )
              : const Icon(Icons.delete),
          onPressed: _bulkDeleting ? null : _bulkDelete,
          tooltip: 'Delete selected',
        ),
      ],
    );
  }

  void _toggleSelect(_Item item) {
    setState(() {
      if (_selectedKeys.contains(item.keyString)) {
        _selectedKeys.remove(item.keyString);
      } else {
        _selectedKeys.add(item.keyString);
      }
    });
  }

  void _clearSelection() {
    setState(_selectedKeys.clear);
  }

  /// Resolves the currently-selected keys back to live `_Item`s (the future may
  /// have refreshed since selection started — any vanished item is silently
  /// skipped). Runs PlanStore.remove for planned, repo.delete for logged.
  Future<void> _bulkDelete() async {
    final items = await _items;
    final selected =
        items.where((it) => _selectedKeys.contains(it.keyString)).toList();
    if (selected.isEmpty) {
      _clearSelection();
      return;
    }
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${selected.length} entries?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _bulkDeleting = true);
    try {
      await _deleteOptimistic(
        selected.map((it) => it.keyString).toSet(),
      );
    } finally {
      if (mounted) setState(() => _bulkDeleting = false);
    }
  }

  Future<void> _create() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FormScreen(
          view: widget.view,
          repository: widget.repository,
        ),
      ),
    );
    if (saved == true) _reload(fresh: true);
  }

  /// Move a logged entry (single row or whole batch) to a different
  /// date. Opens a date picker; on confirm, updates the `date_field`
  /// on every row of the item and pushes the change back through
  /// `repository.update`. Reloads the timeline so the moved entry
  /// disappears (or shifts) without a manual refresh.
  Future<void> _moveToDate(_Item item) async {
    if (item.isPlanned) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Log the entry first, then move it.')),
      );
      return;
    }
    final dateField = widget.view.dateField;
    if (dateField == null) return;
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (_) => _CalendarPickerDialog(
        initial: _selectedDate,
        loggedDates: _loggedDates ?? const {},
      ),
    );
    if (picked == null) return;
    final newDate = DateTime(picked.year, picked.month, picked.day);
    final rows = item.batchRows ?? [item.logged!];
    try {
      for (final row in rows) {
        final updated = Map<String, Object?>.from(row);
        updated[dateField] = newDate;
        await widget.repository.update(widget.view, updated);
      }
      if (!mounted) return;
      setState(() => _expandedLoggedKeys.remove(item.keyString));
      _reload(fresh: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Move failed: $e')),
      );
    }
  }

  Future<void> _edit(_Item item) async {
    if (item.isPlanned) {
      // Save on a planned entry = log. Form is pre-filled with the planned
      // values; the user tweaks them and tapping save commits to the sheet
      // and removes the planned row (same path as the Play button).
      final result = await Navigator.of(context).push<Map<String, Object?>>(
        MaterialPageRoute(
          builder: (_) => FormScreen(
            view: widget.view,
            repository: widget.repository,
            existing: Map<String, Object?>.from(item.planned!.values),
            planMode: true,
          ),
        ),
      );
      if (result == null) return;
      await _logNow(item, overrideValues: result);
    } else {
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => FormScreen(
            view: widget.view,
            repository: widget.repository,
            // Batch tap: hand the whole row list to the form so it
            // re-opens with N populated ingredient blocks. Single-row
            // edit otherwise.
            existing: item.isBatch ? null : item.logged,
            batch: item.isBatch ? item.batchRows : null,
          ),
        ),
      );
      if (saved == true) _reload(fresh: true);
    }
  }

  Future<void> _delete(_Item item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(item.isPlanned
            ? 'Remove this planned entry?'
            : 'Delete this entry?'),
        content: Text(_titleFor(widget.view, item.values)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(item.isPlanned ? 'Remove' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _deleteOptimistic({item.keyString});
  }

  /// Optimistic delete: drops the matching items from the in-memory list
  /// immediately (no spinner / no re-fetch from Sheets), then runs the actual
  /// backend deletes in the background. On error, snackbars and re-syncs from
  /// the source of truth.
  Future<void> _deleteOptimistic(Set<String> keys) async {
    final current = await _items;
    final toDelete =
        current.where((it) => keys.contains(it.keyString)).toList();
    if (toDelete.isEmpty) return;
    final remaining =
        current.where((it) => !keys.contains(it.keyString)).toList();
    setState(() {
      _items = Future.value(remaining);
      _selectedKeys.removeAll(keys);
    });
    try {
      for (final item in toDelete) {
        if (item.isPlanned) {
          await PlanStore.remove(widget.view, item.planned!.localId);
        } else if (item.isBatch) {
          // Batch delete: drop every row sharing the group_key. One
          // failure mid-loop leaves a partial batch; the catch below
          // re-syncs from Sheets so the UI matches truth.
          for (final r in item.batchRows!) {
            await widget.repository.delete(widget.view, r);
            await _pruneUndoMapping(r);
          }
        } else {
          await widget.repository.delete(widget.view, item.logged!);
          await _pruneUndoMapping(item.logged!);
        }
      }
      // The optimistic list is correct on screen, but the row cache still
      // holds the deleted rows (and remaining rows' __row indices have
      // shifted in the sheet). Silently re-sync from truth in the
      // background — no spinner, since the UI already shows `remaining`.
      unawaited(_revalidate(_dateKey()));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e — refreshing')),
      );
      _reload(fresh: true);
    }
  }

  /// A normally-deleted row can never be reverted — drop its undo-logging
  /// mapping (no-op when it has none / no id).
  Future<void> _pruneUndoMapping(Record row) async {
    final rowId = row['id']?.toString();
    if (rowId == null || !_undoMappings.containsKey(rowId)) return;
    await PlanStore.removeUndo(widget.view, rowId);
    _undoMappings.remove(rowId);
  }

  Future<void> _deleteTemplateGroup(String templateName) async {
    final current = await _items;
    final groupKeys = current
        .where((it) =>
            it.isPlanned && it.planned!.templateName == templateName)
        .map((it) => it.keyString)
        .toSet();
    if (groupKeys.isEmpty) return;
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove $templateName?'),
        content: Text('Drops ${groupKeys.length} planned entries.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _deleteOptimistic(groupKeys);
  }

  /// One-tap "Log all" for a template group: promotes every remaining
  /// planned entry in the group through the same `_logNow` path as the
  /// per-row circle — each stamped with the moment it's written, run
  /// sequentially so the existing in-flight guards hold. No confirm;
  /// a snackbar reports the count.
  Future<void> _logAllTemplateGroup(String templateName) async {
    final current = await _items;
    final group = current
        .where((it) =>
            it.isPlanned && it.planned!.templateName == templateName)
        .toList();
    if (group.isEmpty) return;
    for (final item in group) {
      // Skip rows already mid-flight from a per-row tap. notify: true so
      // each logged row flashes (the fade highlight accumulates across the
      // batch) — no snackbar.
      if (_logNowInFlight.contains(item.planned!.localId)) continue;
      await _logNow(item, notify: true);
    }
  }

  /// Promotes a planned entry into a sheet row. The entry's start_time is
  /// stamped with now (unless the user already set one via edit), derives
  /// are applied, then it's written to the sheet and removed from local plan.
  ///
  /// Optimistic: the row stays exactly where it is in the list (under its
  /// template header) and just visually flips to "done". The Sheets `create`
  /// happens in the background; on failure we surface a snackbar and
  /// re-sync from the source of truth.
  Future<void> _logNow(
    _Item item, {
    Map<String, Object?>? overrideValues,
    bool notify = true,
  }) async {
    if (!item.isPlanned) return;
    final planned = item.planned!;
    if (!_logNowInFlight.add(planned.localId)) return;
    // `overrideValues` is the post-edit values map (from the Save-on-planned
    // path). When present, it takes precedence over `planned.values` so any
    // tweaks the user made in the form survive into the logged row.
    final values =
        Map<String, Object?>.from(overrideValues ?? planned.values);
    final plannable = widget.view.plannable;
    if (plannable != null) {
      final existing = values[plannable.logField];
      if (existing == null || (existing is String && existing.isEmpty)) {
        values[plannable.logField] = logNowValue(plannable.logFormat);
      }
    }
    final dateDim = widget.view.dateField;
    // Only backfill from the planning date if the user didn't set their own
    // date in the edit form. Honoring a user-entered date matters for the
    // "logging yesterday's set today" case.
    if (dateDim != null && values[dateDim] == null) {
      values[dateDim] = planned.date;
    }
    applyDerives(widget.view, values);
    // Pre-assign id so we can resolve the row for future edits/deletes without
    // re-fetching from Sheets (the create call doesn't return the row index).
    if (widget.view.dimensionByName('id') != null && values['id'] == null) {
      values['id'] = const Uuid().v4();
    }

    // Optimistic: remove the planned row from where it was and append the
    // freshly-logged row at the END of the merged list (bottom of the
    // logged section). Matches reload: list() sorts a date's logged rows
    // ascending by the plannable log_field (start_time), so a row with
    // start_time = now lands at the bottom of that day's logged rows.
    //
    // Drop the template association (use _Item.logged not
    // loggedFromPlanned) so the just-logged row doesn't drag its template
    // header into the logged section. The template's progress counter
    // ("2 / 5 done") rebuilds from the remaining planned rows on the next
    // _reload — same-session it temporarily under-counts, which is
    // acceptable for an optimistic UI.
    //
    // The +1 row-index shift on existing logged rows mirrors the server-
    // side insert at sheet row 2 that create() is about to do.
    values[rowIndexKey] = 0;
    final current = await _items;
    final idx = current.indexWhere((it) => it.keyString == planned.localId);
    if (idx >= 0) {
      SheetsRepository.shiftRowIndexes(
        current.where((it) => it.isLogged).map((it) => it.logged!),
        by: 1,
      );
      final loggedItem = _Item.logged(values);
      final optimisticId = values['id']?.toString();
      if (optimisticId != null) _optimisticDone[optimisticId] = planned;
      final updated = List<_Item>.from(current);
      updated.removeAt(idx);
      updated.add(loggedItem);
      setState(() {
        _items = Future.value(updated);
      });
      // Instant confirmation: flash the row (replaces the "Logged X"
      // snackbar — no dismissal, no network wait).
      if (notify) _flash([loggedItem.keyString]);
    }

    final rowId = values['id']?.toString();
    try {
      try {
        await widget.repository.create(widget.view, values);
        await PlanStore.remove(widget.view, planned.localId);
        // Undo-logging: remember which planned entry this row came from
        // so the expanded panel's "Revert to plan" can delete the row and
        // restore the entry. Needs a row id (all ledger views have one;
        // views without simply can't revert).
        if (rowId != null) {
          await PlanStore.putUndo(widget.view, rowId, planned);
          _undoMappings[rowId] = planned;
        }
        // UI shows the optimistic row; re-sync the cache (new row + shifted
        // __row indices) from truth in the background, no spinner.
        unawaited(_revalidate(_dateKey()));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Log failed: $e — refreshing')),
        );
        _reload(fresh: true);
        return;
      }
    } finally {
      _logNowInFlight.remove(planned.localId);
    }

    // Fire the post-log LLM hook (if configured) in the background.
    // Response lands in llmCache and the tile rebuilds when ready.
    final hook = widget.view.postLog;
    final llm = widget.llm;
    final cache = widget.llmCache;
    if (hook != null && llm != null && cache != null && rowId != null) {
      _runPostLogHook(hook, values, rowId, llm, cache);
    }
  }

  /// Undo-logging: deletes the logged [row] and restores the planned entry
  /// it was promoted from (see [PlanStore.undoMappings]), then drops the
  /// mapping. Shared by the Log-now snackbar's UNDO action and the
  /// expanded panel's "Revert to plan" button — both single-tap.
  Future<void> _revertToPlan(Record row) async {
    final rowId = row['id']?.toString();
    if (rowId == null) return;
    final entry =
        _undoMappings[rowId] ?? (await PlanStore.undoMappings(widget.view))[rowId];
    if (entry == null) return;
    try {
      // Delete by row values — the engine ledger resolves rows by id, so
      // the optimistic __row=0 on a just-created row is irrelevant here.
      await widget.repository.delete(widget.view, row);
      await PlanStore.addAll(widget.view, [entry]);
      await PlanStore.removeUndo(widget.view, rowId);
      _undoMappings.remove(rowId);
      if (!mounted) return;
      setState(() => _expandedLoggedKeys.clear());
      _reload(fresh: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Revert failed: $e — refreshing')),
      );
      _reload(fresh: true);
    }
  }

  /// Renders the post-log Jinja prompt with row + historical context, calls
  /// the model, stores the response in the cache. Fire-and-forget — the
  /// timeline rebuilds via the cache listener when the response arrives.
  ///
  /// Jinja context exposed to the prompt:
  ///   - `row`            the just-logged record (Map)
  ///   - `view.name`, `view.description`
  ///   - `today`          rows logged today (this view) — list of Maps
  ///   - `last_7_days`    rows in last 7 calendar days
  ///   - `last_30_days`   rows in last 30 calendar days
  ///   - `recent`         most-recent 50 rows regardless of date
  ///   - `all`            every row for this view
  ///   - `last_n_days(n)` callable — rows in last n calendar days
  ///   - `last_n_weeks(n)` callable — rows in last n*7 calendar days
  ///   - `last_n_months(n)` callable — rows in last n*30 calendar days
  ///   - `last_workouts_for(field, value, n)` callable — last n distinct
  ///     date-groups of rows where `field == value`, newest-first. Each
  ///     group is a List<Map> of all rows on that date. Use this for
  ///     "show me the previous 3 bench-press sessions" regardless of how
  ///     long ago they were (calendar windows can miss the last actual
  ///     workout). Pass strings: `last_workouts_for('exercise', row['exercise'], 3)`.
  ///   - `today_for(field, value)` callable — rows logged today where
  ///     `field == value`. Use for "what have I already done in this
  ///     workout for this exercise."
  void _runPostLogHook(
    PostLogHook hook,
    Record row,
    String rowId,
    LlmClient llm,
    LlmResponseCache cache,
  ) {
    if (!llm.has(hook.model)) return;
    cache.markPending(rowId);
    () async {
      try {
        final dateField = widget.view.dateField;

        // Pull all history for this view (best-effort: empty if it fails so
        // the prompt still renders rather than the hook silently dropping).
        List<Record> allRows = [];
        try {
          allRows = await widget.repository.list(widget.view);
        } catch (_) {
          allRows = [];
        }

        // Sort newest-first by dateField (rows without a parseable date sink
        // to the bottom). Stable enough for "recent" / iteration semantics.
        DateTime? rowDay(Record r) {
          if (dateField == null) return null;
          final v = r[dateField];
          if (v is DateTime) return DateTime(v.year, v.month, v.day);
          if (v is String) {
            final d = DateTime.tryParse(v);
            if (d != null) return DateTime(d.year, d.month, d.day);
          }
          return null;
        }

        allRows.sort((a, b) {
          final da = rowDay(a);
          final db = rowDay(b);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da);
        });

        final now = DateTime.now();
        final todayDay = DateTime(now.year, now.month, now.day);

        // "Last N days" = the trailing N calendar days *including today*.
        // n=1 → today only; n=7 → today + 6 prior days.
        List<Record> lastNDays(int n) {
          if (dateField == null || n <= 0) return const [];
          final cutoff = todayDay.subtract(Duration(days: n - 1));
          return allRows.where((r) {
            final d = rowDay(r);
            return d != null && !d.isBefore(cutoff);
          }).toList();
        }

        final todayRows = lastNDays(1);
        final last7 = lastNDays(7);
        final last30 = lastNDays(30);
        final recent = allRows.take(50).toList();

        // last_workouts_for(field, value, n):
        // Group allRows by date (already sorted newest-first), filter to
        // rows where row[field] equals value (stringified compare to
        // tolerate num/string mismatches), take the first n date groups.
        // Each group is a List<Record> with all sets from that day.
        List<List<Record>> lastWorkoutsFor(
          String field,
          Object? value,
          int n,
        ) {
          if (value == null || n <= 0) return const [];
          final target = value.toString();
          final groups = <String, List<Record>>{};
          final orderedKeys = <String>[];
          for (final r in allRows) {
            if (r[field]?.toString() != target) continue;
            final d = rowDay(r);
            if (d == null) continue;
            final key = '${d.year}-'
                '${d.month.toString().padLeft(2, '0')}-'
                '${d.day.toString().padLeft(2, '0')}';
            if (!groups.containsKey(key)) {
              groups[key] = [];
              orderedKeys.add(key);
            }
            groups[key]!.add(r);
            if (orderedKeys.length > n &&
                orderedKeys.indexOf(key) >= n) {
              // we've already collected n distinct days and this row is
              // outside that window — stop scanning further.
              break;
            }
          }
          return orderedKeys.take(n).map((k) => groups[k]!).toList();
        }

        // today_for(field, value): rows from today where field == value.
        List<Record> todayFor(String field, Object? value) {
          if (value == null) return const [];
          final target = value.toString();
          return todayRows
              .where((r) => r[field]?.toString() == target)
              .toList();
        }

        final env = Environment(
          globals: {
            'last_n_days': ([Object? n]) => lastNDays(_coerceInt(n, 7)),
            'last_n_weeks': ([Object? n]) => lastNDays(_coerceInt(n, 1) * 7),
            'last_n_months': ([Object? n]) =>
                lastNDays(_coerceInt(n, 1) * 30),
            'last_workouts_for': (
              [Object? field, Object? value, Object? n]
            ) => lastWorkoutsFor(
              field?.toString() ?? '',
              value,
              _coerceInt(n, 3),
            ),
            'today_for': ([Object? field, Object? value]) =>
                todayFor(field?.toString() ?? '', value),
          },
        );
        final tpl = env.fromString(hook.prompt);
        final rendered = tpl.render({
          'row': row,
          'view': {
            'name': widget.view.name,
            'description': widget.view.description,
          },
          'today': todayRows,
          'last_7_days': last7,
          'last_30_days': last30,
          'recent': recent,
          'all': allRows,
        });
        final response = await llm.complete(hook.model, rendered);
        cache.put(rowId, response);
      } catch (e) {
        cache.putError(rowId, e.toString());
      }
    }();
  }
}

/// Coerces a value handed to a Jinja callable (anything — int, num, String,
/// null) into a Dart int. Falls back to [fallback] when missing or
/// uncoercible. Used so prompts like `last_n_days(7)` and `last_n_days("7")`
/// both work.
int _coerceInt(Object? v, int fallback) {
  if (v == null) return fallback;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

String _titleFor(ViewSchema view, Map<String, Object?> record) =>
    ListDisplayRender.title(view, record);

String? _subtitleFor(ViewSchema view, Map<String, Object?> record) =>
    ListDisplayRender.subtitle(view, record);

/// Date-toggle bar pinned just below the AppBar — left/right chevrons
/// for day-stepping plus a center button that opens [_CalendarPickerDialog]
/// for jump-to-date. Today is rendered as the label "Today" so the
/// default state reads clearly.
class _DateBar extends StatelessWidget {
  final DateTime selected;
  final ValueChanged<DateTime> onChanged;

  /// Set of dates with logged entries. Threaded through to the calendar
  /// dialog so it can mark days. Null while loading.
  final Set<DateTime>? loggedDates;

  const _DateBar({
    required this.selected,
    required this.onChanged,
    this.loggedDates,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final formatter = DateFormat('EEE, MMM d');
    final isToday = _isSameDay(selected, _now());
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 24),
            color: scheme.onSurface,
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                onChanged(selected.subtract(const Duration(days: 1))),
          ),
          Expanded(
            child: TextButton(
              onPressed: () async {
                final picked = await showDialog<DateTime>(
                  context: context,
                  builder: (_) => _CalendarPickerDialog(
                    initial: selected,
                    loggedDates: loggedDates ?? const {},
                  ),
                );
                if (picked != null) onChanged(picked);
              },
              style: TextButton.styleFrom(foregroundColor: scheme.onSurface),
              child: Text(
                isToday ? 'Today' : formatter.format(selected),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 24),
            color: scheme.onSurface,
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                onChanged(selected.add(const Duration(days: 1))),
          ),
        ],
      ),
    );
  }

  static DateTime _now() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Month-view calendar dialog. Days that have at least one logged entry
/// for the current view get a small primary-color dot. Today is outlined.
/// Returns the picked date via Navigator.pop, or null on cancel.
class _CalendarPickerDialog extends StatefulWidget {
  final DateTime initial;
  final Set<DateTime> loggedDates;

  const _CalendarPickerDialog({
    required this.initial,
    required this.loggedDates,
  });

  @override
  State<_CalendarPickerDialog> createState() => _CalendarPickerDialogState();
}

class _CalendarPickerDialogState extends State<_CalendarPickerDialog> {
  late DateTime _focused;
  late DateTime _selected;

  @override
  void initState() {
    super.initState();
    _focused = widget.initial;
    _selected = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pick a date',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (widget.loggedDates.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: scheme.onSurface.withValues(alpha: 0.18),
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '·',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '= logged',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            TableCalendar<void>(
              firstDay: DateTime(2000),
              lastDay: DateTime(DateTime.now().year + 5, 12, 31),
              focusedDay: _focused,
              currentDay: _today(),
              selectedDayPredicate: (d) => _isSameDay(d, _selected),
              onDaySelected: (sel, focus) {
                setState(() {
                  _selected = sel;
                  _focused = focus;
                });
              },
              onPageChanged: (focus) => _focused = focus,
              calendarStyle: const CalendarStyle(
                outsideDaysVisible: false,
              ),
              headerStyle: const HeaderStyle(
                formatButtonVisible: false,
                titleCentered: true,
              ),
              // Custom cell rendering so the "has data" indicator is a
              // filled gray circle *behind the number*, not a tiny dot
              // below — and so today's day doesn't end up with
              // white-on-white text from the default theme.
              calendarBuilders: CalendarBuilders<void>(
                defaultBuilder: (ctx, day, focusedDay) =>
                    _dayCell(ctx, day, isToday: false, isSelected: false),
                todayBuilder: (ctx, day, focusedDay) =>
                    _dayCell(ctx, day, isToday: true, isSelected: false),
                selectedBuilder: (ctx, day, focusedDay) =>
                    _dayCell(ctx, day, isToday: false, isSelected: true),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_selected),
                    child: const Text('Select'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One day cell. State-aware fill rules:
  ///   - selected: primary fill, onPrimary text
  ///   - today: primary outline ring, normal text (so the previously-
  ///     selected day still shows alongside today)
  ///   - has logged data: filled gray circle behind the number
  ///   - otherwise: bare number
  /// The selected ring "wins" over today and logged because the user
  /// just picked it and that's the most important visual signal.
  Widget _dayCell(
    BuildContext context,
    DateTime day, {
    required bool isToday,
    required bool isSelected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final hasData = widget.loggedDates.any((d) => _isSameDay(d, day));
    Color? fill;
    Color textColor = scheme.onSurface;
    BoxBorder? border;
    if (isSelected) {
      fill = scheme.primary;
      textColor = scheme.onPrimary;
    } else if (hasData) {
      // Subtle gray puck so "I trained that day" pops without competing
      // with the primary-colored selected state.
      fill = scheme.onSurface.withValues(alpha: 0.18);
    }
    if (isToday) {
      border = Border.all(color: scheme.primary, width: 1.5);
    }
    return Container(
      margin: const EdgeInsets.all(4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: border,
      ),
      child: Text(
        '${day.day}',
        style: TextStyle(
          color: textColor,
          fontWeight: isToday || isSelected
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    );
  }

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _ErrorView extends StatelessWidget {
  final String error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Text('Error: $error', textAlign: TextAlign.center),
      ),
    );
  }
}

/// "Logged" section at the top of the timeline. Compact one-line tiles
/// per row sorted ascending by the plannable log field (start_time).
/// First tap on a tile EXPANDS it inline — showing every dim's value
/// plus an Edit button — rather than jumping straight to the edit form.
/// Tap again to collapse.
class _CompletedSection extends StatelessWidget {
  final ViewSchema view;
  final List<_Item> items;
  final Set<String> selectedKeys;
  final Set<String> expandedKeys;
  final bool selectionMode;
  final WarehouseConnector repository;
  final void Function(_Item) onTap;
  final void Function(_Item) onEdit;
  final void Function(_Item) onMove;
  final void Function(_Item) onLongPress;
  final void Function(_Item) onDelete;

  /// Row ids with a live undo-logging mapping — their expanded panel gets
  /// a "Revert to plan" button wired to [onRevert].
  final Set<String> revertibleIds;
  final void Function(_Item) onRevert;

  /// When true, swipe-to-delete and the Edit/Move buttons are hidden.
  final bool readOnly;

  /// Per-row trailing extras (clip thumbnail, QBO badge); null = none.
  final Widget? Function(_Item)? trailingFor;

  const _CompletedSection({
    required this.view,
    required this.items,
    required this.selectedKeys,
    required this.expandedKeys,
    required this.selectionMode,
    required this.repository,
    required this.onTap,
    required this.onEdit,
    required this.onMove,
    required this.onLongPress,
    required this.onDelete,
    this.revertibleIds = const {},
    required this.onRevert,
    this.readOnly = false,
    this.trailingFor,
  });

  /// Keys of each exercise's best set in this day's logged rows — the
  /// history panel's "day top" (top_metric score, e.g. e1rm), grouped by
  /// the view's history dimension. Empty when the view declares neither.
  /// Keys of the logged warm-up sets (working_sets.dart's shared rule:
  /// set_type warmup, or an untagged ramp set). Strength-shaped views
  /// only (an `exercise` dim) — elsewhere nothing is a warm-up.
  Set<String> _warmupKeys() {
    if (view.dimensionByName('exercise') == null) return const {};
    final rows = [for (final it in items) it.isBatch ? null : it.logged];
    return {for (final i in warmupIndices(rows)) items[i].keyString};
  }

  Set<String> _bestKeys(Set<String> warmups) {
    if (view.topMetric == null) return const {};
    String? groupField;
    for (final d in view.dimensions) {
      if (d.input?.history ?? false) {
        groupField = d.name;
        break;
      }
    }
    if (groupField == null) return const {};
    final groups = <String?>[];
    final scores = <double?>[];
    for (final it in items) {
      final row = it.isBatch ? null : it.logged;
      final g = row?[groupField]?.toString().trim().toLowerCase();
      groups.add(g == null || g.isEmpty ? null : g);
      // Warm-ups never compete for the day's best set.
      scores.add(row == null || warmups.contains(it.keyString)
          ? null
          : scoreTopMetric(view, row));
    }
    return {
      for (final i in bestIndicesPerGroup(groups, scores)) items[i].keyString,
    };
  }

  @override
  Widget build(BuildContext context) {
    final warmups = _warmupKeys();
    final best = _bestKeys(warmups);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(label: 'Logged', count: '${items.length}'),
        for (final item in items)
          _CompactLoggedTile(
            view: view,
            item: item,
            selected: selectedKeys.contains(item.keyString),
            expanded: expandedKeys.contains(item.keyString),
            isBest: best.contains(item.keyString),
            isWarmup: warmups.contains(item.keyString),
            readOnly: readOnly,
            trailing: trailingFor?.call(item),
            onTap: () => onTap(item),
            onEdit: () => onEdit(item),
            onMove: () => onMove(item),
            onLongPress: () => onLongPress(item),
            onDelete: () => onDelete(item),
            // Batches can't revert (they were never a single planned
            // entry); singles only when a mapping exists for their id.
            onRevert: !readOnly &&
                    !item.isBatch &&
                    item.logged != null &&
                    revertibleIds.contains(item.values['id']?.toString())
                ? () => onRevert(item)
                : null,
          ),
        const Divider(height: 1),
      ],
    );
  }
}

/// Single-line compact tile for an already-logged row. Shows time on the
/// left, title + subtitle inline. Tap toggles inline expansion — the
/// expanded view dumps every non-empty field value + an Edit button.
/// Swipe-to-delete still works in either state.
class _CompactLoggedTile extends StatelessWidget {
  final ViewSchema view;
  final _Item item;
  final bool selected;
  final bool expanded;

  /// The day's best set for its exercise — tinted + bold like the
  /// history panel's day-top row.
  final bool isBest;

  /// A warm-up set (shared working_sets rule) — rendered muted with a
  /// "warm-up" tag so it reads differently from working sets.
  final bool isWarmup;

  /// When true, swipe-to-delete is hidden and the Edit/Move panel is
  /// suppressed. Long-press still does nothing because onLongPress is a
  /// no-op at that point.
  final bool readOnly;

  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onMove;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  /// Non-null only when this row has a live undo-logging mapping — shows
  /// "Revert to plan" in the expanded panel.
  final VoidCallback? onRevert;

  /// Optional extras before the expand chevron (clip thumb, QBO badge).
  final Widget? trailing;

  const _CompactLoggedTile({
    required this.view,
    required this.item,
    required this.selected,
    required this.expanded,
    this.isBest = false,
    this.isWarmup = false,
    required this.onTap,
    required this.onEdit,
    required this.onMove,
    required this.onLongPress,
    required this.onDelete,
    this.onRevert,
    this.readOnly = false,
    this.trailing,
  });

  String? _timeLabel() {
    final logField = view.plannable?.logField;
    if (logField == null) return null;
    final v = item.values[logField];
    if (v == null) return null;
    final s = v.toString();
    if (s.isEmpty) return null;
    // Strip seconds + AM/PM space for compactness: "10:19:00 AM" → "10:19a".
    final match = RegExp(r'^(\d+):(\d+)(?::\d+)?\s*([AaPp])').firstMatch(s);
    if (match == null) return s;
    return '${match.group(1)}:${match.group(2)}${match.group(3)!.toLowerCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = _titleFor(view, item.values);
    // For a batch, the list_display.subtitle template runs against the
    // FIRST row only — for sauces that'd show "1gal Mayo" with no hint
    // that there are 2 more ingredients. Append the batch size so the
    // user sees the whole batch is one tile.
    final baseSubtitle = _subtitleFor(view, item.values);
    final batchSize = item.batchRows?.length;
    final subtitle = batchSize != null && batchSize > 1
        ? '${baseSubtitle ?? ''}${baseSubtitle == null ? '' : ' · '}'
            '$batchSize ${view.repeatGroup?.label ?? "item"}s'
        : baseSubtitle;
    final time = _timeLabel();
    final headerRow = InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.4)
            : (expanded
                ? scheme.surfaceContainerHighest
                : (isBest ? scheme.primaryContainer : null)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(
                time ?? '',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: RichText(
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: DefaultTextStyle.of(context).style,
                  children: [
                    if (isBest)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 3),
                          child: Icon(Icons.bolt,
                              size: 14, color: scheme.primary),
                        ),
                      ),
                    if (isWarmup)
                      const WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: _WarmupTag(),
                        ),
                      ),
                    TextSpan(
                      text: title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isBest
                            ? FontWeight.w700
                            : (isWarmup ? FontWeight.w400 : FontWeight.w500),
                        color: isBest
                            ? scheme.onPrimaryContainer
                            : (isWarmup ? scheme.onSurfaceVariant : null),
                      ),
                    ),
                    if (subtitle != null)
                      TextSpan(
                        text: '  $subtitle',
                        style: AppText.meta(context).copyWith(
                          color: isBest
                              ? scheme.onPrimaryContainer
                              : (isWarmup
                                  ? scheme.outline
                                  : scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            ?trailing,
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
    final inner = expanded
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              headerRow,
              _ExpandedDetails(
                view: view,
                item: item,
                // Read-only: suppress Edit and Move buttons entirely so
                // the expanded panel is purely informational.
                onEdit: readOnly ? null : onEdit,
                onMove: readOnly ? null : onMove,
                onRevert: readOnly ? null : onRevert,
              ),
            ],
          )
        : headerRow;
    // Swipe-to-delete on the compact tile. Disabled while in selection
    // mode (matches the regular _RecordTile behavior), and also
    // disabled for read-only views.
    if (selected || readOnly) return inner;
    return Dismissible(
      key: ValueKey('compact-${item.keyString}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      // Mirror _RecordTile: confirmDismiss runs the parent's dialog +
      // delete logic and returns false. Dismissible reverts the swipe
      // animation; on confirmation, the parent's setState removes the
      // item from the rebuilt list. Stops the bug where a cancelled
      // swipe still made the tile vanish until refresh.
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      child: inner,
    );
  }
}

/// Inline detail panel revealed below a compact logged tile on tap.
/// Renders every non-empty dim's value as a key/value row, plus an
/// Edit button that pushes the FormScreen (preserving the tap-to-edit
/// path while making the default tap show context instead).
class _ExpandedDetails extends StatelessWidget {
  final ViewSchema view;
  final _Item item;

  /// Null when the view is read-only — the Edit button is hidden.
  final VoidCallback? onEdit;

  /// Null when the view is read-only or the item has no date field.
  final VoidCallback? onMove;

  /// Null unless this row was promoted from a planned entry and still
  /// has its undo-logging mapping — shows "Revert to plan" (single tap:
  /// deletes the row, restores the planned entry).
  final VoidCallback? onRevert;

  const _ExpandedDetails({
    required this.view,
    required this.item,
    this.onEdit,
    this.onMove,
    this.onRevert,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rg = view.repeatGroup;
    final repeatFields = rg?.fields.toSet() ?? const <String>{};
    final rows = item.batchRows ?? [item.values];
    final isBatch = rows.length > 1 && rg != null;
    // Walk dims once to split into shared vs repeat groups. Mirrors how
    // the form renders: shared fields once (from the first row, since
    // they're identical by construction across the batch), then per-
    // block sections for the repeating ones.
    final sharedDims = <Dimension>[];
    final repeatDims = <Dimension>[];
    for (final d in view.dimensions) {
      if (!isBatch || !repeatFields.contains(d.name)) {
        sharedDims.add(d);
      } else {
        repeatDims.add(d);
      }
    }
    return Container(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(64, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Shared metadata — sauce, batch_qty, date, start_time, etc.
          // Shown once at the top, not duplicated under every ingredient.
          for (final dim in sharedDims)
            if (_show(dim, rows.first))
              _row(context, dim.name, rows.first[dim.name]),
          // Per-block sections (Ingredient #1, #2, ...) — only the
          // repeating dims, since the shared ones are already up top.
          if (isBatch)
            for (var i = 0; i < rows.length; i++) ...[
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 8 : 6, bottom: 2),
                child: Text(
                  '${rg.label} #${i + 1}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final dim in repeatDims)
                if (_show(dim, rows[i]))
                  _row(context, dim.name, rows[i][dim.name]),
            ],
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onRevert != null)
                  TextButton.icon(
                    icon: const Icon(Icons.undo, size: 16),
                    label: const Text('Revert to plan'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: onRevert,
                  ),
                if (onMove != null)
                  TextButton.icon(
                    icon: const Icon(Icons.calendar_today_outlined, size: 16),
                    label: const Text('Move'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: onMove,
                  ),
                if (onEdit != null)
                  TextButton.icon(
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: onEdit,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String name, Object? value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 1, bottom: 1),
      child: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style.copyWith(
                fontSize: 12,
                color: scheme.onSurface,
              ),
          children: [
            TextSpan(
              text: '$name: ',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            TextSpan(text: value.toString()),
          ],
        ),
      ),
    );
  }

  bool _show(Dimension dim, Map<String, Object?> row) {
    if (dim.name == 'id') return false;
    if (dim.name.startsWith('__')) return false;
    final v = row[dim.name];
    if (v == null) return false;
    if (v is String && v.isEmpty) return false;
    return true;
  }
}

/// Banner shown at the top of the timeline for each batch whose end_time
/// is still blank. Big "Stop & finish" button stamps end_time on every
/// row in the batch and the banner disappears on reload.
class _InProgressBanner extends StatelessWidget {
  final ViewSchema view;
  final _Item item;
  final bool disabled;
  final VoidCallback onFinish;

  const _InProgressBanner({
    required this.view,
    required this.item,
    required this.disabled,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final startedAt = item.values['start_time']?.toString();
    final title = _titleFor(view, item.values);
    final batchSize = item.batchRows?.length ?? 1;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: scheme.tertiary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Making $title',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
                Text(
                  '$batchSize ${view.repeatGroup?.label ?? "item"}s'
                  '${startedAt != null && startedAt.isNotEmpty ? ' · started $startedAt' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onTertiaryContainer.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.stop),
            label: const Text('Done'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: disabled ? null : onFinish,
          ),
        ],
      ),
    );
  }
}


/// Small muted "warm-up" chip marking ramp sets (planned and logged) in
/// the timeline, so they read differently from working sets.
class _WarmupTag extends StatelessWidget {
  const _WarmupTag();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        'warm-up',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
