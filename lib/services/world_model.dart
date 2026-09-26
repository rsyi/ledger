/// Declared causal world model — parser for
/// `airledger-fitness/app/world_model.yaml` (design doc
/// `airledger/docs/superpowers/specs/2026-09-25-sim-design.md` §6).
///
/// The file adopts airlayer's driver vocabulary verbatim (`measure`,
/// `direction`, `form`, `coefficient`, `intercept`, `lag`) and extends
/// it with `fit:` metadata and `sim:` rules (saturation damper, phase
/// rules, lever ranges, the Wilks anchor). Code only EVALUATES the
/// declared config; the shipped coefficients are the cold-start /
/// fallback values the on-demand refit (sim_fit.dart) can override.
///
/// Back-compat by construction: [parseWorldModel] returns null on a
/// missing / malformed / empty document — callers keep whatever they
/// did before the file existed. Pure Dart, no Flutter, no IO.
library;

import 'package:yaml/yaml.dart';

import 'sim_fit.dart' show LiftResponse, SimCoefficients, simLifts;

/// The canonical repo path (same delivery as app/dashboards.yaml).
const kWorldModelPath = 'app/world_model.yaml';

// ---------------------------------------------------------------------------
// Nodes + drivers (airlayer vocabulary)
// ---------------------------------------------------------------------------

/// One declared node of the causal graph.
class WorldModelNode {
  final String id;

  /// Airlayer measure ref ("view.measure") — documentary today (the app
  /// computes the series in Dart); absent for derived nodes.
  final String? measure;

  /// input | derived | null (a plain modeled output).
  final String? kind;

  /// Optional dimension filter (e.g. `{lift: squat}`).
  final Map<String, String> filter;

  const WorldModelNode({
    required this.id,
    this.measure,
    this.kind,
    this.filter = const {},
  });
}

/// One driver edge: `target` responds to `driver` per `form` with the
/// fitted `coefficient`/`intercept`. `fit:` is the audit trail of the
/// last refit (method, window, n, r2, mae) — kept as raw numbers/strings.
class WorldModelDriver {
  final String target;
  final String driver;

  /// linear (level-on-level) | linear_rate (responds to the driver's
  /// weekly rate) — the two forms the sim evaluates today.
  final String form;

  /// positive | negative | unknown.
  final String direction;
  final double coefficient;
  final double intercept;

  /// Fit metadata, verbatim from the YAML (method/window/n/r2/mae_*).
  final Map<String, Object?> fit;

  const WorldModelDriver({
    required this.target,
    required this.driver,
    required this.form,
    required this.direction,
    required this.coefficient,
    required this.intercept,
    this.fit = const {},
  });
}

// ---------------------------------------------------------------------------
// sim: rules
// ---------------------------------------------------------------------------

/// S4 saturation damper bounds (fractions of the all-time peak).
class SaturationRule {
  final double fullBelowPctOfPeak;
  final double zeroAtPctOfPeak;

  const SaturationRule({
    this.fullBelowPctOfPeak = 0.95,
    this.zeroAtPctOfPeak = 1.05,
  });
}

/// Next-cycle auto-generation parameters (design §4 rule 4).
class NextCycleRule {
  final int holdWeeks;
  final double bandTopLb;
  final double cutTargetLb;
  final int reverseWeeks;

  const NextCycleRule({
    this.holdWeeks = 8,
    this.bandTopLb = 170,
    this.cutTargetLb = 154,
    this.reverseWeeks = 3,
  });
}

/// Adaptive phase rules (design §4).
class PhaseRules {
  /// target_or_date — the only supported value today.
  final String cutEndsAt;

  /// maintain — the filler phase between an early cut end and block 1.
  final String earlyCutFiller;
  final double reverseRateLbWk;
  final NextCycleRule nextCycle;

  const PhaseRules({
    this.cutEndsAt = 'target_or_date',
    this.earlyCutFiller = 'maintain',
    this.reverseRateLbWk = 0.15,
    this.nextCycle = const NextCycleRule(),
  });
}

/// Declared min/max range for a slider lever.
class LeverRange {
  final double min;
  final double max;

  const LeverRange({required this.min, required this.max});
}

/// Declared lever ranges (design §5).
class LeverRanges {
  final LeverRange bulkRateLbWk;
  final LeverRange cutRateLbWk;
  final List<int> climbFrequency;
  final LeverRange horizonYr;

  const LeverRanges({
    this.bulkRateLbWk = const LeverRange(min: 0.1, max: 0.6),
    this.cutRateLbWk = const LeverRange(min: -1.6, max: -0.5),
    this.climbFrequency = const [2, 3],
    this.horizonYr = const LeverRange(min: 1, max: 3),
  });
}

/// The `sim:` block — everything the sim core needs beyond coefficients.
class SimRules {
  final SaturationRule saturation;
  final PhaseRules phaseRules;
  final LeverRanges levers;

  /// actual_max_ratio: k = actual-max SBD total / e1RM total at t0.
  final String wilksAnchor;

  const SimRules({
    this.saturation = const SaturationRule(),
    this.phaseRules = const PhaseRules(),
    this.levers = const LeverRanges(),
    this.wilksAnchor = 'actual_max_ratio',
  });
}

// ---------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------

class WorldModel {
  final int version;
  final List<WorldModelNode> nodes;
  final List<WorldModelDriver> drivers;
  final SimRules sim;

  const WorldModel({
    required this.version,
    required this.nodes,
    required this.drivers,
    required this.sim,
  });

  /// Drivers of one target node.
  List<WorldModelDriver> driversOf(String target) =>
      [for (final d in drivers) if (d.target == target) d];

  /// Maps the declared drivers onto the [SimCoefficients] shape the sim
  /// core integrates: per-lift bw-rate responses from the
  /// `e1rm_<lift> ← bw` edges, C2 level anchor from `grade_p75 ← bw`,
  /// C1 frequency term from `grade_p75 ← climb_frequency`. No pooled
  /// entry — the shipped file declares every lift explicitly.
  SimCoefficients toCoefficients() {
    final strength = <String, LiftResponse>{};
    for (final l in simLifts) {
      for (final d in driversOf('e1rm_$l')) {
        if (d.driver == 'bw' && d.form == 'linear_rate') {
          strength[l] = LiftResponse(a: d.intercept, bBw: d.coefficient);
        }
      }
    }
    double? c0, cBw, bf;
    for (final d in driversOf('grade_p75')) {
      if (d.driver == 'bw' && d.form == 'linear') {
        c0 = d.intercept;
        cBw = d.coefficient;
      } else if (d.driver == 'climb_frequency') {
        bf = d.coefficient;
      }
    }
    return SimCoefficients(
      strength: strength,
      pooled: null,
      climbC0: c0,
      climbCBw: cBw,
      climbBf: bf,
    );
  }
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

double? _num(Object? v) => v is num ? v.toDouble() : null;

/// Parses world_model.yaml. Null when [raw] is missing, unparseable, or
/// has no usable `drivers:` list — the back-compat contract (callers
/// behave as if the file doesn't exist). Individual malformed entries
/// are skipped, never fatal; absent `sim:` keys take the design-doc
/// defaults.
WorldModel? parseWorldModel(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  Object? doc;
  try {
    doc = loadYaml(raw);
  } catch (_) {
    return null;
  }
  if (doc is! Map) return null;

  final nodes = <WorldModelNode>[];
  final rawNodes = doc['nodes'];
  if (rawNodes is List) {
    for (final n in rawNodes) {
      if (n is! Map) continue;
      final id = n['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final filter = <String, String>{};
      final rawFilter = n['filter'];
      if (rawFilter is Map) {
        for (final e in rawFilter.entries) {
          filter[e.key.toString()] = e.value.toString();
        }
      }
      nodes.add(WorldModelNode(
        id: id,
        measure: n['measure']?.toString(),
        kind: n['kind']?.toString(),
        filter: filter,
      ));
    }
  }

  final drivers = <WorldModelDriver>[];
  final rawDrivers = doc['drivers'];
  if (rawDrivers is List) {
    for (final d in rawDrivers) {
      if (d is! Map) continue;
      final target = d['target']?.toString().trim() ?? '';
      final driver = d['driver']?.toString().trim() ?? '';
      final coefficient = _num(d['coefficient']);
      if (target.isEmpty || driver.isEmpty || coefficient == null) continue;
      final fit = <String, Object?>{};
      final rawFit = d['fit'];
      if (rawFit is Map) {
        for (final e in rawFit.entries) {
          fit[e.key.toString()] = e.value;
        }
      }
      drivers.add(WorldModelDriver(
        target: target,
        driver: driver,
        form: d['form']?.toString() ?? 'linear',
        direction: d['direction']?.toString() ?? 'unknown',
        coefficient: coefficient,
        intercept: _num(d['intercept']) ?? 0,
        fit: fit,
      ));
    }
  }
  if (drivers.isEmpty) return null;

  var sim = const SimRules();
  final rawSim = doc['sim'];
  if (rawSim is Map) {
    var saturation = const SaturationRule();
    final rawSat = rawSim['saturation'];
    if (rawSat is Map) {
      saturation = SaturationRule(
        fullBelowPctOfPeak: _num(rawSat['full_below_pct_of_peak']) ?? 0.95,
        zeroAtPctOfPeak: _num(rawSat['zero_at_pct_of_peak']) ?? 1.05,
      );
    }
    var phaseRules = const PhaseRules();
    final rawPhase = rawSim['phase_rules'];
    if (rawPhase is Map) {
      var nextCycle = const NextCycleRule();
      final rawNext = rawPhase['next_cycle'];
      if (rawNext is Map) {
        nextCycle = NextCycleRule(
          holdWeeks: _num(rawNext['hold_weeks'])?.round() ?? 8,
          bandTopLb: _num(rawNext['band_top_lb']) ?? 170,
          cutTargetLb: _num(rawNext['cut_target_lb']) ?? 154,
          reverseWeeks: _num(rawNext['reverse_weeks'])?.round() ?? 3,
        );
      }
      phaseRules = PhaseRules(
        cutEndsAt: rawPhase['cut_ends_at']?.toString() ?? 'target_or_date',
        earlyCutFiller: rawPhase['early_cut_filler']?.toString() ?? 'maintain',
        reverseRateLbWk: _num(rawPhase['reverse_rate_lb_wk']) ?? 0.15,
        nextCycle: nextCycle,
      );
    }
    var levers = const LeverRanges();
    final rawLevers = rawSim['levers'];
    if (rawLevers is Map) {
      LeverRange range(Object? v, LeverRange fallback) {
        if (v is Map) {
          final lo = _num(v['min']);
          final hi = _num(v['max']);
          if (lo != null && hi != null) return LeverRange(min: lo, max: hi);
        }
        return fallback;
      }

      final rawFreq = rawLevers['climb_frequency'];
      levers = LeverRanges(
        bulkRateLbWk: range(
          rawLevers['bulk_rate_lb_wk'],
          const LeverRange(min: 0.1, max: 0.6),
        ),
        cutRateLbWk: range(
          rawLevers['cut_rate_lb_wk'],
          const LeverRange(min: -1.6, max: -0.5),
        ),
        climbFrequency: rawFreq is List
            ? [
                for (final f in rawFreq)
                  if (f is num) f.toInt(),
              ]
            : const [2, 3],
        horizonYr: range(
          rawLevers['horizon_yr'],
          const LeverRange(min: 1, max: 3),
        ),
      );
    }
    sim = SimRules(
      saturation: saturation,
      phaseRules: phaseRules,
      levers: levers,
      wilksAnchor:
          rawSim['wilks_anchor']?.toString() ?? 'actual_max_ratio',
    );
  }

  final version = _num(doc['version'])?.round() ?? 1;
  return WorldModel(
    version: version,
    nodes: nodes,
    drivers: drivers,
    sim: sim,
  );
}
