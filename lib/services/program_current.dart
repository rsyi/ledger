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
  final targets = version['targets'] as Map? ?? const {};
  final climbingWk = targets['climbing_wk'] as Map? ?? const {};
  final Object? gainRate;
  if (block.containsKey('rate')) {
    gainRate = block['rate'];
  } else if (emphasis == 'cut') {
    gainRate = cutRateLbWk;
  } else {
    gainRate = null; // reverse block: rate emerges from the kcal ramp.
  }
  final targetsInForce = <String, Object?>{
    'near_max_sets': targets['near_max_sets_wk'],
    'working_sets': targets['working_sets_wk'],
    'working_sets_min_normal': targets['working_sets_wk_min_normal'],
    'bench_days': targets['bench_days_wk'],
    'press_days': targets['press_days_wk'],
    'squat_days': targets['squat_days_wk'],
    'deadlift_days': targets['deadlift_days_wk'],
    'climbing_sessions': emphasis == 'climbing'
        ? climbingWk['climbing_block']
        : climbingWk['lifting_block'],
    'bike_4x4': targets['bike_4x4_wk'],
    'muscle_up_sessions': targets['muscle_up_sessions_wk'],
    'gain_rate_lb_wk': gainRate,
    'bodyweight_band_lb': (targets['bodyweight_lb'] as Map?)?['band'],
    'hard_cap_lb': version['hard_cap_lb'],
    'protein_g_per_lb': targets['protein_g_per_lb'],
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