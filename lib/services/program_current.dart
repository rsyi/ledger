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

/// The strength-wave week (1..4) for a block week under the version's
/// `strength_wave` key (program.yaml v10, final post-cut spec): the
/// repeating 4-week 5/3/1/deload wave, anchored to the BLOCK START —
/// wave week = ((week_in_block − 1) mod 4) + 1. Null when the version
/// declares no wave, the block is outside `applies_to_blocks`, or the
/// inputs are malformed. Blocks 2-7 being 8 weeks, block weeks 4
/// (light) and 8 (test) are both wave week 4 — the deload.
int? strengthWaveWeek(
  Map<Object?, Object?>? version, {
  required int? blockN,
  required int weekInBlock,
}) {
  final wave = version?['strength_wave'];
  if (wave is! Map || blockN == null || weekInBlock < 1) return null;
  final applies = wave['applies_to_blocks'];
  if (applies is! List || !applies.contains(blockN)) return null;
  return (weekInBlock - 1) % 4 + 1;
}

/// Prescribed TOP-SET reps for a wave week (program.yaml v10
/// `strength_wave.top_reps_by_week`, week-type aware):
///   * test week → 1 (the wave deload carries the block-result single);
///   * light week → the wave-restart week-1 reps (a light top-5 at the
///     RPE-6 cap — the block's light week IS the wave's deload);
///   * otherwise → top_reps_by_week[wave week] (5/3/1). Wave week 4 on
///     a NORMAL week can't occur under the v10 calendar; it falls back
///     to the week-1 reps rather than guessing.
/// Null when no wave applies or the table is malformed — callers must
/// skip the top set rather than invent reps.
int? strengthWaveTopReps(
  Map<Object?, Object?>? version, {
  required int? blockN,
  required int weekInBlock,
  String? weekType,
}) {
  final waveWeek =
      strengthWaveWeek(version, blockN: blockN, weekInBlock: weekInBlock);
  if (waveWeek == null) return null;
  final wave = version!['strength_wave'] as Map;
  final byWeek = wave['top_reps_by_week'];
  if (byWeek is! Map) return null;
  int? repsAt(int wk) {
    final v = byWeek['$wk'] ?? byWeek[wk];
    return v is num ? v.toInt() : null;
  }

  if (weekType == 'test') return 1;
  if (weekType == 'light') return repsAt(1);
  return repsAt(waveWeek) ?? repsAt(1);
}

/// One cut-wave week's prescription (program.yaml v11
/// `strength_wave_cut`, approved cut-training revision 2026-09-28):
/// the top set's reps + the fraction of the working max it is priced
/// at, and whether the week is the deload (halved non-top volume).
class CutWaveWeekSpec {
  /// 1..cycle (4).
  final int week;
  final int reps;

  /// Fraction of the working max — weeks 1-3 ARE chart[8][reps]
  /// (0.811 / 0.837 / 0.863); the deload's 0.70 deliberately is not.
  final double pct;
  final bool deload;

  const CutWaveWeekSpec({
    required this.week,
    required this.reps,
    required this.pct,
    required this.deload,
  });
}

/// The cut wave's prescription for [day] (program.yaml v11
/// `strength_wave_cut`). Unlike the post-cut `strength_wave` (block-
/// anchored), the cut wave is CALENDAR-anchored: wave week = ((whole
/// weeks between `anchor_monday` and the day's Monday) mod cycle) + 1.
/// Null when the version declares no cut wave, [blockN] is outside
/// `applies_to_blocks`, the day's Monday precedes the anchor, or the
/// declared week entry is malformed — callers must skip the top set
/// rather than invent one.
CutWaveWeekSpec? strengthWaveCutFor(
  Map<Object?, Object?>? version, {
  required int? blockN,
  required DateTime day,
}) {
  final wave = version?['strength_wave_cut'];
  if (wave is! Map || blockN == null) return null;
  final applies = wave['applies_to_blocks'];
  if (applies is! List || !applies.contains(blockN)) return null;
  final rawAnchor = wave['anchor_monday'];
  final weeks = wave['weeks'];
  if (rawAnchor == null || weeks is! Map || weeks.isEmpty) return null;
  final DateTime anchor;
  try {
    anchor = _parseDay(rawAnchor);
  } catch (_) {
    return null;
  }
  final d = DateTime.utc(day.year, day.month, day.day);
  final monday = d.subtract(Duration(days: d.weekday - 1));
  if (monday.isBefore(anchor)) return null;
  final week = (monday.difference(anchor).inDays ~/ 7) % weeks.length + 1;
  final entry = weeks['$week'] ?? weeks[week];
  if (entry is! Map) return null;
  final reps = entry['reps'];
  final pct = entry['pct'];
  if (reps is! num || pct is! num) return null;
  return CutWaveWeekSpec(
    week: week,
    reps: reps.toInt(),
    pct: pct.toDouble(),
    deload: entry['deload'] == true,
  );
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
  // Bodyweight target (v9): the post-cut band is a SOFT ADVISORY band
  // (`soft_band` + `advisory: true` — coach/post-cut-recomp-spec.md:
  // the hard band is de-emphasized; crossing it prompts the conditioned
  // weight_rules review, nothing automatic). `band` (v6-v8 / block-0
  // override) still wins when present.
  final bodyweightTarget = target('bodyweight_lb');
  final Object? bodyweightBand = bodyweightTarget is Map
      ? (bodyweightTarget['band'] ?? bodyweightTarget['soft_band'])
      : null;
  final Object? bodyweightAdvisory =
      bodyweightTarget is Map ? bodyweightTarget['advisory'] : null;
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
    // Band + cap honor targets_block_0 overrides (block 0 keeps the
    // cut-era [154,172]/172 for the whole cut). v9: the post-cut band
    // is soft/advisory ([154,165]) and the 165 cap is an advisory
    // tripwire (weight_rules), no longer an automatic hold.
    'bodyweight_band_lb': bodyweightBand,
    'bodyweight_band_advisory': bodyweightAdvisory,
    'hard_cap_lb': (block0Targets != null &&
            block0Targets.containsKey('hard_cap_lb'))
        ? block0Targets['hard_cap_lb']
        : version['hard_cap_lb'],
    'protein_g_per_lb': target('protein_g_per_lb'),
    // v9 absolute nutrition targets (post-cut; block 0 pins them null).
    'protein_g_day': target('protein_g_day'),
    'fat_g_day_min': target('fat_g_day_min'),
    'carbs_g_day': target('carbs_g_day'),
    // v9 hypertrophy dose band (8-12 sets/muscle/wk, overlap-counted
    // via the version's exercise_muscle_map; null for block 0).
    'hypertrophy_sets_per_muscle': target('hypertrophy_sets_per_muscle_wk'),
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