/// Plan sections shared by the Progress tab and the Weight page (IA
/// restructure 2026-10-02 — the Plan tab folded into Progress): the
/// program BLOCK timeline with the you-are-here marker, the phase
/// verdict (declared vs observed), and the phase notes (reason + exit
/// criteria). Pure layout over intent-doc maps; no loading.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/display_names.dart' show sentenceCase;
import '../../services/program_current.dart';
import '../../services/program_observed.dart';
import '../../services/projection_snapshot.dart' show ProjectionMetric;
import '../../services/projection_tracking.dart';
import '../design/design.dart';

/// "Cut · since Oct 6, 2025" — the PHASE SectionHeader's count.
String? phaseHeaderMeta(Map<Object?, Object?>? phaseVersion) {
  final p = phaseVersion;
  if (p == null) return null;
  final value = p['value']?.toString();
  final since = p['effective_from']?.toString();
  return [
    if (value != null && value.isNotEmpty) sentenceCase(value),
    if (since != null) 'since ${_fmtIso(since)}',
  ].join(' · ');
}

/// "You are here · week 2 of 12" (+ " · light week" off-normal weeks).
String youAreHereLine({
  required int weekInBlock,
  required int? totalWeeks,
  required String weekType,
}) =>
    'You are here · week $weekInBlock'
    '${totalWeeks != null && totalWeeks > 0 ? ' of $totalWeeks' : ''}'
    '${weekType != 'normal' ? ' · $weekType week' : ''}';

/// The program blocks as rows in one card ("Block 0 · Cut", dates,
/// weight range), past blocks checked, the current block marked in the
/// app accent with "You are here · week N of M" + a block-progress bar.
///
/// FROZEN PROJECTIONS (2026-10-02): with [projections], the current
/// block's row adds its headline bodyweight tracking ("Bodyweight: 0.4 lb
/// ahead of projection"), a past block's row adds its one-line result
/// ("Cut: 163 → 155.8 vs projected 154; strength −1.5% vs projected
/// −3%"), and every block with a frozen snapshot opens [onOpenBlock].
class BlockTimeline extends StatelessWidget {
  final Map<Object?, Object?>? programVersion;
  final ProgramSlice? slice;
  final DateTime today;
  final PhaseProjections? projections;
  final void Function(int block)? onOpenBlock;

  const BlockTimeline({
    super.key,
    required this.programVersion,
    required this.slice,
    required this.today,
    this.projections,
    this.onOpenBlock,
  });

  @override
  Widget build(BuildContext context) {
    final blocks = programVersion?['blocks'];
    if (blocks is! List) return const SizedBox.shrink();
    final currentN = slice?.block['number'] as int?;
    return RowGroupCard(
      margin: EdgeInsets.zero,
      rows: [
        for (final b in blocks)
          if (b is Map) _blockRow(context, b, currentN),
      ],
    );
  }

  Widget _blockRow(BuildContext context, Map b, int? currentN) {
    final scheme = Theme.of(context).colorScheme;
    final n = b['n'] as int?;
    final isCurrent = n != null && n == currentN;
    final emphasis = b['emphasis']?.toString() ?? '';
    final dates = b['dates'] as List?;
    final weights = b['weight'] as List?;
    final start = dates != null ? DateTime.tryParse(dates[0].toString()) : null;
    final end = dates != null ? DateTime.tryParse(dates[1].toString()) : null;
    final fmt = DateFormat("MMM d ''yy");
    final dateStr = start != null && end != null
        ? '${fmt.format(start)} – ${fmt.format(end)}'
        : '';
    final wtStr = weights != null && weights.length == 2
        ? '${weights[0]}→${weights[1]} lb'
        : '';
    final todayD = DateTime(today.year, today.month, today.day);
    final past =
        !isCurrent &&
        end != null &&
        DateTime(end.year, end.month, end.day).isBefore(todayD);

    // Block progress for the you-are-here marker.
    double? progress;
    int? totalWeeks;
    if (isCurrent && start != null && end != null) {
      final s0 = DateTime(start.year, start.month, start.day);
      final total = DateTime(end.year, end.month, end.day)
              .difference(s0)
              .inDays +
          1;
      final done = todayD.difference(s0).inDays + 1;
      if (total > 0) {
        progress = (done / total).clamp(0.0, 1.0);
        totalWeeks = (total / 7).ceil();
      }
    }

    final meta = AppText.meta(context);
    final snapshot = n == null ? null : projections?.byBlock[n];
    String? trackingText;
    String? resultText;
    if (snapshot != null && isCurrent) {
      final t = projections!.track(n, ProjectionMetric.bodyweight, todayD);
      if (t != null && t.status != TrackingStatus.noData) {
        trackingText = 'Bodyweight: ${t.line}';
      }
    } else if (snapshot != null && past) {
      final endD = DateTime(end.year, end.month, end.day);
      resultText = blockResultLine(
        snapshot,
        projections!.actualsAt(endD),
        endD,
      );
    }
    final subtitle = isCurrent
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(dateStr),
              Text(
                youAreHereLine(
                  weekInBlock: slice?.weekInBlock ?? 1,
                  totalWeeks: totalWeeks,
                  weekType: slice?.weekType ?? 'normal',
                ),
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (trackingText != null)
                Text(
                  trackingText,
                  key: ValueKey('plan-block-tracking-$n'),
                ),
              if (progress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      color: scheme.primary,
                      backgroundColor: scheme.primary.withValues(alpha: 0.15),
                    ),
                  ),
                ),
            ],
          )
        : (resultText == null
              ? Text(dateStr)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(dateStr),
                    Text(
                      resultText,
                      key: ValueKey('plan-block-result-$n'),
                      maxLines: 2,
                    ),
                  ],
                ));

    return ExerciseRow(
      key: ValueKey('plan-block-$n'),
      onTap: snapshot != null && onOpenBlock != null
          ? () => onOpenBlock!(n!)
          : null,
      name: 'Block $n · ${sentenceCase(emphasis)}',
      status: past ? ItemStatus.done : ItemStatus.pending,
      leading: isCurrent
          ? Icon(Icons.radio_button_checked, size: 18, color: scheme.primary)
          : null,
      subtitle: subtitle,
      trailing: wtStr.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(wtStr, style: meta),
            ),
    );
  }
}

/// The declared phase vs what the scale did: a status-coloured verdict
/// title + "Declared cut (target −0.75 lb/week) · observed … over 3
/// weeks". The Weight page's weight-verdict text.
class PhaseVerdictCard extends StatelessWidget {
  final String? phase;
  final double? targetRate;
  final PhaseVerdict? verdict;
  final ObservedWeightStats stats;

  const PhaseVerdictCard({
    super.key,
    required this.phase,
    required this.targetRate,
    required this.verdict,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final v = verdict;
    if (phase == null || v == null) {
      return AppCard(
        child: Text(
          'No declared phase — nothing to compare against.',
          style: AppText.meta(context),
        ),
      );
    }

    // Shared status palette: green agree, amber drift, red only for a
    // real mismatch, muted when unknown.
    final (status, icon) = switch (v.state) {
      VerdictState.agree => (ItemStatus.done, Icons.check_circle_outline),
      VerdictState.drift => (ItemStatus.partial, Icons.warning_amber_outlined),
      VerdictState.mismatch => (ItemStatus.problem, Icons.error_outline),
      VerdictState.unknown => (ItemStatus.muted, Icons.help_outline),
    };
    final fg = StatusColors.of(context).forStatus(context, status);

    final declared =
        'Declared $phase'
        '${targetRate != null ? ' (target ${_fmtSigned(targetRate!)} lb/week)' : ''}';
    final observed = v.observedRateLbWk == null
        ? 'no observed rate yet'
        : 'observed ${_fmtSigned(v.observedRateLbWk!)} lb/week over 3 weeks';

    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 22),
          const SizedBox(width: AppSpace.leadGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sentenceCase(v.label),
                  style: AppText.title(context).copyWith(color: fg),
                ),
                const SizedBox(height: 4),
                Text('$declared · $observed', style: AppText.meta(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The phase's reason + exit criteria as one quiet card (the Weight
/// page's "About this phase"; the target figure is deliberately NOT
/// repeated as a headline — the user dropped it from the surface).
class PhaseNotesCard extends StatelessWidget {
  final Map<Object?, Object?>? phaseVersion;

  const PhaseNotesCard({super.key, required this.phaseVersion});

  @override
  Widget build(BuildContext context) {
    final p = phaseVersion;
    final reason = p?['reason']?.toString().trim();
    final exit = p?['exit_criteria']?.toString().trim();
    final meta = AppText.meta(context);
    final lines = <Widget>[
      if (reason != null && reason.isNotEmpty)
        Text(reason, key: const ValueKey('phase-reason'), style: meta),
      if (exit != null && exit.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Exit: $exit',
            key: const ValueKey('phase-exit'),
            style: meta,
          ),
        ),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
    );
  }
}

/// Signed with a true minus sign: `+0.25`, `−0.75`.
String _fmtSigned(double v) =>
    '${v > 0 ? '+' : (v < 0 ? '−' : '')}${v.abs().toStringAsFixed(2)}';

String _fmtIso(String iso) {
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat('MMM d, yyyy').format(d);
}
