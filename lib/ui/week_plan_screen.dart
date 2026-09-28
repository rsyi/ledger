/// Week plan screen — shows the Mon–Sun intent for one ISO week, resolved
/// via the coach intent layer (program.yaml + phase.yaml from GitHub),
/// plus the §4 working-max prescription block on heavy days (top-set
/// options / back-offs / Saturday single + last readings) from the
/// append-only controller tabs via [WmStore].
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/program_current.dart';
import '../services/program_metrics.dart' show mainLiftByExercise;
import '../services/program_provider.dart';
import '../services/week_plan.dart';
import '../services/week_planner.dart' show buildWeekPlannedEntries;
import '../services/wm_store.dart';
import '../services/wm_tabs.dart';
import '../services/working_max.dart';

/// Full-screen week plan view.
///
/// Fetches program.yaml and phase.yaml via [provider] (1 h cache),
/// resolves each day of the selected ISO week via [buildWeekPlan], and
/// renders a header card (block/phase summary) plus 7 day tiles. Left/right
/// chevrons navigate between weeks; the default week follows
/// [defaultWeekStart] (next week when opened on a Sunday). When [wmStore]
/// is present, day tiles carrying a planned top single for a main lift
/// get that lift's prescription block; a failed/empty tab read simply
/// hides the blocks.
class WeekPlanScreen extends StatefulWidget {
  final ProgramProvider provider;

  /// Working-max tab reader; null hides the prescription blocks.
  final WmStore? wmStore;

  /// Today's date — injected so the widget is testable. Defaults to
  /// [DateTime.now] (local) at construction time.
  final DateTime today;

  const WeekPlanScreen({
    super.key,
    required this.provider,
    this.wmStore,
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
      // Best-effort: snapshot() itself returns null on failure.
      final wm = await widget.wmStore?.snapshot();
      return _PlanData(docs: docs, wm: wm);
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
  final WmSnapshot? wm;
  _PlanData({required this.docs, this.wm});
}

/// One lift's §4 prescription for a day tile.
class _LiftRx {
  final Prescription rx;
  final String variant;
  final bool unconfirmed;

  /// Wave-prescribed top reps (program.yaml v10 strength_wave, or the
  /// v11 cut wave on block-0 days) — null pre-wave (older programs),
  /// where the 1/2/3 options show.
  final int? waveTopReps;

  /// Back-off annotation for wave days — built from the program's
  /// structured `backoff_rule` (v11) when declared, else the v10
  /// planned-rows text.
  final String? backoffNote;

  /// Last readings for the lift (up to three, newest last).
  final List<ReadingRow> readings;

  const _LiftRx({
    required this.rx,
    required this.variant,
    required this.unconfirmed,
    required this.readings,
    this.waveTopReps,
    this.backoffNote,
  });
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
    final rxByDay = _prescriptionsByDay(program, week);

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
            prescriptions: rxByDay[day.date] ?? const [],
          ),
      ],
    );
  }

  /// §4 prescriptions for the week's heavy days: a day is "heavy" for a
  /// lift when the program plans a top single (reps == 1) for it. Weights
  /// come from the CURRENT working max via [buildPrescription]; empty when
  /// the tabs haven't been seeded, the lift has no working max, or no
  /// policy covers the date.
  Map<DateTime, List<_LiftRx>> _prescriptionsByDay(
    Map<Object?, Object?> program,
    List<DayPlan> week,
  ) {
    final wm = planData.wm;
    if (wm == null || wm.workingMax.isEmpty) return const {};
    final version = currentVersion(program);
    if (version == null) return const {};
    final policies = loadPolicies(version);
    if (policies.isEmpty) return const {};

    final maxes = currentWorkingMaxesByLift(wm.workingMax);
    LoadPolicy? policyOn(DateTime d, ProgramSlice? slice) => policyForDate(
          policies,
          date: d,
          block: slice?.block['number'] as int?,
          weekType: slice?.weekType,
        );
    final sliceByDay = {for (final d in week) d.date: d.slice};
    final caps = activeCapsByLift(
      wm,
      (d) => policyOn(d, sliceByDay[DateTime.utc(d.year, d.month, d.day)]),
    );

    // Heavy lifts per day from the planned skeleton (no weights needed).
    // A day is heavy for a lift when the program plans a wave top set
    // (`top: true`, program.yaml v10) or a top single (block 0).
    final heavy = <DateTime, Set<String>>{};
    for (final e in buildWeekPlannedEntries(program, weekStart)) {
      if (e['top'] != true && e['reps'] != 1) continue;
      final lift = mainLiftByExercise[e['exercise']];
      if (lift == null) continue;
      (heavy[e['date'] as DateTime] ??= {}).add(lift);
    }

    // v11 backoff_rule → one shared annotation for wave-day Rx blocks.
    String? backoffNote;
    final br = version['backoff_rule'];
    if (br is Map) {
      final drop = br['drop_pct'];
      final dropStr = drop is List ? drop.join('–') : '$drop';
      backoffNote = 'Back-offs/volume per planned rows — hold while '
          'RPE ≤ ${br['hold_if_rpe_lte']}; drop $dropStr% next set if '
          'above (${br['purpose']})';
    }

    final out = <DateTime, List<_LiftRx>>{};
    heavy.forEach((day, lifts) {
      final slice = sliceByDay[day];
      final policy = policyOn(day, slice);
      if (policy == null) return;
      // Wave-prescribed top reps for this week: post-cut wave first,
      // then the v11 cut wave on block-0 days (which also carries the
      // pricing pct). Null pre-wave — the 1/2/3 options remain.
      var waveReps = strengthWaveTopReps(
        version,
        blockN: slice?.block['number'] as int?,
        weekInBlock: slice?.weekInBlock ?? 0,
        weekType: slice?.weekType,
      );
      double? wavePct;
      if (waveReps == null) {
        final cut = strengthWaveCutFor(
          version,
          blockN: slice?.block['number'] as int?,
          day: day,
        );
        if (cut != null) {
          waveReps = cut.reps;
          wavePct = cut.pct;
        }
      }
      for (final lift in lifts) {
        final max = maxes[lift];
        if (max == null) continue;
        final readings = [
          for (final r in wm.readings)
            if (r.lift == lift) r,
        ]..sort((a, b) => a.date.compareTo(b.date));
        (out[day] ??= []).add(_LiftRx(
          rx: buildPrescription(
            lift: lift,
            policy: policy,
            workingMax: max,
            warmupProtocol: version['warmup_protocol'],
            activeCapRpe: caps[lift],
            topReps: waveReps,
            topPct: wavePct,
          ),
          waveTopReps: waveReps,
          backoffNote: backoffNote,
          variant: currentWorkingMax(wm.workingMax, lift)?.variant ??
              defaultVariantByLift[lift] ??
              '',
          unconfirmed: needsConfirmation(wm.workingMax, lift),
          readings: readings.length <= 3
              ? readings
              : readings.sublist(readings.length - 3),
        ));
      }
    });
    return out;
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

  /// §4 prescription blocks for the day's heavy lifts (empty = none).
  final List<_LiftRx> prescriptions;

  const _DayTile({
    required this.day,
    required this.isToday,
    this.prescriptions = const [],
  });

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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  content,
                  for (final rx in prescriptions) _RxBlock(rx: rx),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One lift's §4 prescription block: policy + working max, top-set
/// options for 1/2/3 reps, back-offs, the Saturday single where the
/// policy allows, and the last (up to three) readings with decisions.
class _RxBlock extends StatelessWidget {
  final _LiftRx rx;
  const _RxBlock({required this.rx});

  static String _n(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  static String _readingLine(ReadingRow r) {
    const moves = {'raise', 'drop', 'reset', 'manual'};
    final arrow = moves.contains(r.decision) ? '→${_n(r.wmAfter)}' : '';
    return '${DateFormat('MMM d').format(r.date)}  '
        '${_n(r.weightLb)}×${r.reps} @${_n(r.rpe)} · ${r.decision}$arrow';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = rx.rx;
    final topReps = p.topSetOptions.keys.toList()..sort();
    final tops = [
      for (final reps in topReps)
        if (p.topSetOptions[reps] != null)
          '${_n(p.topSetOptions[reps]!)}×$reps',
    ].join(' · ');
    final small = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${p.lift} · ${p.policyName} · WM ${_n(p.workingMax)} '
            '${rx.variant}${rx.unconfirmed ? ' (unconfirmed seed)' : ''}',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            rx.waveTopReps != null ? 'Top set (wave): $tops' : 'Top set: $tops',
            style: small,
          ),
          Text(
            // Wave weeks: back-offs live in the planned rows; the v11
            // backoff_rule annotation (drift guard) wins when declared
            // — the bulk-era 4×3 @ 82% line would be wrong.
            rx.waveTopReps != null
                ? (rx.backoffNote ??
                    'Back-offs: per planned rows (3-4×5-8 @ 1-3 RIR; '
                        'deadlift 2×4-6)')
                : 'Back-offs: ${p.backOffSets}×${p.backOffReps} @ '
                    '${_n(p.backOffWeight)}'
                    '${p.saturdaySingle != null ? ' · Sat single '
                        '${_n(p.saturdaySingle!)} @8.5' : ''}',
            style: small,
          ),
          if (rx.readings.isNotEmpty) ...[
            const SizedBox(height: 2),
            for (final r in rx.readings)
              Text(_readingLine(r), style: small),
          ],
        ],
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
