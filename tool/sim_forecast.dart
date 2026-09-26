// ignore_for_file: avoid_print

import 'dart:io';

import 'package:airledger/services/program_current.dart' show currentVersion;
import 'package:airledger/services/sim_core.dart';
import 'package:airledger/services/sim_fit.dart';
import 'package:airledger/services/world_model.dart';
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:yaml/yaml.dart';

/// Program-simulation forecast — end-to-end smoke for the W2 sim core
/// (design doc airledger/docs/superpowers/specs/2026-09-25-sim-design.md).
///
///   dart run tool/sim_forecast.dart [--bulk-rate X] [--cut-rate X]
///                                   [--climb-freq 2|3] [--horizon-yr N]
///                                   [--refit]
///
/// Reads FULL history from the workbook (sim_calibrate plumbing),
/// builds the current state vector, loads the declared world model
/// (airledger-fitness app/world_model.yaml) + program (coach/program.yaml
/// current version + coach/phase.yaml), runs the pure-Dart sim with the
/// given levers (defaults per design §5), and prints the trajectory
/// summary: phase segments with bw / per-lift e1RM / Wilks / climbing
/// p75 at each boundary. `--refit` swaps the shipped coefficients for a
/// fresh full-history fit (the app's on-demand path) and reports drift.
final home = Platform.environment['HOME']!;
final configPath = '$home/.config/airledger/config.yaml';
final fitnessRepo = '$home/repos/airledger-fitness';

Future<void> main(List<String> args) async {
  String? argOf(String flag) {
    final i = args.indexOf(flag);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final levers = SimLevers(
    bulkRateLbWk: double.tryParse(argOf('--bulk-rate') ?? ''),
    cutRateLbWk: double.tryParse(argOf('--cut-rate') ?? '') ?? -0.75,
    climbFrequency: int.tryParse(argOf('--climb-freq') ?? '') ?? 2,
    horizonYears: int.tryParse(argOf('--horizon-yr') ?? '') ?? 3,
  );
  final refit = args.contains('--refit');

  // --- Declared config: world model + program + phase -----------------------
  final wm = parseWorldModel(
    File('$fitnessRepo/app/world_model.yaml').readAsStringSync(),
  );
  if (wm == null) {
    stderr.writeln('cannot parse $fitnessRepo/app/world_model.yaml');
    exit(1);
  }
  final programDoc = loadYaml(
    File('$fitnessRepo/coach/program.yaml').readAsStringSync(),
  ) as Map<Object?, Object?>;
  final version = currentVersion(programDoc)!;
  final phaseDoc = loadYaml(
    File('$fitnessRepo/coach/phase.yaml').readAsStringSync(),
  ) as Map<Object?, Object?>;
  final phaseVersion = currentVersion(phaseDoc)!;
  final cutTarget =
      (phaseVersion['target_weight_lb'] as num?)?.toDouble() ??
          wm.sim.phaseRules.nextCycle.cutTargetLb;

  final blocks = <SimBlock>[];
  DateTime? cutEnd;
  for (final b in version['blocks'] as List) {
    final m = b as Map;
    final n = (m['n'] as num).toInt();
    final dates = m['dates'] as List;
    final start = DateTime.parse(dates[0].toString());
    final end = DateTime.parse(dates[1].toString());
    if (n == 0) {
      cutEnd = end; // block 0 IS the cut; its end is the declared date
      continue;
    }
    blocks.add(SimBlock(
      n: n,
      start: start,
      end: end,
      emphasis: m['emphasis'].toString(),
      rate: (m['rate'] as num?)?.toDouble(),
    ));
  }
  final program = SimProgram(
    cutTargetLb: cutTarget,
    cutEndDate: cutEnd!,
    blocks: blocks,
  );

  // --- Live state: full history → weekly series → t0 vector -----------------
  final config = readConfig();
  final api = await sheetsApi(config.keyPath);
  Future<List<List<Object?>>> tab(String name) async {
    try {
      final resp = await api.spreadsheets.values.get(
        config.spreadsheetId,
        "'$name'",
      );
      return resp.values ?? [];
    } on gsheets.DetailedApiRequestError catch (e) {
      if (e.status == 400) return [];
      rethrow;
    }
  }

  final series = buildWeeklySeries(
    strengthRows: strengthRowsFromTab(await tab('strength')),
    weightRows: weightRowsFromTab(await tab('weight')),
    climbs: climbsFromTab(await tab('kaya_ascents')),
  );
  final last = series.length - 1;
  final e1rm0 = <String, double>{};
  final peak0 = <String, double>{};
  for (final l in simLifts) {
    final v = series.e1rm[l]![last];
    if (v == null) continue;
    e1rm0[l] = v;
    var peak = v;
    for (final raw in series.e1rmRaw[l]!) {
      if (raw != null && raw > peak) peak = raw;
    }
    peak0[l] = peak;
  }
  var actualSbd = 0.0;
  var actualComplete = true;
  for (final l in simSbdLifts) {
    final v = series.bestActual[l]![last];
    if (v == null) {
      actualComplete = false;
    } else {
      actualSbd += v;
    }
  }
  final initial = SimInitialState(
    monday: series.mondays[last],
    bw: series.bw[last]!,
    e1rm: e1rm0,
    peak: peak0,
    gradeP75: series.gradeP75[last],
    actualMaxSbdTotalLbs: actualComplete ? actualSbd : null,
  );

  var coefficients = wm.toCoefficients();
  if (refit) {
    final fresh = fitFromSeries(series);
    print('REFIT coefficients (shipped → refit):');
    for (final l in simLifts) {
      final s = wm.toCoefficients().strengthFor(l)!;
      final f = fresh.strengthFor(l)!;
      print('  $l: a ${s.a} → ${f.a.toStringAsFixed(3)}, '
          'b_bw ${s.bBw} → ${f.bBw.toStringAsFixed(3)}');
    }
    print('  climb: c0 ${wm.toCoefficients().climbC0} → '
        '${fresh.climbC0?.toStringAsFixed(2)}, c_bw '
        '${wm.toCoefficients().climbCBw} → '
        '${fresh.climbCBw?.toStringAsFixed(4)}');
    print('');
    coefficients = fresh;
  }

  final result = simulate(
    initial: initial,
    coefficients: coefficients,
    rules: wm.sim,
    program: program,
    levers: levers,
  );

  // --- Summary ---------------------------------------------------------------
  String f1(double? v) => v == null ? '—' : v.toStringAsFixed(1);
  print('SIM FORECAST — ${levers.horizonYears}yr from ${ymd(initial.monday)} '
      '(levers: bulk ${levers.bulkRateLbWk ?? "block rates"}, '
      'cut ${levers.cutRateLbWk}, climb ${levers.climbFrequency}/wk)');
  print('');
  print('t0: bw ${f1(initial.bw)} | '
      '${[for (final l in simLifts) '$l ${f1(initial.e1rm[l])}'].join(' | ')} '
      '| Wilks ${f1(result.weeks.first.wilks)} | '
      'p75 observed ${f1(initial.gradeP75)} (C2 model '
      '${f1(result.weeks.first.gradeP75)})');
  print('');
  print('| phase | weeks | start .. end | bw | squat | bench | dead | press '
      '| Wilks | p75 |');
  print('|---|---|---|---|---|---|---|---|---|---|');
  for (final s in result.segments) {
    final w = s.last;
    print('| ${s.phase} | ${s.weeks} | ${ymd(s.start)} .. ${ymd(s.end)} | '
        '${f1(s.first.bw)} → ${f1(w.bw)} | ${f1(w.e1rm['squat'])} | '
        '${f1(w.e1rm['bench'])} | ${f1(w.e1rm['deadlift'])} | '
        '${f1(w.e1rm['press'])} | ${f1(w.wilks)} | ${f1(w.gradeP75)} |');
  }
  final end = result.weeks.last;
  print('');
  print('horizon (${ymd(end.monday)}): bw ${f1(end.bw)} | '
      '${[for (final l in simLifts) '$l ${f1(end.e1rm[l])}'].join(' | ')} '
      '| Wilks ${f1(end.wilks)} | p75 ${f1(end.gradeP75)}');
}

// ---------------------------------------------------------------------------
// Config / API (sim_calibrate pattern)
// ---------------------------------------------------------------------------

({String spreadsheetId, String keyPath}) readConfig() {
  final lines = File(configPath).readAsLinesSync();
  String? pick(String key) {
    for (final l in lines) {
      if (l.startsWith('$key:')) return l.substring(key.length + 1).trim();
    }
    return null;
  }

  final spreadsheetId = pick('spreadsheet_id');
  if (spreadsheetId == null || spreadsheetId.isEmpty) {
    print('no spreadsheet_id in $configPath');
    exit(1);
  }
  final keyPath =
      pick('service_account_key_path') ??
      '$home/.config/airledger/service-account.json';
  return (spreadsheetId: spreadsheetId, keyPath: keyPath);
}

Future<gsheets.SheetsApi> sheetsApi(String keyPath) async {
  final keyJson = await File(keyPath).readAsString();
  final credentials = ServiceAccountCredentials.fromJson(keyJson);
  final client = await clientViaServiceAccount(credentials, [
    gsheets.SheetsApi.spreadsheetsScope,
  ]);
  return gsheets.SheetsApi(client);
}

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
