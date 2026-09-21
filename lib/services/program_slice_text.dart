/// Renders a [ProgramSlice] (plus optional phase + strategy) as terse
/// markdown for injection into the coach system prompt.
///
/// Pure function, zero Flutter/IO imports. Output begins with
/// `## PROGRAM SLICE` and is typically 600–900 characters.
library;

import 'program_current.dart';

/// Renders [slice] (with optional [phase] and [strategy] version maps) as
/// a compact markdown block. All arguments except [slice] are nullable;
/// absent sections are silently omitted.
///
/// [phase] should be the resolved `currentVersion` map from phase.yaml.
/// [strategy] should be the resolved `currentVersion` map from strategy.yaml.
String renderProgramSlice(
  ProgramSlice slice, {
  Map<Object?, Object?>? phase,
  Map<Object?, Object?>? strategy,
}) {
  final buf = StringBuffer();
  buf.writeln('## PROGRAM SLICE');

  // --- Phase line ---
  if (phase != null) {
    final value = phase['value']?.toString() ?? '?';
    final effectiveFrom = phase['effective_from']?.toString() ?? '?';
    final reason = phase['reason']?.toString();
    final targetWt = phase['target_weight_lb'];
    final phaseLineParts = ['phase=$value', 'from=$effectiveFrom'];
    if (targetWt != null) phaseLineParts.add('target=${targetWt}lb');
    if (reason != null && reason.isNotEmpty) {
      phaseLineParts.add('reason="${reason.trim()}"');
    }
    buf.writeln('Phase: ${phaseLineParts.join(', ')}');
  }

  // --- Strategy ---
  if (strategy != null) {
    final text = strategy['text']?.toString().trim();
    if (text != null && text.isNotEmpty) {
      buf.writeln('Strategy: $text');
    }
  }

  // --- Block / week / week_type line ---
  final block = slice.block;
  final blockN = block['number'];
  final emphasis = block['emphasis']?.toString() ?? '?';
  final blockDates = block['dates'];
  final targetWt = block['target_weight'];
  final blockDateStr = blockDates is List && blockDates.length == 2
      ? '${blockDates[0]}…${blockDates[1]}'
      : '';
  final targetWtStr = targetWt is List && targetWt.length == 2
      ? '${targetWt[0]}→${targetWt[1]}lb'
      : (targetWt?.toString() ?? '');
  final blockParts = [
    'block=$blockN/$emphasis',
    if (blockDateStr.isNotEmpty) blockDateStr,
    if (targetWtStr.isNotEmpty) targetWtStr,
  ];
  buf.writeln(
      'Block: ${blockParts.join(', ')} | week ${slice.weekInBlock} | ${slice.weekType}');

  // --- Today's template ---
  final tt = slice.todayTemplate;
  final weekday = tt['weekday']?.toString() ?? '?';
  final morning = tt['morning']?.toString().trim();
  final afternoon = tt['afternoon']?.toString().trim();
  final blockNote = tt['block_note']?.toString().trim();
  buf.writeln('Today ($weekday):');
  if (morning != null && morning.isNotEmpty) buf.writeln('  AM: $morning');
  if (afternoon != null && afternoon.isNotEmpty) buf.writeln('  PM: $afternoon');
  if (blockNote != null && blockNote.isNotEmpty) {
    buf.writeln('  Note: $blockNote');
  }
  if ((morning == null || morning.isEmpty) &&
      (afternoon == null || afternoon.isEmpty)) {
    buf.writeln('  Off');
  }

  // --- Targets in force ---
  final tif = slice.targetsInForce;
  final targetParts = <String>[];

  void addTarget(String key, String label) {
    final v = tif[key];
    if (v == null) return;
    if (v is List) {
      targetParts.add('$label=${v.join('-')}');
    } else {
      targetParts.add('$label=$v');
    }
  }

  addTarget('near_max_sets', 'near_max_sets');
  addTarget('working_sets', 'working_sets');
  addTarget('working_sets_min_normal', 'working_sets_min');
  addTarget('bench_days', 'bench_days');
  addTarget('squat_days', 'squat_days');
  addTarget('deadlift_days', 'deadlift_days');
  addTarget('climbing_sessions', 'climbing');
  addTarget('bike_4x4', 'bike_4x4');
  addTarget('gain_rate_lb_wk', 'gain_rate_lb_wk');
  addTarget('hard_cap_lb', 'hard_cap');
  addTarget('protein_g_per_lb', 'protein_g/lb');

  if (targetParts.isNotEmpty) {
    buf.writeln('Targets: ${targetParts.join(', ')}');
  }

  // --- Rules in force ---
  if (slice.rulesInForce.isNotEmpty) {
    buf.writeln('Rules: ${slice.rulesInForce.join(', ')}');
  }

  return buf.toString().trimRight();
}
