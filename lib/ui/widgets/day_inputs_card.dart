import 'package:flutter/material.dart';

import '../../services/day_inputs.dart';
import '../../services/program_current.dart';
import '../../services/program_provider.dart';

/// The Today tab's day-scale INPUT surface: what the program prescribes
/// today and tomorrow. Input metrics are only legible at short timescales
/// (did I do today's session; what's coming tomorrow), so they lead the
/// Today tab; week-scale inputs live on the Week tab and outputs on
/// Progress.
///
/// Resolves each date's `ProgramSlice.todayTemplate` through
/// [programCurrent] and renders it via the pure [summarizeDayInputs].
class DayInputsCard extends StatefulWidget {
  /// Intent-docs provider — supplies the parsed program/phase YAML. Null
  /// when GitHub config is absent; the card then renders nothing.
  final ProgramProvider? provider;

  const DayInputsCard({super.key, required this.provider});

  @override
  DayInputsCardState createState() => DayInputsCardState();
}

class DayInputsCardState extends State<DayInputsCard> {
  late Future<List<DayInputSummary>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// Rebuilds from fresh program docs (pull-to-refresh / tab return).
  void reload() => setState(() => _future = _load());

  Future<List<DayInputSummary>> _load() async {
    final provider = widget.provider;
    if (provider == null) return const [];
    final docs = await provider.load();
    final program = docs.program;
    if (program == null) return const [];
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return [
      summarizeDayInputs(
        label: 'Today',
        weekday: weekdayAbbr(today),
        template: programCurrent(program, docs.phase, today)?.todayTemplate,
      ),
      summarizeDayInputs(
        label: 'Tomorrow',
        weekday: weekdayAbbr(tomorrow),
        template: programCurrent(program, docs.phase, tomorrow)?.todayTemplate,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<DayInputSummary>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _DayInputsSkeleton();
        }
        final days = snap.data ?? const <DayInputSummary>[];
        if (days.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Card(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ON THE PLAN',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 0.8,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < days.length; i++) ...[
                  if (i > 0) const Divider(height: 20),
                  _DayRow(day: days[i]),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DayRow extends StatelessWidget {
  final DayInputSummary day;
  const _DayRow({required this.day});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              day.label,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(day.weekday, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            if (day.isRest) ...[
              const Spacer(),
              Text('Rest', style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
            ],
          ],
        ),
        if (day.blockNote != null) ...[
          const SizedBox(height: 2),
          Text(day.blockNote!, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        ],
        if (day.morning != null) _ProseLine(tag: 'AM', text: day.morning!),
        if (day.afternoon != null) _ProseLine(tag: 'PM', text: day.afternoon!),
      ],
    );
  }
}

class _ProseLine extends StatelessWidget {
  final String tag;
  final String text;
  const _ProseLine({required this.tag, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Text(
              tag,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _DayInputsSkeleton extends StatelessWidget {
  const _DayInputsSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Card(
      margin: EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: SizedBox(
        height: 96,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
