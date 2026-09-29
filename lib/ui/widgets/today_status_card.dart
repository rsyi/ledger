import 'package:flutter/material.dart';

import '../../models/view_schema.dart';
import '../../services/plan_store.dart';
import '../../services/program_current.dart';
import '../../services/program_provider.dart';
import '../../services/today_status.dart';
import '../../services/warehouse_connector.dart';

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

  /// Tap handler — the shell selects the Log tab.
  final VoidCallback onOpen;

  const TodayStatusCard({
    super.key,
    required this.mealsView,
    required this.mealsRepo,
    required this.strengthView,
    required this.strengthRepo,
    required this.provider,
    required this.onOpen,
  });

  @override
  State<TodayStatusCard> createState() => TodayStatusCardState();
}

class TodayStatusCardState extends State<TodayStatusCard> {
  TodayStatus? _status;

  @override
  void initState() {
    super.initState();
    refresh();
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
                          _line(
                            context,
                            status.foodText,
                            status.foodState,
                          ),
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
