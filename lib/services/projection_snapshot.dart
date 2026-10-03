/// projection_snapshot.dart — FROZEN PHASE PROJECTIONS (spec
/// docs/superpowers/specs/2026-10-02-phase-projections-design.md).
///
/// The nightly `forecast` tab is replace-all and recalibrates, so it
/// never offers a fixed line to judge yourself against. A SNAPSHOT is
/// that fixed line: at a block's first nightly run the writer freezes
/// the weekly projected path + an uncertainty band for every metric
/// from block start to block end, plus the inputs it ran on. Snapshots
/// live in the APPEND-ONLY `projection_snapshots` tab (one row per
/// block × metric × week) and are never rewritten; the UI and the MCP
/// coach context use each block's SELECTED snapshot (see
/// [firstSnapshotForBlock]: newest baseline_version, then newest
/// actuals_version, then the earliest made_at).
///
/// ANCHORING — every metric's projection starts AT THE OBSERVED VALUE on
/// the block's start day (data available then only) and follows the
/// model's trajectory from there:
///   * bodyweight — the sim's own bw path (the run is seeded with the
///     7-day average at block start, so it is anchored by construction);
///   * body_fat — observed scale BF + the sim's BF change (the sim's BF
///     is on the DEXA basis, ~6 pts above the Withings scale; anchoring
///     the change keeps the comparison basis-consistent);
///   * strength_total / `e1rm_<lift>` — the INDEX basis (what logged
///     e1RMs show — the sim's attempt-gated index line, NOT true
///     expressed strength, which the logs never measure directly):
///     total = sIdx (the run is seeded with the observed SBD e1RM total,
///     so sIdx(0) IS the observed total); per lift = observed e1RM ×
///     the lift's index-basis relative change (lift × sIdx/sTrue);
///   * climbing_grade — observed 4-week p75 grade + the sim's C change
///     (the forecast tab's gradeAnchorOffset idea);
///   * vo2max — the sim value (no measured VO2 source exists).
/// Without an observed anchor a metric falls back to the raw model.
///
/// BAND METHOD (documented choice): the sim's Monte Carlo only noises
/// strength capacity and climbing (σcap 1.5 lb/wk, σC 0.05 V/wk + the
/// §7 injury hazard), while bodyweight/BF/VO2 are driven by the dialed
/// rate r and come out deterministic. So the band is the ENVELOPE of
///   (1) the MC p10..p90 across [mcPaths] seeded paths (strength,
///       climbing),
///   (2) two deterministic RATE-BRACKET runs at r ± [rateTolLbWk]
///       (0.25 lb/wk — the declared-rate slack the phase verdict
///       tolerates; moves bodyweight, BF, VO2 and the cut-cost term of
///       strength), and
///   (3) a measurement-noise FLOOR around the projected line: ±1.25 lb
///       bodyweight (the 7-day-average scale noise forecast_calibration
///       uses), ±1.0 pt BF, ±3% e1RM (≈ the calibration's 25 lb total
///       band), ±1.0 VO2, ±0.5 V climbing.
/// The band therefore starts at the floor in week 0 and widens with the
/// model's own uncertainty.
///
/// Pure Dart (no Flutter, no IO).
library;

import 'dart:convert';
import 'dart:math';

import 'sim2_harness.dart';
import 'sim2_model.dart';

/// The append-only tab in the main workbook.
const String projectionSnapshotsTabName = 'projection_snapshots';

/// Column order (spec): inputs_json is filled on the snapshot's first
/// (bodyweight week-0) row only.
const List<String> projectionSnapshotHeaders = [
  'block',
  'metric',
  'week_start',
  'projected',
  'band_lo',
  'band_hi',
  'made_at',
  'program_version',
  'inputs_json',
];

/// Version of the ACTUAL definitions the anchors were computed with
/// (projection_tracking.dart). v1 = calendar-week e1RM; v2 = rolling
/// 7-day e1RM. A snapshot's week-0 anchors must use the same definition
/// as the live actuals it is tracked against, so selection prefers the
/// newest version present for a block (an anchor-definition change is
/// a system re-baseline) and the nightly writer re-freezes a block
/// whose snapshots all predate the current version. Older snapshots
/// stay in the tab (append-only history).
const int projectionActualsVersion = 2;

/// USER RE-BASELINE marker (inputs_json `baseline_version`, absent = 1).
/// A user-directed re-baseline of a block (e.g. 2026-10-02: block 0
/// re-frozen on the program's declared rate after a thin-data
/// nutrition rate) appends a new set with baseline_version = the
/// block's max + 1 and `supersedes` = the made_at of the set it
/// replaces; selection prefers the highest baseline_version, so the
/// superseded set stays in the tab as readable history. A system
/// re-freeze (actuals-definition bump) CARRIES the block's current max
/// baseline_version, never outranking the user's choice.
int maxBaselineVersionForBlock(List<ProjectionSnapshot> existing, int block) {
  var v = 0;
  for (final s in existing) {
    if (s.block == block && s.baselineVersion > v) v = s.baselineVersion;
  }
  return v == 0 ? 1 : v;
}

/// Model identity recorded in every snapshot's inputs.
const String projectionModelVersion = 'sim2 v2.1 (fitted 2026-09-26)';

/// Metric wire ids.
abstract final class ProjectionMetric {
  static const bodyweight = 'bodyweight';
  static const bodyFat = 'body_fat';
  static const strengthTotal = 'strength_total';
  static const e1rmSquat = 'e1rm_squat';
  static const e1rmBench = 'e1rm_bench';
  static const e1rmDeadlift = 'e1rm_deadlift';
  static const e1rmPress = 'e1rm_press';
  static const vo2max = 'vo2max';
  static const climbingGrade = 'climbing_grade';

  /// Canonical order (rows are written in this order).
  static const all = [
    bodyweight,
    bodyFat,
    strengthTotal,
    e1rmSquat,
    e1rmBench,
    e1rmDeadlift,
    e1rmPress,
    vo2max,
    climbingGrade,
  ];

  static const lifts = ['squat', 'bench', 'deadlift', 'press'];

  static String e1rm(String lift) => 'e1rm_$lift';
}

/// Band floors (measurement noise) — see the library note.
const double projectionBwFloorLb = 1.25;
const double projectionBfFloorPts = 1.0;
const double projectionStrengthFloorFrac = 0.03;
const double projectionVo2Floor = 1.0;
const double projectionClimbFloorV = 0.5;

/// Default rate bracket (lb/wk) for the deterministic band runs.
const double projectionRateTolLbWk = 0.25;

/// One weekly projected value: [weekStart] is the Monday the value
/// applies to (week 0 = the block's start Monday, the anchor).
class ProjectionPoint {
  final DateTime weekStart;
  final double projected, lo, hi;

  const ProjectionPoint(this.weekStart, this.projected, this.lo, this.hi);
}

/// The observed values on the block's start day (null = no data then).
class ProjectionAnchors {
  final double? bodyweight;
  final double? bodyFat;
  final double? climbingGrade;

  /// lift → latest RPE-adjusted e1RM (squat/bench/deadlift/press).
  final Map<String, double> e1rm;

  const ProjectionAnchors({
    this.bodyweight,
    this.bodyFat,
    this.climbingGrade,
    this.e1rm = const {},
  });

  /// SBD e1RM total (the index anchor); null unless all three exist.
  double? get indexTotal {
    final s = e1rm['squat'], b = e1rm['bench'], d = e1rm['deadlift'];
    return s == null || b == null || d == null ? null : s + b + d;
  }

  Map<String, Object?> toJson() => {
    'bodyweight': _r2(bodyweight),
    'body_fat': _r2(bodyFat),
    'climbing_grade': _r2(climbingGrade),
    'e1rm': {for (final e in e1rm.entries) e.key: _r2(e.value)},
    'index_total': _r2(indexTotal),
  };
}

/// One frozen projection set: a block × made_at.
class ProjectionSnapshot {
  final int block;
  final DateTime madeAt;
  final String programVersion;

  /// metric → weekly points, ascending by weekStart.
  final Map<String, List<ProjectionPoint>> metrics;

  /// The inputs the projection ran on (decoded inputs_json).
  final Map<String, Object?> inputs;

  const ProjectionSnapshot({
    required this.block,
    required this.madeAt,
    required this.programVersion,
    required this.metrics,
    this.inputs = const {},
  });

  /// The actual-definitions version the anchors used (1 when absent —
  /// the first backfill predates the field).
  int get actualsVersion =>
      (inputs['actuals_version'] as num?)?.toInt() ??
      int.tryParse('${inputs['actuals_version']}') ??
      1;

  /// The user re-baseline generation (1 when absent — every snapshot
  /// before the 2026-10-02 block-0 re-baseline).
  int get baselineVersion =>
      (inputs['baseline_version'] as num?)?.toInt() ??
      int.tryParse('${inputs['baseline_version']}') ??
      1;

  /// Where the weight rate came from: 'declared' (the program's block
  /// rate) or 'logged_intake' (the nutrition estimate). Older sets
  /// recorded only `r_source` ('declared_block_rate' / 'nutrition').
  String? get rateSource {
    final v = inputs['rate_source']?.toString();
    if (v != null) return v;
    return switch (inputs['r_source']?.toString()) {
      'nutrition' => 'logged_intake',
      'declared_block_rate' => 'declared',
      _ => null,
    };
  }

  /// Block emphasis (cut / reverse / climbing / lifting) from inputs.
  String? get emphasis => inputs['block_emphasis']?.toString();

  /// First projected week (the anchor Monday).
  DateTime? get start {
    final fromInputs = DateTime.tryParse('${inputs['block_start']}');
    if (fromInputs != null) return _utcDay(fromInputs);
    final pts =
        metrics[ProjectionMetric.bodyweight] ??
        (metrics.isEmpty ? null : metrics.values.first);
    return pts == null || pts.isEmpty ? null : pts.first.weekStart;
  }

  /// Declared block end (inputs), else the last projected week.
  DateTime? get end {
    final fromInputs = DateTime.tryParse('${inputs['block_end']}');
    if (fromInputs != null) return _utcDay(fromInputs);
    final pts =
        metrics[ProjectionMetric.bodyweight] ??
        (metrics.isEmpty ? null : metrics.values.first);
    return pts == null || pts.isEmpty ? null : pts.last.weekStart;
  }

  /// Sheet rows (no header), canonical metric order, inputs_json on the
  /// very first row only.
  List<List<Object?>> toRows() {
    final out = <List<Object?>>[];
    final made = madeAt.toIso8601String();
    var first = true;
    for (final m in [
      ...ProjectionMetric.all.where(metrics.containsKey),
      ...metrics.keys.where((k) => !ProjectionMetric.all.contains(k)),
    ]) {
      for (final p in metrics[m]!) {
        out.add([
          block,
          m,
          _ymd(p.weekStart),
          _r2(p.projected),
          _r2(p.lo),
          _r2(p.hi),
          made,
          programVersion,
          first ? jsonEncode(inputs) : '',
        ]);
        first = false;
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

/// Per-time-step metric values from one run (index 0 = the start
/// state, index k = the state after week k−1's step).
List<Map<String, double>> _runValues(
  Sim2Run run,
  ProjectionAnchors a,
  double startIndexTotal,
) {
  final st = run.start;
  // Week-0 per-lift index values: lift × sIdx/sTrue.
  final r0 = startIndexTotal / st.s;
  final lift0 = {
    'squat': st.squat * r0,
    'bench': st.bench * r0,
    'deadlift': st.deadlift * r0,
    'press': st.press * r0,
  };
  final out = <Map<String, double>>[];
  void add({
    required double bw,
    required double bf,
    required double sIdx,
    required double sTrue,
    required Map<String, double> lifts,
    required double vo2,
    required double c,
  }) {
    final ratio = sIdx / sTrue;
    final m = <String, double>{
      ProjectionMetric.bodyweight: bw,
      ProjectionMetric.bodyFat: a.bodyFat == null
          ? bf
          : a.bodyFat! + (bf - st.bfPct),
      ProjectionMetric.strengthTotal: a.indexTotal == null
          ? sIdx
          : a.indexTotal! * sIdx / startIndexTotal,
      ProjectionMetric.vo2max: vo2,
      ProjectionMetric.climbingGrade: a.climbingGrade == null
          ? c
          : a.climbingGrade! + (c - st.c),
    };
    for (final l in ProjectionMetric.lifts) {
      final idx = lifts[l]! * ratio;
      final anchor = a.e1rm[l];
      m[ProjectionMetric.e1rm(l)] = anchor == null
          ? idx
          : anchor * idx / lift0[l]!;
    }
    out.add(m);
  }

  add(
    bw: st.bw,
    bf: st.bfPct,
    sIdx: startIndexTotal,
    sTrue: st.s,
    lifts: {
      'squat': st.squat,
      'bench': st.bench,
      'deadlift': st.deadlift,
      'press': st.press,
    },
    vo2: st.vo2,
    c: st.c,
  );
  for (final w in run.weeks) {
    add(
      bw: w.bw,
      bf: w.bfPct,
      sIdx: w.sIdx,
      sTrue: w.sTrue,
      lifts: {
        'squat': w.squat,
        'bench': w.bench,
        'deadlift': w.deadlift,
        'press': w.press,
      },
      vo2: w.vo2,
      c: w.c,
    );
  }
  return out;
}

double _floorFor(String metric, double projected) => switch (metric) {
  ProjectionMetric.bodyweight => projectionBwFloorLb,
  ProjectionMetric.bodyFat => projectionBfFloorPts,
  ProjectionMetric.vo2max => projectionVo2Floor,
  ProjectionMetric.climbingGrade => projectionClimbFloorV,
  _ => projectionStrengthFloorFrac * projected.abs(),
};

double _pct(List<double> sorted, double q) {
  final pos = q * (sorted.length - 1);
  final lo = pos.floor(), hi = pos.ceil();
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

/// The plain-language band method stored in inputs_json.
const String projectionBandMethod =
    'envelope of MC p10-p90 (strength/climbing noise + injury hazard), '
    'deterministic rate-bracket runs at r ± rate_tol, and a '
    'measurement-noise floor (bw ±1.25 lb, BF ±1.0 pt, e1RM ±3%, '
    'VO2 ±1.0, climbing ±0.5 V)';

/// Freezes the projection for block [blockN] of [blocks]: a weekly run
/// from the block's start Monday to its end, anchored on [anchors] (the
/// observed values on the block's start day). [rLbWk]/[proteinGPerLb]
/// are the nutrition-derived dials for the block (null → the declared
/// block rate / baseline protein). [extraInputs] (TMs, nutrition
/// numbers, recalibration scales, replay flag…) are merged into the
/// recorded inputs. Null when [blockN] is not in [blocks].
ProjectionSnapshot? buildProjectionSnapshot({
  required Sim2Params params,
  required List<Sim2Block> blocks,
  required int blockN,
  required ProjectionAnchors anchors,
  required DateTime madeAt,
  required String programVersion,
  double? rLbWk,
  double? proteinGPerLb,
  Map<String, Object?> extraInputs = const {},
  int mcPaths = 200,
  double rateTolLbWk = projectionRateTolLbWk,
}) {
  final idx = blocks.indexWhere((b) => b.n == blockN);
  if (idx < 0) return null;
  final block = blocks[idx];
  final startMonday = sim2StartMonday(block.start);
  final startIndexTotal = anchors.indexTotal ?? sim2SeedIndexTotal;
  final baseR = rLbWk ?? block.r;

  Sim2Run run({double? r, Random? rng}) => sim2Run(
    params: params,
    blocks: blocks,
    start: startMonday,
    horizon: block.end,
    blockOverrides: {
      if (r != null || proteinGPerLb != null)
        blockN: Sim2DialOverrides(r: r, p: proteinGPerLb),
    },
    observedBw: anchors.bodyweight,
    observedIndexTotal: startIndexTotal,
    rng: rng,
    sNoise: rng == null ? 0 : 1.5,
    cNoise: rng == null ? 0 : 0.05,
    injuries: rng != null,
  );

  final det = _runValues(run(r: rLbWk), anchors, startIndexTotal);
  final brackets = [
    _runValues(run(r: baseR - rateTolLbWk), anchors, startIndexTotal),
    _runValues(run(r: baseR + rateTolLbWk), anchors, startIndexTotal),
  ];
  final paths = [
    for (var i = 0; i < mcPaths; i++)
      _runValues(run(r: rLbWk, rng: Random(42 + i)), anchors, startIndexTotal),
  ];

  final metrics = <String, List<ProjectionPoint>>{};
  for (final m in ProjectionMetric.all) {
    final pts = <ProjectionPoint>[];
    for (var k = 0; k < det.length; k++) {
      final p = det[k][m]!;
      final floor = _floorFor(m, p);
      var lo = p - floor, hi = p + floor;
      for (final b in brackets) {
        lo = min(lo, b[k][m]!);
        hi = max(hi, b[k][m]!);
      }
      if (paths.isNotEmpty) {
        final vals = [for (final path in paths) path[k][m]!]..sort();
        lo = min(lo, _pct(vals, 0.10));
        hi = max(hi, _pct(vals, 0.90));
      }
      pts.add(
        ProjectionPoint(startMonday.add(Duration(days: 7 * k)), p, lo, hi),
      );
    }
    metrics[m] = pts;
  }

  final inputs = <String, Object?>{
    'block': blockN,
    'block_emphasis': block.emphasis,
    'block_start': _ymd(block.start),
    'block_end': _ymd(block.end),
    'anchor_date': _ymd(block.start),
    'program_version': programVersion,
    'model_version': projectionModelVersion,
    'actuals_version': projectionActualsVersion,
    'r_lb_wk': _r2(baseR),
    'r_source': rLbWk == null ? 'declared_block_rate' : 'nutrition',
    'rate_source': rLbWk == null ? 'declared' : 'logged_intake',
    'baseline_version': 1,
    'protein_g_per_lb': _r2(proteinGPerLb),
    'anchors': anchors.toJson(),
    'params': {for (final d in sim2ParamDefs) d.id: d.get(params)},
    'band_method': projectionBandMethod,
    'mc_paths': mcPaths,
    'rate_tol_lb_wk': rateTolLbWk,
    ...extraInputs,
  };

  return ProjectionSnapshot(
    block: blockN,
    madeAt: madeAt,
    programVersion: programVersion,
    metrics: metrics,
    inputs: inputs,
  );
}

// ---------------------------------------------------------------------------
// Codec + selection
// ---------------------------------------------------------------------------

/// True when row 1 of the raw tab is the expected header (every
/// [projectionSnapshotHeaders] column, in order) — or the tab is empty
/// (a fresh tab gets its header written first). The nightly writer
/// REFUSES to append under anything else (the values.append-at-A1
/// gotcha once ate program_moves' header row; appending below a data
/// row would bake the damage in).
bool projectionTabHeaderOk(List<List<Object?>> tab) {
  if (tab.isEmpty) return true;
  final row = tab.first;
  if (row.length < projectionSnapshotHeaders.length) return false;
  for (var i = 0; i < projectionSnapshotHeaders.length; i++) {
    if ((row[i]?.toString() ?? '').trim() != projectionSnapshotHeaders[i]) {
      return false;
    }
  }
  return true;
}

/// Row 1 looks like a DATA row (numeric block + a known metric) — the
/// header row is missing.
bool _looksLikeDataRow(List<Object?> row) =>
    row.length >= 4 &&
    num.tryParse('${row[0]}'.trim()) != null &&
    ProjectionMetric.all.contains('${row[1]}'.trim());

/// Decodes the raw tab (header + rows) into snapshot sets grouped by
/// (block, made_at), sorted by block then made_at. Header-driven;
/// malformed rows are skipped, never fatal. REPAIR-READ: when row 1 is
/// a data row (the header was lost), every row — row 1 included — is
/// read positionally in [projectionSnapshotHeaders] order.
List<ProjectionSnapshot> parseProjectionSnapshots(List<List<Object?>> tab) {
  if (tab.isEmpty) return const [];
  final headerless =
      !projectionTabHeaderOk(tab) && _looksLikeDataRow(tab.first);
  if (!headerless && tab.length < 2) return const [];
  final head = <String, int>{
    if (headerless)
      for (var i = 0; i < projectionSnapshotHeaders.length; i++)
        projectionSnapshotHeaders[i]: i
    else
      for (var i = 0; i < tab.first.length; i++)
        tab.first[i].toString().trim(): i,
  };
  String cell(List<Object?> r, String k) {
    final i = head[k];
    return i == null || i >= r.length ? '' : (r[i]?.toString() ?? '').trim();
  }

  final groups = <String, _Group>{};
  for (final r in tab.skip(headerless ? 0 : 1)) {
    final block =
        int.tryParse(cell(r, 'block')) ??
        double.tryParse(cell(r, 'block'))?.round();
    final metric = cell(r, 'metric');
    final week = DateTime.tryParse(cell(r, 'week_start'));
    final proj = double.tryParse(cell(r, 'projected'));
    final made = cell(r, 'made_at');
    final madeAt = DateTime.tryParse(made);
    if (block == null ||
        metric.isEmpty ||
        week == null ||
        proj == null ||
        madeAt == null) {
      continue;
    }
    final g = groups.putIfAbsent(
      '$block|$made',
      () => _Group(block, madeAt, cell(r, 'program_version')),
    );
    final lo = double.tryParse(cell(r, 'band_lo')) ?? proj;
    final hi = double.tryParse(cell(r, 'band_hi')) ?? proj;
    g.metrics
        .putIfAbsent(metric, () => [])
        .add(ProjectionPoint(_utcDay(week), proj, lo, hi));
    final ij = cell(r, 'inputs_json');
    if (ij.isNotEmpty && g.inputs.isEmpty) {
      try {
        final decoded = jsonDecode(ij);
        if (decoded is Map) {
          g.inputs.addAll({
            for (final e in decoded.entries) '${e.key}': e.value,
          });
        }
      } catch (_) {
        /* malformed inputs degrade to empty */
      }
    }
  }
  final out = [
    for (final g in groups.values)
      ProjectionSnapshot(
        block: g.block,
        madeAt: g.madeAt,
        programVersion: g.programVersion,
        metrics: {
          for (final e in g.metrics.entries)
            e.key: (e.value
              ..sort((a, b) => a.weekStart.compareTo(b.weekStart))),
        },
        inputs: g.inputs,
      ),
  ];
  out.sort(
    (a, b) => a.block != b.block
        ? a.block.compareTo(b.block)
        : a.madeAt.compareTo(b.madeAt),
  );
  return out;
}

class _Group {
  final int block;
  final DateTime madeAt;
  final String programVersion;
  final Map<String, List<ProjectionPoint>> metrics = {};
  final Map<String, Object?> inputs = {};

  _Group(this.block, this.madeAt, this.programVersion);
}

/// Selection order: the highest baseline_version (a USER re-baseline)
/// wins, then the newest actuals_version (a system re-baseline), then
/// the earliest made_at (re-snapshots with the same baseline +
/// definitions never displace the first). Mirrored by ledger-mcp
/// src/phase_tracking.ts.
bool _preferred(ProjectionSnapshot a, ProjectionSnapshot b) =>
    a.baselineVersion != b.baselineVersion
        ? a.baselineVersion > b.baselineVersion
        : a.actualsVersion != b.actualsVersion
        ? a.actualsVersion > b.actualsVersion
        : a.madeAt.isBefore(b.madeAt);

/// The block's SELECTED snapshot (newest baseline_version, then newest
/// actuals definition, then earliest made_at) — what the UI and the
/// coach track against. Null when the block has none.
ProjectionSnapshot? firstSnapshotForBlock(
  List<ProjectionSnapshot> snapshots,
  int block,
) {
  ProjectionSnapshot? best;
  for (final s in snapshots) {
    if (s.block != block) continue;
    if (best == null || _preferred(s, best)) best = s;
  }
  return best;
}

/// First snapshot per block ([firstSnapshotForBlock]'s rule), keyed by
/// block number.
Map<int, ProjectionSnapshot> firstSnapshotsByBlock(
  List<ProjectionSnapshot> snapshots,
) {
  final out = <int, ProjectionSnapshot>{};
  for (final s in snapshots) {
    final cur = out[s.block];
    if (cur == null || _preferred(s, cur)) out[s.block] = s;
  }
  return out;
}

/// The first snapshot of the block covering [day] (its recorded
/// block_start ≤ day ≤ block_end); when no block covers the day, the
/// latest block that started on/before it (a finished phase keeps
/// tracking at its end until the next block is frozen). Null when no
/// snapshot started by [day]. Mirrored by the MCP phase_tracking block.
ProjectionSnapshot? snapshotForDay(
  Map<int, ProjectionSnapshot> firstByBlock,
  DateTime day,
) {
  final d = _utcDay(day);
  ProjectionSnapshot? latest;
  for (final s in firstByBlock.values) {
    final start = s.start, end = s.end;
    if (start == null || d.isBefore(start)) continue;
    if (end != null && !d.isAfter(end)) return s;
    if (latest == null || start.isAfter(latest.start!)) latest = s;
  }
  return latest;
}

/// Whether the nightly writer still owes [block] its snapshot: none
/// yet, or every existing one predates [projectionActualsVersion]
/// (anchors on a superseded actual definition — re-freeze once).
bool snapshotNeededForBlock(List<ProjectionSnapshot> existing, int block) =>
    !existing.any(
      (s) => s.block == block && s.actualsVersion >= projectionActualsVersion,
    );

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

DateTime _utcDay(DateTime d) => DateTime.utc(d.year, d.month, d.day);

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

double? _r2(double? v) => v == null ? null : double.parse(v.toStringAsFixed(2));
