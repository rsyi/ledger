/// Program screen — THE ROUTINE (restructured 2026-09-28 per user
/// feedback: "too unstructured… don't want freeform text").
///
/// Layout, top to bottom:
///   1. Header — week range + block + the plain-words week status
///      ("Week 2 of 4 · top set 4 reps @ 84%"). No jargon anywhere on
///      this screen: no "wave", no "Rx", no section-sign references.
///   2. TRAINING MAXES — one row per lift: current TM, the 2-week
///      change ("310 · was 320 ↓ · Oct 1"), Confirm when a proposed
///      value awaits confirmation. Tap a lift → full-screen TM trend
///      plot (append-only working_max tab history). Menu: manual set +
///      refresh. A manual edit recomputes every displayed load
///      immediately (the store's cache is busted on write and the
///      whole screen refetches).
///   3. Day tiles — ONE summary line (`squat heavy · bench volume`)
///      plus a bare list of exercise rows (`Squat 1×5 · 260 lb (81%)`;
///      accessories show the double-progression suggestion or stay
///      blank), and the backoff rule collapsed to one short line on
///      heavy days. Template prose is never rendered.
///
/// All row/summary/label formatting is pure and tested —
/// services/routine_display.dart. Phases live on the Progress tab and
/// the forecast/sim on the Weight / Strength pages, not here. Entry
/// points (2026-10-02, Plan tab retired): Today's program card "Full
/// week" action, the Week tab's app-bar icon, and every old
/// week-plan / Program deep link.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/bodyweight_cache.dart' show BodyweightCache;
import '../services/display_names.dart' show sentenceCase;
import '../services/program_current.dart';
import '../services/program_metrics.dart'
    show StrengthRow, liftReferencesAsOf, mainLiftByExercise;
import '../services/program_provider.dart';
import '../services/routine_display.dart';
import '../services/sheets_repository.dart' show Record;
import '../services/warehouse_connector.dart';
import '../services/week_plan.dart';
import '../services/week_planner.dart' show buildWeekPlannedEntries;
import '../services/wm_store.dart';
import '../services/wm_tabs.dart';
import '../services/working_max.dart'
    show LoadPolicy, defaultVariantByLift, loadPolicies, policyForDate;
import 'design/design.dart';
import 'widgets/chart_bottom_axis.dart';
import 'widgets/chart_range.dart';
import 'widgets/pinned_tooltip_line_chart.dart';

/// Full-screen routine view (the Program surface).
///
/// Fetches program.yaml/phase.yaml via [provider] (1 h cache), the
/// training-max tabs via [wmStore], and the strength history via
/// [strengthRepo] (references + accessory double-progression). Left/
/// right chevrons navigate weeks; the default week follows
/// [defaultWeekStart] (next week when opened on the week's last day).
class ProgramScreen extends StatefulWidget {
  final ProgramProvider provider;

  /// Training-max tab reader/writer; null hides the TRAINING MAXES
  /// section (loads fall back to reference e1rms).
  final WmStore? wmStore;

  /// Strength history for accessory suggestions + reference e1rms.
  /// Null → mains still price off the TM; accessories stay blank.
  final WarehouseConnector? strengthRepo;
  final ViewSchema? strengthView;

  /// Injected for tests; defaults to DateTime.now().
  final DateTime? today;

  const ProgramScreen({
    super.key,
    required this.provider,
    this.wmStore,
    this.strengthRepo,
    this.strengthView,
    this.today,
  });

  @override
  State<ProgramScreen> createState() => _ProgramScreenState();
}

class _RoutineData {
  final IntentDocs docs;
  final WmSnapshot? wm;
  final List<StrengthRow> history;
  const _RoutineData({required this.docs, this.wm, this.history = const []});
}

class _ProgramScreenState extends State<ProgramScreen> {
  late final DateTime _today;
  late DateTime _weekStart; // Monday of the displayed week
  late Future<_RoutineData?> _load;
  bool _wmBusy = false;

  @override
  void initState() {
    super.initState();
    _today = widget.today ?? DateTime.now();
    _weekStart = defaultWeekStart(_today);
    _load = _fetch();
  }

  Future<_RoutineData?> _fetch() async {
    try {
      final docs = await widget.provider.load();
      final wm = await widget.wmStore?.snapshot();
      var history = const <StrengthRow>[];
      if (widget.strengthRepo != null && widget.strengthView != null) {
        try {
          final recs = await widget.strengthRepo!.list(widget.strengthView!);
          history = [for (final r in recs) ?_strengthRow(r)];
        } catch (_) {}
      }
      return _RoutineData(docs: docs, wm: wm, history: history);
    } catch (_) {
      return null;
    }
  }

  Future<void> _refresh() async {
    ProgramProvider.clearCache();
    final next = _fetch();
    setState(() => _load = next);
    await next;
  }

  /// Runs a training-max write, then refetches EVERYTHING so every
  /// displayed load reprices off the new value (deterministic edit →
  /// recompute; WmStore busts its cache on write, so the refetch
  /// reads the fresh tab).
  Future<void> _wmAction(Future<void> Function() op) async {
    setState(() => _wmBusy = true);
    try {
      await op();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _wmBusy = false;
          _load = _fetch();
        });
      }
    }
  }

  Future<void> _setTrainingMaxDialog() async {
    final store = widget.wmStore;
    if (store == null) return;
    var lift = 'bench';
    final valueCtl = TextEditingController();
    final reasonCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Set training max'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: lift,
                decoration: const InputDecoration(labelText: 'Lift'),
                items: [
                  for (final l in defaultVariantByLift.keys)
                    DropdownMenuItem(value: l, child: Text(l)),
                ],
                onChanged: (v) => setLocal(() => lift = v ?? lift),
              ),
              TextField(
                controller: valueCtl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Training max (lb)'),
              ),
              TextField(
                controller: reasonCtl,
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
    final value = double.tryParse(valueCtl.text.trim());
    if (ok != true || value == null || value <= 0) return;
    await _wmAction(() => store.setWorkingMax(
          lift: lift,
          valueLb: value,
          reason: reasonCtl.text,
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Program'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous week',
            onPressed: () => setState(() {
              _weekStart = _weekStart.subtract(const Duration(days: 7));
            }),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next week',
            onPressed: () => setState(() {
              _weekStart = _weekStart.add(const Duration(days: 7));
            }),
          ),
        ],
      ),
      // SafeArea(bottom): the screen is pushed on the root navigator
      // with no bottom bar, so under edge-to-edge the last visible line
      // drew BENEATH the gesture-navigation handle — the 2026-10-02
      // audit's "Muscle Up Green Band struck through" was that pill
      // over the text, not a text decoration.
      body: SafeArea(
        top: false,
        child: FutureBuilder<_RoutineData?>(
          future: _load,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snap.data;
            if (data == null || data.docs.program == null) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Program data unavailable — check GitHub config.'),
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: _refresh,
              child: _RoutineView(
                data: data,
                weekStart: _weekStart,
                today: _today,
                hasWmStore: widget.wmStore != null,
                wmBusy: _wmBusy,
                strengthView: widget.strengthView,
                onSetTrainingMax: _setTrainingMaxDialog,
                onConfirmSeed: (lift) =>
                    _wmAction(() => widget.wmStore!.confirmSeed(lift)),
                onRefreshMaxes: () => _wmAction(() async {}),
              ),
            );
          },
        ),
      ),
    );
  }

  static StrengthRow? _strengthRow(Record r) {
    final rawDate = r['date'];
    final date = rawDate is DateTime
        ? rawDate
        : DateTime.tryParse(rawDate?.toString() ?? '');
    final exercise = r['exercise']?.toString();
    if (date == null || exercise == null || exercise.isEmpty) return null;
    num? numOf(Object? v) => v is num ? v : num.tryParse(v?.toString() ?? '');
    final weight = numOf(r['weight']);
    final reps = numOf(r['reps']);
    if (weight == null || reps == null) return null;
    return StrengthRow(
      date: date,
      exercise: exercise,
      weight: weight.toDouble(),
      reps: reps.round(),
      rpe: numOf(r['rpe'])?.toDouble(),
      notes: r['notes']?.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// Week view
// ---------------------------------------------------------------------------

class _RoutineView extends StatelessWidget {
  final _RoutineData data;
  final DateTime weekStart;
  final DateTime today;
  final bool hasWmStore;
  final bool wmBusy;

  /// Target view for scheduling planned rows. Null → the schedule
  /// actions are hidden (no view to write into).
  final ViewSchema? strengthView;

  final VoidCallback onSetTrainingMax;
  final ValueChanged<String> onConfirmSeed;
  final VoidCallback onRefreshMaxes;

  const _RoutineView({
    required this.data,
    required this.weekStart,
    required this.today,
    required this.hasWmStore,
    required this.wmBusy,
    required this.strengthView,
    required this.onSetTrainingMax,
    required this.onConfirmSeed,
    required this.onRefreshMaxes,
  });

  @override
  Widget build(BuildContext context) {
    final program = data.docs.program!;
    final phase = data.docs.phase;
    final version = currentVersion(program);
    final week = buildWeekPlan(program, phase, weekStart);

    ProgramSlice? repSlice;
    for (final d in week) {
      if (d.slice != null) {
        repSlice = d.slice;
        break;
      }
    }

    // Weight inputs: training maxes + caps (TM path), reference e1rms
    // (fallback), accessory history (double progression).
    final wm = data.wm;
    final maxes = wm == null
        ? const <String, double>{}
        : currentWorkingMaxesByLift(wm.workingMax);
    final policies = version == null ? const <LoadPolicy>[] : loadPolicies(version);
    final sliceByDay = {for (final d in week) d.date: d.slice};
    LoadPolicy? policyOn(DateTime d) {
      if (policies.isEmpty) return null;
      final slice = sliceByDay[DateTime.utc(d.year, d.month, d.day)] ??
          programCurrent(program, phase, d);
      return policyForDate(
        policies,
        date: d,
        block: slice?.block['number'] as int?,
        weekType: slice?.weekType,
      );
    }

    final caps = wm == null
        ? const <String, double>{}
        : activeCapsByLift(wm, policyOn);
    final references = liftReferencesAsOf(data.history, today);

    // Plan entries for EXACTLY the displayed Mon–Sun days. The default
    // (snapped) call would price the Sat-start ACCOUNTING window
    // (Sat–Fri under program.yaml v7 `week_start: saturday`), which
    // excludes the displayed Saturday — the 2026-09-28 "Saturday shows
    // as Rest" regression.
    final entries = buildWeekPlannedEntries(
      program,
      week.first.date,
      references: references,
      workingMaxes: maxes,
      capRpeByLift: caps,
      accessoryHistory: data.history,
      snapToWeekStart: false,
    );
    final linesByDay = sessionLinesByDay(entries);
    final backoff = backoffLine(version?['backoff_rule']);

    final todayUtc = DateTime.utc(today.year, today.month, today.day);
    const gutter = EdgeInsets.symmetric(horizontal: AppSpace.gutter);
    return ListView(
      key: const ValueKey('routine-list'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sectionGap),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
          padding: gutter,
          child: _HeaderCard(
            weekStart: weekStart,
            slice: repSlice,
            phaseYaml: phase,
            version: version,
          ),
        ),
        if (hasWmStore) ...[
          SectionHeader(
            label: 'Training maxes',
            actions: [
              wmBusy
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'set') onSetTrainingMax();
                        if (v == 'refresh') onRefreshMaxes();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                            value: 'set', child: Text('Set training max…')),
                        PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                      ],
                    ),
            ],
          ),
          Padding(
            padding: gutter,
            child: AppCard(
              padding: EdgeInsets.zero,
              child: _TrainingMaxSection(
                snapshot: wm,
                today: today,
                busy: wmBusy,
                onConfirm: onConfirmSeed,
              ),
            ),
          ),
        ],
        const SectionHeader(label: 'Sessions'),
        for (final day in week)
          _DayTile(
            day: day,
            isToday: day.date == todayUtc,
            lines: linesByDay[day.date] ?? const [],
            maxes: maxes,
            backoff: backoff,
            bodyweight: BodyweightCache.currentLbs,
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header card — week + block + plain-words week status
// ---------------------------------------------------------------------------

class _HeaderCard extends StatelessWidget {
  final DateTime weekStart;
  final ProgramSlice? slice;
  final Map<Object?, Object?>? phaseYaml;
  final Map<Object?, Object?>? version;

  const _HeaderCard({
    required this.weekStart,
    required this.slice,
    required this.phaseYaml,
    required this.version,
  });

  /// "Week 2 of 4 · top set 4 reps @ 84%" — pure, tested in
  /// routine_display. Null pre-program.
  String? _statusLine() {
    final s = slice;
    if (s == null || version == null) return null;
    final blockN = s.block['number'] as int?;
    return weekStatusLine(
      cut: strengthWaveCutFor(version, blockN: blockN, day: weekStart),
      waveWeek: strengthWaveWeek(version,
          blockN: blockN, weekInBlock: s.weekInBlock),
      waveReps: strengthWaveTopReps(version,
          blockN: blockN, weekInBlock: s.weekInBlock, weekType: s.weekType),
      weekType: s.weekType,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final weekEnd = weekStart.add(const Duration(days: 6));
    final dateRange = '${_fmtShort(weekStart)} – ${_fmtShort(weekEnd)}';

    String? blockLine;
    String? weekTypeLine;
    String? phaseLine;
    if (slice != null) {
      final s = slice!;
      final blockN = s.block['number'];
      final emphasis = s.block['emphasis']?.toString() ?? '';
      blockLine = 'Block $blockN · $emphasis · week ${s.weekInBlock} in block';
      weekTypeLine = s.weekType;
    }
    final phaseVersion = phaseYaml != null ? currentVersion(phaseYaml!) : null;
    if (phaseVersion != null) {
      final value = phaseVersion['value']?.toString() ?? '';
      phaseLine = 'Phase: $value';
    }
    final status = _statusLine();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(dateRange, style: AppText.title(context)),
              ),
              if (weekTypeLine != null && weekTypeLine != 'normal')
                _WeekTypeBadge(type: weekTypeLine),
            ],
          ),
          if (blockLine != null) ...[
            const SizedBox(height: 6),
            Text(
              '$blockLine${phaseLine != null ? ' · $phaseLine' : ''}',
              style: AppText.meta(context),
            ),
          ],
          if (status != null) ...[
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.chip),
              ),
              child: Text(
                status,
                style: AppText.meta(context).copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
          if (slice == null) ...[
            const SizedBox(height: 6),
            Text('No program for this week', style: AppText.meta(context)),
          ],
        ],
      ),
    );
  }
}

class _WeekTypeBadge extends StatelessWidget {
  final String type;
  const _WeekTypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    switch (type) {
      case 'light':
        bg = scheme.tertiaryContainer;
        fg = scheme.onTertiaryContainer;
      case 'test':
        bg = scheme.secondaryContainer;
        fg = scheme.onSecondaryContainer;
      default:
        bg = scheme.surfaceContainerLow;
        fg = scheme.onSurfaceVariant;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        type,
        style: AppText.meta(context)
            .copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Training maxes — top section
// ---------------------------------------------------------------------------

class _TrainingMaxSection extends StatelessWidget {
  final WmSnapshot? snapshot;
  final DateTime today;
  final bool busy;
  final ValueChanged<String> onConfirm;

  const _TrainingMaxSection({
    required this.snapshot,
    required this.today,
    required this.busy,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final snap = snapshot;
    final rows = <(String, TmSignal, bool)>[
      if (snap != null)
        for (final lift in defaultVariantByLift.keys)
          if (tmSignal(snap.workingMax, lift, today) case final TmSignal s)
            (lift, s, needsConfirmation(snap.workingMax, lift)),
    ];
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpace.gutter),
        child: Text(
          snap == null
              ? 'Training maxes unavailable — pull to retry.'
              : 'No training maxes yet.',
          style: AppText.meta(context),
        ),
      );
    }
    // ExerciseRow rows, hairline-divided (the Progress lifts pattern):
    // lift name · "since … · manual/auto" meta · the TM as the trailing
    // figure; an unconfirmed seed reads amber with its Confirm action.
    final value = AppText.row(context).copyWith(
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const RowDivider(),
          ExerciseRow(
            key: ValueKey('tm-row-${rows[i].$1}'),
            name: liftTitle(rows[i].$1),
            status: rows[i].$3 ? ItemStatus.partial : ItemStatus.muted,
            subtitle: Text(tmSignalSuffix(rows[i].$2)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => _TmTrendScreen(
                lift: rows[i].$1,
                rows: snap!.workingMax,
                signal: rows[i].$2,
              ),
            )),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (rows[i].$3)
                  busy
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text('…',
                              style: TextStyle(
                                  color: scheme.onSurfaceVariant)),
                        )
                      : TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => onConfirm(rows[i].$1),
                          child: const Text('Confirm'),
                        ),
                Padding(
                  padding: const EdgeInsets.only(right: 8, left: 4),
                  child: Text('${fmtLb(rows[i].$2.current)} lb', style: value),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 'squat' → 'Squat', 'press' → 'Overhead press' (the Progress
  /// tab's lift names).
  static String liftTitle(String lift) {
    final n = lift == 'press' ? 'overhead press' : lift;
    return n[0].toUpperCase() + n.substring(1);
  }

  static String fmtLb(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();
}

/// Full-screen trend plot of one lift's training-max history (the
/// append-only working_max tab).
class _TmTrendScreen extends StatefulWidget {
  final String lift;
  final List<WorkingMaxRow> rows;
  final TmSignal signal;

  const _TmTrendScreen({
    required this.lift,
    required this.rows,
    required this.signal,
  });

  @override
  State<_TmTrendScreen> createState() => _TmTrendScreenState();
}

class _TmTrendScreenState extends State<_TmTrendScreen> {
  ChartRange? _selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = _TrainingMaxSection.liftTitle(widget.lift);
    final points = tmHistoryPoints(widget.rows, widget.lift);
    final variant =
        currentWorkingMax(widget.rows, widget.lift)?.variant ?? '';

    return Scaffold(
      appBar: AppBar(title: Text('$title training max')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${_TrainingMaxSection.fmtLb(widget.signal.current)} lb',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text: '  ${tmSignalSuffix(widget.signal)}'
                        '${variant.isNotEmpty ? ' · $variant' : ''}',
                    style: AppText.meta(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: points.length < 2
                  ? Center(
                      child: Text(
                        points.isEmpty
                            ? 'No recorded values yet.'
                            : 'One recorded value — the plot appears once '
                                'it changes.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : _chart(context, points),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chart(
      BuildContext context, List<({DateTime day, double value})> points) {
    final scheme = Theme.of(context).colorScheme;
    final series = <ChartSeriesPoint>[
      for (final p in points) (day: p.day, value: p.value),
    ];
    final anchor = series.last.day;
    final chips = visibleRanges(
      points: series,
      ranges: const [ChartRange.m3, ChartRange.m6, ChartRange.y1, ChartRange.all],
      today: anchor,
    );
    final range = resolveRange(chips, _selected ?? ChartRange.all);
    final clipped = clipSeriesToRange(series, range, anchor);

    double dayX(DateTime d) => d.millisecondsSinceEpoch / 86400000;
    final spots = [for (final p in clipped) FlSpot(dayX(p.day), p.value)];
    var xMin = dayX(range.startFor(anchor) ?? clipped.first.day);
    final xMax = spots.last.x;
    if (xMax - xMin < 1) xMin = xMax - 1;
    final ys = spots.map((s) => s.y).toList();
    final yMin = ys.reduce((a, b) => a < b ? a : b);
    final yMax = ys.reduce((a, b) => a > b ? a : b);
    final yPad = (yMax - yMin).abs() * 0.1 + 2.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chips.length > 1)
          ChartRangeSelector(
            ranges: chips,
            selected: range,
            onChanged: (r) => setState(() => _selected = r),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => PinnedTooltipLineChart(
              key: ValueKey(range),
              data: LineChartData(
                minX: xMin,
                maxX: xMax,
                minY: yMin - yPad,
                maxY: yMax + yPad,
                gridData:
                    const FlGridData(show: true, drawVerticalLine: false),
                borderData: FlBorderData(
                  show: true,
                  border: Border(
                    left: BorderSide(color: scheme.outlineVariant),
                    bottom: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(),
                  topTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (value, meta) => Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          value.toStringAsFixed(0),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: dateBottomTitles(
                      minX: xMin,
                      maxX: xMax,
                      plotWidth: (constraints.maxWidth - 44).clamp(1, 10000),
                      style: const TextStyle(fontSize: 11),
                      reservedSize: 32,
                    ),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: false,
                    isStepLineChart: true,
                    barWidth: 2,
                    color: scheme.primary,
                    dotData: FlDotData(
                      show: spots.length < 80,
                      getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
                        radius: 3,
                        color: scheme.primary,
                        strokeWidth: 0,
                      ),
                    ),
                  ),
                ],
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => Colors.black.withValues(alpha: 0.7),
                    getTooltipItems: (touched) => [
                      for (final s in touched)
                        LineTooltipItem(
                          '${DateFormat('yyyy-MM-dd').format(DateTime.fromMillisecondsSinceEpoch((s.x * 86400000).toInt(), isUtc: true))}\n'
                          '${s.y.toStringAsFixed(0)} lb',
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Day tile — one summary line + bare exercise rows
// ---------------------------------------------------------------------------

class _DayTile extends StatelessWidget {
  final DayPlan day;
  final bool isToday;
  final List<SessionLine> lines;
  final Map<String, double> maxes;
  final String? backoff;

  /// Current bodyweight (lb) for `BW+N` on weighted bodyweight moves.
  final double? bodyweight;

  const _DayTile({
    required this.day,
    required this.isToday,
    required this.lines,
    required this.maxes,
    required this.backoff,
    this.bodyweight,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slice = day.slice;
    final date = day.date;

    final weekdayLabel = DateFormat('EEE').format(date);
    final dateLabel = DateFormat('MMM d').format(date);

    final summary = slice == null
        ? 'No program'
        : daySummary(
            lines: lines,
            morning: slice.todayTemplate['morning']?.toString(),
            afternoon: slice.todayTemplate['afternoon']?.toString(),
          );
    final muted = slice == null || summary == 'Rest';
    final hasTop = lines.any((l) => l.top);

    // The dense per-exercise lines (the redesign's reference style):
    // meta role, top sets emphasised in the row colour.
    final meta = AppText.meta(context);

    // One card per day (the shared rows-in-a-card style); today's card
    // carries the accent outline + accent weekday.
    return AppCard(
      key: ValueKey('routine-day-${DateFormat('yyyy-MM-dd').format(date)}'),
      margin: const EdgeInsets.fromLTRB(
        AppSpace.gutter,
        0,
        AppSpace.gutter,
        8,
      ),
      padding: const EdgeInsets.symmetric(
        vertical: 12,
        horizontal: AppSpace.gutter,
      ),
      highlighted: isToday,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  weekdayLabel,
                  style: AppText.row(context).copyWith(
                    fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                    color: isToday ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                Text(dateLabel, style: meta),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.leadGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sentenceCase(summary),
                  style: muted
                      ? meta.copyWith(fontStyle: FontStyle.italic)
                      : AppText.row(
                          context,
                        ).copyWith(fontWeight: FontWeight.w600),
                ),
                if (lines.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  for (final l in lines)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        formatSessionLine(
                          l,
                          tm: maxes[mainLiftByExercise[l.exercise]],
                          bodyweight: bodyweight,
                        ),
                        style: l.top
                            ? meta.copyWith(
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              )
                            : meta,
                      ),
                    ),
                  if (hasTop && backoff != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Back-offs: $backoff', style: meta),
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

String _fmtShort(DateTime d) => DateFormat('MMM d').format(d);
