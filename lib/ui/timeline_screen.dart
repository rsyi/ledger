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
import '../models/template.dart';
import '../services/derive.dart';
import '../services/qbo_push_store.dart';
import '../services/qbo_service.dart';
import '../services/row_cache.dart';
import '../services/template_interpolator.dart';
import '../services/template_loader.dart';
import '../services/github_client.dart';
import '../services/list_display_render.dart';
import '../services/llm_client.dart';
import '../services/llm_response_cache.dart';
import '../services/log_now.dart';
import '../services/plan_store.dart';
import '../services/sheets_repository.dart';
import '../services/warehouse_connector.dart';
import 'chat_screen.dart';
import 'form_screen.dart';
import 'templates_screen.dart';
import 'widgets/history_panel.dart';

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

  const TimelineScreen({
    super.key,
    required this.view,
    required this.repository,
    this.llm,
    this.llmCache,
    this.chatModel,
    this.github,
    this.analytics,
    this.kioskMode = false,
    this.qboSpec,
    this.qboService,
  });

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  DateTime _selectedDate = _today();
  late Future<List<_Item>> _items;
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

  /// Set of dates that have at least one logged row for this view.
  /// Populated lazily — fed into the date-bar calendar so the user can see
  /// which days have data at a glance. Null while loading; empty if the
  /// fetch failed (calendar simply has no markers).
  Set<DateTime>? _loggedDates;

  /// Templates for this view. Drives the "Recipes" production strip
  /// when the view also declares a repeat_group — each template becomes
  /// a one-tap "Make a batch of X" button that auto-logs the batch
  /// without opening a form. Null while loading; empty when the view
  /// has no templates.
  List<Template>? _templates;

  /// True when a one-tap recipe button or finish button is mid-flight.
  /// Gates duplicate taps + disables the buttons visually.
  bool _producing = false;

  /// keyStrings of logged tiles currently expanded inline. Tap toggles;
  /// expanded view shows the row's full field values plus an Edit
  /// button. Kept on the state (not the section widget) so it survives
  /// timeline rebuilds (LLM cache update, etc.).
  final Set<String> _expandedLoggedKeys = {};

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
    _loadTemplates();
    _loadQboStatuses();
    widget.llmCache?.addListener(_onLlmUpdate);
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

  Future<void> _loadTemplates() async {
    try {
      final ts = await TemplateLoader.loadForView(widget.view.name);
      if (!mounted) return;
      setState(() => _templates = ts);
    } catch (_) {
      if (!mounted) return;
      setState(() => _templates = const []);
    }
  }

  /// One-tap production: render a recipe template's entries with no
  /// variables, stamp them as a single fresh batch, write straight to
  /// the sheet — bypassing the form AND the plan store. The user sees
  /// the in-progress banner appear at the top once the writes land.
  Future<void> _startProduction(Template template) async {
    if (_producing) return;
    setState(() => _producing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final rendered = TemplateInterpolator.apply(
        template,
        widget.view,
        const {},
      );
      final groupKey = widget.view.repeatGroup?.groupKey;
      final batchId = const Uuid().v4();
      final now = DateTime.now();
      final stamp = DateFormat('h:mm:ss a').format(now);
      for (final entry in rendered) {
        final record = Map<String, Object?>.from(entry);
        record[widget.view.dateField ?? 'date'] = now;
        record['start_time'] = stamp;
        if (groupKey != null) record[groupKey] = batchId;
        record['id'] = const Uuid().v4();
        applyDerives(widget.view, record);
        await widget.repository.create(widget.view, record);
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Started ${template.name}'),
          duration: const Duration(milliseconds: 800),
        ),
      );
      _reload(fresh: true);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Start failed: $e')));
    } finally {
      if (mounted) setState(() => _producing = false);
    }
  }

  /// One-tap finish: stamp end_time on every row in the batch.
  Future<void> _finishProduction(_Item item) async {
    if (_producing || !item.isBatch) return;
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

  /// Push the dedicated production screen — big single-button-per-recipe
  /// layout backed by this state's _startProduction/_finishProduction.
  /// The screen owns its own items future so it can refresh in-place
  /// after each action; popping back returns to a freshly-reloaded
  /// timeline (host._reload runs inside _startProduction/_finish).
  Future<void> _openFullscreenProduction() async {
    if (_templates == null || _templates!.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => _FullscreenBatchScreen(host: this)),
    );
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
      setState(() => _items = Future.value(items));
    } catch (_) {
      // keep serving cached data
    } finally {
      _revalidating.remove(dateKey);
    }
  }

  /// Merges planned (local) entries with logged (sheet) rows and folds
  /// repeat-group batches. Pure assembly over an already-fetched row list.
  Future<List<_Item>> _assemble(List<Record> logged) async {
    final planned = await PlanStore.loadForDate(widget.view, _selectedDate);

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
            if (widget.view.dateField != null)
              _DateBar(
                selected: _selectedDate,
                loggedDates: _loggedDates,
                onChanged: (d) {
                  setState(() => _selectedDate = d);
                  _reload();
                },
              ),
            // Recipe production strip + in-progress banner — only for
            // views that combine repeat_group (batched) with templates
            // (recipe-like presets). Lets the user tap a sauce name to
            // start a batch and tap Stop to finish, no form involved.
            if (widget.view.repeatGroup != null &&
                (_templates?.isNotEmpty ?? false))
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
                      _RecipesStrip(
                        templates: _templates!,
                        disabled: _producing,
                        onStart: _startProduction,
                        onFullscreen: _openFullscreenProduction,
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
                    return const Center(child: Text('No entries.'));
                  }
                  // Split into logged vs planned. Logged go in a compact,
                  // collapsible "completed" section at the top so the user
                  // can see what's done at a glance without it crowding out
                  // the planned items (which are the actionable ones).
                  final logged = items.where((it) => it.isLogged).toList();
                  final planned = items.where((it) => !it.isLogged).toList();
                  final plannedRows = _groupByTemplate(planned);
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
                          // First tap toggles inline expand (shows full
                          // fields). The expanded panel surfaces Edit +
                          // Move buttons that route into the dedicated
                          // methods. While in selection mode the
                          // original toggle-select behavior wins.
                          onTap: (item) => _selectionMode
                              ? _toggleSelect(item)
                              : _toggleExpand(item.keyString),
                          onEdit: _edit,
                          onMove: _moveToDate,
                          onLongPress: _toggleSelect,
                          onDelete: _delete,
                        ),
                      for (var i = 0; i < plannedRows.length; i++) ...[
                        if (i > 0 &&
                            plannedRows[i] is! _HeaderRow &&
                            plannedRows[i - 1] is! _HeaderRow)
                          const Divider(height: 1),
                        if (plannedRows[i] is _HeaderRow)
                          _TemplateHeader(
                            name: (plannedRows[i] as _HeaderRow).name,
                            totalCount:
                                (plannedRows[i] as _HeaderRow).totalCount,
                            doneCount:
                                (plannedRows[i] as _HeaderRow).doneCount,
                            onDelete: () => _deleteTemplateGroup(
                                (plannedRows[i] as _HeaderRow).name),
                          )
                        else
                          Builder(builder: (_) {
                            final item = plannedRows[i] as _Item;
                            final selected =
                                _selectedKeys.contains(item.keyString);
                            final qboId = _qboEnabled
                                ? item.values['id']?.toString()
                                : null;
                            return _RecordTile(
                              view: widget.view,
                              item: item,
                              selected: selected,
                              selectionMode: _selectionMode,
                              llmCache: widget.llmCache,
                              repository: widget.repository,
                              qboStatus:
                                  qboId == null ? null : _qboStatus[qboId],
                              onQboRetry: qboId == null
                                  ? null
                                  : () => _retryQbo(item.values),
                              onTap: _selectionMode
                                  ? () => _toggleSelect(item)
                                  : () => _edit(item),
                              onLongPress: () => _toggleSelect(item),
                              onDelete: () => _delete(item),
                              onLogNow: () => _logNow(item),
                            );
                          }),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                onPressed: _create,
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  AppBar _buildNormalAppBar() {
    return AppBar(
      title: Text(widget.view.name),
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
              // The chat's apply_template / add_planned_entry tools
              // mutate PlanStore; refresh the timeline on return so any
              // new planned entries show up.
              if (mounted) _reload();
            },
            tooltip: 'Chat about this view',
          ),
        IconButton(
          icon: const Icon(Icons.list_alt),
          onPressed: _openTemplates,
          tooltip: 'Templates',
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

  Future<void> _openTemplates() async {
    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TemplatesScreen(
          view: widget.view,
          repository: widget.repository,
          onDate: _selectedDate,
        ),
      ),
    );
    if (applied == true) _reload();
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
          }
        } else {
          await widget.repository.delete(widget.view, item.logged!);
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

  /// Promotes a planned entry into a sheet row. The entry's start_time is
  /// stamped with now (unless the user already set one via edit), derives
  /// are applied, then it's written to the sheet and removed from local plan.
  ///
  /// Optimistic: the row stays exactly where it is in the list (under its
  /// template header) and just visually flips to "done". The Sheets `create`
  /// happens in the background; on failure we surface a snackbar and
  /// re-sync from the source of truth.
  Future<void> _logNow(_Item item, {Map<String, Object?>? overrideValues}) async {
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
      final updated = List<_Item>.from(current);
      updated.removeAt(idx);
      updated.add(_Item.logged(values));
      setState(() => _items = Future.value(updated));
    }

    try {
      try {
        await widget.repository.create(widget.view, values);
        await PlanStore.remove(widget.view, planned.localId);
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
    final rowId = values['id']?.toString();
    if (hook != null && llm != null && cache != null && rowId != null) {
      _runPostLogHook(hook, values, rowId, llm, cache);
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

/// Walks the ordered item list once, emitting a `_HeaderRow` data marker
/// whenever the planned-template attribution changes. Logged items and
/// ad-hoc planned items (no template) emit no header. Assumes items are
/// already grouped contiguously by template — true because `PlanStore.addAll`
/// appends in apply order and we never interleave.
List<Object> _groupByTemplate(List<_Item> items) {
  final out = <Object>[];
  String? lastHeader;
  // Pre-count done / total per template name. `loggedFromPlanned` items count
  // toward both totals and dones; pure `planned` items count toward totals only.
  final totals = <String, int>{};
  final dones = <String, int>{};
  for (final it in items) {
    final t = it.templateName;
    if (t == null) continue;
    totals[t] = (totals[t] ?? 0) + 1;
    if (it.isLogged) dones[t] = (dones[t] ?? 0) + 1;
  }
  for (final item in items) {
    final templateName = item.templateName;
    if (templateName != null && templateName != lastHeader) {
      out.add(_HeaderRow(
        name: templateName,
        totalCount: totals[templateName] ?? 0,
        doneCount: dones[templateName] ?? 0,
      ));
      lastHeader = templateName;
    } else if (templateName == null) {
      lastHeader = null;
    }
    out.add(item);
  }
  return out;
}

/// Data-only marker for a template group header. The actual widget
/// (`_TemplateHeader`) is constructed in the timeline's itemBuilder so it can
/// close over the delete callback.
class _HeaderRow {
  final String name;
  final int totalCount;
  final int doneCount;
  _HeaderRow({
    required this.name,
    required this.totalCount,
    required this.doneCount,
  });
}

/// Section header rendered above the planned items that came from the same
/// template apply. The trailing delete button removes the whole group
/// (after confirm).
class _TemplateHeader extends StatelessWidget {
  final String name;
  final int totalCount;
  final int doneCount;
  final VoidCallback onDelete;

  const _TemplateHeader({
    required this.name,
    required this.totalCount,
    required this.doneCount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.only(left: 16, right: 4, top: 10, bottom: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outline, width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              '$doneCount / $totalCount',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            color: scheme.onSurfaceVariant,
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
            tooltip: 'Remove group',
          ),
        ],
      ),
    );
  }
}


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
                                fontSize: 10,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '= logged',
                            style: TextStyle(
                              fontSize: 11,
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

class _RecordTile extends StatelessWidget {
  final ViewSchema view;
  final _Item item;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  final VoidCallback onLogNow;
  final LlmResponseCache? llmCache;
  final WarehouseConnector repository;

  /// QuickBooks push status for this row (null when the view isn't
  /// QBO-mapped). Drives the trailing badge. [onQboRetry] pushes just this
  /// row (used for pending/failed badges).
  final QboPushRecord? qboStatus;
  final VoidCallback? onQboRetry;

  const _RecordTile({
    required this.view,
    required this.item,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
    required this.onLogNow,
    required this.repository,
    this.llmCache,
    this.qboStatus,
    this.onQboRetry,
  });

  /// First dimension on the view opted-in to `input.history: true` whose
  /// value is non-empty on this row. The history icon scopes to this dim.
  /// Returns null when no opted-in dim has a value (e.g. blank fields,
  /// planned rows without the subject field filled in).
  ({Dimension dim, String value})? _historyTarget() {
    for (final d in view.dimensions) {
      if (!(d.input?.history ?? false)) continue;
      final raw = item.values[d.name];
      final s = raw?.toString().trim();
      if (s == null || s.isEmpty) continue;
      return (dim: d, value: s);
    }
    return null;
  }

  Widget? _buildTrailing(BuildContext context) {
    if (selectionMode) return null;
    final badge = _qboBadge(context);
    final history = _historyButton(context);
    if (badge == null && history == null) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [?badge, ?history],
    );
  }

  Widget? _historyButton(BuildContext context) {
    final t = _historyTarget();
    if (t == null) return null;
    return IconButton(
      icon: const Icon(Icons.history),
      tooltip: 'History',
      onPressed: () => showHistorySheet(
        context: context,
        view: view,
        dim: t.dim,
        value: t.value,
        repository: repository,
      ),
    );
  }

  /// Trailing badge showing this transaction's QuickBooks push status.
  /// Pending/failed badges are tappable to push just this row.
  Widget? _qboBadge(BuildContext context) {
    if (!item.isLogged || qboStatus == null) return null;
    final scheme = Theme.of(context).colorScheme;
    switch (qboStatus!.status) {
      case QboPushStatus.pushed:
        return const Tooltip(
          message: 'Pushed to QuickBooks',
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.cloud_done, size: 18, color: Colors.green),
          ),
        );
      case QboPushStatus.pushing:
        return const Padding(
          padding: EdgeInsets.all(9),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case QboPushStatus.failed:
        return IconButton(
          icon: Icon(Icons.error_outline, size: 18, color: scheme.error),
          tooltip: qboStatus!.error ?? 'Push failed — tap to retry',
          onPressed: onQboRetry,
        );
      case QboPushStatus.pending:
        return IconButton(
          icon: Icon(Icons.cloud_queue, size: 18, color: scheme.outline),
          tooltip: 'Not pushed yet — tap to push',
          onPressed: onQboRetry,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _subtitleFor(view, item.values);
    final scheme = Theme.of(context).colorScheme;
    final rowId = item.logged?['id']?.toString();
    final llmResponse =
        rowId == null ? null : llmCache?.get(rowId);
    final llmPending =
        rowId == null ? false : (llmCache?.isPending(rowId) ?? false);
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minLeadingWidth: 0,
      horizontalTitleGap: 14,
      minVerticalPadding: 10,
      selected: selected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.4),
      // The leading slot doubles as the log-button when the row is planned:
      // the empty orange circle is tappable (with a Material ripple to
      // signal "this is a button") and tap = log. Replaces the separate
      // trailing play button — same affordance the user's intuition was
      // already reaching for.
      leading: selectionMode
          ? Icon(
              selected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 22,
              color: selected ? scheme.secondary : scheme.outlineVariant,
            )
          : (item.isPlanned
              ? _LogCircle(onTap: onLogNow)
              : const Padding(
                  padding: EdgeInsets.all(11),
                  child: Icon(Icons.check_circle,
                      size: 22, color: Colors.green),
                )),
      title: Text(_titleFor(view, item.values)),
      subtitle: (subtitle == null && llmResponse == null && !llmPending)
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subtitle != null) Text(subtitle),
                if (llmPending)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                          ),
                    ),
                  )
                else if (llmResponse != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      llmResponse,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                            height: 1.35,
                          ),
                    ),
                  ),
              ],
            ),
      // Trailing slot: history icon when an opted-in dim has a value and
      // we're not in selection mode. The leading circle remains the log
      // button for planned rows.
      trailing: _buildTrailing(context),
      onTap: onTap,
      onLongPress: onLongPress,
    );
    // Swipe-to-delete is disabled in selection mode — too easy to fire
    // accidentally while scrolling through a long selection.
    if (selectionMode) return tile;
    return Dismissible(
      key: ValueKey(item.keyString),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      child: tile,
    );
  }
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

/// Tappable empty-circle that fills the row's leading slot for planned
/// items. Tap = promote-to-logged (calls onLogNow). The Material ink
/// ripple is what makes the affordance read "this is a button" instead
/// of "this is a status icon" — the visual is otherwise identical to
/// the static green check the row flips to once logged.
class _LogCircle extends StatelessWidget {
  final VoidCallback onTap;
  const _LogCircle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        // 44x44 hit target — Material accessibility minimum — even though
        // the visual circle is only 22px. The extra padding is invisible
        // but catches near-misses comfortably.
        customBorder: const CircleBorder(),
        child: const Padding(
          padding: EdgeInsets.all(11),
          child: Icon(
            Icons.radio_button_unchecked,
            size: 22,
            color: Colors.orange,
          ),
        ),
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
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Icon(Icons.check_circle, color: scheme.primary, size: 16),
              const SizedBox(width: 6),
              Text(
                '${items.length} logged',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        for (final item in items)
          _CompactLoggedTile(
            view: view,
            item: item,
            selected: selectedKeys.contains(item.keyString),
            expanded: expandedKeys.contains(item.keyString),
            onTap: () => onTap(item),
            onEdit: () => onEdit(item),
            onMove: () => onMove(item),
            onLongPress: () => onLongPress(item),
            onDelete: () => onDelete(item),
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
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onMove;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  const _CompactLoggedTile({
    required this.view,
    required this.item,
    required this.selected,
    required this.expanded,
    required this.onTap,
    required this.onEdit,
    required this.onMove,
    required this.onLongPress,
    required this.onDelete,
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
                : null),
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
                    TextSpan(
                      text: title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null)
                      TextSpan(
                        text: '  $subtitle',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
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
                onEdit: onEdit,
                onMove: onMove,
              ),
            ],
          )
        : headerRow;
    // Swipe-to-delete on the compact tile. Disabled while in selection
    // mode (matches the regular _RecordTile behavior).
    if (selected) return inner;
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
  final VoidCallback onEdit;
  final VoidCallback? onMove;

  const _ExpandedDetails({
    required this.view,
    required this.item,
    required this.onEdit,
    this.onMove,
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
                    fontSize: 11,
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

/// Horizontal scroll of "Make a batch of X" buttons, one per recipe
/// template. Tap = auto-log a batch with start_time stamped, no form.
/// Sits at the top of the timeline for views that combine repeat_group
/// + templates (i.e. recipe-driven production logs like sauces).
class _RecipesStrip extends StatelessWidget {
  final List<Template> templates;
  final bool disabled;
  final void Function(Template) onStart;
  final VoidCallback onFullscreen;

  const _RecipesStrip({
    required this.templates,
    required this.disabled,
    required this.onStart,
    required this.onFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Make a batch',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                // Fullscreen: opens a dedicated production screen with
                // big buttons + recent batches. The strip stays here for
                // quick taps from the timeline.
                IconButton(
                  icon: const Icon(Icons.fullscreen, size: 20),
                  tooltip: 'Production view',
                  visualDensity: VisualDensity.compact,
                  onPressed: onFullscreen,
                ),
              ],
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: templates.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final t = templates[i];
                return FilledButton.tonalIcon(
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(t.name),
                  onPressed: disabled ? null : () => onStart(t),
                );
              },
            ),
          ),
        ],
      ),
    );
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



/// Production view — the big-buttons-per-recipe screen the user pushes
/// from the `_RecipesStrip` fullscreen icon. Optimized for a kitchen
/// device where the cook is making sauce: tap a sauce → it logs +
/// shows in the in-progress section; tap Done on the in-progress card
/// → it closes the batch.
///
/// Data lifecycle: owns its own `_items` future fetched from
/// `host._fetch()`. Each user action calls back into the host's
/// `_startProduction` / `_finishProduction` (which also reload the
/// host's timeline), then refreshes our local items so the screen
/// reflects the new state without a manual pull-to-refresh.
class _FullscreenBatchScreen extends StatefulWidget {
  final _TimelineScreenState host;
  const _FullscreenBatchScreen({required this.host});

  @override
  State<_FullscreenBatchScreen> createState() => _FullscreenBatchScreenState();
}

class _FullscreenBatchScreenState extends State<_FullscreenBatchScreen> {
  late Future<List<_Item>> _items;
  bool _producing = false;

  @override
  void initState() {
    super.initState();
    _items = widget.host._fetch();
  }

  Future<void> _refreshItems() async {
    setState(() => _items = widget.host._fetch(forceFresh: true));
  }

  Future<void> _startBatch(Template t) async {
    if (_producing) return;
    setState(() => _producing = true);
    try {
      await widget.host._startProduction(t);
    } finally {
      if (mounted) {
        await _refreshItems();
        setState(() => _producing = false);
      }
    }
  }

  Future<void> _finishBatch(_Item item) async {
    if (_producing) return;
    setState(() => _producing = true);
    try {
      await widget.host._finishProduction(item);
    } finally {
      if (mounted) {
        await _refreshItems();
        setState(() => _producing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final view = host.widget.view;
    final scheme = Theme.of(context).colorScheme;
    final templates = host._templates ?? const <Template>[];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.fullscreen_exit),
          tooltip: 'Collapse',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Production'),
      ),
      body: FutureBuilder<List<_Item>>(
        future: _items,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? const <_Item>[];
          final active = host._activeBatches(items);
          final completed = items
              .where((it) => it.isBatch && !active.contains(it))
              .toList();
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // In-progress at top — most-pressing UI.
                if (active.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 6),
                    child: Text(
                      'IN PROGRESS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final it in active)
                    _InProgressBanner(
                      view: view,
                      item: it,
                      disabled: _producing,
                      onFinish: () => _finishBatch(it),
                    ),
                  const SizedBox(height: 24),
                ],
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6),
                  child: Text(
                    'MAKE A BATCH',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                // Big single-column buttons — wide tap target sized
                // for kitchen use (gloves, glanced-at screens).
                for (final t in templates) ...[
                  _BigRecipeButton(
                    template: t,
                    disabled: _producing,
                    onTap: () => _startBatch(t),
                  ),
                  const SizedBox(height: 12),
                ],
                if (completed.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 6),
                    child: Text(
                      'RECENT BATCHES',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < completed.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _BatchSummaryRow(view: view, item: completed[i]),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One row in the production-view recipe list. Big enough for a
/// gloved/glanced tap. Shows recipe name + (if present) the recipe's
/// description on a second line.
class _BigRecipeButton extends StatelessWidget {
  final Template template;
  final bool disabled;
  final VoidCallback onTap;

  const _BigRecipeButton({
    required this.template,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton(
      onPressed: disabled ? null : onTap,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
        textStyle: const TextStyle(fontSize: 18),
        alignment: Alignment.centerLeft,
      ),
      child: Row(
        children: [
          const Icon(Icons.play_arrow, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  template.name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (template.description != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    template.description!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: scheme.onPrimary.withValues(alpha: 0.75),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact summary line for a completed batch in the production view.
class _BatchSummaryRow extends StatelessWidget {
  final ViewSchema view;
  final _Item item;
  const _BatchSummaryRow({required this.view, required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = _titleFor(view, item.values);
    final subtitle = _subtitleFor(view, item.values);
    final start = item.values['start_time']?.toString();
    final end = item.values['end_time']?.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          if (start != null && start.isNotEmpty) ...[
            SizedBox(
              width: 72,
              child: Text(
                start,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (end != null && end.isNotEmpty)
            Icon(
              Icons.check_circle,
              size: 16,
              color: scheme.primary,
            ),
        ],
      ),
    );
  }
}
