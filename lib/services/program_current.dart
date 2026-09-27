/// Program "current slice" resolver — Intent layer (coach v4).
///
/// Pure Dart, zero Flutter/IO imports. Input is the parsed YAML of
/// `coach/program.yaml` (+ optionally `coach/phase.yaml`) from
/// airledger-fitness and a date; output is the §3 program slice the
/// coach context builders inject. The TypeScript twin lives in
/// ledger-mcp `src/program.ts`; both are pinned to the shared fixtures
/// at `airledger-fitness/coach/fixtures/program_current_cases.yaml`.
library;

const List<String> _weekdayKeys = [
  'mon',
  'tue',
  'wed',
  'thu',
  'fri',
  'sat',
  'sun',
];

/// Gain-rate range for cut-emphasis blocks (lb/week). The program doc
/// only carries positive block rates; the cut target brackets the
/// phase's -0.75 lb/week.
const List<double> cutRateLbWk = [-1.0, -0.5];

/// The resolved program slice for one date (spec §3 `program` object).
class ProgramSlice {
  final String id;
  final int version;

  /// {number, emphasis, dates: [start, end], target_weight: [from, to]}
  final Map<String, Object?> block;
  final int weekInBlock;

  /// normal | light | test
  final String weekType;

  /// {weekday, morning, afternoon} (+ block_note for block-0 overrides)
  final Map<String, Object?> todayTemplate;
  final Map<String, Object?> targetsInForce;
  final List<String> rulesInForce;

  const ProgramSlice({
    required this.id,
    required this.version,
    required this.block,
    required this.weekInBlock,
    required this.weekType,
    required this.todayTemplate,
    required this.targetsInForce,
    required this.rulesInForce,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'version': version,
        'block': block,
        'week_in_block': weekInBlock,
        'week_type': weekType,
        'today_template': todayTemplate,
        'targets_in_force': targetsInForce,
        'rules_in_force': rulesInForce,
      };
}

/// Current version of a versioned intent doc ({versions: [...]}):
/// the LAST entry without `pending: true`. Null when none qualify.
Map<Object?, Object?>? currentVersion(Map<Object?, Object?>? doc) {
  final versions = doc?['versions'];
  if (versions is! List) return null;
  for (var i = versions.length - 1; i >= 0; i--) {
    final v = versions[i];
    if (v is Map && v['pending'] != true) {
      return Map<Object?, Object?>.from(v);
    }
  }
  return null;
}

DateTime _parseDay(Object? s) {
  final d = DateTime.parse(s.toString());
  return DateTime.utc(d.year, d.month, d.day);
}

const Map<String, int> _weekdayByName = {
  'monday': DateTime.monday,
  'tuesday': DateTime.tuesday,
  'wednesday': DateTime.wednesday,
  'thursday': DateTime.thursday,
  'friday': DateTime.friday,
  'saturday': DateTime.saturday,
  'sunday': DateTime.sunday,
};

/// The ACCOUNTING week's start day for a program [version] — its
/// `week_start:` key (program.yaml v7, user amendment 2026-09-22:
/// `saturday`, so weekend sessions read as getting ahead of the coming
/// week rather than catching up the old one) as a `DateTime.monday..
/// sunday` constant. Absent / unrecognized / null version → Monday
/// (ISO weeks, the pre-v7 behavior).
///
/// Scope: weekly ROLLUP keying only (metrics, flags, live this-week,
/// planner window, weekly Wilks stat). Program STRUCTURE — block
/// boundaries, week_in_block, week_type — remains Monday-anchored and
/// is deliberately not affected by this key (accounting weeks map onto
/// it through anchorMondayOf in program_metrics.dart).
int weekStartDayOf(Map<Object?, Object?>? version) =>
    _weekdayByName[version?['week_start']?.toString().trim().toLowerCase()] ??
    DateTime.monday;

/// Resolve the program slice for [date]. Returns null when [date] falls
/// outside every block of the current program version (e.g. pre-program)
/// or when no non-pending version exists.
ProgramSlice? programCurrent(
  Map<Object?, Object?> programYaml,
  Map<Object?, Object?>? phaseYaml,
  DateTime date,
) {
  final version = currentVersion(programYaml);
  if (version == null) return null;

  final day = DateTime.utc(date.year, date.month, date.day);

  // Find the block containing the date (inclusive on both ends).
  final blocks = version['blocks'];
  if (blocks is! List) return null;
  Map<Object?, Object?>? block;
  for (final b in blocks) {
    if (b is! Map) continue;
    final dates = b['dates'] as List;
    final start = _parseDay(dates[0]);
    final end = _parseDay(dates[1]);
    if (!day.isBefore(start) && !day.isAfter(end)) {
      block = Map<Object?, Object?>.from(b);
      break;
    }
  }
  if (block == null) return null;

  final blockN = block['n'] as int;
  final emphasis = block['emphasis'].toString();
  final blockStart = _parseDay((block['dates'] as List)[0]);

  // week_in_block: 1-based count of Mondays; the week containing the
  // block's start date is week 1. DateTime.weekday: Mon=1..Sun=7.
  final startMonday =
      blockStart.subtract(Duration(days: blockStart.weekday - 1));
  final weekInBlock = day.difference(startMonday).inDays ~/ 7 + 1;

  // week_type: light/test cadence only for week_types.applies_to_blocks
  // (blocks 2-7 in v1); other blocks are all normal.
  final weekTypes = version['week_types'] as Map? ?? const {};
  final appliesTo = (weekTypes['applies_to_blocks'] as List?) ?? const [];
  var weekType = 'normal';
  if (appliesTo.contains(blockN)) {
    for (final name in ['light', 'test']) {
      final rule = weekTypes[name];
      if (rule is Map && rule['week_in_block'] == weekInBlock) {
        weekType = name;
        break;
      }
    }
  }

  // Today's template row.
  // For block 0, prefer weekly_template_block_0 when present.
  final weekday = _weekdayKeys[day.weekday - 1];
  final template = version['weekly_template'] as Map? ?? const {};
  final block0Template = version['weekly_template_block_0'] as Map?;
  final Map activeTemplate =
      (blockN == 0 && block0Template != null) ? block0Template : template;
  final today = activeTemplate[weekday];
  final todayTemplate = <String, Object?>{
    'weekday': weekday,
    'morning': today is Map ? today['morning'] : null,
    'afternoon': today is Map ? today['afternoon'] : null,
  };
  if (blockN == 0) {
    final blockNote = version['block_0_loads'];
    if (blockNote != null) {
      todayTemplate['block_note'] = blockNote;
    } else if (template['block_0_overrides'] != null) {
      // Legacy fallback: v1 used block_0_overrides on the template map.
      todayTemplate['block_note'] = template['block_0_overrides'];
    }
  }

  // Targets in force: weekly targets resolved for this block.
  //
  // Block-0 override (program.yaml v6 `targets_block_0`, mirroring the
  // weekly_template_block_0 convention): a key PRESENT in the override
  // replaces the base `targets` value for block-0 dates — including an
  // explicit null, which means "no target in force" (phase-aware flag
  // rules treat it as off); a key ABSENT falls through to base targets.
  final targets = version['targets'] as Map? ?? const {};
  final block0Targets =
      blockN == 0 ? version['targets_block_0'] as Map? : null;
  Object? target(String key) =>
      (block0Targets != null && block0Targets.containsKey(key))
          ? block0Targets[key]
          : targets[key];
  // Gain-rate target. Rated blocks (2-7) normally carry the block's own
  // `rate`; under `variant: recomposition` (program.yaml v8) the bulk
  // block rates are superseded by the variant's flat band —
  // targets.gain_rate_lb_wk.blocks_2_7 ([0.0, 0.15]) — while the block
  // list itself stays untouched (structure/history). Blocks 0-1 are
  // outside the variant (the cut and the reverse diet are unchanged).
  final variant = version['variant']?.toString();
  final gainRateTarget = targets['gain_rate_lb_wk'];
  final Object? gainRate;
  if (block.containsKey('rate')) {
    final recompBand = (variant == 'recomposition' && gainRateTarget is Map)
        ? gainRateTarget['blocks_2_7']
        : null;
    gainRate = recompBand ?? block['rate'];
  } else if (emphasis == 'cut') {
    gainRate = cutRateLbWk;
  } else {
    gainRate = null; // reverse block: rate emerges from the kcal ramp.
  }
  // climbing_wk: base is emphasis-keyed ({lifting_block, climbing_block});
  // the block-0 override is a plain scalar (a cut block is neither).
  final Object? climbingRaw = target('climbing_wk');
  final Object? climbingSessions = climbingRaw is Map
      ? (emphasis == 'climbing'
          ? climbingRaw['climbing_block']
          : climbingRaw['lifting_block'])
      : climbingRaw;
  // WEIGHT_FAST alarm rate in force: block-0 override key first
  // (program.yaml v8 pins the cut-era 0.6 there), then the base
  // targets' gain_rate_lb_wk map (`alarm`: bulk 0.6, recomp 0.3).
  // Null pre-v6 targets → flag evaluators keep their legacy threshold.
  final Object? gainRateAlarm = (block0Targets != null &&
          block0Targets.containsKey('gain_rate_alarm_lb_wk'))
      ? block0Targets['gain_rate_alarm_lb_wk']
      : (gainRateTarget is Map ? gainRateTarget['alarm'] : null);
  final targetsInForce = <String, Object?>{
    'near_max_sets': target('near_max_sets_wk'),
    'working_sets': target('working_sets_wk'),
    'working_sets_min_normal': target('working_sets_wk_min_normal'),
    'bench_days': target('bench_days_wk'),
    'press_days': target('press_days_wk'),
    'squat_days': target('squat_days_wk'),
    'deadlift_days': target('deadlift_days_wk'),
    'climbing_sessions': climbingSessions,
    'bike_4x4': target('bike_4x4_wk'),
    'muscle_up_sessions': target('muscle_up_sessions_wk'),
    'gain_rate_lb_wk': gainRate,
    'gain_rate_alarm_lb_wk': gainRateAlarm,
    // Band + cap honor targets_block_0 overrides (v8: block 0 keeps
    // the cut-era [154,172]/172 while the recomp year runs
    // [152,162]/165 from Dec 14).
    'bodyweight_band_lb': (target('bodyweight_lb') as Map?)?['band'],
    'hard_cap_lb': (block0Targets != null &&
            block0Targets.containsKey('hard_cap_lb'))
        ? block0Targets['hard_cap_lb']
        : version['hard_cap_lb'],
    'protein_g_per_lb': target('protein_g_per_lb'),
    // The program variant (v8: 'recomposition') rides along so flag
    // evaluators / dashboards can select variant-specific behavior
    // (WEIGHT_FLAT off, recomp eigenvector set). Null pre-v8.
    'variant': variant,
  };

  final rules = (version['rules'] as List? ?? const [])
      .map((r) => r.toString())
      .toList();

  return ProgramSlice(
    id: version['id'].toString(),
    version: version['version'] as int,
    block: {
      'number': blockN,
      'emphasis': emphasis,
      'dates': block['dates'],
      'target_weight': block['weight'],
      if (block['notes'] != null) 'notes': block['notes'],
    },
    weekInBlock: weekInBlock,
    weekType: weekType,
    todayTemplate: todayTemplate,
    targetsInForce: targetsInForce,
    rulesInForce: rules,
  );
}