/// PHASE PROJECTION view (phase-projections spec 2026-10-02): one
/// block's projection, frozen at its start, against what actually
/// happened — opened from a Progress phase-timeline row. A past block
/// tracks at its last day and leads with its one-line result ("Cut: 163
/// → 155.8 vs projected 154; strength −1.5% vs projected −3%"); the
/// current block tracks today.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/display_names.dart' show sentenceCase;
import '../services/projection_snapshot.dart';
import '../services/projection_tracking.dart';
import 'design/design.dart';
import 'widgets/projection_card.dart';

class PhaseProjectionScreen extends StatelessWidget {
  final ProjectionSnapshot snapshot;
  final PhaseProjections projections;

  /// Injectable clock for tests; defaults to DateTime.now().
  final DateTime? today;

  const PhaseProjectionScreen({
    super.key,
    required this.snapshot,
    required this.projections,
    this.today,
  });

  @override
  Widget build(BuildContext context) {
    final now = today ?? DateTime.now();
    final todayD = DateTime(now.year, now.month, now.day);
    final end = snapshot.end;
    final endD = end == null ? null : DateTime(end.year, end.month, end.day);
    final past = endD != null && endD.isBefore(todayD);
    final trackDay = past ? endD : todayD;
    final result = blockResultLine(
      snapshot,
      projections.actualsAt(trackDay),
      trackDay,
    );
    final fmt = DateFormat("MMM d ''yy");
    final start = snapshot.start;
    final name =
        'Block ${snapshot.block}'
        '${snapshot.emphasis == null ? '' : ' · ${sentenceCase(snapshot.emphasis!)}'}';
    const gutter = EdgeInsets.symmetric(horizontal: AppSpace.gutter);
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SectionHeader(
            label: past ? 'Result' : 'So far',
            count: start == null || end == null
                ? null
                : '${fmt.format(start)} – ${fmt.format(end)}',
          ),
          Padding(
            padding: gutter,
            child: AppCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result ?? 'Not enough data to summarize this block yet.',
                    key: const ValueKey('phase-projection-result'),
                    style: AppText.row(context),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Against the projection frozen at the block start '
                    '(made ${DateFormat('MMM d').format(snapshot.madeAt.toLocal())}'
                    ', program v${snapshot.programVersion})'
                    '${past ? ' — tracked at the block\'s last day' : ''}.',
                    style: AppText.meta(context),
                  ),
                ],
              ),
            ),
          ),
          for (final m in ProjectionMetric.all)
            if (snapshot.metrics.containsKey(m)) ...[
              const SizedBox(height: AppSpace.sectionGap),
              Padding(
                padding: gutter,
                child: ProjectionCard(
                  metric: m,
                  snapshot: snapshot,
                  projections: projections,
                  today: now,
                  trackDay: trackDay,
                ),
              ),
            ],
        ],
      ),
    );
  }
}
