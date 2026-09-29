/// Program screen — THE ROUTINE (tab split, 2026-09-28): this week's
/// periodized template rendered from program.yaml (v12 `routine:` base
/// week + phase overrides) and the live working maxes.
///
/// Replaces/absorbs the old Week Plan screen — one routine surface, not
/// two. Per day: the template prose (AM/PM), the planner's structured
/// session rows (mains priced off TM × wave pct / chart, accessories
/// off the double-progression suggestions), and the §4 prescription
/// block for heavy lifts with the backoff_rule annotation. The
/// working-maxes card (configuration — the one part that writes) sits
/// at the bottom. Phases + forecast/sim live on the Plan tab
/// (plan_screen.dart), not here.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/view_schema.dart';
import '../services/program_current.dart';
import '../services/program_metrics.dart'
    show StrengthRow, liftReferencesAsOf, mainLiftByExercise;
import '../services/program_provider.dart';
import '../services/sheets_repository.dart' show Record;
import '../services/warehouse_connector.dart';
import '../services/week_plan.dart';
import '../services/week_planner.dart' show buildWeekPlannedEntries;
import '../services/wm_store.dart';
import '../services/wm_tabs.dart';
import '../services/working_max.dart';
import 'widgets/working_max_card.dart';

/// Full-screen routine view (the Program surface).
///
/// Fetches program.yaml/phase.yaml via [provider] (1 h cache), the
/// working-max tabs via [wmStore], and the strength history via
/// [strengthRepo] (references + accessory double-progression). Left/
/// right chevrons navigate weeks; the default week follows
/// [defaultWeekStart] (next week when opened on the week's last day).
class ProgramScreen extends StatefulWidget {
  final ProgramProvider provider;

  /// Working-max tab reader; null hides prescriptions + the WM card.
  final WmStore? wmStore;

  /// Strength history for accessory suggestions + reference e1rms.
  /// Null → mains still price off the TM; accessories stay weightless.
  final WarehouseConnector? strengthRepo;
  final ViewSchema? strengthView;

  /// Injected for tests; defaults to DateTime.now().
  final DateTime? today;

  const ProgramScreen({
    super.key,
    required this.provider,
    this.wmStore,
    this.strengthRepo,
    this.strengthView,
    this.today,
  });

  @override
  State<ProgramScreen> createState() => _ProgramScreenState();
}

class _RoutineData {
  final IntentDocs docs;
  final WmSnapshot? wm;
  final List<StrengthRow> history;
  const _RoutineData({required this.docs, this.wm, this.history = const []});
}

class _ProgramScreenState extends State<ProgramScreen> {
  late final DateTime _today;
  late DateTime _weekStart; // Monday of the displayed week
  late Future<_RoutineData?> _load;

  @override
  void initState() {
    super.initState();
    _today = widget.today ?? DateTime.now();
    _weekStart = defaultWeekStart(_today);
    _load = _fetch();
  }

  Future<_RoutineData?> _fetch() async {
    try {
      final docs = await widget.provider.load();
      final wm = await widget.wmStore?.snapshot();
      var history = const <StrengthRow>[];
      if (widget.strengthRepo != null && widget.strengthView != null) {
        try {
          final recs = await widget.strengthRepo!.list(widget.strengthView!);
          history = [for (final r in recs) ?_strengthRow(r)];
        } catch (_) {}
      }
      return _RoutineData(docs: docs, wm: wm, history: history);
    } catch (_) {
      return null;
    }
  }

  Future<void> _refresh() async {
    ProgramProvider.clearCache();
    final next = _fetch();
    setState(() => _load = next);
    await next;
  }

  void _shiftWeek(int weeks) => setState(() {
        _weekStart = _weekStart.add(Duration(days: 7 * weeks));
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Program'),
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
      body: FutureBuilder<_RoutineData?>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          if (data == null || data.docs.program == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Program data unavailable — check GitHub config.'),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: _RoutineView(
              data: data,
              weekStart: _weekStart,
              today: _today,
              wmStore: widget.wmStore,
            ),
          );
        },
      ),
    );
  }

  static StrengthRow? _strengthRow(Record r) {
    final rawDate = r['date'];
    final date = rawDate is DateTime
        ? rawDate
        : DateTime.tryParse(rawDate?.toString() ?? '');
    final exercise = r['exercise']?.toString();
    if (date == null || exercise == null || exercise.isEmpty) return null;
    num? numOf(Object? v) => v is num ? v : num.tryParse(v?.toString() ?? '');
    final weight = numOf(r['weight']);
    final reps = numOf(r['reps']);
    if (weight == null || reps == null) return null;
    return StrengthRow(
      date: date,
      exercise: exercise,
      weight: weight.toDouble(),
      reps: reps.round(),
      rpe: numOf(r['rpe'])?.toDouble(),
      notes: r['notes']?.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// Week view
// ---------------------------------------------------------------------------

/// One lift's §4 prescription for a day tile.
class _LiftRx {
  final Prescription rx;
  final String variant;
  final bool unconfirmed;

  /// Wave-prescribed top reps (v10 strength_wave / v11 cut wave).
  final int? waveTopReps;
  final String? backoffNote;
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

/// One grouped session line: `sets` identical sets of an exercise.
class _SessionLine {
  final String exercise;
  final int sets;
  final num reps;
  final num? weight;
  final bool top;
  const _SessionLine({
    required this.exercise,
    required this.sets,
    required this.reps,
    this.weight,
    this.top = false,
  });
}

class _RoutineView extends StatelessWidget {
  final _RoutineData data;
  final DateTime weekStart;
  final DateTime today;
  final WmStore? wmStore;

  const _RoutineView({
    required this.data,
    required this.weekStart,
    required this.today,
    required this.wmStore,
  });

  @override
  Widget build(BuildContext context) {
    final program = data.docs.program!;
    final phase = data.docs.phase;
    final version = currentVersion(program);
    final week = buildWeekPlan(program, phase, weekStart);

    ProgramSlice? repSlice;
    for (final d in week) {
      if (d.slice != null) {
        repSlice = d.slice;
        break;
      }
    }

    // Weight inputs: working maxes + caps (TM path), reference e1rms
    // (fallback), accessory history (double progression).
    final wm = data.wm;
    final maxes =
        wm == null ? const <String, double>{} : currentWorkingMaxesByLift(wm.workingMax);
    final policies = version == null ? const <LoadPolicy>[] : loadPolicies(version);
    final sliceByDay = {for (final d in week) d.date: d.slice};
    LoadPolicy? policyOn(DateTime d) {
      if (policies.isEmpty) return null;
      final slice = sliceByDay[DateTime.utc(d.year, d.month, d.day)] ??
          programCurrent(program, phase, d);
      return policyForDate(
        policies,
        date: d,
        block: slice?.block['number'] as int?,
        weekType: slice?.weekType,
      );
    }

    final caps = wm == null
        ? const <String, double>{}
        : activeCapsByLift(wm, policyOn);
    final references = liftReferencesAsOf(data.history, today);

    final entries = buildWeekPlannedEntries(
      program,
      weekStart,
      references: references,
      workingMaxes: maxes,
      capRpeByLift: caps,
      accessoryHistory: data.history,
    );
    final linesByDay = _groupSessionLines(entries);
    final rxByDay = _prescriptionsByDay(version, entries, week, policyOn);

    final todayUtc = DateTime.utc(today.year, today.month, today.day);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        _HeaderCard(
          weekStart: weekStart,
          slice: repSlice,
          phaseYaml: phase,
          version: version,
        ),
        const SizedBox(height: 12),
        for (final day in week)
          _DayTile(
            day: day,
            isToday: day.date == todayUtc,
            lines: linesByDay[day.date] ?? const [],
            prescriptions: rxByDay[day.date] ?? const [],
          ),
        if (wmStore != null) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Text(
              'WORKING MAXES',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: WorkingMaxCard(store: wmStore!),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  /// Groups the planner's one-row-per-set output into per-day session
  /// lines: consecutive identical (exercise, reps, weight, top) rows
  /// merge into `N × reps @ weight`.
  Map<DateTime, List<_SessionLine>> _groupSessionLines(
    List<Map<String, Object?>> entries,
  ) {
    final out = <DateTime, List<_SessionLine>>{};
    for (final e in entries) {
      final date = e['date'] as DateTime;
      final exercise = e['exercise'] as String;
      final reps = e['reps'] as num;
      final weight = e['weight'] as num?;
      final top = e['top'] == true;
      final lines = out[date] ??= [];
      final last = lines.isEmpty ? null : lines.last;
      if (last != null &&
          last.exercise == exercise &&
          last.reps == reps &&
          last.weight == weight &&
          last.top == top) {
        lines[lines.length - 1] = _SessionLine(
          exercise: exercise,
          sets: last.sets + 1,
          reps: reps,
          weight: weight,
          top: top,
        );
      } else {
        lines.add(_SessionLine(
          exercise: exercise,
          sets: 1,
          reps: reps,
          weight: weight,
          top: top,
        ));
      }
    }
    return out;
  }

  /// §4 prescriptions for the week's heavy days (wave-aware; same math
  /// as the coach context's next_prescriptions).
  Map<DateTime, List<_LiftRx>> _prescriptionsByDay(
    Map<Object?, Object?>? version,
    List<Map<String, Object?>> entries,
    List<DayPlan> week,
    LoadPolicy? Function(DateTime) policyOn,
  ) {
    final wm = data.wm;
    if (wm == null || wm.workingMax.isEmpty || version == null) {
      return const {};
    }
    final maxes = currentWorkingMaxesByLift(wm.workingMax);
    final caps = activeCapsByLift(wm, policyOn);
    final sliceByDay = {for (final d in week) d.date: d.slice};

    // Heavy lifts per day: a planned wave top (`top: true`) or a top
    // single (legacy block-0 shape).
    final heavy = <DateTime, Set<String>>{};
    for (final e in entries) {
      if (e['top'] != true && e['reps'] != 1) continue;
      final lift = mainLiftByExercise[e['exercise']];
      if (lift == null) continue;
      (heavy[e['date'] as DateTime] ??= {}).add(lift);
    }

    // v11/v12 backoff_rule → one shared annotation for wave-day blocks.
    String? backoffNote;
    final br = version['backoff_rule'];
    if (br is Map) {
      final drop = br['drop_pct'];
      final dropStr = drop is List ? drop.join('–') : '$drop';
      backoffNote = 'Back-offs/volume per the session rows — hold while '
          'RPE ≤ ${br['hold_if_rpe_lte']}; drop $dropStr% next set if '
          'above (${br['purpose']})';
    }

    final out = <DateTime, List<_LiftRx>>{};
    heavy.forEach((day, lifts) {
      final slice = sliceByDay[day];
      final policy = policyOn(day);
      if (policy == null) return;
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
// Header card — week + block + WAVE STATE
// ---------------------------------------------------------------------------

class _HeaderCard extends StatelessWidget {
  final DateTime weekStart;
  final ProgramSlice? slice;
  final Map<Object?, Object?>? phaseYaml;
  final Map<Object?, Object?>? version;

  const _HeaderCard({
    required this.weekStart,
    required this.slice,
    required this.phaseYaml,
    required this.version,
  });

  /// The wave-state line for the displayed week: the cut wave's
  /// calendar week (5/4/3/deload @ %TM) or the post-cut block wave's
  /// prescribed top reps. Null pre-wave.
  String? _waveLine() {
    final s = slice;
    if (s == null || version == null) return null;
    final blockN = s.block['number'] as int?;
    final cut = strengthWaveCutFor(version, blockN: blockN, day: weekStart);
    if (cut != null) {
      final pct = (cut.pct * 100).round();
      return cut.deload
          ? 'Cut wave week ${cut.week} of 4 — DELOAD: top 1×${cut.reps} '
              '@ ~$pct% TM, non-top volume halved'
          : 'Cut wave week ${cut.week} of 4 — top 1×${cut.reps} @ $pct% TM '
              '(RPE 7–8)';
    }
    final reps = strengthWaveTopReps(
      version,
      blockN: blockN,
      weekInBlock: s.weekInBlock,
      weekType: s.weekType,
    );
    if (reps == null) return null;
    return switch (s.weekType) {
      'light' => 'Wave deload (light week) — top 1×$reps at the RPE-6 cap, '
          'volume halved',
      'test' => 'Test week — the block-result single (1×1 @ RPE 8), '
          'volume halved',
      _ => 'Strength wave — top 1×$reps @ RPE 7–8 this week',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final weekEnd = weekStart.add(const Duration(days: 6));
    final dateRange = '${_fmtShort(weekStart)} – ${_fmtShort(weekEnd)}';

    String? blockLine;
    String? weekTypeLine;
    String? phaseLine;
    if (slice != null) {
      final s = slice!;
      final blockN = s.block['number'];
      final emphasis = s.block['emphasis']?.toString() ?? '';
      blockLine =
          'Block $blockN · $emphasis · week ${s.weekInBlock} in block';
      weekTypeLine = s.weekType;
    }
    final phaseVersion = phaseYaml != null ? currentVersion(phaseYaml!) : null;
    if (phaseVersion != null) {
      final value = phaseVersion['value']?.toString() ?? '';
      phaseLine = 'Phase: $value';
    }
    final wave = _waveLine();

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
                if (weekTypeLine != null && weekTypeLine != 'normal')
                  _WeekTypeBadge(type: weekTypeLine),
              ],
            ),
            if (blockLine != null) ...[
              const SizedBox(height: 6),
              Text(
                '$blockLine${phaseLine != null ? ' · $phaseLine' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
            if (wave != null) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  wave,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
      default:
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
// Day tile — prose + session rows + Rx blocks
// ---------------------------------------------------------------------------

class _DayTile extends StatelessWidget {
  final DayPlan day;
  final bool isToday;
  final List<_SessionLine> lines;
  final List<_LiftRx> prescriptions;

  const _DayTile({
    required this.day,
    required this.isToday,
    this.lines = const [],
    this.prescriptions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slice = day.slice;
    final date = day.date;

    final weekdayLabel = DateFormat('EEEE').format(date);
    final dateLabel = DateFormat('MMM d').format(date);

    final morning = slice?.todayTemplate['morning']?.toString().trim();
    final afternoon = slice?.todayTemplate['afternoon']?.toString().trim();
    final hasContent = (morning != null && morning.isNotEmpty) ||
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
            _ProseLine(label: 'AM', text: morning),
          if (afternoon != null && afternoon.isNotEmpty)
            _ProseLine(label: 'PM', text: afternoon),
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
            SizedBox(
              width: 52,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    weekdayLabel.substring(0, 3),
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
                  if (lines.isNotEmpty) _SessionCard(lines: lines),
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

/// The day's structured session: one line per exercise segment with
/// prescribed sets × reps and the priced load (TM math for mains,
/// double-progression suggestions for accessories, blank = log by
/// feel / no history).
class _SessionCard extends StatelessWidget {
  final List<_SessionLine> lines;
  const _SessionCard({required this.lines});

  static String _n(num v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

    // Merge warm-up segments of an exercise into one compact line:
    // consecutive segments of the same exercise render together.
    final rows = <Widget>[];
    String? currentExercise;
    final buffer = <String>[];
    var bufferHasTop = false;
    void flush() {
      if (currentExercise == null) return;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Text(
                currentExercise,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight:
                          bufferHasTop ? FontWeight.w600 : FontWeight.w400,
                    ),
              ),
            ),
            Expanded(
              flex: 6,
              child: Text(
                buffer.join(' · '),
                textAlign: TextAlign.right,
                style: small?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight:
                      bufferHasTop ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ));
      buffer.clear();
      bufferHasTop = false;
    }

    for (final l in lines) {
      if (l.exercise != currentExercise) {
        flush();
        currentExercise = l.exercise;
      }
      final setsReps = '${l.sets}×${_n(l.reps)}';
      final w = l.weight == null ? '' : ' @ ${_n(l.weight!)}';
      buffer.add('$setsReps$w${l.top ? ' (top)' : ''}');
      if (l.top) bufferHasTop = true;
    }
    flush();

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }
}

/// One lift's §4 prescription block (wave-aware).
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
            '${p.lift} · ${p.policyName} · TM ${_n(p.workingMax)} '
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
          if (rx.backoffNote != null) Text(rx.backoffNote!, style: small),
          if (rx.readings.isNotEmpty) ...[
            const SizedBox(height: 2),
            for (final r in rx.readings) Text(_readingLine(r), style: small),
          ],
        ],
      ),
    );
  }
}

class _ProseLine extends StatelessWidget {
  final String label; // 'AM' or 'PM'
  final String text;

  const _ProseLine({required this.label, required this.text});

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

String _fmtShort(DateTime d) => DateFormat('MMM d').format(d);
