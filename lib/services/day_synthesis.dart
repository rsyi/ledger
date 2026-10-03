/// Day-synthesis context assembly: gathers "how is today going vs the
/// plan" into a compact prompt for the LLM, and derives the small tally
/// the post-log notification uses. Pure — no Flutter, no IO, no LLM call
/// (that rides the existing LlmClient seam). Every branch is covered by
/// test/day_synthesis_test.dart.
///
/// TRAINING comes ONLY from the shared [DayStatus] (day_status.dart) — the
/// exact per-item state the Today program card shows (allocation, Whoop /
/// Kaya / 4x4 session credits, moves, skips), rendered as an explicit
/// PROGRAM STATUS block. The prompt carries no routine prose, no planned
/// period for DONE items and no separate "climbing: not logged" line, so
/// the model has nothing to re-derive a conflicting picture from
/// (2026-10-02: a Whoop MORNING climb was ticked on the card while the
/// read said "make sure that PM light climbing session actually
/// happens"). It ADVISES; it never fabricates.
library;

import 'day_status.dart';
import 'whoop_activity.dart';

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

/// What was logged today outside the program checklist: meals, and the
/// Kaya ascent count (the refresh flow's Kaya-sync prompt reads it).
class SynthLogged {
  final List<SynthMeal> meals;

  /// Count of Kaya climbing rows logged today (>0 = Kaya has the session).
  final int climbCount;

  const SynthLogged({
    this.meals = const [],
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

  /// Today's program, item by item — the SAME resolution the Today card
  /// shows. Null when no program could be loaded (the prompt then says
  /// so and the model must not comment on training).
  final DayStatus? status;
  final SynthLogged logged;
  final SynthTargets targets;

  /// Last night's recovery/sleep (Whoop). Empty [SynthRecovery] when no
  /// recovery data is available — the prompt then omits the line.
  final SynthRecovery recovery;

  /// Today's Whoop workouts (local time) — context only; any session that
  /// completes a program item is already reflected in [status].
  final List<WhoopActivity> activities;

  const DaySynthesisContext({
    required this.hour,
    required this.phase,
    required this.status,
    required this.logged,
    required this.targets,
    this.recovery = const SynthRecovery(),
    this.activities = const [],
  });

  double get proteinSoFar => _sum(logged.meals, (m) => m.proteinG);
  double get carbsSoFar => _sum(logged.meals, (m) => m.carbsG);
  double get fatSoFar => _sum(logged.meals, (m) => m.fatG);
  double get kcalSoFar => _sum(logged.meals, (m) => m.calories);

  /// Program lift items done / live today (notification tally).
  int get liftsHit => status?.liftsHit ?? 0;
  int get liftsPlanned => status?.liftsPlanned ?? 0;

  /// True when today's program still has a PENDING climb (nothing —
  /// logged ascents, Whoop — credits it yet). Same answer as the card.
  bool get climbToCome => status?.climbPending ?? false;

  /// True when today's (live) program includes a climb at all.
  bool get climbPrescribed => status?.climbPrescribed ?? false;

  /// Everything the read depends on, bucketed so noise doesn't churn the
  /// LLM: the status block (any set logged, Whoop sync, calisthenics set,
  /// move or skip changes it), macros (protein/carbs/fat 10 g, kcal 100),
  /// recovery, phase and the part of the day. A stored read whose
  /// fingerprint differs is stale → regenerated.
  String get fingerprint {
    int b(double v, double step) => (v / step).floor();
    final daypart = hour < 12 ? 'am' : (hour < 17 ? 'pm' : 'eve');
    final raw = [
      status?.promptBlock() ?? 'no-program',
      'p${b(proteinSoFar, 10)} c${b(carbsSoFar, 10)} f${b(fatSoFar, 10)} '
          'k${b(kcalSoFar, 100)} m${logged.meals.length}',
      'r${recovery.recoveryScore?.round()} s${recovery.sleepHours} '
          'h${recovery.hrvMs?.round()}',
      'kaya${logged.climbCount > 0}',
      phase,
      daypart,
    ].join('|');
    return _fnv1a(raw);
  }
}

/// 32-bit FNV-1a over UTF-16 code units, hex — stable across runs (the
/// stored fingerprint must compare equal after an app restart, which
/// String.hashCode doesn't promise).
String _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

double _sum(List<SynthMeal> meals, double? Function(SynthMeal) f) {
  var total = 0.0;
  for (final m in meals) {
    total += f(m) ?? 0;
  }
  return total;
}

/// Builds the compact LLM prompt for the day synthesis. Output is kept
/// VERY short (the Today tab leads with progress bars — the read is a
/// one-liner nudge, not a report). Training facts come ONLY from the
/// PROGRAM STATUS block (the card's own per-item state).
String buildDaySynthesisPrompt(DaySynthesisContext c) {
  final b = StringBuffer();
  b.writeln(
    'You are Robert\'s training coach giving a SHORT, unprompted read on '
    'how today is going against the plan. HARD LIMIT: one or two sentences '
    '(roughly 30 words), plain language, no preamble, no bullet list, no '
    'markdown headers. Lead with the single most useful, timing-aware nudge '
    '(e.g. carbs before a still-PENDING session, protein to hit the floor). '
    'The macros/calories are already shown as bars, so do not recite every '
    'number — add judgment, not a recap. Never invent numbers.',
  );
  b.writeln();
  b.writeln('TRAINING RULES:');
  b.writeln('- PROGRAM STATUS below is authoritative — it is exactly what '
      'the user sees ticked on the Today card. Do not re-derive the day from '
      'a routine, a planned time of day or anything else.');
  b.writeln('- Only nudge items marked PENDING.');
  b.writeln('- Never suggest repeating, or "making sure" of, an item marked '
      'DONE. DONE is final whenever it happened — a session Whoop detected '
      'counts as done regardless of the time it was planned for.');
  b.writeln('- MOVED and SKIPPED items are not today\'s work; don\'t raise '
      'them.');
  b.writeln("- If TRAINING LEFT TODAY is none, today's training is complete: "
      'say so (or leave training out) and focus on food and recovery.');
  b.writeln();
  b.writeln('Local time: ${_fmtHour(c.hour)}.');
  if (c.phase.isNotEmpty) b.writeln('Phase: ${c.phase}.');
  b.writeln();

  final recoveryLine = _recoveryLine(c.recovery);
  if (recoveryLine != null) {
    b.writeln('RECOVERY (last night, from Whoop):');
    b.writeln('- $recoveryLine');
    b.writeln('  Factor readiness into advice about PENDING work — if '
        'recovery/sleep is low, bias toward keeping it easy; if it\'s '
        'strong, it\'s fine to push.');
    b.writeln();
  }

  final status = c.status;
  if (status == null) {
    b.writeln('PROGRAM STATUS: unavailable (program not loaded) — do not '
        'comment on training.');
  } else {
    b.writeln(status.promptBlock());
  }
  b.writeln();

  if (c.activities.isNotEmpty) {
    b.writeln('WHOOP SESSIONS TODAY (context only — already reflected in '
        'PROGRAM STATUS):');
    for (final a in c.activities) {
      final t = a.start == null
          ? ''
          : ' ${a.start!.hour.toString().padLeft(2, '0')}:'
              '${a.start!.minute.toString().padLeft(2, '0')}';
      b.writeln('- ${a.sport}$t'
          '${a.strain == null ? '' : ' · strain ${a.strain!.toStringAsFixed(1)}'}'
          '${a.durationMin == null ? '' : ' · ${a.durationMin!.round()} min'}');
    }
    b.writeln();
  }

  b.writeln('FOOD SO FAR TODAY:');
  if (c.logged.meals.isEmpty) {
    b.writeln('- food: nothing logged yet');
  } else {
    b.writeln(
      '- food: ${_g(c.proteinSoFar)} protein, ${_g(c.carbsSoFar)} carbs, '
      '${_g(c.fatSoFar)} fat, ${c.kcalSoFar.round()} kcal '
      '(${c.logged.meals.length} meal(s))',
    );
  }
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
  final pf = c.targets.resolvedProteinBand;
  if (pf != null && pf.isNotEmpty && c.proteinSoFar < pf[0]) {
    b.writeln('- still to eat: ${(pf[0] - c.proteinSoFar).round()}g more '
        'protein to the floor');
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
