/// GOALS tab — the input eigenvectors (bottom-nav Progress/Goals split
/// 2026-09-29).
///
/// The home page split into two surfaces per the output-metrics-over-
/// input-metrics principle: PROGRESS shows outputs (weight trajectory,
/// strength), GOALS shows the few causal INPUTS the user controls day to
/// day. Each goal is a plain-language row with a clear met / partial /
/// unmet state and a tap-through detail sheet.
///
/// The goal set is DECLARED in app/dashboards.yaml `phases:` →
/// `<phase>:` → `goals:`, phase-selected (cut vs recomp differ — e.g.
/// the calorie band flips deficit ↔ surplus). Pure evaluation lives in
/// services/goals_service.dart (tested); this file is layout + the data
/// fetch (the same sources the driver checklist reads).
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/domain_config.dart' show DomainConfigProvider;
import '../services/goals_service.dart';
import '../services/heart_rate_service.dart';
import '../services/home_synthesis.dart' show asNum, strengthRowFromRecord;
import '../services/muscle_volume.dart'
    show
        hypertrophyMuscleGroups,
        hypertrophyTrackedGroups,
        parseExerciseMuscleMap;
import '../services/nutrition_model.dart'
    show buildNutritionForecast, mealRowsFromRecords;
import '../services/phase_eigenvectors.dart' show effectivePhaseKey;
import '../services/program_current.dart'
    show currentVersion, programCurrent, routineWeekFor, weekStartDayOf;
import '../services/program_metrics.dart'
    show GradedSet, StrengthRow, WeightRow, gradeSets;
import '../services/program_observed.dart' show observedWeightStats;
import '../services/program_item_pricing.dart'
    show mainLiftByItem, pricedWeek;
import '../services/program_provider.dart' show IntentDocs, ProgramProvider;
import '../services/program_week.dart' show mondayOf, prescribedWeek;
import '../services/week_state_loader.dart';
import '../services/warehouse_connector.dart';
import '../services/weight_series.dart' show loadDailyWeighIns;
import '../services/whoop_activity.dart';
import '../services/wilks.dart' show contemporaneousBodyweightLbs;
import 'design/design.dart';

/// Everything the goal rows render from — one evaluation over the
/// current accounting week.
class _GoalsData {
  final String phaseTitle;
  final List<GoalEval> goals;

  /// The accounting week's first weekday (program.yaml `week_start`) —
  /// climbing / cardio / zone-2 count over it; program sets + muscle
  /// groups count over the Mon–Sun program week the header shows.
  final int weekStartDay;
  const _GoalsData({
    required this.phaseTitle,
    required this.goals,
    required this.weekStartDay,
  });
}

class GoalsScreen extends StatefulWidget {
  final ProgramProvider? provider;
  final DomainConfigProvider? dashboards;
  final AnalyticsEngine? analytics;

  final ViewSchema? weightView;
  final WarehouseConnector? weightRepo;
  final ViewSchema? strengthView;
  final WarehouseConnector? strengthRepo;
  final ViewSchema? climbingView;
  final WarehouseConnector? climbingRepo;
  final ViewSchema? mealsView;
  final WarehouseConnector? mealsRepo;
  final ViewSchema? cardioView;
  final WarehouseConnector? cardioRepo;

  /// Whoop workouts — climbing credit + the zone-2 run goal.
  final ViewSchema? workoutsView;
  final WarehouseConnector? workoutsRepo;

  /// program_moves (moves + skips) — program progress reads the
  /// EFFECTIVE week, like the program day card.
  final ViewSchema? programMovesView;
  final WarehouseConnector? programMovesRepo;

  /// Calisthenics log — credits skill items + muscle groups.
  final ViewSchema? calisthenicsView;
  final WarehouseConnector? calisthenicsRepo;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  const GoalsScreen({
    super.key,
    this.provider,
    this.dashboards,
    this.analytics,
    this.weightView,
    this.weightRepo,
    this.strengthView,
    this.strengthRepo,
    this.climbingView,
    this.climbingRepo,
    this.mealsView,
    this.mealsRepo,
    this.cardioView,
    this.cardioRepo,
    this.workoutsView,
    this.workoutsRepo,
    this.programMovesView,
    this.programMovesRepo,
    this.calisthenicsView,
    this.calisthenicsRepo,
    this.today,
  });

  @override
  State<GoalsScreen> createState() => GoalsScreenState();
}

class GoalsScreenState extends State<GoalsScreen> {
  late final DateTime _today;
  late Future<_GoalsData?> _future;

  @override
  void initState() {
    super.initState();
    _today = widget.today ?? DateTime.now();
    _future = _compute();
  }

  /// Pull-to-refresh: bust the shared dashboards-config cache + refire.
  Future<void> reload() async {
    DomainConfigProvider.clearCache();
    setState(() => _future = _compute());
    await _future;
  }

  static Future<T?> _guard<T>(Future<T?> Function() fn) async {
    try {
      return await fn();
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, Object?>>> _rows(
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

  Future<_GoalsData?> _compute() async {
    final raw = await _guard(() async => widget.dashboards?.loadRaw());
    final byPhase = parseGoals(raw);
    if (byPhase == null) return null;

    final IntentDocs? docs =
        await _guard(() async => widget.provider?.load());
    final phase = currentVersion(docs?.phase)?['value']?.toString();
    if (phase == null) return null;
    final version = currentVersion(docs?.program);
    final phaseKey = effectivePhaseKey(
      phase,
      variant: version?['variant']?.toString(),
      available: byPhase.keys,
    );
    final configs = byPhase[phaseKey];
    if (configs == null || configs.isEmpty) return null;

    final weekStartDay = weekStartDayOf(version);

    // Which weekdays the routine trains each main lift (today's block) —
    // lets a 0-set lift say "due Fri" instead of reading as missed.
    final program = docs?.program;
    final blockN = program == null
        ? null
        : programCurrent(program, docs?.phase, _today)?.block['n'];
    final liftDays = mainLiftWeekdays(
      routineWeekFor(version, blockN is num ? blockN.toInt() : null),
    );

    // The effective Mon–Sun program week + its working sets, via the
    // SAME loader the program day card uses (moves, skips, warm-up rule,
    // calisthenics) so "program sets per lift" agrees with the card.
    final provider = widget.provider;
    final WeekState? state = provider == null
        ? null
        : await _guard(() => WeekStateLoader(
              loadDocs: provider.load,
              programMovesView: widget.programMovesView,
              programMovesRepo: widget.programMovesRepo,
              strengthView: widget.strengthView,
              strengthRepo: widget.strengthRepo,
              calisthenicsView: widget.calisthenicsView,
              calisthenicsRepo: widget.calisthenicsRepo,
            ).load(_today));
    // Which main lift each prescribed item trains — the program card's
    // own priced-line matching (sets don't depend on weights, so no TM
    // read is needed here).
    var itemLifts = const <String, String>{};
    if (state != null && program != null) {
      try {
        itemLifts = mainLiftByItem(
          prescribedWeek(state.docs, _today),
          pricedWeek(program, docs?.phase, mondayOf(_today), today: _today),
        );
      } catch (_) {/* honest: name fallback */}
    }

    // Strength (graded main-lift sets + raw rows for the accessory check).
    final strengthRecords = state?.strengthRows ??
        await _rows(widget.strengthRepo, widget.strengthView);
    final strengthRows = <StrengthRow>[
      for (final r in strengthRecords) ?strengthRowFromRecord(r),
    ];
    final graded = strengthRows.isEmpty
        ? const <GradedSet>[]
        : gradeSets(strengthRows);
    final rawStrength = <({DateTime date, String exercise})>[];
    for (final r in strengthRecords) {
      final d = _date(r['date']);
      final ex = r['exercise']?.toString();
      if (d != null && ex != null && ex.isNotEmpty) {
        rawStrength.add((date: d, exercise: ex));
      }
    }

    // Weigh-ins → bodyweight + maintenance/intake (nutrition_model).
    final weights = widget.weightView == null
        ? null
        : await _guard(() async => loadDailyWeighIns(
              analytics: widget.analytics,
              view: widget.weightView,
              repo: widget.weightRepo,
            ));
    final daily = weights?.daily ?? const <WeightRow>[];
    final bw = observedWeightStats(daily, _today).bw7dAvg ??
        contemporaneousBodyweightLbs(daily, _today);

    // Meals → per-day protein / carbs / calories + the forecast summary.
    final mealRecords = await _rows(widget.mealsRepo, widget.mealsView);
    final proteinByDay = <DateTime, double>{};
    final carbsByDay = <DateTime, double>{};
    final kcalByDay = <DateTime, double>{};
    for (final r in mealRecords) {
      final d = _date(r['eaten_at']);
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      final p = asNum(r['protein_g']);
      final c = asNum(r['carbs_g']);
      final k = asNum(r['calories']);
      if (p != null) proteinByDay[day] = (proteinByDay[day] ?? 0) + p;
      if (c != null) carbsByDay[day] = (carbsByDay[day] ?? 0) + c;
      if (k != null) kcalByDay[day] = (kcalByDay[day] ?? 0) + k;
    }
    final forecast = buildNutritionForecast(
      meals: mealRowsFromRecords(mealRecords),
      weighIns: daily,
      today: _today,
    );

    // Climbing + cardio dates (cardio applies the 4x4 type filter).
    final climbingDates = <DateTime>[
      for (final r in await _rows(widget.climbingRepo, widget.climbingView))
        ?_date(r['date']),
    ];
    const fourByFourTypes = {'treadmill', 'bike', 'stairmaster'};
    final cardioDates = <DateTime>[];
    for (final r in await _rows(widget.cardioRepo, widget.cardioView)) {
      final type = r['type']?.toString().trim().toLowerCase() ?? '';
      if (type.isNotEmpty && !fourByFourTypes.contains(type)) continue;
      final d = _date(r['date']);
      if (d != null) cardioDates.add(d);
    }

    // Whoop workouts → activities (climb credit + zone-2 runs).
    final activities = whoopActivitiesFromRecords(
        await _rows(widget.workoutsRepo, widget.workoutsView));
    final maxHr = HeartRateService.instance?.maxHr.value?.toDouble();

    final goals = evaluateGoals(
      configs: configs,
      inputs: GoalInputs(
        graded: graded,
        strengthRows: rawStrength,
        proteinByDay: proteinByDay,
        carbsByDay: carbsByDay,
        kcalByDay: kcalByDay,
        bodyweightLb: bw,
        intakeKcal7d: forecast.avg7?.kcal,
        maintenanceKcal: forecast.effectiveMaintenanceKcal,
        climbingDates: climbingDates,
        cardioDates: cardioDates,
        activities: activities,
        maxHr: maxHr,
        liftDays: liftDays,
        programWeek: state?.week,
        programSkips: state?.skips.keys.toSet() ?? const {},
        itemLifts: itemLifts,
        weekWorkingSets: state?.weekSets ?? const [],
        muscleMap: parseExerciseMuscleMap(version),
        muscleGroups: hypertrophyMuscleGroups(version),
        trackedGroups: hypertrophyTrackedGroups(version),
      ),
      today: _today,
      weekStartDay: weekStartDay,
    );

    final title = phase.isEmpty
        ? phase
        : phase[0].toUpperCase() + phase.substring(1);
    // macros + calorie_band are DAY-scale inputs — they moved to the
    // Today tab's progress bars (2026-09-30). Week keeps the genuinely
    // week-scale eigenvectors (hard sets, climbing, cardio frequency).
    const dayScale = {'macros', 'calorie_band'};
    final weekGoals =
        goals.where((g) => !dayScale.contains(g.config.id)).toList();
    return _GoalsData(
      phaseTitle: title,
      goals: weekGoals,
      weekStartDay: weekStartDay,
    );
  }

  static DateTime? _date(Object? raw) => raw is DateTime
      ? raw
      : DateTime.tryParse(raw?.toString() ?? '') ??
          DateTime.tryParse((raw?.toString() ?? '').split(' ').first);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_GoalsData?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snap.data;
        if (data == null || data.goals.isEmpty) {
          return const _Placeholder();
        }
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            SectionHeader(
              label: 'This week — ${data.phaseTitle}',
              count: programWeekRange(_today),
            ),
            GoalList(
              goals: data.goals,
              onTap: (g) => _openSheet(g, data.weekStartDay),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openSheet(GoalEval g, int weekStartDay) async {
    if (!mounted) return;
    await showDetailSheet(
      context: context,
      title: g.label,
      subtitle: '${goalStatusWord(g.status)} · ${g.value}',
      body: GoalDetail(
        goal: g,
        windowNote: goalWindowNote(g, _today, weekStartDay),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Display helpers (pure — pinned by test/goals_screen_test.dart)
// ---------------------------------------------------------------------------

/// 'Mon Sep 28 – Sun Oct 4' — the Mon–Sun program week holding [today].
String programWeekRange(DateTime today) {
  final monday = DateTime(
    today.year,
    today.month,
    today.day,
  ).subtract(Duration(days: today.weekday - DateTime.monday));
  final sunday = monday.add(const Duration(days: 6));
  final f = DateFormat('EEE MMM d');
  return '${f.format(monday)} – ${f.format(sunday)}';
}

/// The counting window for goals evaluated over the ACCOUNTING week
/// (climbing, cardio, zone-2, legacy hard sets) when it isn't the Mon–Sun
/// week the header shows — e.g. 'Counted Sat Sep 26 – Fri Oct 2 (your
/// accounting week).' Null when the windows agree.
String? goalWindowNote(GoalEval g, DateTime today, int weekStartDay) {
  if (weekStartDay == DateTime.monday) return null;
  final programWeek =
      g.muscles.isNotEmpty ||
      (g.ticks.isNotEmpty && g.ticks.any((t) => t.fromProgram)) ||
      g.config.id == 'muscle_stimulus';
  if (programWeek) return null;
  final day = DateTime(today.year, today.month, today.day);
  final start = day.subtract(
    Duration(days: (day.weekday - weekStartDay + 7) % 7),
  );
  final end = start.add(const Duration(days: 6));
  final f = DateFormat('EEE MMM d');
  return 'Counted ${f.format(start)} – ${f.format(end)} '
      '(your accounting week).';
}

/// The row's one meta line. Program sets read 'done of prescribed sets'
/// (+ who is behind) — the per-lift bars carry the rest; other goals
/// show their value plus any short result detail ('1/1 run · 43 min ·
/// avg HR 122').
String goalMeta(GoalEval g) {
  if (g.ticks.isNotEmpty && g.ticks.any((t) => t.fromProgram)) {
    final done = g.ticks.fold<int>(0, (n, t) => n + t.done.clamp(0, t.target));
    final target = g.ticks.fold<int>(0, (n, t) => n + t.target);
    final behind = [
      for (final t in g.ticks)
        if (t.behind) liftDisplayName(t.lift),
    ];
    return '$done of $target sets'
        '${behind.isEmpty ? '' : ' · behind on ${behind.join(', ')}'}';
  }
  if (g.muscles.isNotEmpty ||
      g.status == GoalStatus.unknown ||
      g.detail.isEmpty ||
      g.detail == 'nice to have') {
    return g.value;
  }
  return '${g.value} · ${g.detail}';
}

ItemStatus goalItemStatus(GoalStatus s) => switch (s) {
  GoalStatus.met => ItemStatus.done,
  GoalStatus.partial => ItemStatus.partial,
  GoalStatus.unmet => ItemStatus.problem,
  GoalStatus.unknown => ItemStatus.pending,
  GoalStatus.optional => ItemStatus.pending,
};

String goalStatusWord(GoalStatus s) => switch (s) {
  GoalStatus.met => 'On track',
  GoalStatus.partial => 'Getting there',
  GoalStatus.unmet => 'Off track',
  GoalStatus.unknown => 'No data',
  GoalStatus.optional => 'Nice to have',
};

ItemStatus _liftStatus(GoalLiftTick t) => t.complete
    ? ItemStatus.done
    : t.behind
    ? ItemStatus.problem
    : t.done > 0
    ? ItemStatus.partial
    : ItemStatus.pending;

/// '4/4', '3/7 · Sat', '0/3 · Wed/Fri'.
String liftProgressText(GoalLiftTick t) {
  final due = t.dueAhead
      ? ' · ${t.remainingDays.map(weekdayShort).join('/')}'
      : '';
  return '${t.done}/${t.target}$due';
}

ItemStatus _muscleStatus(GoalMuscleRow m) => m.over
    ? ItemStatus.problem
    : m.inBand
    ? ItemStatus.done
    : m.behindPace
    ? ItemStatus.partial
    : ItemStatus.pending;

String _sets1(double v) => v.toStringAsFixed(1);

String _bandText(GoalMuscleRow m) =>
    '${m.lo.toStringAsFixed(m.lo % 1 == 0 ? 0 : 1)}–'
    '${m.hi.toStringAsFixed(m.hi % 1 == 0 ? 0 : 1)}';

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

/// All goal rows in the one card style, hairline-separated.
class GoalList extends StatelessWidget {
  final List<GoalEval> goals;
  final void Function(GoalEval) onTap;
  const GoalList({super.key, required this.goals, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final divider = Divider(
      height: 1,
      thickness: 1,
      indent: AppSpace.gutter + AppSpace.lead + AppSpace.leadGap,
      color: Theme.of(
        context,
      ).colorScheme.outlineVariant.withValues(alpha: 0.4),
    );
    return AppCard(
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < goals.length; i++) ...[
            if (i > 0) divider,
            GoalRow(goal: goals[i], onTap: () => onTap(goals[i])),
          ],
        ],
      ),
    );
  }
}

/// One goal on the Week tab, on the shared row pattern: status mark ·
/// label · meta · chevron, with compact per-lift / per-muscle bars below
/// when the goal has them. Optional goals that aren't met read a neutral
/// "Nice to have" instead of a failure.
class GoalRow extends StatelessWidget {
  final GoalEval goal;
  final VoidCallback onTap;
  const GoalRow({super.key, required this.goal, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final g = goal;
    final Widget? bars = g.ticks.isNotEmpty
        ? GoalBars(lines: [for (final t in g.ticks) GoalBarLine.lift(t)])
        : g.muscles.isNotEmpty
        ? GoalBars(lines: [for (final m in g.muscles) GoalBarLine.muscle(m)])
        : null;
    return ExerciseRow(
      name: g.label,
      meta: goalMeta(g),
      status: goalItemStatus(g.status),
      onTap: onTap,
      chips: [if (bars != null) SizedBox(width: double.infinity, child: bars)],
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (g.status == GoalStatus.optional)
            StatusChip(
              label: goalStatusWord(g.status),
              status: ItemStatus.pending,
            ),
          Icon(
            Icons.chevron_right,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// One line of a [GoalBars] table: name · thin bar · trailing figure.
class GoalBarLine {
  final String name;
  final double value;
  final double scale;

  /// Shaded target band (muscle groups' 8–12), null for none.
  final double? bandLo;
  final double? bandHi;

  final String trailing;
  final ItemStatus status;

  const GoalBarLine({
    required this.name,
    required this.value,
    required this.scale,
    required this.trailing,
    required this.status,
    this.bandLo,
    this.bandHi,
  });

  /// Program sets done / prescribed for one lift.
  factory GoalBarLine.lift(GoalLiftTick t) => GoalBarLine(
    name: liftDisplayName(t.lift),
    value: t.done.toDouble(),
    scale: (t.target > t.done ? t.target : t.done).toDouble(),
    trailing: liftProgressText(t),
    status: _liftStatus(t),
  );

  /// Sets for one muscle group against the band.
  factory GoalBarLine.muscle(GoalMuscleRow m) => GoalBarLine(
    name: muscleDisplayName(m.group),
    value: m.sets,
    scale: m.hi * 1.25 > m.sets ? m.hi * 1.25 : m.sets,
    bandLo: m.lo,
    bandHi: m.hi,
    trailing: _sets1(m.sets),
    status: _muscleStatus(m),
  );
}

/// Compact aligned bars — one dense line per lift / muscle group.
class GoalBars extends StatelessWidget {
  final List<GoalBarLine> lines;
  const GoalBars({super.key, required this.lines});

  @override
  Widget build(BuildContext context) {
    final meta = AppText.meta(context);
    final name = meta.copyWith(color: Theme.of(context).colorScheme.onSurface);
    return Table(
      // Name + figure columns size to content but are capped so the bar
      // always keeps a readable share of a phone-width row.
      columnWidths: const {
        0: MinColumnWidth(IntrinsicColumnWidth(), FractionColumnWidth(0.46)),
        1: FlexColumnWidth(),
        2: MinColumnWidth(IntrinsicColumnWidth(), FractionColumnWidth(0.3)),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (final l in lines)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 10, top: 3, bottom: 3),
                child: Text(
                  l.name,
                  style: name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _MiniBar(line: l),
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(
                  l.trailing,
                  style: meta.copyWith(
                    color: l.status == ItemStatus.pending
                        ? null
                        : StatusColors.of(context).forStatus(context, l.status),
                  ),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _MiniBar extends StatelessWidget {
  final GoalBarLine line;
  final double height;
  const _MiniBar({required this.line, this.height = 4});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = StatusColors.of(context);
    final fill = line.status == ItemStatus.pending
        ? scheme.onSurfaceVariant
        : colors.forStatus(context, line.status);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        double x(double v) =>
            line.scale <= 0 ? 0 : (v / line.scale).clamp(0.0, 1.0) * w;
        final radius = BorderRadius.circular(height / 2);
        return SizedBox(
          height: height + 4,
          width: w,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Container(
                height: height,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: radius,
                ),
              ),
              if (line.bandLo != null && line.bandHi != null)
                Positioned(
                  left: x(line.bandLo!),
                  width: x(line.bandHi!) - x(line.bandLo!),
                  top: 0,
                  bottom: 0,
                  child: Container(color: colors.done.withValues(alpha: 0.22)),
                ),
              Container(
                height: height,
                width: x(line.value),
                decoration: BoxDecoration(color: fill, borderRadius: radius),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Detail sheet body
// ---------------------------------------------------------------------------

/// The tap-through detail for one goal (the [showDetailSheet] body; the
/// sheet itself carries the label + status · value).
class GoalDetail extends StatelessWidget {
  final GoalEval goal;

  /// Counting-window note for accounting-week goals (see
  /// [goalWindowNote]).
  final String? windowNote;

  const GoalDetail({super.key, required this.goal, this.windowNote});

  @override
  Widget build(BuildContext context) {
    final g = goal;
    final meta = AppText.meta(context);
    final body = AppText.row(context).copyWith(fontWeight: FontWeight.w400);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (g.detail.isNotEmpty) Text(g.detail, style: meta),
          if (windowNote != null) ...[
            const SizedBox(height: 4),
            Text(windowNote!, style: meta),
          ],
          if (g.config.description != null) ...[
            const SizedBox(height: 10),
            Text(g.config.description!, style: body),
          ],
          if (g.ticks.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sectionGap),
            GoalBars(lines: [for (final t in g.ticks) GoalBarLine.lift(t)]),
            const SizedBox(height: 8),
            for (final t in g.ticks) _LiftDetailLine(tick: t),
          ],
          if (g.muscles.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final m in g.muscles) _MuscleDetail(row: m),
          ],
          if (g.trackedMuscles.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sectionGap),
            Text('Tracked only (no target)', style: meta),
            const SizedBox(height: 2),
            for (final m in g.trackedMuscles) _TrackedMuscleDetail(row: m),
          ],
        ],
      ),
    );
  }
}

/// One lift's detail line in the sheet, in full words.
class _LiftDetailLine extends StatelessWidget {
  final GoalLiftTick tick;
  const _LiftDetailLine({required this.tick});

  @override
  Widget build(BuildContext context) {
    final acc = tick.accessoriesDone;
    final accText = acc == null
        ? ''
        : acc
        ? ' · accessories done'
        : ' · accessories not yet';
    final String when;
    if (tick.dueAhead) {
      when = ' · still due ${tick.remainingDays.map(weekdayShort).join('/')}';
    } else if (tick.scheduledDays.isNotEmpty) {
      when = ' · trained ${tick.scheduledDays.map(weekdayShort).join('/')}';
    } else {
      when = '';
    }
    final behind = tick.behind ? ' · behind (earlier sets not logged)' : '';
    final String head;
    if (tick.fromProgram) {
      head =
          '${liftDisplayName(tick.lift)}: ${tick.done} of ${tick.target} '
          'program sets (${tick.hardSets} at RPE 7 or higher)';
    } else if (tick.done != tick.hardSets) {
      head =
          '${liftDisplayName(tick.lift)}: ${tick.done} of ${tick.target} '
          'sets (your target; ${tick.hardSets} at RPE 7 or higher)';
    } else {
      head =
          '${liftDisplayName(tick.lift)}: ${tick.hardSets} of '
          '${tick.target} hard sets';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text('$head$when$behind$accText', style: AppText.meta(context)),
    );
  }
}

/// One muscle group in the sheet: sets vs the band (bar with the band
/// shaded), its state in words, and what contributed.
class _MuscleDetail extends StatelessWidget {
  final GoalMuscleRow row;
  const _MuscleDetail({required this.row});

  @override
  Widget build(BuildContext context) {
    final status = _muscleStatus(row);
    final color = status == ItemStatus.pending
        ? Theme.of(context).colorScheme.onSurface
        : StatusColors.of(context).forStatus(context, status);
    final pace = row.behindPace ? ' · behind pace' : '';
    final from = row.contributors.isEmpty
        ? 'nothing logged yet'
        : row.contributors
              .map((e) => '${e.key} ${_sets1(e.value)}')
              .join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${muscleDisplayName(row.group)}: ${_sets1(row.sets)} sets · '
            '${row.state} (${_bandText(row)})$pace',
            style: AppText.row(context).copyWith(color: color),
          ),
          const SizedBox(height: 4),
          _MiniBar(line: GoalBarLine.muscle(row), height: 6),
          const SizedBox(height: 2),
          Text('from: $from', style: AppText.meta(context)),
        ],
      ),
    );
  }
}

/// One tracked-only muscle group in the sheet (v16 tracked_groups):
/// its sets and contributors in neutral text — no band, no bar colour,
/// never red.
class _TrackedMuscleDetail extends StatelessWidget {
  final GoalMuscleRow row;
  const _TrackedMuscleDetail({required this.row});

  @override
  Widget build(BuildContext context) {
    final from = row.contributors.isEmpty
        ? 'nothing logged yet'
        : row.contributors
              .map((e) => '${e.key} ${_sets1(e.value)}')
              .join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${muscleDisplayName(row.group)}: ${_sets1(row.sets)} sets',
            style: AppText.row(context),
          ),
          Text('from: $from', style: AppText.meta(context)),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No goals for the current phase yet.\n'
            'They appear after the next schema sync.',
            textAlign: TextAlign.center,
            style: AppText.meta(context),
          ),
        ),
      ],
    );
  }
}
