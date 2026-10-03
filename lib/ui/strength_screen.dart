/// STRENGTH page (IA restructure 2026-10-02): opened from the Progress
/// tab's Strength row. The strength half of the old Plan tab plus the
/// weekly Wilks breakdown that used to be a bottom sheet:
///
///   * THIS WEEK — the weekly actual-max Wilks decomposed into its three
///     lifts (each line kg × coefficient; the lines sum to the stat),
///     with the note on why it won't match the per-lift e1RMs;
///   * PROJECTION — "Staying on this program, by …" + the strength-total
///     chart with the capacity toggle;
///   * MORE PROJECTIONS — climbing, VO2 max, fatigue budget folds;
///   * MODEL DETAILS — the one provenance disclosure, at the bottom.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/home_synthesis.dart' show fmtLb;
import '../services/app_settings.dart' show effectiveWeekStartDay;
import '../services/program_metrics.dart' show StrengthRow, WeightRow;
import '../services/wilks.dart'
    show WilksLiftPart, weeklyWilksSeries, wilksWeekDecomposition;
import 'design/design.dart';
import 'plan_data.dart';
import 'widgets/forecast_section.dart';

class StrengthScreen extends StatelessWidget {
  final PlanSources sources;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  /// Test hook: the forecast's Monte Carlo runner.
  final Sim2McRunner? mcRunner;

  const StrengthScreen({
    super.key,
    required this.sources,
    this.today,
    this.mcRunner,
  });

  @override
  Widget build(BuildContext context) {
    final now = today ?? DateTime.now();
    return PlanDataPage(
      title: 'Strength',
      sources: sources,
      today: now,
      build: (context, data) => [
        WeeklyWilksCard(
          rows: data.strengthRows,
          daily: data.daily,
          weekStartDay: effectiveWeekStartDay(data.docs.program),
          today: now,
        ),
        if (data.forecast != null)
          ForecastSection(
            inputs: data.forecast!,
            today: now,
            focus: ForecastFocus.strength,
            mcRunner: mcRunner ?? sim2IsolateMcRunner,
          )
        else ...[
          const SectionHeader(label: 'Projection'),
          forecastUnavailableCard(context, data),
        ],
      ],
    );
  }
}

/// THIS WEEK: the weekly actual-max Wilks and its per-lift
/// decomposition (was the Progress strength row's detail sheet).
class WeeklyWilksCard extends StatelessWidget {
  final List<StrengthRow> rows;
  final List<WeightRow> daily;
  final int weekStartDay;
  final DateTime today;

  const WeeklyWilksCard({
    super.key,
    required this.rows,
    required this.daily,
    required this.weekStartDay,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final weeks = rows.isEmpty || daily.isEmpty
        ? null
        : weeklyWilksSeries(
            rows,
            daily,
            through: today,
            weekStartDay: weekStartDay,
          );
    final week = weeks == null || weeks.isEmpty ? null : weeks.last;
    final parts = week == null
        ? const <WilksLiftPart>[]
        : wilksWeekDecomposition(week);
    final meta = AppText.meta(context);
    final row = AppText.row(context);
    final Widget body;
    if (week == null || parts.isEmpty) {
      body = Text(
        'Not enough squat, bench and deadlift history with weigh-ins to '
        'score a week yet.',
        style: meta,
      );
    } else {
      String name(String lift) => lift[0].toUpperCase() + lift.substring(1);
      body = Column(
        key: const ValueKey('weekly-wilks'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Wilks ${week.wilks.toStringAsFixed(1)}',
            style: AppText.title(context),
          ),
          Text(
            'at ${week.bodyweightLbs.toStringAsFixed(1)} lb bodyweight '
            '(the week\'s average)',
            style: meta,
          ),
          const SizedBox(height: 8),
          for (final p in parts)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${name(p.lift)} ${fmtLb(p.weightLbs.roundToDouble())} lb'
                      '${p.carriedFrom == null ? '' : ' · carried from '
                                '${DateFormat('MMM d').format(p.carriedFrom!)}'}',
                      style: row,
                    ),
                  ),
                  Text(
                    '${p.displayPoints.toStringAsFixed(1)} points',
                    style: meta,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'The heaviest weight you actually lifted per lift this week '
            '(any reps; a lift not trained this week carries its last '
            'week), scored against bodyweight. These are actual lifts, '
            'not estimates — so they won\'t add up to the per-lift '
            'estimated maxes on the Progress tab.',
            style: meta,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(label: 'This week'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
          child: AppCard(padding: const EdgeInsets.all(12), child: body),
        ),
      ],
    );
  }
}
