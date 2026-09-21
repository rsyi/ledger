// ignore_for_file: avoid_print

import 'dart:io';

import 'package:yaml/yaml.dart';
import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_slice_text.dart';

/// Prints the current PROGRAM SLICE to stdout from local coach/ YAML files.
///
///   dart run tool/program_slice.dart [--date YYYY-MM-DD]
///
/// Reads from ~/repos/airledger-fitness/coach/ (program.yaml, phase.yaml,
/// strategy.yaml). Exits 1 with a message if program.yaml is missing.
final home = Platform.environment['HOME']!;
final coachDir = '$home/repos/airledger-fitness/coach';

void main(List<String> args) {
  DateTime date = DateTime.now();
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--date':
        final raw = args[++i];
        final parsed = DateTime.tryParse(raw);
        if (parsed == null) {
          print('error: invalid --date value "$raw" (expected YYYY-MM-DD)');
          exit(1);
        }
        date = parsed;
      default:
        print('unknown arg: ${args[i]}');
        exit(1);
    }
  }

  // Normalise to UTC midnight.
  final day = DateTime.utc(date.year, date.month, date.day);

  // --- Load program.yaml (required) ---
  final programFile = File('$coachDir/program.yaml');
  if (!programFile.existsSync()) {
    print(
        'error: program.yaml not found at $coachDir/program.yaml\n'
        'Check that ~/repos/airledger-fitness is checked out and up to date.');
    exit(1);
  }
  final programYaml =
      Map<Object?, Object?>.from(loadYaml(programFile.readAsStringSync()) as Map);

  // --- Load phase.yaml (optional but expected) ---
  Map<Object?, Object?>? phaseYaml;
  final phaseFile = File('$coachDir/phase.yaml');
  if (phaseFile.existsSync()) {
    final parsed = loadYaml(phaseFile.readAsStringSync());
    if (parsed is Map) phaseYaml = Map<Object?, Object?>.from(parsed);
  }

  // --- Load strategy.yaml (optional; may 404/not exist) ---
  Map<Object?, Object?>? strategyYaml;
  final strategyFile = File('$coachDir/strategy.yaml');
  if (strategyFile.existsSync()) {
    final parsed = loadYaml(strategyFile.readAsStringSync());
    if (parsed is Map) strategyYaml = Map<Object?, Object?>.from(parsed);
  }

  // --- Resolve program slice ---
  final slice = programCurrent(programYaml, phaseYaml, day);
  if (slice == null) {
    print('error: date ${day.toIso8601String().substring(0, 10)} falls outside '
        'every block in program.yaml (pre-program or post-program date)');
    exit(1);
  }

  final phase = phaseYaml != null ? currentVersion(phaseYaml) : null;
  final strategy =
      strategyYaml != null ? currentVersion(strategyYaml) : null;

  print(renderProgramSlice(slice, phase: phase, strategy: strategy));
}
