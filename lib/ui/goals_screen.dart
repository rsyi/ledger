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

import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/domain_config.dart' show DomainConfigProvider;
import '../services/goals_service.dart';
import '../services/heart_rate_service.dart';
import '../services/home_synthesis.dart' show asNum, strengthRowFromRecord;
import '../services/nutrition_model.dart'
    show buildNutritionForecast, mealRowsFromRecords;
import '../services/phase_eigenvectors.dart' show effectivePhaseKey;
import '../services/program_current.dart'
    show currentVersion, programCurrent, routineWeekFor, weekStartDayOf;
import '../services/program_metrics.dart'
    show GradedSet, StrengthRow, WeightRow, gradeSets;
import '../services/program_observed.dart' show observedWeightStats;
import '../services/program_provider.dart' show IntentDocs, ProgramProvider;
import '../services/warehouse_connector.dart';
import '../services/weight_series.dart' show loadDailyWeighIns;
import '../services/whoop_activity.dart';
import '../services/wilks.dart' show contemporaneousBodyweightLbs;
import 'app_text.dart';

/// Everything the goal rows render from — one evaluation over the
/// current accounting week.
class _GoalsData {
  final String phaseTitle;
  final List<GoalEval> goals;
  const _GoalsData({required this.phaseTitle, required this.goals});
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

    // Strength (graded main-lift sets + raw rows for the accessory check).
    final strengthRecords =
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
    return _GoalsData(phaseTitle: title, goals: weekGoals);
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
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                'This week — ${data.phaseTitle}',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            for (final g in data.goals)
              _GoalCard(goal: g, onTap: () => _openSheet(g)),
          ],
        );
      },
    );
  }

  Future<void> _openSheet(GoalEval g) async {
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
              Row(
                children: [
                  _StatusDot(status: g.status),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      g.label,
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(g.value, style: Theme.of(ctx).textTheme.titleSmall),
              if (g.detail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(g.detail, style: AppText.tag(ctx)),
              ],
              if (g.config.description != null) ...[
                const SizedBox(height: 12),
                Text(g.config.description!),
              ],
              if (g.ticks.isNotEmpty) ...[
                const SizedBox(height: 14),
                for (final t in g.ticks) _LiftDetailLine(tick: t),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

Color _statusColor(BuildContext context, GoalStatus s) {
  final scheme = Theme.of(context).colorScheme;
  return switch (s) {
    GoalStatus.met => Colors.green.shade600,
    GoalStatus.partial => Colors.amber.shade700,
    GoalStatus.unmet => scheme.error,
    GoalStatus.unknown => scheme.outline,
    GoalStatus.optional => scheme.outline,
  };
}

String _statusWord(GoalStatus s) => switch (s) {
      GoalStatus.met => 'On track',
      GoalStatus.partial => 'Getting there',
      GoalStatus.unmet => 'Off track',
      GoalStatus.unknown => 'No data',
      GoalStatus.optional => 'Nice to have',
    };

class _StatusDot extends StatelessWidget {
  final GoalStatus status;
  const _StatusDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final icon = switch (status) {
      GoalStatus.met => Icons.check_circle,
      GoalStatus.partial => Icons.timelapse,
      GoalStatus.unmet => Icons.cancel,
      GoalStatus.unknown => Icons.help_outline,
      GoalStatus.optional => Icons.radio_button_unchecked,
    };
    return Icon(icon, size: 20, color: _statusColor(context, status));
  }
}

class _GoalCard extends StatelessWidget {
  final GoalEval goal;
  final VoidCallback onTap;
  const _GoalCard({required this.goal, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, goal.status);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _StatusDot(status: goal.status),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      goal.label,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    _statusWord(goal.status),
                    style: AppText.tag(context)?.copyWith(color: color),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
              const SizedBox(height: 6),
              Text(goal.value),
              if (goal.detail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(goal.detail, style: AppText.tag(context)),
              ],
              if (goal.ticks.isNotEmpty) ...[
                const SizedBox(height: 8),
                _LiftTickRow(ticks: goal.ticks),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Per-lift hard-set progress pills for the hard_sets goal — one chip
/// per lift showing sets toward target and an accessory tick.
class _LiftTickRow extends StatelessWidget {
  final List<GoalLiftTick> ticks;
  const _LiftTickRow({required this.ticks});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final t in ticks)
          _LiftChip(tick: t),
      ],
    );
  }
}

String _liftName(String key) => switch (key) {
      'press' => 'overhead press',
      _ => key,
    };

class _LiftChip extends StatelessWidget {
  final GoalLiftTick tick;
  const _LiftChip({required this.tick});

  @override
  Widget build(BuildContext context) {
    final done = tick.hardSets >= tick.target;
    final some = tick.hardSets > 0;
    // Grey = nothing logged yet. When the lift's routine day is still
    // ahead, say so ("· Fri") so grey reads "not trained yet", not
    // "missed" — deadlift is Friday-only, the last day of the week.
    final due = tick.pending
        ? ' · ${tick.remainingDays.map(weekdayShort).join('/')}'
        : '';
    final color = done
        ? Colors.green.shade600
        : some
            ? Colors.amber.shade700
            : Theme.of(context).colorScheme.outline;
    // Accessory tick appended when declared for the lift.
    final acc = tick.accessoriesDone;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_liftName(tick.lift)} ${tick.hardSets}/${tick.target}$due',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
          if (acc != null) ...[
            const SizedBox(width: 6),
            Icon(
              acc ? Icons.done : Icons.remove,
              size: 13,
              color: acc ? Colors.green.shade600 : color,
            ),
          ],
        ],
      ),
    );
  }
}

/// One lift's detail line in the sheet: hard sets vs target + accessory
/// state, in full words.
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
    final days = tick.pending ? tick.remainingDays : tick.scheduledDays;
    final when = days.isEmpty
        ? ''
        : tick.pending
            ? ' · due ${days.map(weekdayShort).join('/')}'
            : ' · trained ${days.map(weekdayShort).join('/')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '${_liftName(tick.lift)}: ${tick.hardSets} of ${tick.target} '
        'hard sets$when$accText',
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
      children: const [
        SizedBox(height: 120),
        Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No goals for the current phase yet.\n'
            'They appear after the next schema sync.',
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
