// ignore_for_file: avoid_print

/// Prints the home STRENGTH card's recent column per lift on BOTH
/// bases — plain capped Epley (pre-2026-09-25) vs the RPE-adjusted
/// capped e1RM (`max_e1rm_rpe`) the card shows now — computed from the
/// live sheet mirror through the exact card path (gradeSets →
/// recentBestE1rm with the program's light-week exclusion), so the
/// deltas are the real on-card changes.
///
///   dart run tool/e1rm_rpe_compare.dart
library;

import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:yaml/yaml.dart';

import 'package:airledger/services/home_synthesis.dart'
    show fmtAge, recentBestE1rm, synthesisLifts;
import 'package:airledger/services/program_current.dart'
    show currentVersion, programCurrent, weekStartDayOf;
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, anchorMondayOf, gradeSets;

const _spreadsheetId = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME']!;
  final program =
      loadYaml(
            await File(
              '$home/repos/airledger-fitness/coach/program.yaml',
            ).readAsString(),
          )
          as Map<Object?, Object?>;
  final phase =
      loadYaml(
            await File(
              '$home/repos/airledger-fitness/coach/phase.yaml',
            ).readAsString(),
          )
          as Map<Object?, Object?>;
  final wsDay = weekStartDayOf(currentVersion(program));

  final keyJson = await File(
    '$home/.config/airledger/service-account.json',
  ).readAsString();
  final client = await clientViaServiceAccount(
    ServiceAccountCredentials.fromJson(keyJson),
    [sheets.SheetsApi.spreadsheetsReadonlyScope],
  );
  final tab = (await sheets.SheetsApi(
    client,
  ).spreadsheets.values.get(_spreadsheetId, "'strength'")).values ??
      const [];
  final head = [for (final h in tab.first) h.toString().toLowerCase()];
  final iDate = head.indexOf('date');
  final iEx = head.indexOf('exercise');
  final iWt = head.indexOf('weight');
  final iReps = head.indexOf('reps');
  final iRpe = head.indexOf('rpe');
  final rows = <StrengthRow>[];
  for (final r in tab.skip(1)) {
    if ([iDate, iEx, iWt, iReps].any((i) => r.length <= i)) continue;
    final d = DateTime.tryParse(r[iDate]?.toString() ?? '');
    final wt = double.tryParse(r[iWt]?.toString() ?? '');
    final reps = double.tryParse(r[iReps]?.toString() ?? '');
    final ex = r[iEx]?.toString() ?? '';
    if (d == null || wt == null || reps == null || ex.isEmpty) continue;
    final rpe = iRpe >= 0 && r.length > iRpe
        ? double.tryParse(r[iRpe]?.toString() ?? '')
        : null;
    rows.add(
      StrengthRow(
        date: d,
        exercise: ex,
        weight: wt,
        reps: reps.round(),
        rpe: rpe,
      ),
    );
  }
  client.close();

  final today = DateTime.now();
  String? weekTypeOf(DateTime weekStart) =>
      programCurrent(program, phase, anchorMondayOf(weekStart))?.weekType;
  final graded = gradeSets(rows);
  print('recent column (14-day best of real work), per lift:');
  for (final lift in synthesisLifts) {
    final old = recentBestE1rm(
      graded,
      lift,
      today,
      weekTypeOf: weekTypeOf,
      weekStartDay: wsDay,
    );
    final adj = recentBestE1rm(
      graded,
      lift,
      today,
      weekTypeOf: weekTypeOf,
      weekStartDay: wsDay,
      rpeAdjusted: true,
    );
    if (old == null || adj == null) {
      print('  ${lift.padRight(9)} —');
      continue;
    }
    print(
      '  ${lift.padRight(9)}'
      ' old ${old.value.round().toString().padLeft(3)}'
      ' (${fmtAge(old.date, today)})'
      ' → new ${adj.value.round().toString().padLeft(3)}'
      ' (${fmtAge(adj.date, today)})'
      '  Δ ${(adj.value - old.value).toStringAsFixed(1)}',
    );
  }
  exit(0);
}
