// ignore_for_file: avoid_print

/// Prints the CURRENT weekly actual-max Wilks decomposition off-device
/// (2026-09-25): the same [weeklyWilksSeries] + [wilksWeekDecomposition]
/// the hero STRENGTH row's detail sheet renders, computed from the live
/// sheet mirror — the sanity check that the sheet's three lift lines
/// sum to the displayed stat with real data.
///
///   dart run tool/wilks_decomposition.dart [program.yaml path]
///
/// The accounting week start comes from the live program.yaml
/// (default ~/repos/airledger-fitness/coach/program.yaml — v7 says
/// saturday); pass a path to point elsewhere.
library;

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/program_current.dart'
    show currentVersion, weekStartDayOf;
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, WeightRow;
import 'package:airledger/services/wilks.dart';

const _spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME']!;
  final programPath = args.isNotEmpty
      ? args[0]
      : '$home/repos/airledger-fitness/coach/program.yaml';
  final program =
      loadYaml(await File(programPath).readAsString()) as Map<Object?, Object?>;
  final wsDay = weekStartDayOf(currentVersion(program));

  final keyJson = await File(
    '$home/.config/airledger/service-account.json',
  ).readAsString();
  final client = await clientViaServiceAccount(
    ServiceAccountCredentials.fromJson(keyJson),
    [sheets.SheetsApi.spreadsheetsReadonlyScope],
  );
  final api = sheets.SheetsApi(client);
  Future<List<List<Object?>>> tab(String name) async =>
      (await api.spreadsheets.values.get(_spreadsheetId, "'$name'")).values ??
      const [];

  final weightRows = await tab('weight');
  final wHead = [for (final h in weightRows.first) h.toString()];
  final wDate = wHead.indexOf('date');
  final wLbs = wHead.indexOf('weight_lbs');
  final daily = <WeightRow>[];
  for (final r in weightRows.skip(1)) {
    if (r.length <= wDate || r.length <= wLbs) continue;
    final d = DateTime.tryParse(r[wDate]?.toString() ?? '');
    final v = double.tryParse(r[wLbs]?.toString() ?? '');
    if (d == null || v == null || v <= 0) continue;
    daily.add(WeightRow(date: d, weightLbs: v));
  }

  final strengthTab = await tab('strength');
  final sHead = [for (final h in strengthTab.first) h.toString().toLowerCase()];
  final sDate = sHead.indexOf('date');
  final sEx = sHead.indexOf('exercise');
  final sWt = sHead.indexOf('weight');
  final sReps = sHead.indexOf('reps');
  final rows = <StrengthRow>[];
  for (final r in strengthTab.skip(1)) {
    if ([sDate, sEx, sWt, sReps].any((i) => r.length <= i)) continue;
    final d = DateTime.tryParse(r[sDate]?.toString() ?? '');
    final wt = double.tryParse(r[sWt]?.toString() ?? '');
    final reps = double.tryParse(r[sReps]?.toString() ?? '');
    final ex = r[sEx]?.toString() ?? '';
    if (d == null || wt == null || reps == null || ex.isEmpty) continue;
    rows.add(
      StrengthRow(date: d, exercise: ex, weight: wt, reps: reps.round()),
    );
  }

  final weeks = weeklyWilksSeries(
    rows,
    daily,
    through: DateTime.now(),
    weekStartDay: wsDay,
  );
  if (weeks.isEmpty) {
    print('no computable Wilks weeks');
    exit(1);
  }
  final week = weeks.last;
  final parts = wilksWeekDecomposition(week);
  String day(DateTime d) => d.toIso8601String().substring(0, 10);
  print('week of ${day(week.weekStart)} (week start day $wsDay) · '
      'bw ${week.bodyweightLbs.toStringAsFixed(1)} lb');
  for (final p in parts) {
    print(
      '  ${p.lift.padRight(9)} ${p.weightLbs.toStringAsFixed(0).padLeft(4)}'
      '${p.carriedFrom == null ? '            ' : ' (carried ${day(p.carriedFrom!)})'.padRight(12)}'
      ' → ${p.displayPoints.toStringAsFixed(1)}w'
      '  (exact ${p.points.toStringAsFixed(4)})',
    );
  }
  final sum = parts.fold<double>(0, (s, p) => s + p.displayPoints);
  print('  displayed sum ${sum.toStringAsFixed(1)} · '
      'stat ${week.wilks.toStringAsFixed(1)} · '
      'match: ${sum.toStringAsFixed(1) == week.wilks.toStringAsFixed(1)}');
  exit(0);
}
