// ignore_for_file: avoid_print

import 'dart:io';

import 'package:airledger/services/program_metrics.dart'
    show StrengthRow, epleyE1rm, liftReferencesAsOf, mainLiftByExercise;
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:googleapis_auth/auth_io.dart';

/// One-time equipment-flag backfill for the strength tab (2026-09-21
/// schema hardening: Paused / Belted / Wrist Wraps / Knee Sleeves).
///
///   dart run tool/migrate_equipment.dart            # dry-run (default)
///   dart run tool/migrate_equipment.dart --confirm  # write to the sheet
///
/// What gets backfilled:
///   - **Belted** — Barbell Squat + Barbell Deadlift rows only.
///     1. Notes keywords first: unbelted/beltless/"no belt" -> FALSE;
///        belted/belt -> TRUE (checked in that order — 'no belt' would
///        otherwise hit the bare 'belt' regex).
///     2. Else INFERENCE, applied ONLY to each day's top set per lift
///        (max weight, ties by e1rm — mirrors the working-max reading
///        concept; warm-ups/back-offs stay blank because a warm-up's low
///        effort says nothing about belt use):
///          - effort >= 0.93 vs the 42-day reference (the canonical
///            program_metrics liftReferencesAsOf window) -> TRUE ("very
///            close to peak strength => likely belted").
///          - effort <= 0.80 -> FALSE, but ONLY when the surrounding
///            ±3 weeks show a clearly stronger same-lift cluster
///            (>= 2 other days whose top set hits effort >= 0.92) —
///            i.e. genuinely bimodal, not a detraining/deload stretch.
///          - anything else, or no reference -> BLANK (unknown is
///            honest; the working-max chain falls back to notes).
///   - **Paused** — Flat Barbell Bench Press rows, notes keywords ONLY
///     (no inference): paused/pause/pins -> TRUE (a pin press is a dead
///     stop); touch and go/TnG -> FALSE.
///   - **Wrist Wraps / Knee Sleeves** — NEVER backfilled (user has never
///     used either; the columns exist only so the option is a first-class
///     schema citizen going forward). --confirm still creates the headers.
///
/// Idempotent: rows whose target cell already has a value are skipped.
/// Writes touch ONLY the new columns (batch value ranges per contiguous
/// run); the engine picks the values up on its next sheet pull.
final home = Platform.environment['HOME']!;
final configPath = '$home/.config/airledger/config.yaml';

const beltLifts = {'Barbell Squat', 'Barbell Deadlift'};
const benchName = 'Flat Barbell Bench Press';

// Inference thresholds (documented above).
const beltedEffortGte = 0.93;
const unbeltedEffortLte = 0.80;
const clusterEffortGte = 0.92;
const clusterMinDays = 2;
const clusterWindowDays = 21;

final unbeltedRe =
    RegExp(r'\bunbelted\b|\bbeltless\b|no belt', caseSensitive: false);
final beltedRe = RegExp(r'\bbelted\b|\bbelt\b', caseSensitive: false);
final pausedRe = RegExp(r'\bpaused?\b|\bpins?\b', caseSensitive: false);
final tngRe = RegExp(r'touch[\s&-]*(and|n|&)[\s-]*go|\btng\b',
    caseSensitive: false);

class Assignment {
  final int sheetRow; // 1-based sheet row number
  final bool value;
  final String rule; // explicit-true / explicit-false / inferred-...
  final String evidence;
  Assignment(this.sheetRow, this.value, this.rule, this.evidence);
}

Future<void> main(List<String> args) async {
  final confirm = args.contains('--confirm');
  final config = readConfig();
  final api = await sheetsApi(config.keyPath);
  final resp =
      await api.spreadsheets.values.get(config.spreadsheetId, "'strength'");
  final tab = resp.values ?? [];
  if (tab.isEmpty) {
    print('strength tab is empty — nothing to do');
    exit(1);
  }
  final head = headerIndex(tab);

  // ---------------------------------------------------------------------
  // Build main-lift rows (reference math input) + per-sheet-row facts.
  // ---------------------------------------------------------------------
  final today = DateTime.now();
  final mains = <StrengthRow>[];
  // Per sheet row (index into tab): parsed facts for candidate rows.
  final rowDate = <int, DateTime>{};
  final rowExercise = <int, String>{};
  final rowWeight = <int, double>{};
  final rowReps = <int, int>{};
  final rowNotes = <int, String>{};

  for (var i = 1; i < tab.length; i++) {
    final r = tab[i];
    final date = parseSheetDate(cell(r, head['Date']));
    if (date == null || date.isAfter(today)) continue; // planned/future
    final exercise = cell(r, head['Exercise']);
    if (!mainLiftByExercise.containsKey(exercise)) continue;
    final weight = double.tryParse(cell(r, head['Weight']));
    final reps = double.tryParse(cell(r, head['Reps']));
    if (weight == null || reps == null || weight <= 0 || reps <= 0) continue;
    rowDate[i] = date;
    rowExercise[i] = exercise;
    rowWeight[i] = weight;
    rowReps[i] = reps.round();
    rowNotes[i] = cell(r, head['Notes']);
    mains.add(StrengthRow(
      date: date,
      exercise: exercise,
      weight: weight,
      reps: reps.round(),
    ));
  }

  // Reference per (lift, day) via the canonical 42-day-window helper,
  // computed once per distinct workout day.
  final refByDay = <String, Map<String, double>>{}; // ymd -> lift -> ref
  for (final d in rowDate.values.toSet()) {
    refByDay[ymd(d)] ??= liftReferencesAsOf(mains, d);
  }
  double? refFor(int i) =>
      refByDay[ymd(rowDate[i]!)]?[mainLiftByExercise[rowExercise[i]!]!];
  double effortOf(int i) =>
      epleyE1rm(rowWeight[i]!, rowReps[i]!) / refFor(i)!;

  // Day-top set per (lift, day): max weight, ties by e1rm.
  final topByLiftDay = <String, int>{}; // '<lift>|<ymd>' -> tab index
  for (final i in rowDate.keys) {
    final key = '${mainLiftByExercise[rowExercise[i]!]}|${ymd(rowDate[i]!)}';
    final cur = topByLiftDay[key];
    if (cur == null ||
        rowWeight[i]! > rowWeight[cur]! ||
        (rowWeight[i] == rowWeight[cur] &&
            epleyE1rm(rowWeight[i]!, rowReps[i]!) >
                epleyE1rm(rowWeight[cur]!, rowReps[cur]!))) {
      topByLiftDay[key] = i;
    }
  }
  final topSetRows = topByLiftDay.values.toSet();

  // Day-top efforts per lift, date-sorted, for the ±3-week cluster check.
  final topEffortsByLift = <String, List<(DateTime, double)>>{};
  for (final i in topSetRows) {
    if (refFor(i) == null) continue;
    final lift = mainLiftByExercise[rowExercise[i]!]!;
    (topEffortsByLift[lift] ??= []).add((rowDate[i]!, effortOf(i)));
  }
  for (final l in topEffortsByLift.values) {
    l.sort((a, b) => a.$1.compareTo(b.$1));
  }

  int strongClusterDays(String lift, DateTime around) {
    final days = <String>{};
    for (final (d, e)
        in topEffortsByLift[lift] ?? const <(DateTime, double)>[]) {
      if ((d.difference(around).inDays).abs() > clusterWindowDays) continue;
      if (ymd(d) == ymd(around)) continue; // exclude the candidate's own day
      if (e >= clusterEffortGte) days.add(ymd(d));
    }
    return days.length;
  }

  // ---------------------------------------------------------------------
  // Decide Belted (squat/deadlift) and Paused (bench).
  // ---------------------------------------------------------------------
  final belted = <Assignment>[];
  final paused = <Assignment>[];
  final blanks = <String, int>{}; // reason -> count
  void blank(String why) => blanks[why] = (blanks[why] ?? 0) + 1;

  String setDesc(int i) =>
      '${ymd(rowDate[i]!)} ${rowExercise[i]} '
      '${fmtNum(rowWeight[i]!)}x${rowReps[i]}';

  final beltedIdx = head['Belted'];
  final pausedIdx = head['Paused'];

  for (final i in rowDate.keys) {
    final exercise = rowExercise[i]!;

    if (beltLifts.contains(exercise)) {
      if (cell(tab[i], beltedIdx).isNotEmpty) {
        blank('already set (skipped)');
        continue;
      }
      final notes = rowNotes[i]!;
      if (unbeltedRe.hasMatch(notes)) {
        belted.add(Assignment(
            i + 1, false, 'explicit-false', '${setDesc(i)} notes:"$notes"'));
        continue;
      }
      if (beltedRe.hasMatch(notes)) {
        belted.add(Assignment(
            i + 1, true, 'explicit-true', '${setDesc(i)} notes:"$notes"'));
        continue;
      }
      if (!topSetRows.contains(i)) {
        blank('not the day-top set');
        continue;
      }
      final ref = refFor(i);
      if (ref == null) {
        blank('no 42d reference yet');
        continue;
      }
      final effort = effortOf(i);
      if (effort >= beltedEffortGte) {
        belted.add(Assignment(i + 1, true, 'inferred-true',
            '${setDesc(i)} effort ${effort.toStringAsFixed(3)} '
            '(e1rm ${epleyE1rm(rowWeight[i]!, rowReps[i]!).toStringAsFixed(1)}'
            ' / ref ${ref.toStringAsFixed(1)}) >= $beltedEffortGte'));
      } else if (effort <= unbeltedEffortLte) {
        final lift = mainLiftByExercise[exercise]!;
        final strong = strongClusterDays(lift, rowDate[i]!);
        if (strong >= clusterMinDays) {
          belted.add(Assignment(i + 1, false, 'inferred-false',
              '${setDesc(i)} effort ${effort.toStringAsFixed(3)} <= '
              '$unbeltedEffortLte with $strong strong days (effort >= '
              '$clusterEffortGte) within ±$clusterWindowDays d'));
        } else {
          blank('weak top set but no strong cluster (±3wk) — left blank');
        }
      } else {
        blank('effort in the ambiguous band — left blank');
      }
    } else if (exercise == benchName) {
      if (cell(tab[i], pausedIdx).isNotEmpty) continue;
      final notes = rowNotes[i]!;
      if (notes.isEmpty) continue;
      if (tngRe.hasMatch(notes)) {
        paused.add(Assignment(
            i + 1, false, 'explicit-false', '${setDesc(i)} notes:"$notes"'));
      } else if (pausedRe.hasMatch(notes)) {
        paused.add(Assignment(
            i + 1, true, 'explicit-true', '${setDesc(i)} notes:"$notes"'));
      }
    }
  }

  // ---------------------------------------------------------------------
  // Report
  // ---------------------------------------------------------------------
  int count(List<Assignment> xs, String rule) =>
      xs.where((a) => a.rule == rule).length;

  final sdRows = rowDate.keys
      .where((i) => beltLifts.contains(rowExercise[i]))
      .length;
  print('# migrate_equipment ${confirm ? "APPLY" : "DRY-RUN"} '
      '(${ymd(today)})');
  print('');
  print('strength tab: ${tab.length - 1} data rows; '
      '${rowDate.length} logged main-lift rows in scope; '
      '$sdRows squat/deadlift rows.');
  print('');
  print('## Belted (squat + deadlift): ${belted.length} assignments');
  print('  explicit-true   (notes say belt):    '
      '${count(belted, 'explicit-true')}');
  print('  explicit-false  (notes say no belt): '
      '${count(belted, 'explicit-false')}');
  print('  inferred-true   (effort >= $beltedEffortGte, day-top): '
      '${count(belted, 'inferred-true')}');
  print('  inferred-false  (effort <= $unbeltedEffortLte + strong '
      'cluster): ${count(belted, 'inferred-false')}');
  print('  left blank, by reason:');
  for (final e in blanks.entries) {
    print('    ${e.key}: ${e.value}');
  }
  print('');
  print('## Paused (bench, notes only): ${paused.length} assignments');
  print('  explicit-true:  ${count(paused, 'explicit-true')}');
  print('  explicit-false: ${count(paused, 'explicit-false')}');
  print('');

  final inferences =
      belted.where((a) => a.rule.startsWith('inferred')).toList();
  print('## Sample inferences (up to 20 of ${inferences.length})');
  // Spread samples across the list (not just the earliest rows).
  final step =
      inferences.length <= 20 ? 1 : (inferences.length / 20).ceil();
  for (var k = 0; k < inferences.length && k ~/ step < 20; k += step) {
    final a = inferences[k];
    print('  row ${a.sheetRow}  ${a.value ? 'TRUE ' : 'FALSE'} '
        '[${a.rule}] ${a.evidence}');
  }
  print('');

  // Distribution sanity: belted rate by year (assignments only).
  print('## Distribution sanity — belted assignments by year');
  final byYear = <int, List<Assignment>>{};
  for (final a in belted) {
    (byYear[rowDate[a.sheetRow - 1]!.year] ??= []).add(a);
  }
  for (final y in byYear.keys.toList()..sort()) {
    final xs = byYear[y]!;
    final t = xs.where((a) => a.value).length;
    print('  $y: $t TRUE / ${xs.length - t} FALSE (${xs.length} total)');
  }
  print('');

  if (!confirm) {
    print('Dry-run only. Re-run with --confirm to write.');
    exit(0);
  }

  // ---------------------------------------------------------------------
  // Apply — headers first, then per-column contiguous runs. New columns
  // only; no other cell is ever touched.
  // ---------------------------------------------------------------------
  final header = tab.first.map((c) => c.toString()).toList();
  var nextCol = header.length;
  final colOf = <String, int>{};
  final headerWrites = <gsheets.ValueRange>[];
  for (final name in ['Paused', 'Belted', 'Wrist Wraps', 'Knee Sleeves']) {
    final existing = header.indexOf(name);
    if (existing >= 0) {
      colOf[name] = existing;
    } else {
      colOf[name] = nextCol;
      headerWrites.add(gsheets.ValueRange(
        range: "'strength'!${colLetter(nextCol)}1",
        values: [
          [name]
        ],
      ));
      nextCol++;
    }
  }
  if (headerWrites.isNotEmpty) {
    // The grid may be narrower than the columns we're adding — expand it
    // first (values.batchUpdate can't grow the grid).
    final meta = await api.spreadsheets.get(config.spreadsheetId);
    final sheet = meta.sheets!
        .firstWhere((s) => s.properties?.title == 'strength');
    final gridCols = sheet.properties?.gridProperties?.columnCount ?? 0;
    if (gridCols < nextCol) {
      await api.spreadsheets.batchUpdate(
        gsheets.BatchUpdateSpreadsheetRequest(requests: [
          gsheets.Request(
            appendDimension: gsheets.AppendDimensionRequest(
              sheetId: sheet.properties!.sheetId,
              dimension: 'COLUMNS',
              length: nextCol - gridCols,
            ),
          ),
        ]),
        config.spreadsheetId,
      );
      print('expanded grid from $gridCols to $nextCol columns');
    }
    await api.spreadsheets.values.batchUpdate(
      gsheets.BatchUpdateValuesRequest(
          valueInputOption: 'RAW', data: headerWrites),
      config.spreadsheetId,
    );
    print('created headers: '
        '${headerWrites.map((v) => v.values!.first.first).join(', ')}');
  }

  Future<void> writeColumn(String column, List<Assignment> xs) async {
    if (xs.isEmpty) return;
    final col = colLetter(colOf[column]!);
    xs.sort((a, b) => a.sheetRow.compareTo(b.sheetRow));
    final data = <gsheets.ValueRange>[];
    var runStart = 0;
    for (var k = 1; k <= xs.length; k++) {
      if (k == xs.length || xs[k].sheetRow != xs[k - 1].sheetRow + 1) {
        final run = xs.sublist(runStart, k);
        data.add(gsheets.ValueRange(
          range: "'strength'!$col${run.first.sheetRow}:"
              '$col${run.last.sheetRow}',
          values: [
            for (final a in run) [a.value]
          ],
        ));
        runStart = k;
      }
    }
    // batchUpdate caps are generous, but chunk anyway for safety.
    const chunk = 500;
    for (var k = 0; k < data.length; k += chunk) {
      await api.spreadsheets.values.batchUpdate(
        gsheets.BatchUpdateValuesRequest(
          valueInputOption: 'RAW',
          data: data.sublist(
              k, k + chunk > data.length ? data.length : k + chunk),
        ),
        config.spreadsheetId,
      );
    }
    print('wrote ${xs.length} $column cells in ${data.length} ranges');
  }

  await writeColumn('Belted', belted);
  await writeColumn('Paused', paused);
  print('done. Wrist Wraps / Knee Sleeves intentionally not backfilled.');
}

// ---------------------------------------------------------------------------
// Helpers (wm_replay.dart plumbing)
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
  final keyPath = pick('service_account_key_path') ??
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

/// 0-based column index -> A1 letter(s).
String colLetter(int i) {
  var n = i + 1;
  var s = '';
  while (n > 0) {
    n--;
    s = String.fromCharCode(65 + n % 26) + s;
    n ~/= 26;
  }
  return s;
}
