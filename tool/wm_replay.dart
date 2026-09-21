// ignore_for_file: avoid_print

import 'dart:io';

import 'package:airledger/services/program_current.dart';
import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, mainLiftByExercise;
import 'package:airledger/services/working_max.dart';
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:yaml/yaml.dart';

/// §7.1 acceptance replay for the working-max controller spec (airledger
/// repo, docs/superpowers/specs/2026-09-21-working-max-controller-spec.md).
///
///   dart run tool/wm_replay.dart
///
/// Reads the REAL strength rows Aug 1 – Sep 21 2026 from the workbook
/// (coach_backtest.dart plumbing), extracts §1.2 readings for all four
/// lifts, replays cut_early from the §5 seeds, and prints the full trace —
/// per reading: date, lift, raw + converted weight, reps, rpe, variant,
/// kind, decision, wm before/after, reason. The bench sequence should
/// reproduce §7.1: Aug 17 hold; Aug 24 drop→235 cap 8.5; Sep 7 hold;
/// Sep 14 drop→230.
///
/// Notes: §5 marks the deadlift PAIN_CAP active AT SEED (Sep 17 back
/// twinge) — that affects evaluations from Sep 21 onward, not this replay
/// window, so the replay runs the plain cut_early rules and prints a
/// reminder instead.
final home = Platform.environment['HOME']!;
final configPath = '$home/.config/airledger/config.yaml';

const seeds = <String, double>{
  'bench': 240, // paused
  'squat': 320, // belted
  'deadlift': 330, // belted
  'press': 140, // standard
};

Future<void> main() async {
  final config = readConfig();
  final api = await sheetsApi(config.keyPath);
  final resp =
      await api.spreadsheets.values.get(config.spreadsheetId, "'strength'");
  final tab = resp.values ?? [];
  final head = headerIndex(tab);

  final from = DateTime(2026, 8, 1);
  final to = DateTime(2026, 9, 21);
  final rows = <StrengthRow>[];
  for (final r in tab.skip(1)) {
    final date = parseSheetDate(cell(r, head['Date']));
    if (date == null || date.isBefore(from) || date.isAfter(to)) continue;
    final exercise = cell(r, head['Exercise']);
    if (!mainLiftByExercise.containsKey(exercise)) continue;
    final weight = double.tryParse(cell(r, head['Weight']));
    final reps = double.tryParse(cell(r, head['Reps']));
    if (weight == null || reps == null) continue;
    // No planned-row filter needed: planned rows never carry RPE (the
    // planner never fills it) and readings require RPE.
    final rpeText = cell(r, head['RPE']);
    rows.add(StrengthRow(
      date: date,
      exercise: exercise,
      weight: weight,
      reps: reps.round(),
      rpe: rpeText.isEmpty ? null : double.tryParse(rpeText),
      notes: cell(r, head['Notes']),
      // Structured equipment flags (2026-09-21 hardening) — preferred
      // over notes keywords by the variant parser when present.
      paused: boolCell(cell(r, head['Paused'])),
      belted: boolCell(cell(r, head['Belted'])),
    ));
  }

  // cut_early from the LIVE program.yaml v5 (sibling checkout, same file
  // the app syncs), so the replay exercises the real policy encoding.
  final programFile = File('../airledger-fitness/coach/program.yaml');
  final program =
      loadYaml(programFile.readAsStringSync()) as Map<Object?, Object?>;
  final policies = loadPolicies(currentVersion(program)!);
  final cutEarly = policies.firstWhere((p) => p.name == 'cut_early');

  print('# Working-max §7.1 replay — real strength rows '
      '${ymd(from)}..${ymd(to)}, cut_early, §5 seeds');
  print('');
  print('${rows.length} main-lift rows in window. Seeds: $seeds.');
  print('Note: §5 deadlift PAIN_CAP (Sep 17 back twinge) is active AT SEED '
      '(Sep 21) — outside this window; replay applies plain cut_early.');
  print('Pre-program window: no light/test weeks; kinds are heavy_top, or');
  print('capped for the reading right after a drop (extraction rule).');

  final expectedBench = <(String, String, double)>[
    ('2026-08-17', 'hold', 240),
    ('2026-08-24', 'drop', 235),
    ('2026-09-07', 'hold', 235),
    ('2026-09-14', 'drop', 230),
  ];

  for (final lift in ['bench', 'squat', 'deadlift', 'press']) {
    final decisions = replayLift(
      lift: lift,
      seedWm: seeds[lift]!,
      rows: rows,
      policyFor: (_) => cutEarly,
    );
    print('');
    print('## $lift (seed ${fmtNum(seeds[lift]!)})');
    if (decisions.isEmpty) {
      print('  no readings in window');
      continue;
    }
    for (final d in decisions) {
      final r = d.reading!;
      final conv = (r.rawWeightLb - r.weightLb).abs() > 0.01
          ? '${fmtNum(r.rawWeightLb)}→${r.weightLb.toStringAsFixed(1)}'
          : fmtNum(r.weightLb);
      print('  ${ymd(d.date)}  ${conv}x${r.reps}@${fmtNum(r.rpe)}'
          ' [${r.variant}/${r.kind}'
          '${r.grinder ? ' grinder' : ''}${r.missed ? ' missed' : ''}]'
          '  → ${d.action.toUpperCase().padRight(5)} '
          'wm ${fmtNum(d.wmBefore)}→${fmtNum(d.wmAfter)}'
          '${d.capNextTopSetRpe != null ? ' cap ${fmtNum(d.capNextTopSetRpe!)}' : ''}'
          '${d.noTopSetsNextWeek ? ' NO_TOP_SETS_NEXT_WEEK' : ''}'
          '${d.flags.isNotEmpty ? ' flags=${d.flags.join(',')}' : ''}'
          '  (${d.reason})');
    }
    if (lift == 'bench') {
      print('');
      print('  §7.1 expected vs actual:');
      var ok = true;
      for (final (date, action, wm) in expectedBench) {
        final match = decisions.where((d) => ymd(d.date) == date).toList();
        final got = match.isEmpty
            ? 'MISSING'
            : '${match.first.action} → ${fmtNum(match.first.wmAfter)}';
        final pass = match.isNotEmpty &&
            match.first.action == action &&
            match.first.wmAfter == wm;
        if (!pass) ok = false;
        print('    $date expected $action → ${fmtNum(wm)}; got $got '
            '${pass ? 'OK' : '<< DIVERGES'}');
      }
      final extras = [
        for (final d in decisions)
          if (!expectedBench.any((e) => e.$1 == ymd(d.date))) ymd(d.date),
      ];
      if (extras.isNotEmpty) {
        print('    extra bench readings not in §7.1: ${extras.join(', ')}');
      }
      print('  §7.1 bench sequence: ${ok ? 'PASS' : 'CHECK ABOVE'}');
      print('');
      print('  Known real-data divergence (2026-09-21): the Aug 24 top');
      print('  single is LOGGED as 230x1@8.75 ("I think between 8.5 and 9');
      print('  but hard to place. paused on pins") — the spec fixture');
      print('  idealizes it to @9. Under the literal cut_early drop rule');
      print('  (rpe >= 9) 8.75 holds, so the real trace runs one 5 lb step');
      print('  above §7.1 from Aug 24 on (Sep 14 drops 240→235, not');
      print('  235→230), and Sep 7 stays kind=heavy_top (no cap active)');
      print('  instead of §7.1\'s capped-after-drop. The §7.1 sequence');
      print('  itself is pinned by test/working_max_test.dart with the');
      print('  spec\'s own four fixtures and passes.');
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers (coach_backtest.dart pattern)
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

Map<String, int> headerIndex(List<List<Object?>> tab) => tab.isEmpty
    ? {}
    : {
        for (var i = 0; i < tab.first.length; i++)
          tab.first[i].toString(): i,
      };

String cell(List<Object?> row, int? i) =>
    i == null || i < 0 || i >= row.length
        ? ''
        : (row[i]?.toString() ?? '').trim();

/// Tri-state boolean cell: blank/missing = null (not recorded).
bool? boolCell(String s) =>
    s.isEmpty ? null : s.toLowerCase() == 'true';

/// Sheet dates are YYYY-MM-DD (ISO); tolerate M/D/YYYY just in case.
DateTime? parseSheetDate(String s) {
  if (s.isEmpty) return null;
  final iso = DateTime.tryParse(s);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final us = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(s);
  if (us != null) {
    return DateTime(
      int.parse(us.group(3)!),
      int.parse(us.group(1)!),
      int.parse(us.group(2)!),
    );
  }
  return null;
}

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String fmtNum(num v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();
