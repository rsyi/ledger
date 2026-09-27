/// `forecast` tab codec — the nightly sim trajectory as sheet rows.
/// One row per simulated week, REPLACE-ALL written by
/// tool/program_status_update.dart and read by the MCP worker's
/// get_coach_context `forecast` block.
///
/// RE-POINTED to sim2 v2.1 (2026-09-26 spec): the writer now encodes a
/// [Sim2Run] via [sim2ForecastTabRows] — SAME headers/shape (the MCP
/// block keeps parsing unchanged), new values: per-lift columns carry
/// TRUE expressed strength (RPE basis, capacity × expression), `phase`
/// carries the block emphasis (cut/reverse/climbing/lifting), and
/// `grade_p75` carries the sim2 continuous grade C (the §3 module has
/// its own [log] anchor — the v1 offset-anchoring is retired with the
/// v1 model; [gradeAnchorOffset] + the [SimResult] encoder remain only
/// for the superseded v1 path/tests). Pure Dart — no Flutter, no IO.
library;

import 'sim_core.dart' show SimResult, SimWeek;
import 'sim_fit.dart' show simLifts;
import 'sim2_harness.dart' show Sim2Run;
import 'wilks.dart' show wilksPointsLb;

/// The tab name in the workbook.
const String forecastTabName = 'forecast';

/// Header row: monday, phase, bw, per-lift e1RM, wilks, grade_p75.
const List<String> forecastTabHeaders = [
  'monday',
  'phase',
  'bw',
  'e1rm_squat',
  'e1rm_bench',
  'e1rm_deadlift',
  'e1rm_press',
  'wilks',
  'grade_p75',
];

/// The delta applied to every forecast grade so the curve starts at the
/// OBSERVED p75 instead of the model's raw level. Zero when either side
/// is missing (no anchoring possible → raw model values pass through).
double gradeAnchorOffset({double? observedP75, double? modelP75}) =>
    observedP75 == null || modelP75 == null ? 0 : observedP75 - modelP75;

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Object _r1(double v) => double.parse(v.toStringAsFixed(1));

/// Encodes [result] as forecast-tab data rows (header not included).
/// [gradeOffset] is the [gradeAnchorOffset] to apply to every grade
/// cell; weeks with no climbing model leave the cell blank.
List<List<Object?>> forecastTabRows(SimResult result, {double gradeOffset = 0}) {
  return [
    for (final w in result.weeks)
      [
        _ymd(w.monday),
        w.phase,
        _r1(w.bw),
        for (final l in simLifts) w.e1rm[l] == null ? '' : _r1(w.e1rm[l]!),
        _r1(w.wilks),
        w.gradeP75 == null ? '' : _r1(w.gradeP75! + gradeOffset),
      ],
  ];
}

/// Encodes a sim2 [run] as forecast-tab data rows (header not
/// included) — the v2.1 nightly writer's path. Column mapping per the
/// library note: true expressed per-lift, Wilks from the SBD expressed
/// total at the week's bw, C in the grade column.
List<List<Object?>> sim2ForecastTabRows(Sim2Run run) => [
      for (final w in run.weeks)
        [
          _ymd(w.monday),
          w.emphasis,
          _r1(w.bw),
          _r1(w.squat),
          _r1(w.bench),
          _r1(w.deadlift),
          _r1(w.press),
          _r1(wilksPointsLb(w.sTrue, w.bw)),
          _r1(w.c),
        ],
    ];

/// One decoded forecast-tab row.
class ForecastWeekRow {
  final DateTime monday;
  final String phase;
  final double bw;
  final Map<String, double> e1rm;
  final double wilks;

  /// Offset-anchored forecast grade; null when the cell was blank.
  final double? gradeP75;

  const ForecastWeekRow({
    required this.monday,
    required this.phase,
    required this.bw,
    required this.e1rm,
    required this.wilks,
    this.gradeP75,
  });
}

/// Decodes a raw forecast tab (header row + data rows, the shape
/// values.get returns). Header-driven so column drift is tolerated;
/// rows missing monday/phase/bw/wilks are skipped, never fatal.
List<ForecastWeekRow> parseForecastTab(List<List<Object?>> tab) {
  if (tab.length < 2) return const [];
  final head = <String, int>{
    for (var i = 0; i < tab.first.length; i++) tab.first[i].toString().trim(): i,
  };
  String cell(List<Object?> row, int? i) =>
      i == null || i < 0 || i >= row.length
          ? ''
          : (row[i]?.toString() ?? '').trim();
  double? num_(List<Object?> row, int? i) => double.tryParse(cell(row, i));

  final out = <ForecastWeekRow>[];
  for (final r in tab.skip(1)) {
    final monday = DateTime.tryParse(cell(r, head['monday']));
    final phase = cell(r, head['phase']);
    final bw = num_(r, head['bw']);
    final wilks = num_(r, head['wilks']);
    if (monday == null || phase.isEmpty || bw == null || wilks == null) {
      continue;
    }
    out.add(ForecastWeekRow(
      monday: monday,
      phase: phase,
      bw: bw,
      e1rm: {
        for (final l in simLifts)
          if (num_(r, head['e1rm_$l']) != null) l: num_(r, head['e1rm_$l'])!,
      },
      wilks: wilks,
      gradeP75: num_(r, head['grade_p75']),
    ));
  }
  return out;
}

/// Convenience for tests/callers: encode a header+data table in one call.
List<List<Object?>> forecastTabTable(SimResult result, {double gradeOffset = 0}) =>
    [forecastTabHeaders, ...forecastTabRows(result, gradeOffset: gradeOffset)];

/// Placeholder-free milestone extraction shared by the summary line and
/// the milestone table: phase-boundary weeks (each segment's last week).
List<SimWeek> phaseBoundaryWeeks(SimResult result) =>
    [for (final s in result.segments) s.last];
