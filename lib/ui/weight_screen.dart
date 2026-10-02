/// WEIGHT page (IA restructure 2026-10-02): opened from the Progress
/// tab's Weight row. Everything the old Plan tab said about bodyweight,
/// in one place:
///
///   * the phase VERDICT — declared phase vs what the scale did (the
///     same check the Weight row's status chip carries);
///   * the BODYWEIGHT trajectory — observed daily weigh-ins + 7-day
///     average, then the single-trajectory projection;
///   * the NUTRITION card — Macrofactor intake → adaptive maintenance →
///     the projected rate, with the calorie what-if stepper (the lever
///     for weight);
///   * BODY COMPOSITION — the projected body-fat line;
///   * ABOUT THIS PHASE — the reason + exit criteria (the target figure
///     is no longer a headline anywhere).
library;

import 'package:flutter/material.dart';

import '../services/program_current.dart';
import '../services/program_observed.dart';
import 'design/design.dart';
import 'plan_data.dart';
import 'widgets/forecast_section.dart';
import 'widgets/plan_sections.dart';

class WeightScreen extends StatelessWidget {
  final PlanSources sources;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  /// Test hook: the forecast's Monte Carlo runner (unused on this page's
  /// focus, kept for parity with the Strength page).
  final Sim2McRunner? mcRunner;

  const WeightScreen({
    super.key,
    required this.sources,
    this.today,
    this.mcRunner,
  });

  @override
  Widget build(BuildContext context) {
    final now = today ?? DateTime.now();
    return PlanDataPage(
      title: 'Weight',
      sources: sources,
      today: now,
      build: (context, data) => weightPageSections(
        context,
        data,
        now,
        mcRunner: mcRunner,
      ),
    );
  }
}

/// The Weight page body (exposed for tests).
List<Widget> weightPageSections(
  BuildContext context,
  PlanData data,
  DateTime today, {
  Sim2McRunner? mcRunner,
}) {
  final phaseVersion = currentVersion(data.docs.phase);
  final phase = phaseVersion?['value']?.toString();
  final targetRate = (phaseVersion?['target_rate_lb_per_week'] as num?)
      ?.toDouble();
  final stats = observedWeightStats(data.daily, today);
  final verdict = phase == null
      ? null
      : phaseVerdict(
          phase: phase,
          targetRateLbWk: targetRate,
          recentRates: stats.recentRates,
          bw3wkChange: stats.bw3wkChange,
        );
  const gutter = EdgeInsets.symmetric(horizontal: AppSpace.gutter);
  return [
    SectionHeader(label: 'Verdict', count: phaseHeaderMeta(phaseVersion)),
    Padding(
      padding: gutter,
      child: PhaseVerdictCard(
        key: const ValueKey('weight-verdict'),
        phase: phase,
        targetRate: targetRate,
        verdict: verdict,
        stats: stats,
      ),
    ),
    if (data.forecast != null)
      ForecastSection(
        inputs: data.forecast!,
        today: today,
        focus: ForecastFocus.weight,
        mcRunner: mcRunner ?? sim2IsolateMcRunner,
      )
    else ...[
      const SectionHeader(label: 'Bodyweight'),
      forecastUnavailableCard(context, data),
    ],
    if (phaseVersion != null &&
        ((phaseVersion['reason']?.toString().trim().isNotEmpty ?? false) ||
            (phaseVersion['exit_criteria']?.toString().trim().isNotEmpty ??
                false))) ...[
      const SectionHeader(label: 'About this phase'),
      Padding(
        padding: gutter,
        child: PhaseNotesCard(phaseVersion: phaseVersion),
      ),
    ],
  ];
}
