// ignore_for_file: avoid_print

/// Reproduces app/dashboards.yaml `last_bulk` from live sheet data
/// (2026-09-22): the bulk START is the weigh-in trough — the minimum
/// trailing-7-day average in the ~14 months before the declared bulk
/// end (coach/phase.yaml v1: cut effective 2025-10-06) — via the same
/// tested [weighInTrough] the synthetic suite covers. Also prints each
/// main lift's last-bulk top vs all-time top (actual weight, any reps
/// ≥ 1) with contemporaneous-bodyweight Wilks — the STRENGTH card's
/// numbers, computed off-device for sanity.
///
///   dart run tool/derive_bulk_window.dart [end YYYY-MM-DD] [start …]
///
/// `end` defaults to 2025-10-06; passing `start` skips re-derivation
/// and just prices the window (e.g. after hand-editing dashboards.yaml).
library;

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

import 'package:airledger/services/bulk_window.dart';
import 'package:airledger/services/domain_metrics.dart'
    show allTimeBestWeights, bestWeightsInWindow;
import 'package:airledger/services/home_synthesis.dart'
    show fmtMonthTag, synthesisLifts;
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, WeightRow;
import 'package:airledger/services/wilks.dart'
    show contemporaneousBodyweightLbs, wilksPointsLb;

const _spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';

Future<void> main(List<String> args) async {
  final end = DateTime.parse(args.isNotEmpty ? args[0] : '2025-10-06');
  final home = Platform.environment['HOME']!;
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

  // weight tab: headers id,date,day_of_week,time,weight_lbs,…
  final weightRows = await tab('weight');
  final wHead = [for (final h in weightRows.first) h.toString()];
  final wDate = wHead.indexOf('date');
  final wLbs = wHead.indexOf('weight_lbs');
  final weighIns = <({DateTime day, double value})>[];
  for (final r in weightRows.skip(1)) {
    if (r.length <= wDate || r.length <= wLbs) continue;
    final d = DateTime.tryParse(r[wDate]?.toString() ?? '');
    final v = double.tryParse(r[wLbs]?.toString() ?? '');
    if (d == null || v == null || v <= 0) continue;
    weighIns.add((day: d, value: v));
  }

  final start = args.length > 1
      ? DateTime.parse(args[1])
      : weighInTrough(weighIns, end: end)?.day;
  if (start == null) {
    print('no weigh-ins in the lookback window — nothing to derive');
    exit(1);
  }
  final trough = weighInTrough(weighIns, end: end);
  print('declared bulk end : ${end.toIso8601String().substring(0, 10)}');
  print(
    'derived start     : ${trough?.day.toIso8601String().substring(0, 10)}'
    ' (7d-avg trough ${trough?.avg7.toStringAsFixed(1)} lb)',
  );

  // strength tab → StrengthRow per set (sheet headers are Title Case:
  // id, Date, Day of Week, Exercise, Weight, Reps, …).
  final strengthRows = await tab('strength');
  final sHead = [
    for (final h in strengthRows.first) h.toString().toLowerCase(),
  ];
  final sDate = sHead.indexOf('date');
  final sEx = sHead.indexOf('exercise');
  final sWt = sHead.indexOf('weight');
  final sReps = sHead.indexOf('reps');
  final rows = <StrengthRow>[];
  for (final r in strengthRows.skip(1)) {
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

  final daily = [
    for (final w in weighIns) WeightRow(date: w.day, weightLbs: w.value),
  ];
  final bulk = bestWeightsInWindow(rows, start: start, end: end);
  final allTime = allTimeBestWeights(rows, DateTime.now());
  String cell(({double value, DateTime date})? v) {
    if (v == null) return '—';
    final bw = contemporaneousBodyweightLbs(daily, v.date);
    final w = bw == null
        ? ''
        : ' · ${wilksPointsLb(v.value, bw).toStringAsFixed(1)}w'
              ' @ ${bw.toStringAsFixed(1)}bw';
    return '${v.value}$w · ${fmtMonthTag(v.date)}';
  }

  print('lift      last-bulk top                     all-time top');
  for (final lift in synthesisLifts) {
    print(
      '${lift.padRight(10)}'
      '${cell(bulk[lift]).padRight(34)}'
      '${cell(allTime[lift])}',
    );
  }
  exit(0);
}
