/// Day-synthesis context assembly: gathers "how is today going vs the
/// plan" into a compact prompt for the LLM, and derives the small tally
/// the post-log notification uses. Pure — no Flutter, no IO, no LLM call
/// (that rides the existing LlmClient seam). Every branch is covered by
/// test/day_synthesis_test.dart.
///
/// The synthesis answers, in plain language: what have I done so far today
/// (meals + macros, sets, 4x4, climbing) vs what today's PROGRAM calls for
/// vs what's LEFT — with timing- and remaining-work-aware nutrition /
/// training advice. It ADVISES; it never fabricates. If the routine has a
/// PM climb and none is logged, the prompt states the climb is still to
/// come — so the model can't call it a rest day.
library;

/// A meal eaten today (macros already summed per record; nulls = not
/// reported). [atHour] is the local hour it was eaten (0–23), or null.
class SynthMeal {
  final double? calories;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;
  final int? atHour;

  const SynthMeal({
    this.calories,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.atHour,
  });
}

/// A strength set logged today.
class SynthSet {
  final String exercise;
  final double? weight;
  final int? reps;

  const SynthSet({required this.exercise, this.weight, this.reps});
}

/// The macro targets in force today (from the program slice).
///
/// The CUT phase (block 0) exposes RELATIVE protein — `protein_g_per_lb`
/// (e.g. [0.8, 1.0]) — and no hard carb target (carbs are a soft floor,
/// not a ceiling), while the post-Dec-14 recomp phase exposes ABSOLUTE
/// grams ([protein_g_day] / [carbs_g_day] / [fat_g_day_min]). Both shapes
/// feed this class; [resolvedProteinBand] flattens them to an absolute
/// g/day band using [bodyweightLb] so the prompt always has a real target
/// to judge intake against (the cut previously fell through to a bare "no
/// target" because only the absolute keys were read).
class SynthTargets {
  /// ABSOLUTE [lo, hi] grams/day; the low end is the floor we compare
  /// against. Present only in the recomp phase.
  final List<double>? proteinGDay;

  /// RELATIVE protein band ([g/lb-of-bodyweight lo, hi]). Present in the
  /// cut phase; resolved to absolute grams via [bodyweightLb].
  final List<double>? proteinGPerLb;

  /// Current 7-day-average bodyweight (lb) — prices [proteinGPerLb].
  final double? bodyweightLb;

  /// ABSOLUTE carb band [lo, hi] grams/day. Present only in the recomp
  /// phase; the cut has no hard carb target (a soft floor lives in the
  /// GOALS surface config, not the program slice).
  final List<double>? carbsGDay;
  final double? fatGDayMin;

  const SynthTargets({
    this.proteinGDay,
    this.proteinGPerLb,
    this.bodyweightLb,
    this.carbsGDay,
    this.fatGDayMin,
  });

  /// The protein target as an ABSOLUTE g/day band, resolving the cut's
  /// per-lb band against [bodyweightLb] when the absolute band is absent.
  /// Null when neither an absolute band nor (per-lb band + bodyweight) is
  /// available — the caller then falls back to [proteinPerLbText].
  List<double>? get resolvedProteinBand {
    if (proteinGDay != null && proteinGDay!.isNotEmpty) return proteinGDay;
    final perLb = proteinGPerLb;
    final bw = bodyweightLb;
    if (perLb != null && perLb.isNotEmpty && bw != null && bw > 0) {
      return [for (final x in perLb) x * bw];
    }
    return null;
  }

  /// The per-lb protein band as display text ("0.8–1.0 g/lb"), or null
  /// when no per-lb band is declared. Used as the honest fallback when a
  /// per-lb target exists but bodyweight is unavailable — better than
  /// "no target".
  String? get proteinPerLbText {
    final perLb = proteinGPerLb;
    if (perLb == null || perLb.isEmpty) return null;
    // 1 decimal when exact at tenths (0.8 → "0.8"), else 2 (1.05 → "1.05").
    String n(double v) => (v * 10).roundToDouble() == v * 10
        ? v.toStringAsFixed(1)
        : v.toStringAsFixed(2);
    if (perLb.length >= 2 && perLb[1] != perLb[0]) {
      return '${n(perLb[0])}–${n(perLb[1])} g/lb';
    }
    return '${n(perLb[0])} g/lb';
  }
}

/// The program's call for today, distilled from the routine prose + planned
/// strength lines.
class SynthProgramDay {
  /// Routine morning prose (e.g. "AM 4x4 intervals").
  final String morning;

  /// Routine afternoon prose (e.g. "PM hard climbing session").
  final String afternoon;

  /// Planned strength exercise names for today (from PlanStore / planner).
  final List<String> plannedLifts;

  /// True when today's routine calls for a 4x4 cardio session.
  final bool wants4x4;

  /// The climbing flavor for today ("hard session", "limit session", …)
  /// or null when no climb is scheduled.
  final String? climbCall;

  const SynthProgramDay({
    this.morning = '',
    this.afternoon = '',
    this.plannedLifts = const [],
    this.wants4x4 = false,
    this.climbCall,
  });
}

/// What was actually logged today across domains.
class SynthLogged {
  final List<SynthMeal> meals;
  final List<SynthSet> sets;

  /// True when a 4x4 cardio session is logged today.
  final bool did4x4;

  /// Count of climbing rows/ascents logged today (>0 = climbed).
  final int climbCount;

  const SynthLogged({
    this.meals = const [],
    this.sets = const [],
    this.did4x4 = false,
    this.climbCount = 0,
  });
}

/// Last night's objective recovery (Whoop → `recovery` view), so the
/// synthesis can factor readiness into its training advice ("slept 7.4h,
/// recovery 80 — good to push" / "recovery low, keep it easy"). All
/// fields nullable — a missing night or a partial pull leaves them null,
/// and the prompt simply omits the recovery line.
class SynthRecovery {
  /// The recovery row's day (`yyyy-mm-dd`), for the "last night" framing.
  final String? day;
  final double? sleepHours;

  /// Whoop recovery score (0–100; green ≥67 / yellow 34–66 / red <34).
  final double? recoveryScore;
  final double? hrvMs;

  /// 7-day average recovery score across the recent window — a trend
  /// anchor so "recovery 80" reads against the user's own baseline.
  final double? recoveryScore7dAvg;

  const SynthRecovery({
    this.day,
    this.sleepHours,
    this.recoveryScore,
    this.hrvMs,
    this.recoveryScore7dAvg,
  });

  /// True when there's at least one numeric signal worth stating.
  bool get hasData =>
      sleepHours != null || recoveryScore != null || hrvMs != null;
}

/// The assembled, phase- and time-aware picture the prompt renders from,
/// and the notification tally reads.
class DaySynthesisContext {
  final int hour; // 0–23 local
  final String phase; // 'cut' | 'recomp' | … | '' when unknown
  final SynthProgramDay program;
  final SynthLogged logged;
  final SynthTargets targets;

  /// Last night's recovery/sleep (Whoop). Empty [SynthRecovery] when no
  /// recovery data is available — the prompt then omits the line.
  final SynthRecovery recovery;

  const DaySynthesisContext({
    required this.hour,
    required this.phase,
    required this.program,
    required this.logged,
    required this.targets,
    this.recovery = const SynthRecovery(),
  });

  double get proteinSoFar => _sum(logged.meals, (m) => m.proteinG);
  double get carbsSoFar => _sum(logged.meals, (m) => m.carbsG);
  double get fatSoFar => _sum(logged.meals, (m) => m.fatG);
  double get kcalSoFar => _sum(logged.meals, (m) => m.calories);

  /// Distinct exercise names logged (lower-cased, insertion order).
  List<String> get liftsDone {
    final seen = <String>[];
    for (final s in logged.sets) {
      final n = s.exercise.trim().toLowerCase();
      if (n.isNotEmpty && !seen.contains(n)) seen.add(n);
    }
    return seen;
  }

  /// Distinct planned lift names (lower-cased, insertion order).
  List<String> get liftsPlanned {
    final seen = <String>[];
    for (final e in program.plannedLifts) {
      final n = e.trim().toLowerCase();
      if (n.isNotEmpty && !seen.contains(n)) seen.add(n);
    }
    return seen;
  }

  /// Planned lifts not yet logged today.
  List<String> get liftsRemaining {
    final done = liftsDone.toSet();
    return [for (final l in liftsPlanned) if (!done.contains(l)) l];
  }

  /// True when the routine wants a climb today and none is logged yet.
  bool get climbToCome => program.climbCall != null && logged.climbCount == 0;

  /// True when the routine wants a 4x4 and none is logged yet.
  bool get cardioToCome => program.wants4x4 && !logged.did4x4;
}

double _sum(List<SynthMeal> meals, double? Function(SynthMeal) f) {
  var total = 0.0;
  for (final m in meals) {
    total += f(m) ?? 0;
  }
  return total;
}

/// Builds the compact LLM prompt for the day synthesis. Short output is
/// requested explicitly (2–3 bullets or one short paragraph). The context
/// lines are all facts — the model reasons over them; it must not invent
/// numbers or claim unlogged work.
String buildDaySynthesisPrompt(DaySynthesisContext c) {
  final b = StringBuffer();
  b.writeln(
    'You are Robert\'s training coach giving a SHORT, unprompted read on '
    'how today is going against the plan. Be concise and actionable: 2–3 '
    'short bullets or one short paragraph, plain language, no preamble. '
    'Give timing- and remaining-work-aware nutrition/training advice '
    '(e.g. carbs before a climb, protein to hit the floor). Advise only '
    'from the facts below — never invent numbers and never claim work '
    'that is not logged. If a session is still to come, say so.',
  );
  b.writeln();
  b.writeln('Local time: ${_fmtHour(c.hour)}.');
  if (c.phase.isNotEmpty) b.writeln('Phase: ${c.phase}.');
  b.writeln();

  final recoveryLine = _recoveryLine(c.recovery);
  if (recoveryLine != null) {
    b.writeln('RECOVERY (last night, from Whoop):');
    b.writeln('- $recoveryLine');
    b.writeln('  Factor readiness into today\'s training advice — if '
        'recovery/sleep is low, bias toward keeping it easy; if it\'s '
        'strong, it\'s fine to push the hard work.');
    b.writeln();
  }

  b.writeln('TODAY\'S PROGRAM:');
  final callParts = <String>[];
  if (c.program.plannedLifts.isNotEmpty) {
    callParts.add('lifting — ${c.liftsPlanned.join(', ')}');
  }
  if (c.program.wants4x4) callParts.add('4x4 cardio');
  if (c.program.climbCall != null) {
    callParts.add('climbing (${c.program.climbCall})');
  }
  if (callParts.isEmpty) {
    b.writeln('- rest day (no training scheduled)');
  } else {
    for (final p in callParts) {
      b.writeln('- $p');
    }
  }
  final prose = [c.program.morning, c.program.afternoon]
      .where((s) => s.trim().isNotEmpty)
      .join(' / ');
  if (prose.isNotEmpty) b.writeln('  routine: $prose');
  b.writeln();

  b.writeln('DONE SO FAR TODAY:');
  if (c.logged.meals.isEmpty) {
    b.writeln('- food: nothing logged yet');
  } else {
    b.writeln(
      '- food: ${_g(c.proteinSoFar)} protein, ${_g(c.carbsSoFar)} carbs, '
      '${_g(c.fatSoFar)} fat, ${c.kcalSoFar.round()} kcal '
      '(${c.logged.meals.length} meal(s))',
    );
  }
  if (c.liftsDone.isEmpty) {
    b.writeln('- lifting: none logged');
  } else {
    b.writeln('- lifting: ${c.liftsDone.join(', ')} '
        '(${c.logged.sets.length} sets)');
  }
  b.writeln('- 4x4: ${c.logged.did4x4 ? 'done' : 'not logged'}');
  b.writeln(
    '- climbing: ${c.logged.climbCount > 0 ? 'logged (${c.logged.climbCount})' : 'not logged'}',
  );
  b.writeln();

  b.writeln('MACRO TARGETS TODAY:');
  final resolvedProtein = c.targets.resolvedProteinBand;
  if (resolvedProtein != null) {
    b.writeln('- protein floor: ${_target(resolvedProtein)}');
  } else if (c.targets.proteinPerLbText != null) {
    // Per-lb target declared but no bodyweight to price it — honest text.
    b.writeln('- protein floor: ${c.targets.proteinPerLbText}');
  } else {
    b.writeln('- protein floor: no target');
  }
  // Carbs: absolute band when the recomp phase declares one; otherwise the
  // cut has no hard carb target (carbs are a floor, not a ceiling — never
  // "no target", which reads as "nothing to hit").
  if (c.targets.carbsGDay != null) {
    b.writeln('- carbs: ${_target(c.targets.carbsGDay)}');
  } else {
    b.writeln('- carbs: no hard target on the cut (carbs are a floor, '
        'not a ceiling — enough to fuel training)');
  }
  b.writeln(
    '- fat floor: ${c.targets.fatGDayMin == null ? 'no target' : '${c.targets.fatGDayMin!.round()}g'}',
  );
  b.writeln();

  b.writeln('STILL TO COME:');
  final left = <String>[];
  if (c.liftsRemaining.isNotEmpty) {
    left.add('lifting: ${c.liftsRemaining.join(', ')}');
  }
  if (c.cardioToCome) left.add('4x4 cardio');
  if (c.climbToCome) left.add('climbing (${c.program.climbCall})');
  final pf = c.targets.resolvedProteinBand;
  if (pf != null && pf.isNotEmpty && c.proteinSoFar < pf[0]) {
    left.add('${(pf[0] - c.proteinSoFar).round()}g more protein to the floor');
  }
  if (left.isEmpty) {
    b.writeln('- nothing outstanding');
  } else {
    for (final l in left) {
      b.writeln('- $l');
    }
  }

  return b.toString().trimRight();
}

/// Compact recovery read ("slept 7.4h · recovery 80 (green) · HRV 65ms,
/// 7d avg 74"), or null when no numeric signal is present (the line is
/// then omitted — never a bare "recovery: no data").
String? _recoveryLine(SynthRecovery r) {
  if (!r.hasData) return null;
  final parts = <String>[];
  if (r.sleepHours != null) {
    parts.add('slept ${_num1(r.sleepHours!)}h');
  }
  if (r.recoveryScore != null) {
    final s = r.recoveryScore!;
    final band = s >= 67 ? 'green' : (s >= 34 ? 'yellow' : 'red');
    parts.add('recovery ${s.round()} ($band)');
  }
  if (r.hrvMs != null) parts.add('HRV ${r.hrvMs!.round()}ms');
  if (r.recoveryScore7dAvg != null) {
    parts.add('7d avg recovery ${r.recoveryScore7dAvg!.round()}');
  }
  return parts.join(' · ');
}

String _num1(double v) {
  final r = (v * 10).roundToDouble() / 10;
  return r == r.roundToDouble() ? r.round().toString() : r.toStringAsFixed(1);
}

String _fmtHour(int h) {
  final hr = h % 24;
  final period = hr < 12 ? 'am' : 'pm';
  final h12 = hr % 12 == 0 ? 12 : hr % 12;
  return '$h12$period';
}

String _g(double v) => '${v.round()}g';

String _target(List<double>? band) {
  if (band == null || band.isEmpty) return 'no target';
  if (band.length >= 2 && band[1] != band[0]) {
    return '${band[0].round()}–${band[1].round()}g';
  }
  return '${band[0].round()}g';
}
