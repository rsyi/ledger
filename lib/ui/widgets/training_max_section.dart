/// Human-in-the-loop training maxes (2026-10-16 — user: "I'd like to know
/// that training maxes have been updated, rather than it happening
/// automatically … these changes are logged somewhere … in the
/// 'Progress' section").
///
///   * [TrainingMaxSection] — Progress tab: pending proposals as review
///     cards (Accept / Keep), the TM in force per lift, and the dated
///     change log with a lift filter.
///   * [TmProposalCard] — one pending proposal ("Deadlift: 340 → 360 ·
///     from 295×5 @ RPE 8.5 (est 358, median of 3 sets)"); fast-loop
///     drops carry a "recommended" chip.
///   * [TmHistoryRows] — the change log rows (also the Lift page's TM
///     history).
///   * [TmProposalPill] — Today's compact "1 training-max update to
///     review ›" pill (hidden when nothing is pending).
///
/// All state comes from the append-only working_max tab (wm_tabs.dart
/// pure helpers); Accept / Keep append rows through WmStore.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/wm_tabs.dart';
import '../../services/working_max.dart' show defaultVariantByLift;
import '../design/design.dart';

/// Accept / keep callback: (lift, proposal id) → appended?
typedef TmDecide = Future<bool> Function(String lift, String proposalId);

/// 'squat' → 'Squat', 'press' → 'Overhead press'.
String tmLiftTitle(String lift) {
  final n = lift == 'press' ? 'overhead press' : lift;
  return n[0].toUpperCase() + n.substring(1);
}

String _lb(num v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// Plain-language count for the pill / header.
String tmReviewLabel(int n) =>
    '$n training-max update${n == 1 ? '' : 's'} to review';

/// One pending proposal with Accept / Keep actions.
class TmProposalCard extends StatefulWidget {
  final WorkingMaxRow proposal;

  /// The TM in force (what Keep keeps).
  final double acceptedLb;

  final TmDecide? onAccept;
  final TmDecide? onDecline;

  /// Called after a successful decision (reload the snapshot).
  final VoidCallback? onDecided;

  const TmProposalCard({
    super.key,
    required this.proposal,
    required this.acceptedLb,
    this.onAccept,
    this.onDecline,
    this.onDecided,
  });

  @override
  State<TmProposalCard> createState() => _TmProposalCardState();
}

class _TmProposalCardState extends State<TmProposalCard> {
  bool _busy = false;

  Future<void> _run(TmDecide? fn) async {
    if (fn == null || _busy) return;
    final p = widget.proposal;
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await fn(p.lift, tmProposalIdOf(p));
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('Couldn\'t save — the proposal may have changed. '
            'Pull to refresh.'),
      ));
      return;
    }
    widget.onDecided?.call();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final up = p.valueLb > widget.acceptedLb;
    final recommended = isTmRecommended(p);
    final title = '${tmLiftTitle(p.lift)}: ${_lb(widget.acceptedLb)} → '
        '${_lb(p.valueLb)}';
    return AppCard(
      key: ValueKey('tm-proposal-${p.lift}'),
      margin: const EdgeInsets.fromLTRB(AppSpace.gutter, 0, AppSpace.gutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(up ? Icons.trending_up : Icons.trending_down, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: AppText.row(context))),
              if (recommended)
                const StatusChip(
                  label: 'recommended',
                  status: ItemStatus.partial,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${tmProposalEvidence(p)} · '
            '${DateFormat('MMM d').format(p.effectiveFrom)}',
            style: AppText.meta(context),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton(
                key: ValueKey('tm-accept-${p.lift}'),
                onPressed: _busy || widget.onAccept == null
                    ? null
                    : () => _run(widget.onAccept),
                child: Text('Accept ${_lb(p.valueLb)}'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: ValueKey('tm-keep-${p.lift}'),
                onPressed: _busy || widget.onDecline == null
                    ? null
                    : () => _run(widget.onDecline),
                child: Text('Keep ${_lb(widget.acceptedLb)}'),
              ),
              if (_busy) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// The dated change log as rows (newest first). [showLift] prefixes the
/// lift name (the all-lifts Progress view).
class TmHistoryRows extends StatelessWidget {
  final List<TmHistoryEvent> events;
  final bool showLift;

  const TmHistoryRows({
    super.key,
    required this.events,
    this.showLift = true,
  });

  static ItemStatus _status(TmHistoryEvent e) => switch (e.outcome) {
        'accepted' || 'set by you' || 'starting value' => ItemStatus.done,
        'pain cap' => ItemStatus.problem,
        _ => ItemStatus.muted,
      };

  static String _values(TmHistoryEvent e) {
    final from = e.fromLb;
    if (from == null || from == e.toLb) return '${_lb(e.toLb)} lb';
    return '${_lb(from)} → ${_lb(e.toLb)} lb';
  }

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return AppCard(
        margin: const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
        child: Text('No training-max changes yet.',
            style: AppText.meta(context)),
      );
    }
    return RowGroupCard(
      rows: [
        for (final e in events)
          ExerciseRow(
            name: showLift
                ? '${tmLiftTitle(e.lift)} ${_values(e)}'
                : _values(e),
            meta: '${DateFormat('MMM d, yyyy').format(e.date)} · '
                '${e.outcome}${e.recommended ? ' (recommended)' : ''}',
            status: _status(e),
            subtitle: e.evidence.isEmpty ? null : Text(e.evidence),
          ),
      ],
    );
  }
}

/// Progress tab: TRAINING MAXES — review cards, the TM in force, and the
/// change log filtered by lift.
class TrainingMaxSection extends StatefulWidget {
  /// The working_max + readings snapshot (WmStore.snapshot).
  final Future<WmSnapshot?> snapshot;

  final TmDecide? onAccept;
  final TmDecide? onDecline;

  /// After Accept / Keep: reload [snapshot] (the parent re-fires it).
  final VoidCallback? onDecided;

  /// Rows shown before "Show all".
  final int historyLimit;

  const TrainingMaxSection({
    super.key,
    required this.snapshot,
    this.onAccept,
    this.onDecline,
    this.onDecided,
    this.historyLimit = 8,
  });

  @override
  State<TrainingMaxSection> createState() => _TrainingMaxSectionState();
}

class _TrainingMaxSectionState extends State<TrainingMaxSection> {
  /// null = all lifts.
  String? _lift;
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<WmSnapshot?>(
      future: widget.snapshot,
      builder: (context, snap) {
        final data = snap.data;
        final pending =
            data == null ? const <WorkingMaxRow>[] : pendingTmProposals(data.workingMax);
        return Column(
          key: const ValueKey('tm-section'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SectionHeader(
              label: 'Training maxes',
              count: pending.isEmpty ? null : '${pending.length} to review',
            ),
            if (snap.connectionState != ConnectionState.done)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (data == null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpace.gutter),
                child: Text('Training maxes unavailable — pull to retry.',
                    style: AppText.meta(context)),
              )
            else
              ..._body(context, data, pending),
          ],
        );
      },
    );
  }

  List<Widget> _body(
    BuildContext context,
    WmSnapshot data,
    List<WorkingMaxRow> pending,
  ) {
    final rows = data.workingMax;
    final now = currentWorkingMaxesByLift(rows);
    final history = tmChangeHistory(rows, lift: _lift);
    final shown =
        _showAll ? history : history.take(widget.historyLimit).toList();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpace.gutter, 0, AppSpace.gutter, 8),
        child: Text(
          pending.isEmpty
              ? 'Automatic updates wait here for your OK before the program '
                  'uses them.'
              : 'Suggested from your recent top sets — nothing changes until '
                  'you accept.',
          style: AppText.meta(context),
        ),
      ),
      for (final p in pending)
        TmProposalCard(
          proposal: p,
          acceptedLb: now[p.lift] ?? p.valueLb,
          onAccept: widget.onAccept,
          onDecline: widget.onDecline,
          onDecided: widget.onDecided,
        ),
      if (now.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpace.gutter, 4, AppSpace.gutter, 8),
          child: StatStrip(items: [
            for (final lift in defaultVariantByLift.keys)
              if (now[lift] != null)
                StatItem(tmLiftTitle(lift), '${_lb(now[lift]!)} lb'),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpace.gutter, 4, AppSpace.gutter, 8),
        child: Wrap(
          spacing: AppSpace.chip,
          runSpacing: AppSpace.chip,
          children: [
            for (final lift in <String?>[null, ...defaultVariantByLift.keys])
              ChoiceChip(
                key: ValueKey('tm-filter-${lift ?? 'all'}'),
                label: Text(lift == null ? 'All' : tmLiftTitle(lift)),
                selected: _lift == lift,
                onSelected: (_) => setState(() {
                  _lift = lift;
                  _showAll = false;
                }),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
      TmHistoryRows(
        key: const ValueKey('tm-history'),
        events: shown,
        showLift: _lift == null,
      ),
      if (history.length > shown.length)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton(
              onPressed: () => setState(() => _showAll = true),
              child: Text('Show all ${history.length} changes'),
            ),
          ),
        ),
    ];
  }
}

/// Today: a compact pill shown while TM proposals await review. Tap →
/// [onOpen] (the Progress tab's TRAINING MAXES section).
class TmProposalPill extends StatefulWidget {
  /// Loads the snapshot (WmStore.snapshot). Null → hidden.
  final Future<WmSnapshot?> Function()? load;
  final VoidCallback onOpen;

  const TmProposalPill({super.key, required this.load, required this.onOpen});

  @override
  State<TmProposalPill> createState() => TmProposalPillState();
}

class TmProposalPillState extends State<TmProposalPill> {
  late Future<int> _count;

  @override
  void initState() {
    super.initState();
    _count = _fetch();
  }

  Future<int> _fetch() async {
    try {
      final snap = await widget.load?.call();
      return snap == null ? 0 : pendingTmProposals(snap.workingMax).length;
    } catch (_) {
      return 0;
    }
  }

  /// Re-reads the snapshot (tab switch / pull-to-refresh).
  void reload() => setState(() => _count = _fetch());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: _count,
      builder: (context, snap) {
        final n = snap.data ?? 0;
        if (n == 0) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpace.gutter, 4, AppSpace.gutter, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Material(
              key: const ValueKey('tm-pill'),
              color: scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: widget.onOpen,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(
                    '${tmReviewLabel(n)} ›',
                    style: TextStyle(
                      color: scheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
