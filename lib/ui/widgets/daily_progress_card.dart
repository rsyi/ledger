import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/view_schema.dart';
import '../../services/analytics_engine.dart';
import '../../services/bodyweight_cache.dart';
import '../../services/daily_macros.dart';
import '../../services/domain_config.dart' show DomainConfigProvider;
import '../../services/goals_service.dart' show GoalConfig, parseGoals;
import '../../services/home_synthesis.dart' show asNum;
import '../../services/nutrition_model.dart'
    show buildNutritionForecast, mealRowsFromRecords;
import '../../services/phase_eigenvectors.dart' show effectivePhaseKey;
import '../../services/program_current.dart'
    show currentVersion, programCurrent;
import '../../services/program_metrics.dart' show WeightRow;
import '../../services/program_observed.dart' show observedWeightStats;
import '../../services/program_provider.dart' show IntentDocs, ProgramProvider;
import '../../services/warehouse_connector.dart';
import '../../services/weight_series.dart' show loadDailyWeighIns;
import '../../services/wilks.dart' show contemporaneousBodyweightLbs;
import 'skeleton.dart';

/// The Today tab's hero: today's intake as calorie + macro progress bars.
///
/// Day-scale tracking — protein/carbs/fat against the phase targets and
/// calories against the adaptive maintenance estimate. Resolution mirrors
/// the Week tab's goals (protein per-lb priced on 7-day bodyweight, carbs
/// floor + calorie mode from the goal config, maintenance from the
/// nutrition model); this surface shows them for TODAY instead of the
/// week.
class DailyProgressCard extends StatefulWidget {
  final ProgramProvider? provider;
  final DomainConfigProvider? dashboards;
  final AnalyticsEngine? analytics;
  final ViewSchema? mealsView;
  final WarehouseConnector? mealsRepo;
  final ViewSchema? weightView;
  final WarehouseConnector? weightRepo;

  /// The day to show (date-only).
  final DateTime date;

  const DailyProgressCard({
    super.key,
    required this.provider,
    required this.dashboards,
    required this.analytics,
    required this.mealsView,
    required this.mealsRepo,
    required this.weightView,
    required this.weightRepo,
    required this.date,
  });

  @override
  DailyProgressCardState createState() => DailyProgressCardState();
}

/// Prefs key for a user-set maintenance override. Macrofactor has no API
/// and exports only intake (not expenditure) to Health Connect, so the
/// app can't read MF's maintenance — the model estimates it from intake
/// vs weight trend. This lets the user pin the number when they know it.
const String kMaintenanceOverrideKey = 'daily_maintenance_override_kcal';

class DailyProgressCardState extends State<DailyProgressCard> {
  late Future<List<MacroBar>?> _future;

  /// The maintenance value actually used for the calorie bar (override if
  /// set, else the model estimate) — surfaced in the edit dialog.
  double? _maintenanceUsed;
  bool _maintenanceIsOverride = false;

  @override
  void initState() {
    super.initState();
    _future = _compute();
  }

  @override
  void didUpdateWidget(DailyProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final a = oldWidget.date, b = widget.date;
    if (a.year != b.year || a.month != b.month || a.day != b.day) reload();
  }

  /// Re-reads meals/weight/targets (pull-to-refresh, log events, day change).
  void reload() => setState(() => _future = _compute());

  Future<void> _editMaintenance() async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getDouble(kMaintenanceOverrideKey);
    final controller = TextEditingController(
      text: (current ?? _maintenanceUsed)?.round().toString() ?? '',
    );
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Maintenance calories'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set your maintenance (TDEE) in kcal. The cut goal is to eat '
              'below this — the bar is green while under. Leave blank to use '
              'the app\'s estimate from your intake and weight trend.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                suffixText: 'kcal',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'clear'),
            child: const Text('Use estimate'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (result == 'clear' || result.isEmpty) {
      await prefs.remove(kMaintenanceOverrideKey);
    } else {
      final v = double.tryParse(result);
      if (v != null && v > 0) await prefs.setDouble(kMaintenanceOverrideKey, v);
    }
    reload();
  }

  Future<List<Map<String, Object?>>> _rows(
      WarehouseConnector? repo, ViewSchema? view) async {
    if (repo == null || view == null) return const [];
    try {
      return await repo.list(view);
    } catch (_) {
      return const [];
    }
  }

  Future<T?> _guard<T>(Future<T?> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }

  static DateTime? _date(Object? v) {
    if (v is DateTime) return v;
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }

  Future<List<MacroBar>?> _compute() async {
    final dayStart =
        DateTime(widget.date.year, widget.date.month, widget.date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    // --- today's intake + the full meals list (for maintenance) ---
    final mealRecords = await _rows(widget.mealsRepo, widget.mealsView);
    double pEaten = 0, cEaten = 0, fEaten = 0, kEaten = 0;
    for (final r in mealRecords) {
      final d = _date(r['eaten_at']);
      if (d == null || d.isBefore(dayStart) || !d.isBefore(dayEnd)) continue;
      pEaten += asNum(r['protein_g']) ?? 0;
      cEaten += asNum(r['carbs_g']) ?? 0;
      fEaten += asNum(r['fat_g']) ?? 0;
      kEaten += asNum(r['calories']) ?? 0;
    }

    // --- bodyweight (prices per-lb protein) + maintenance ---
    final weights = widget.weightView == null
        ? null
        : await _guard(() async => loadDailyWeighIns(
              analytics: widget.analytics,
              view: widget.weightView,
              repo: widget.weightRepo,
            ));
    final daily = weights?.daily ?? const <WeightRow>[];
    final bw = observedWeightStats(daily, dayStart).bw7dAvg ??
        contemporaneousBodyweightLbs(daily, dayStart);
    BodyweightCache.update(bw); // feeds the strength form's auto-fill
    final forecast = buildNutritionForecast(
      meals: mealRowsFromRecords(mealRecords),
      weighIns: daily,
      today: dayStart,
    );
    final prefs = await SharedPreferences.getInstance();
    final override = prefs.getDouble(kMaintenanceOverrideKey);
    final maintenance = override ?? forecast.maintenance?.kcal;
    _maintenanceUsed = maintenance;
    _maintenanceIsOverride = override != null;

    // --- phase targets: protein band + carbs floor + calorie mode from
    // the goal config; fat floor / recomp carb band from the slice ---
    double? proteinFloor, carbsFloor, fatMin;
    String? calorieMode;
    final raw = await _guard(() async => widget.dashboards?.loadRaw());
    final byPhase = parseGoals(raw);
    final IntentDocs? docs =
        await _guard(() async => widget.provider?.load());
    final phase = currentVersion(docs?.phase)?['value']?.toString();
    final version = currentVersion(docs?.program);
    if (byPhase != null && phase != null) {
      final phaseKey = effectivePhaseKey(
        phase,
        variant: version?['variant']?.toString(),
        available: byPhase.keys,
      );
      for (final g in byPhase[phaseKey] ?? const <GoalConfig>[]) {
        if (g.id == 'macros') {
          // Aim for the TOP of the protein band (the user targets a full
          // 1 g/lb, not the 0.8 floor); resolve the cut's per-lb band
          // against 7-day bodyweight.
          final abs = g.proteinGDay;
          final perLb = g.proteinGPerLb;
          if (abs != null && abs.isNotEmpty) {
            proteinFloor = abs.last;
          } else if (perLb != null && perLb.isNotEmpty && bw != null && bw > 0) {
            proteinFloor = perLb.last * bw;
          }
          carbsFloor = g.carbsFloorGDay;
        } else if (g.id == 'calorie_band') {
          calorieMode = g.calorieMode;
        }
      }
    }
    if (docs?.program != null) {
      final slice = programCurrent(docs!.program!, docs.phase, dayStart);
      final fv = slice?.targetsInForce['fat_g_day_min'];
      if (fv is num) fatMin = fv.toDouble();
      if (carbsFloor == null) {
        final cv = slice?.targetsInForce['carbs_g_day'];
        if (cv is List && cv.isNotEmpty && cv.first is num) {
          carbsFloor = (cv.first as num).toDouble();
        }
      }
    }

    return buildDailyMacros(
      proteinEaten: pEaten,
      proteinFloor: proteinFloor,
      carbsEaten: cEaten,
      carbsFloor: carbsFloor,
      fatEaten: fEaten,
      fatMin: fatMin,
      kcalEaten: kEaten,
      maintenanceKcal: maintenance,
      calorieMode: calorieMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MacroBar>?>(
      future: _future,
      builder: (context, snap) {
        final scheme = Theme.of(context).colorScheme;
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: CardSkeleton(bars: [
              (width: double.infinity, height: 12),
              (width: double.infinity, height: 12),
              (width: double.infinity, height: 12),
              (width: double.infinity, height: 12),
            ]),
          );
        } else {
          final bars = snap.data ?? const <MacroBar>[];
          body = Column(
            children: [
              for (final b in bars) ...[
                _MacroBarRow(
                  bar: b,
                  // The calorie reference (maintenance) is tappable to
                  // override — the only editable target.
                  onEdit: b.label == 'Calories' ? _editMaintenance : null,
                  isOverride: b.label == 'Calories' && _maintenanceIsOverride,
                ),
                if (b != bars.last) const SizedBox(height: 10),
              ],
            ],
          );
        }
        return Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: body,
          ),
        );
      },
    );
  }
}

class _MacroBarRow extends StatelessWidget {
  final MacroBar bar;
  final VoidCallback? onEdit;
  final bool isOverride;
  const _MacroBarRow({required this.bar, this.onEdit, this.isOverride = false});

  String _fmt(double v) {
    final n = v.round();
    if (n < 1000) return '$n';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (fill, textColor) = switch (bar.state) {
      MacroState.good => (scheme.primary, scheme.onSurface),
      MacroState.high => (scheme.error, scheme.error),
      MacroState.low => (scheme.tertiary, scheme.onSurface),
      MacroState.none => (scheme.outline, scheme.onSurfaceVariant),
    };
    // 'under maint' reads as the cut goal (eat below maintenance); the
    // ~ marks it as an estimate unless the user pinned it (• set).
    final maintTag = isOverride ? ' set' : '';
    final trailing = bar.target == null
        ? '${_fmt(bar.current)} ${bar.unit}'
        : bar.unit == 'kcal'
            ? '${_fmt(bar.current)} / ${isOverride ? '' : '~'}'
                '${_fmt(bar.target!)}$maintTag'
            : '${_fmt(bar.current)} / ${_fmt(bar.target!)} ${bar.unit}';
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 58,
          child: Text(
            bar.label,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurface),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: bar.fraction,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(fill),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 112,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  trailing,
                  textAlign: TextAlign.right,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: textColor),
                ),
              ),
              if (onEdit != null)
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Icon(Icons.edit_outlined,
                      size: 13, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ],
    );
    if (onEdit == null) return row;
    return InkWell(onTap: onEdit, child: row);
  }
}
