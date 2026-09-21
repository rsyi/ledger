/// Week plan screen — shows the Mon–Sun intent for one ISO week, resolved
/// via the coach intent layer (program.yaml + phase.yaml from GitHub).
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/program_current.dart';
import '../services/program_provider.dart';
import '../services/week_plan.dart';

/// Full-screen week plan view.
///
/// Fetches program.yaml and phase.yaml via [provider] (1 h cache),
/// resolves each day of the selected ISO week via [buildWeekPlan], and
/// renders a header card (block/phase summary) plus 7 day tiles. Left/right
/// chevrons navigate between weeks; the default week follows
/// [defaultWeekStart] (next week when opened on a Sunday).
class WeekPlanScreen extends StatefulWidget {
  final ProgramProvider provider;

  /// Today's date — injected so the widget is testable. Defaults to
  /// [DateTime.now] (local) at construction time.
  final DateTime today;

  const WeekPlanScreen({
    super.key,
    required this.provider,
    DateTime? today,
  }) : today = today ?? const _NowPlaceholder();

  @override
  State<WeekPlanScreen> createState() => _WeekPlanScreenState();
}

// Dart doesn't allow non-const defaults for non-const constructors the way we
// want, so we just inline the call in the State instead.
class _NowPlaceholder implements DateTime {
  const _NowPlaceholder();
  // All DateTime members — we'll never actually use any of them; the State
  // replaces this with a real value immediately.
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _WeekPlanScreenState extends State<WeekPlanScreen> {
  late DateTime _weekStart; // Monday of the displayed week
  late Future<_PlanData?> _load;

  @override
  void initState() {
    super.initState();
    // Use real DateTime.now() as the effective "today" (the _NowPlaceholder
    // trick keeps the constructor const-compatible; real callers pass today).
    final today = widget.today is _NowPlaceholder ? DateTime.now() : widget.today;
    _weekStart = defaultWeekStart(today);
    _load = _fetchPlan();
  }

  Future<_PlanData?> _fetchPlan() async {
    try {
      final docs = await widget.provider.load();
      return _PlanData(docs: docs);
    } catch (_) {
      return null;
    }
  }

  void _shiftWeek(int weeks) {
    setState(() {
      _weekStart = _weekStart.add(Duration(days: 7 * weeks));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Week plan'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous week',
            onPressed: () => _shiftWeek(-1),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next week',
            onPressed: () => _shiftWeek(1),
          ),
        ],
      ),
      body: FutureBuilder<_PlanData?>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final planData = snap.data;
          if (planData == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Program data unavailable — check GitHub config.'),
              ),
            );
          }
          return _WeekView(
            planData: planData,
            weekStart: _weekStart,
            today: widget.today is _NowPlaceholder
                ? DateTime.now()
                : widget.today,
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Internal data holder
// ---------------------------------------------------------------------------

class _PlanData {
  final IntentDocs docs;
  _PlanData({required this.docs});
}

// ---------------------------------------------------------------------------
// Week view (synchronous once data is loaded)
// ---------------------------------------------------------------------------

class _WeekView extends StatelessWidget {
  final _PlanData planData;
  final DateTime weekStart;
  final DateTime today;

  const _WeekView({
    required this.planData,
    required this.weekStart,
    required this.today,
  });

  @override
  Widget build(BuildContext context) {
    final docs = planData.docs;
    final program = docs.program;

    if (program == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'No program found. Push coach/program.yaml to the schemas repo.'),
        ),
      );
    }

    final phase = docs.phase;
    final week = buildWeekPlan(program, phase, weekStart);

    // Header info from a representative slice (use any non-null slice in week).
    ProgramSlice? repSlice;
    for (final d in week) {
      if (d.slice != null) {
        repSlice = d.slice;
        break;
      }
    }

    final todayUtc = DateTime.utc(today.year, today.month, today.day);

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        _HeaderCard(
          weekStart: weekStart,
          slice: repSlice,
          phaseYaml: phase,
        ),
        const SizedBox(height: 12),
        for (final day in week)
          _DayTile(
            day: day,
            isToday: day.date == todayUtc,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header card
// ---------------------------------------------------------------------------

class _HeaderCard extends StatelessWidget {
  final DateTime weekStart;
  final ProgramSlice? slice;
  final Map<Object?, Object?>? phaseYaml;

  const _HeaderCard({
    required this.weekStart,
    required this.slice,
    required this.phaseYaml,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final weekEnd = weekStart.add(const Duration(days: 6));
    final dateRange =
        '${_fmtShort(weekStart)} – ${_fmtShort(weekEnd)}';

    // Week N of the year (ISO).
    final weekN = _isoWeekNumber(weekStart);

    String? blockLine;
    String? weekTypeLine;
    String? phaseLine;

    if (slice != null) {
      final s = slice!;
      final blockN = s.block['number'];
      final emphasis = s.block['emphasis']?.toString() ?? '';
      final targetWt = s.block['target_weight'];
      final targetWtStr = targetWt is List && targetWt.length == 2
          ? '${targetWt[0]}→${targetWt[1]} lb'
          : '';
      blockLine =
          'Block $blockN · $emphasis${targetWtStr.isNotEmpty ? ' · $targetWtStr' : ''}  (week ${s.weekInBlock} in block)';
      weekTypeLine = s.weekType;
    }

    // Phase value + target weight.
    final phaseVersion =
        phaseYaml != null ? currentVersion(phaseYaml!) : null;
    if (phaseVersion != null) {
      final value = phaseVersion['value']?.toString() ?? '';
      final targetWt = phaseVersion['target_weight_lb'];
      phaseLine = 'Phase: $value'
          '${targetWt != null ? ' · target $targetWt lb' : ''}';
    }

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    dateRange,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  'Week $weekN',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
            if (weekTypeLine != null) ...[
              const SizedBox(height: 6),
              _WeekTypeBadge(type: weekTypeLine),
            ],
            if (blockLine != null) ...[
              const SizedBox(height: 6),
              Text(
                blockLine,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            if (phaseLine != null) ...[
              const SizedBox(height: 4),
              Text(
                phaseLine,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
            if (slice == null) ...[
              const SizedBox(height: 6),
              Text(
                'No program for this week',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Week-type badge (colored for light/test)
// ---------------------------------------------------------------------------

class _WeekTypeBadge extends StatelessWidget {
  final String type;
  const _WeekTypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    switch (type) {
      case 'light':
        bg = scheme.tertiaryContainer;
        fg = scheme.onTertiaryContainer;
      case 'test':
        bg = scheme.secondaryContainer;
        fg = scheme.onSecondaryContainer;
      default: // normal
        bg = scheme.surfaceContainerLow;
        fg = scheme.onSurfaceVariant;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        type,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Day tile
// ---------------------------------------------------------------------------

class _DayTile extends StatelessWidget {
  final DayPlan day;
  final bool isToday;

  const _DayTile({required this.day, required this.isToday});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slice = day.slice;
    final date = day.date;

    final weekdayLabel = DateFormat('EEEE').format(date); // e.g. Monday
    final dateLabel = DateFormat('MMM d').format(date); // e.g. Sep 21

    final morning = slice?.todayTemplate['morning']?.toString().trim();
    final afternoon = slice?.todayTemplate['afternoon']?.toString().trim();
    final hasContent =
        (morning != null && morning.isNotEmpty) ||
        (afternoon != null && afternoon.isNotEmpty);

    Widget content;
    if (slice == null) {
      content = Text(
        'No program',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
      );
    } else if (!hasContent) {
      content = Text(
        'Off',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (morning != null && morning.isNotEmpty)
            _SessionLine(label: 'AM', text: morning),
          if (afternoon != null && afternoon.isNotEmpty)
            _SessionLine(label: 'PM', text: afternoon),
        ],
      );
    }

    return Material(
      color: isToday
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left column: weekday + date
            SizedBox(
              width: 52,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    weekdayLabel.substring(0, 3), // Mon, Tue, …
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontWeight:
                              isToday ? FontWeight.w700 : FontWeight.w500,
                          color: isToday
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                  ),
                  Text(
                    dateLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

class _SessionLine extends StatelessWidget {
  final String label; // 'AM' or 'PM'
  final String text;

  const _SessionLine({required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _fmtShort(DateTime d) => DateFormat('MMM d').format(d);

/// ISO week number (1–53).
int _isoWeekNumber(DateTime d) {
  // ISO week: week containing the first Thursday of the year is week 1.
  final thursday = d.add(Duration(days: 4 - d.weekday));
  final firstDayOfYear = DateTime.utc(thursday.year, 1, 1);
  final dayOfYear = thursday.difference(firstDayOfYear).inDays;
  return dayOfYear ~/ 7 + 1;
}
