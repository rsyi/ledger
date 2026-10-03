import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/coach_proposal.dart';
import '../../services/app_settings.dart' show effectiveWeekStartDay;
import '../../services/coach_proposal_store.dart';
import '../../services/program_moves.dart' show isAllowedMove;
import '../../services/week_start.dart';

/// In-bubble card for a `kind=proposal` coach message. Pure
/// presentation — the chat screen owns PlanStore writes, state
/// persistence, and navigation.
class CoachProposalCard extends StatelessWidget {
  final CoachProposal proposal;

  /// Null = pending (no action taken on this device yet).
  final CoachProposalStatus? status;

  /// Disables buttons while a schedule/undo write is in flight.
  final bool busy;

  final VoidCallback onSchedule;
  final VoidCallback onUndo;
  final VoidCallback onDismiss;

  const CoachProposalCard({
    super.key,
    required this.proposal,
    required this.status,
    required this.busy,
    required this.onSchedule,
    required this.onUndo,
    required this.onDismiss,
  });

  static String _entryLine(Map<String, Object?> e) {
    final parts = <String>[];
    for (final v in e.values) {
      final s = v?.toString().trim();
      if (s == null || s.isEmpty) continue;
      parts.add(s);
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dateLabel = DateFormat('EEE, MMM d').format(proposal.date);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_note, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$dateLabel · ${proposal.view}',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          if (proposal.template != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                proposal.template!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          const SizedBox(height: 6),
          for (final e in proposal.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('• ${_entryLine(e)}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 6),
          _ProposalFooter(
            status: status,
            busy: busy,
            onSchedule: onSchedule,
            onUndo: onUndo,
            onDismiss: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// Shared Schedule / Undo / Not now footer for proposal cards.
class _ProposalFooter extends StatelessWidget {
  final CoachProposalStatus? status;
  final bool busy;

  /// False disables Schedule (Not now / Undo stay live).
  final bool canSchedule;
  final VoidCallback onSchedule;
  final VoidCallback onUndo;
  final VoidCallback onDismiss;

  const _ProposalFooter({
    required this.status,
    required this.busy,
    this.canSchedule = true,
    required this.onSchedule,
    required this.onUndo,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case null:
        return Row(
          children: [
            FilledButton(
              onPressed: busy || !canSchedule ? null : onSchedule,
              child: const Text('Schedule'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: busy ? null : onDismiss,
              child: const Text('Not now'),
            ),
          ],
        );
      case CoachProposalStatus.scheduled:
        return Row(
          children: [
            Icon(Icons.check_circle, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            const Text('Scheduled'),
            const Spacer(),
            TextButton(
              onPressed: busy ? null : onUndo,
              child: const Text('Undo'),
            ),
          ],
        );
      case CoachProposalStatus.undone:
      case CoachProposalStatus.dismissed:
        return Row(
          children: [
            Text(
              status == CoachProposalStatus.undone ? 'Undone' : 'Dismissed',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            TextButton(
              onPressed: busy || !canSchedule ? null : onSchedule,
              child: const Text('Schedule again'),
            ),
          ],
        );
    }
  }
}

/// In-bubble card for a `kind=proposal` coach message carrying a
/// [MovesProposal] — "Bench heavy: Wed 9/30 → Fri 10/2" lines. Pure
/// presentation; the chat screen writes the `program_moves` rows.
class MovesProposalCard extends StatelessWidget {
  final MovesProposal proposal;
  final CoachProposalStatus? status;
  final bool busy;

  /// False when this build has no writable `program_moves` view —
  /// Schedule is disabled and a hint explains why.
  final bool canSchedule;

  final VoidCallback onSchedule;
  final VoidCallback onUndo;
  final VoidCallback onDismiss;

  /// Today (local). When set, a stale proposal — a move into a past day
  /// or outside today's configured week — gets Schedule disabled with
  /// [staleReason]. Null skips the check.
  final DateTime? today;

  const MovesProposalCard({
    super.key,
    required this.proposal,
    required this.status,
    required this.busy,
    required this.canSchedule,
    required this.onSchedule,
    required this.onUndo,
    required this.onDismiss,
    this.today,
  });

  static final _day = DateFormat('EEE M/d');

  /// Why [p] can no longer be scheduled on [today] (null = it can): a
  /// move the resolver would ignore in today's CONFIGURED week
  /// ([weekStartDay], week_start.dart) — its target outside the week, or
  /// its from day neither in the week nor a ≤7-day pull-forward from
  /// next week — or targeting a day before today (the item would be
  /// missed again at once).
  static String? staleReason(MovesProposal p, DateTime today,
      {int? weekStartDay}) {
    final ws = weekStartDay ?? effectiveWeekStartDay(null);
    final t = DateTime(today.year, today.month, today.day);
    final mon = weekStartOf(t, ws);
    final sun = weekEndOf(t, ws);
    bool inWeek(DateTime d) => !d.isBefore(mon) && !d.isAfter(sun);
    bool fromOk(ProposedMove m) =>
        inWeek(m.from) ||
        (m.from.isAfter(sun) && isAllowedMove(m.from, m.to, weekStartDay: ws));
    if (p.moves.any((m) => !inWeek(m.to) || !fromOk(m))) {
      return 'Expired — this proposal is for another week.';
    }
    if (p.moves.any((m) => m.to.isBefore(t))) {
      return 'Expired — a move targets a past day.';
    }
    return null;
  }

  static String moveLine(ProposedMove m) =>
      '${m.item}: ${_day.format(m.from)} → ${_day.format(m.to)}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final day = today;
    final stale = day == null ? null : staleReason(proposal, day);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.swap_horiz, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Move program items',
                  style: text.labelLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final m in proposal.moves)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(moveLine(m), style: text.bodySmall),
                  if (m.note.isNotEmpty)
                    Text(
                      m.note,
                      style: text.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          _ProposalFooter(
            status: status,
            busy: busy,
            canSchedule: canSchedule && stale == null,
            onSchedule: onSchedule,
            onUndo: onUndo,
            onDismiss: onDismiss,
          ),
          if (canSchedule &&
              stale != null &&
              status != CoachProposalStatus.scheduled)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                stale,
                style: text.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          if (!canSchedule && status != CoachProposalStatus.scheduled)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Moves unavailable in this build (no program_moves view).',
                style: text.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}
