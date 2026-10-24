import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/home_synthesis.dart' show fmtLb;
import '../../services/wilks.dart';
import '../design/design.dart';

/// The strength header's "Wilks · est. total" breakdown (2026-10-23,
/// user: "click on my powerlifting total and my wilks to be able to see
/// what those values come from and from what dates, and what my
/// estimated one rep max is for each one of those exercises").
///
/// Renders a [StrengthTotalBreakdown] — the SAME object the header chips
/// are computed from (domain_metrics.dart strengthTotalOf), so the sheet
/// can never disagree with the header. Per SBD lift: the estimate, its
/// source set (tap → that day in the timeline, row highlighted), the
/// lookback window; then the sum, the bodyweight + coefficient, and how
/// the RPE-adjusted e1RM works.
Future<void> showStrengthTotalSheet(
  BuildContext context, {
  required StrengthTotalBreakdown breakdown,
  Map<String, Map<String, Object?>> recordsById = const {},
  void Function(LiftEstimate lift)? onOpenSet,
}) {
  return showDetailSheet(
    context: context,
    title: 'Wilks · est. total',
    subtitle:
        'Squat + bench + deadlift — overhead press is not part of '
        'a powerlifting total',
    body: StrengthTotalBody(
      breakdown: breakdown,
      recordsById: recordsById,
      onOpenSet: onOpenSet,
    ),
  );
}

/// Display rounding of the total, identical to the header's `pl_total`
/// chip (`lb` unit).
String fmtTotalLbs(double v) => '${fmtLb(v.roundToDouble())} lb';

/// Display rounding of the Wilks score, identical to the header chip.
String fmtWilks(double v) => v.toStringAsFixed(1);

const _liftNames = {'squat': 'Squat', 'bench': 'Bench', 'deadlift': 'Deadlift'};

/// Sheet body (exposed for tests).
class StrengthTotalBody extends StatelessWidget {
  final StrengthTotalBreakdown breakdown;

  /// Source records by id — for the belted/paused flags on each set.
  final Map<String, Map<String, Object?>> recordsById;

  /// Opens a lift's source set; null = rows not tappable. The sheet
  /// closes first.
  final void Function(LiftEstimate lift)? onOpenSet;

  const StrengthTotalBody({
    super.key,
    required this.breakdown,
    this.recordsById = const {},
    this.onOpenSet,
  });

  static final _day = DateFormat('EEE MMM d');
  static final _md = DateFormat('MMM d');

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// Per-lift integers that sum EXACTLY to the rounded total (largest
  /// remainder) — three independently rounded lifts can miss the
  /// header's total by 1 lb.
  static List<int> _displayParts(List<double> exact) {
    final total = exact.fold<double>(0, (a, b) => a + b).round();
    final parts = [for (final e in exact) e.floor()];
    var diff = total - parts.fold<int>(0, (a, b) => a + b);
    final order = List.generate(exact.length, (i) => i)
      ..sort(
        (a, b) => (exact[b] - exact[b].floor()).compareTo(
          exact[a] - exact[a].floor(),
        ),
      );
    for (var k = 0; diff > 0 && k < order.length; k++, diff--) {
      parts[order[k]]++;
    }
    return parts;
  }

  String _flags(LiftEstimate l) {
    final rec = l.source.id == null ? null : recordsById[l.source.id];
    bool? flag(String k) => rec?[k] is bool ? rec![k] as bool : null;
    final belted = flag('belted');
    final paused = flag('paused');
    return [
      if (belted == true) 'belted',
      if (belted == false) 'beltless',
      if (paused == true) 'paused',
      if (paused == false) 'touch-and-go',
    ].map((s) => ' · $s').join();
  }

  @override
  Widget build(BuildContext context) {
    final b = breakdown;
    final meta = AppText.meta(context);
    final rowStyle = AppText.row(context);
    final parts = _displayParts([for (final l in b.lifts) l.e1rmLbs]);
    final total = b.totalLbs;

    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(text.toUpperCase(), style: AppText.section(context)),
    );

    Widget line(String text, {Key? key, TextStyle? style}) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(text, key: key, style: style ?? meta),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Headline: the two header numbers.
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            for (final (name, key, value) in [
              (
                'Wilks',
                'strength-total-wilks',
                b.wilks == null ? '—' : fmtWilks(b.wilks!),
              ),
              (
                'est. total',
                'strength-total-total',
                total == null ? '—' : fmtTotalLbs(total),
              ),
            ])
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('$name ', style: meta),
                  Text(
                    value,
                    key: ValueKey(key),
                    style: AppText.title(context),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: AppSpace.sectionGap),
        label('Estimated 1RM per lift'),
        for (final (i, l) in b.lifts.indexed)
          InkWell(
            key: ValueKey('strength-total-${l.lift}'),
            onTap: onOpenSet == null || l.source.id == null
                ? null
                : () {
                    Navigator.of(context).pop();
                    onOpenSet!(l);
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_liftNames[l.lift]}  ${parts[i]} lb est. 1RM',
                          style: rowStyle,
                        ),
                        line(
                          'from ${_n(l.source.weight)}×${l.source.reps}'
                          '${l.source.rpe == null ? ' (no RPE)' : ' @ RPE ${_n(l.source.rpe!)}'}'
                          '${_flags(l)} · ${_day.format(l.source.date)}',
                        ),
                        line(
                          'window: ${_md.format(l.windowStart)} – '
                          '${_md.format(l.windowEnd)}, best set of the latest '
                          'trained week'
                          '${l.carried ? ' (carried — not trained this week)' : ''}',
                        ),
                      ],
                    ),
                  ),
                  if (onOpenSet != null && l.source.id != null)
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                ],
              ),
            ),
          ),
        for (final m in b.missing)
          line('${_liftNames[m]} — no working sets yet', style: meta),
        const SizedBox(height: AppSpace.sectionGap),
        label('Total'),
        line(
          total == null
              ? 'No squat/bench/deadlift working sets yet.'
              : '${parts.join(' + ')} = ${fmtTotalLbs(total)}'
                    '${b.missing.isEmpty ? '' : ' (missing: ${b.missing.join(', ')})'}',
          style: rowStyle,
        ),
        const SizedBox(height: AppSpace.sectionGap),
        label('Bodyweight + Wilks'),
        if (b.bodyweightLbs == null)
          line('No weigh-ins yet — Wilks needs a bodyweight.')
        else ...[
          line(
            'Bodyweight ${b.bodyweightLbs!.toStringAsFixed(1)} lb — average '
            'of ${b.bwCount} weigh-in${b.bwCount == 1 ? '' : 's'}, '
            '${_md.format(b.bwFirst!)}'
            '${b.bwLast == b.bwFirst ? '' : ' – ${_md.format(b.bwLast!)}'}'
            ' (week of ${_md.format(b.bwWeekStart!)}'
            '${b.bwCarried ? ', carried — no weigh-ins this week' : ''})',
            style: rowStyle,
          ),
          line(
            'WILKS-2020 coefficient ${b.coeff!.toStringAsFixed(4)} at '
            '${(b.bodyweightLbs! * kgPerLb).toStringAsFixed(1)} kg',
          ),
          if (b.wilks != null)
            line(
              '${(total! * kgPerLb).toStringAsFixed(1)} kg × '
              '${b.coeff!.toStringAsFixed(4)} = ${fmtWilks(b.wilks!)}',
            )
          else
            line('Wilks needs all three lifts.'),
        ],
        const SizedBox(height: AppSpace.sectionGap),
        line(
          'Estimated 1RM = RPE-adjusted e1RM: Epley on reps + reps in '
          'reserve (10 − RPE), capped at 12 — 275×5 @ RPE 8.5 counts as '
          '6.5 reps → 275 × (1 + 6.5/30) ≈ 335. No RPE → plain Epley. '
          'Warm-ups excluded.',
        ),
      ],
    );
  }
}
