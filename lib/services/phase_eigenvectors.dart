/// Phase-eigenvector engine — the home hero's brain.
///
/// The home page's PHASE hero asks one question per declared phase:
/// "are the eigenvectors of this phase being satisfied?"
///
///   cut       lose weight inside the declared rate band, WITHOUT losing
///             strength (weekly Wilks holds within floor_pct of the
///             cut-start reference; 3+ consecutive weeks under the floor
///             is the act signal).
///   bulk      gain weight slowly (block rate band, alarm above), gain
///             strength (Wilks trending UP over the block), and deliver
///             the inputs (near-max + working sets vs targets-in-force).
///   maintain  hold the scale, hold the Wilks.
///   reverse   hold-to-slight-gain while kcal ramp finds maintenance,
///             hold the Wilks.
///
/// The eigenvector SETS and their thresholds are declared in
/// `app/dashboards.yaml` under `phases:` (engine-free presentation
/// config, same file as the domain dashboards); coach/phase.yaml's
/// current `value` selects which set is live. No `phases:` section →
/// [parsePhaseEigenvectors] returns null and the home dashboard renders
/// its pre-hero four-card grid unchanged (back-compat by construction).
///
/// Pure Dart, no Flutter, no IO — every verdict here is unit-tested;
/// the hero UI stays layout-only.
library;

import 'package:yaml/yaml.dart';

import 'home_synthesis.dart'
    show LiveWeekCounts, StatusWeek, asNum, targetNumber, targetText;
import 'program_current.dart' show ProgramSlice;
import 'program_metrics.dart' show WeightRow, weekStartOf;
import 'program_observed.dart' show ObservedWeightStats, sevenDayAvgSeries;
import 'wilks.dart' show WilksWeek;

// ---------------------------------------------------------------------------
// Config (dashboards.yaml `phases:` section)
// ---------------------------------------------------------------------------

/// One declared eigenvector. The `id` selects the computation:
/// weight_loss / gain_rate / weight_hold (the rate family),
/// wilks_stability / strength_gain (the Wilks family),
/// inputs_delivered (weekly quotas). Unknown ids degrade to an
/// unknown-verdict row, never an error.
class EigenvectorConfig {
  final String id;

  /// Row label ("weight", "strength", "inputs"). Absent → per-id default.
  final String? label;

  /// Rate family: the lb/wk band the observed 3-week rate should land
  /// in (`rate_band: [-1.0, -0.5]`). Absent → derived from the program
  /// slice's gain_rate_lb_wk when possible.
  final List<double>? rateBand;

  /// Rate family: red thresholds (observed >= act_above or <=
  /// act_below → act). Absent → no red via that edge.
  final double? actAbove;
  final double? actBelow;

  /// Wilks family: reference anchor date (weekly Wilks AS OF this day
  /// is the yardstick). Absent → the running block's start date.
  final DateTime? from;

  /// Wilks family: acceptable drop below the reference, in percent —
  /// floor = reference × (1 − floor_pct/100).
  final double? floorPct;

  /// Wilks family: consecutive weeks under the floor that flip the
  /// verdict to act. Default 3 ("3+ = act").
  final int actWeeksBelow;

  const EigenvectorConfig({
    required this.id,
    this.label,
    this.rateBand,
    this.actAbove,
    this.actBelow,
    this.from,
    this.floorPct,
    this.actWeeksBelow = 3,
  });
}

/// The dashboards.yaml `phases:` key the app should render for a
/// declared [phase] under a program [variant] (program.yaml v8):
/// `variant: recomposition` redirects a declared `bulk` phase to the
/// `recomp` set when [available] carries one — the recomp year replaces
/// the bulk's gain-rate eigenvector with weight-hold; the bulk set
/// stays defined-but-unselected (flip the variant off and it returns).
/// Every other combination passes [phase] through unchanged, so a
/// dashboards.yaml without a recomp set (or a pre-v8 program) behaves
/// exactly as before.
String effectivePhaseKey(
  String phase, {
  String? variant,
  required Iterable<String> available,
}) =>
    (variant == 'recomposition' &&
            phase == 'bulk' &&
            available.contains('recomp'))
        ? 'recomp'
        : phase;

/// Parses the `phases:` section of dashboards.yaml: phase value →
/// eigenvector list. Null when [raw] is missing/malformed OR has no
/// usable `phases:` map — the caller keeps the pre-hero dashboard.
/// Individual bad entries are skipped, never fatal.
Map<String, List<EigenvectorConfig>>? parsePhaseEigenvectors(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  Object? doc;
  try {
    doc = loadYaml(raw);
  } catch (_) {
    return null;
  }
  if (doc is! Map) return null;
  final phases = doc['phases'];
  if (phases is! Map) return null;
  final out = <String, List<EigenvectorConfig>>{};
  for (final entry in phases.entries) {
    final name = entry.key?.toString().trim() ?? '';
    final body = entry.value;
    if (name.isEmpty || body is! Map) continue;
    final vectors = body['eigenvectors'];
    if (vectors is! List) continue;
    final parsed = <EigenvectorConfig>[];
    for (final v in vectors) {
      if (v is! Map) continue;
      final id = v['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final band = v['rate_band'];
      final actWeeks = v['act_weeks_below'];
      parsed.add(EigenvectorConfig(
        id: id,
        label: v['label']?.toString(),
        rateBand: band is List && band.length == 2 && band.every((e) => e is num)
            ? [(band[0] as num).toDouble(), (band[1] as num).toDouble()]
            : null,
        actAbove: (v['act_above'] as num?)?.toDouble(),
        actBelow: (v['act_below'] as num?)?.toDouble(),
        from: DateTime.tryParse(v['from']?.toString() ?? ''),
        floorPct: (v['floor_pct'] as num?)?.toDouble(),
        actWeeksBelow: actWeeks is num ? actWeeks.toInt() : 3,
      ));
    }
    if (parsed.isNotEmpty) out[name] = parsed;
  }
  return out.isEmpty ? null : out;
}

// ---------------------------------------------------------------------------
// Verdicts
// ---------------------------------------------------------------------------

/// The hero's three-state chip (+ unknown for missing data).
enum EigenVerdict { agree, drifting, act, unknown }

/// Rate-family verdict: where the observed weekly rate sits relative to
/// the declared band. Red edges are explicit thresholds ([actAbove] /
/// [actBelow]) so "gaining on a cut" and "runaway bulk" go red without
/// waiting weeks; anything outside the band but inside the red edges is
/// drifting.
EigenVerdict rateBandVerdict(
  double? observed,
  List<double>? band, {
  double? actAbove,
  double? actBelow,
}) {
  if (observed == null || band == null || band.length != 2) {
    return EigenVerdict.unknown;
  }
  if (actAbove != null && observed >= actAbove) return EigenVerdict.act;
  if (actBelow != null && observed <= actBelow) return EigenVerdict.act;
  final lo = band[0] <= band[1] ? band[0] : band[1];
  final hi = band[0] <= band[1] ? band[1] : band[0];
  if (observed >= lo && observed <= hi) return EigenVerdict.agree;
  return EigenVerdict.drifting;
}

/// Wilks-family result: the current weekly value vs the [from]-anchored
/// reference and its floor, plus the consecutive-weeks-below count that
/// drives the act signal.
class WilksStability {
  final double? current;
  final double? reference;
  final double? floor;

  /// Consecutive weeks (ending at the newest) with Wilks strictly under
  /// the floor. Only weeks at/after the anchor count — history before
  /// the phase started can't trip the alarm.
  final int weeksBelowFloor;
  final EigenVerdict verdict;

  const WilksStability({
    required this.current,
    required this.reference,
    required this.floor,
    required this.weeksBelowFloor,
    required this.verdict,
  });
}

/// Computes [WilksStability] from the weekly series.
///
/// Reference = the weekly value AS OF [from] (the last week whose Monday
/// is not after [from]'s week — the Wilks the phase was walked into
/// with; same anchoring as the strength domain's wilks_series). Floor =
/// reference × (1 − [floorPct]/100); null [floorPct] → floor coincides
/// with the reference (zero tolerance is never implied silently — the
/// verdict then only distinguishes at/above vs below reference).
///
/// Verdict:
///   • [requireGain] false (cut/maintain/reverse "stability"): agree
///     while at/above the floor; drifting once under it; act after
///     [actWeeksBelow] consecutive weeks under it.
///   • [requireGain] true (bulk "strength_gain"): agree only at/above
///     the REFERENCE (the block should trend up); between floor and
///     reference is drifting; under the floor counts toward act.
WilksStability wilksStability({
  required List<WilksWeek> weeks,
  required DateTime? from,
  required double? floorPct,
  int actWeeksBelow = 3,
  bool requireGain = false,
}) {
  final current = weeks.isEmpty ? null : weeks.last.wilks;
  double? reference;
  DateTime? anchorMonday;
  if (from != null && weeks.isNotEmpty) {
    // Anchor keying is inherited from the series' own week keys (the
    // configured accounting week start), so the comparison below can
    // never straddle two calendars.
    anchorMonday = weekStartOf(
      DateTime(from.year, from.month, from.day),
      weeks.first.weekStart.weekday,
    );
    for (final w in weeks) {
      if (!w.weekStart.isAfter(anchorMonday)) reference = w.wilks;
    }
  }
  final floor = reference == null
      ? null
      : reference * (1 - (floorPct ?? 0) / 100);
  var below = 0;
  if (floor != null) {
    for (var i = weeks.length - 1; i >= 0; i--) {
      final w = weeks[i];
      if (anchorMonday != null && w.weekStart.isBefore(anchorMonday)) break;
      if (w.wilks < floor) {
        below++;
      } else {
        break;
      }
    }
  }
  EigenVerdict verdict;
  if (current == null || reference == null) {
    verdict = EigenVerdict.unknown;
  } else if (below >= actWeeksBelow) {
    verdict = EigenVerdict.act;
  } else if (below >= 1) {
    verdict = EigenVerdict.drifting;
  } else if (requireGain && current < reference) {
    verdict = EigenVerdict.drifting;
  } else {
    verdict = EigenVerdict.agree;
  }
  return WilksStability(
    current: current,
    reference: reference,
    floor: floor,
    weeksBelowFloor: below,
    verdict: verdict,
  );
}

/// One weekly quota's verdict: [done] vs [target] (num | [lo, hi] |
/// null), pro-rated by [weekElapsedFraction] (1.0 for a completed
/// status week; weekday/7 for the running week so Monday isn't red).
/// No target in force (null / ≤0) → unknown — a cut with no volume
/// floor must not fail a volume quota.
EigenVerdict quotaVerdict(
  double? done,
  Object? target, {
  double weekElapsedFraction = 1.0,
}) {
  final t = targetNumber(target);
  if (t == null || t <= 0 || done == null) return EigenVerdict.unknown;
  final f = weekElapsedFraction.clamp(1 / 7, 1.0);
  final ratio = done / (t * f);
  if (ratio >= 0.9) return EigenVerdict.agree;
  if (ratio >= 0.5) return EigenVerdict.drifting;
  return EigenVerdict.act;
}

/// Combines verdicts: any act → act, else any drifting → drifting, else
/// any agree → agree (partial data still counts), else unknown.
EigenVerdict worstVerdict(Iterable<EigenVerdict> verdicts) {
  var sawAgree = false;
  var sawDrift = false;
  for (final v in verdicts) {
    switch (v) {
      case EigenVerdict.act:
        return EigenVerdict.act;
      case EigenVerdict.drifting:
        sawDrift = true;
      case EigenVerdict.agree:
        sawAgree = true;
      case EigenVerdict.unknown:
        break;
    }
  }
  if (sawDrift) return EigenVerdict.drifting;
  return sawAgree ? EigenVerdict.agree : EigenVerdict.unknown;
}

// ---------------------------------------------------------------------------
// Hero assembly
// ---------------------------------------------------------------------------

/// Where a hero row navigates on tap.
enum EigenNav { program, strength, status }

/// One rendered eigenvector row: verdict chip + the one number that
/// matters + optional sparkline points.
class EigenRowData {
  final String id;
  final String label;
  final EigenVerdict verdict;

  /// The one-line number(s), preformatted ("-0.40 lb/wk · target
  /// -0.75", "Wilks 327.5 · floor 319.3 · 0 wks below").
  final String detail;
  final List<({DateTime day, double value})> spark;

  /// Faint horizontal guide lines on the sparkline (Wilks reference /
  /// floor). Null → none.
  final double? sparkReference;
  final double? sparkFloor;
  final EigenNav nav;

  const EigenRowData({
    required this.id,
    required this.label,
    required this.verdict,
    required this.detail,
    this.spark = const [],
    this.sparkReference,
    this.sparkFloor,
    required this.nav,
  });
}

/// Everything the hero card renders.
class PhaseHeroData {
  /// Display phase name ("Cut", "Bulk").
  final String phaseTitle;

  /// "block 0 · wk 1 · day 1 of 84" — null when no program slice
  /// resolved (offline).
  final String? blockLine;

  /// The block's trajectory, e.g. "163 → 154 lb by Dec 13". Null when
  /// the block carries no weight endpoints.
  final String? trajectory;

  final List<EigenRowData> rows;

  /// The worst row verdict — tints the whole card.
  EigenVerdict get overall => worstVerdict(rows.map((r) => r.verdict));

  const PhaseHeroData({
    required this.phaseTitle,
    required this.blockLine,
    required this.trajectory,
    required this.rows,
  });
}

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _fmtSigned(double v, {int digits = 2}) =>
    '${v > 0 ? '+' : ''}${v.toStringAsFixed(digits)}';

DateTime? _parseDay(Object? s) {
  final d = DateTime.tryParse(s?.toString() ?? '');
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

int _daysBetween(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day)
    .difference(DateTime.utc(a.year, a.month, a.day))
    .inDays;

/// Builds the hero from already-fetched inputs. Null when the config has
/// no eigenvectors for the declared phase (or no phase is declared) —
/// the dashboard then renders its legacy grid.
PhaseHeroData? buildPhaseHero({
  required Map<String, List<EigenvectorConfig>>? phases,
  required String? phaseValue,
  required double? targetRateLbWk,
  required ProgramSlice? slice,
  required ObservedWeightStats stats,
  required List<WeightRow> weightDaily,
  required List<WilksWeek> wilksWeeks,
  required StatusWeek? statusWeek,
  required Map<String, Object?> targets,
  required DateTime today,
  LiveWeekCounts? live,
}) {
  if (phases == null || phaseValue == null) return null;
  final configs = phases[phaseValue];
  if (configs == null || configs.isEmpty) return null;

  // Block header pieces.
  String? blockLine;
  String? trajectory;
  DateTime? blockStart;
  if (slice != null) {
    final dates = slice.block['dates'];
    DateTime? blockEnd;
    if (dates is List && dates.length == 2) {
      blockStart = _parseDay(dates[0]);
      blockEnd = _parseDay(dates[1]);
    }
    final n = slice.block['number'];
    final parts = <String>[
      if (n != null) 'block $n',
      'wk ${slice.weekInBlock}',
      if (blockStart != null && blockEnd != null)
        'day ${_daysBetween(blockStart, today) + 1} of '
            '${_daysBetween(blockStart, blockEnd) + 1}',
    ];
    blockLine = parts.join(' · ');
    final w = slice.block['target_weight'];
    if (w is List && w.length == 2 && blockEnd != null) {
      trajectory = '${w[0]} → ${w[1]} lb by '
          '${_monthNames[blockEnd.month - 1]} ${blockEnd.day}';
    }
  }

  final rows = <EigenRowData>[
    for (final c in configs)
      _buildRow(
        c,
        targetRateLbWk: targetRateLbWk,
        slice: slice,
        blockStart: blockStart,
        stats: stats,
        weightDaily: weightDaily,
        wilksWeeks: wilksWeeks,
        statusWeek: statusWeek,
        targets: targets,
        today: today,
        live: live,
      ),
  ];

  return PhaseHeroData(
    phaseTitle: phaseValue.isEmpty
        ? phaseValue
        : phaseValue[0].toUpperCase() + phaseValue.substring(1),
    blockLine: blockLine,
    trajectory: trajectory,
    rows: rows,
  );
}

EigenRowData _buildRow(
  EigenvectorConfig c, {
  required double? targetRateLbWk,
  required ProgramSlice? slice,
  required DateTime? blockStart,
  required ObservedWeightStats stats,
  required List<WeightRow> weightDaily,
  required List<WilksWeek> wilksWeeks,
  required StatusWeek? statusWeek,
  required Map<String, Object?> targets,
  required DateTime today,
  LiveWeekCounts? live,
}) {
  switch (c.id) {
    case 'weight_loss':
    case 'gain_rate':
    case 'weight_hold':
      // Observed rate: 3-week change / 3 when available (the flag-grade
      // window), else the latest weekly rate — same selection as
      // program_observed.phaseVerdict.
      double? observed =
          stats.bw3wkChange == null ? null : stats.bw3wkChange! / 3;
      if (observed == null) {
        for (final r in stats.recentRates) {
          if (r != null) observed = r;
        }
      }
      // Band: config first; else derive from the slice's
      // gain_rate_lb_wk (list passes through; a scalar block rate r
      // becomes [r/2, 1.5r] — a generous bracket until the config
      // declares the real one).
      var band = c.rateBand;
      if (band == null) {
        final g = targets['gain_rate_lb_wk'];
        if (g is List && g.length == 2) {
          final lo = asNum(g[0]);
          final hi = asNum(g[1]);
          if (lo != null && hi != null) band = [lo, hi];
        } else {
          final r = asNum(g);
          if (r != null && r != 0) band = [r / 2, r * 1.5];
        }
      }
      final verdict = rateBandVerdict(
        observed,
        band,
        actAbove: c.actAbove,
        actBelow: c.actBelow,
      );
      final target = targetRateLbWk ??
          (band == null ? null : (band[0] + band[1]) / 2);
      final detail = stats.bw7dAvg == null && observed == null
          ? 'no weigh-in data'
          : [
              if (stats.bw7dAvg != null)
                '${stats.bw7dAvg!.toStringAsFixed(1)} lb',
              observed == null
                  ? 'no trend yet'
                  : '${_fmtSigned(observed)} lb/wk',
              if (target != null) 'target ${_fmtSigned(target)}',
            ].join(' · ');
      final avg = sevenDayAvgSeries(weightDaily);
      return EigenRowData(
        id: c.id,
        label: c.label ?? 'weight',
        verdict: verdict,
        detail: detail,
        spark: [
          for (final w in avg)
            if (_daysBetween(w.date, today) <= 42 &&
                !w.date.isAfter(today))
              (day: w.date, value: w.weightLbs),
        ],
        nav: EigenNav.program,
      );

    case 'wilks_stability':
    case 'strength_gain':
      final s = wilksStability(
        weeks: wilksWeeks,
        from: c.from ?? blockStart,
        floorPct: c.floorPct,
        actWeeksBelow: c.actWeeksBelow,
        requireGain: c.id == 'strength_gain',
      );
      String detail;
      if (s.current == null) {
        detail = 'no Wilks history yet';
      } else {
        final parts = ['Wilks ${s.current!.toStringAsFixed(1)}'];
        if (c.id == 'strength_gain' && s.reference != null) {
          parts.add('start ${s.reference!.toStringAsFixed(1)}');
          parts.add(_fmtSigned(s.current! - s.reference!, digits: 1));
        } else if (s.floor != null) {
          // Holding: show where the floor sits. Breached: the streak
          // count is the number that matters (3+ = act) — the floor
          // itself stays visible as the sparkline's dashed guide.
          parts.add(s.weeksBelowFloor == 0
              ? 'floor ${s.floor!.toStringAsFixed(1)}'
              : '${s.weeksBelowFloor} wk below floor');
        }
        detail = parts.join(' · ');
      }
      // Sparkline: trailing 26 weekly points — enough lead-in to see
      // the phase-start level without dwarfing the cut window.
      final spark = wilksWeeks.length <= 26
          ? wilksWeeks
          : wilksWeeks.sublist(wilksWeeks.length - 26);
      return EigenRowData(
        id: c.id,
        label: c.label ?? 'strength',
        verdict: s.verdict,
        detail: detail,
        spark: [for (final w in spark) (day: w.weekStart, value: w.wilks)],
        sparkReference: s.reference,
        sparkFloor: s.floor == s.reference ? null : s.floor,
        nav: EigenNav.strength,
      );

    case 'inputs_delivered':
      final row = statusWeek?.row;
      if (row == null && live == null) {
        return EigenRowData(
          id: c.id,
          label: c.label ?? 'inputs',
          verdict: EigenVerdict.unknown,
          detail: 'no status data',
          nav: EigenNav.status,
        );
      }
      // LIVE current-week counts (2026-09-22) beat the nightly status
      // row — the tab is stale all day. The row remains the fallback
      // (and the only source for completed weeks). Pro-rate the running
      // week by days elapsed IN THE ACCOUNTING WEEK (weekday/7 assumed
      // Monday starts; wrong under v7's saturday weeks).
      final weekAnchor = live?.weekStart ?? statusWeek!.weekMonday;
      final fraction = live != null || statusWeek!.isCurrentWeek
          ? (_daysBetween(weekAnchor, today) + 1).clamp(1, 7) / 7
          : 1.0;
      final nearMax = live != null
          ? live.nearMaxSets.toDouble()
          : asNum(row!['near_max_sets']);
      final working = live != null
          ? live.workingSets.toDouble()
          : asNum(row!['working_sets']);
      final verdict = worstVerdict([
        quotaVerdict(nearMax, targets['near_max_sets'],
            weekElapsedFraction: fraction),
        quotaVerdict(working, targets['working_sets'],
            weekElapsedFraction: fraction),
      ]);
      String q(double? done, Object? target) =>
          '${done == null ? '—' : done.round()}/${targetText(target)}';
      return EigenRowData(
        id: c.id,
        label: c.label ?? 'inputs',
        verdict: verdict,
        detail: 'near-max ${q(nearMax, targets['near_max_sets'])} · '
            'sets ${q(working, targets['working_sets'])}',
        nav: EigenNav.status,
      );

    default:
      return EigenRowData(
        id: c.id,
        label: c.label ?? c.id,
        verdict: EigenVerdict.unknown,
        detail: 'unknown eigenvector',
        nav: EigenNav.program,
      );
  }
}
