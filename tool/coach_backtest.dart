// ignore_for_file: avoid_print

import 'dart:io';

import 'package:airledger/services/program_metrics.dart';
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:googleapis_auth/auth_io.dart';

/// §6 backtest for the coach intent-layers spec (airledger repo,
/// docs/superpowers/specs/2026-09-20-coach-intent-layers-spec.md).
///
///   dart run tool/coach_backtest.dart
///
/// Reads FULL strength + weight + 4x4 + climbing history from the workbook
/// (coach_dump.dart pattern), runs gradeSets → weeklyRollup → evaluateFlags
/// from lib/services/program_metrics.dart, and prints each §6 acceptance
/// check with PASS/FAIL and the underlying numbers, plus the weekly metrics
/// tables for the windows §6 names.
///
/// Window convention: a date window selects ISO weeks FULLY CONTAINED in it
/// (Monday >= start AND Sunday <= end). §6's windows all end on a Sunday
/// except checks 1 and 4, which end on a Monday; there the week "of" the end
/// Monday extends past the window and is excluded — its numbers are printed
/// alongside so the ambiguity stays visible.
final home = Platform.environment['HOME']!;
final configPath = '$home/.config/airledger/config.yaml';

Future<void> main() async {
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

  final strengthTab = await tab('strength');
  final weightTab = await tab('weight');
  final cardioTab = await tab('4x4');
  final climbTab = await tab('kaya_ascents');

  // -------------------------------------------------------------------------
  // Map sheet rows → metrics inputs (tolerant; anomalies counted + reported).
  // -------------------------------------------------------------------------
  final anomalies = <String, int>{};
  void anomaly(String kind) => anomalies[kind] = (anomalies[kind] ?? 0) + 1;

  final sHead = headerIndex(strengthTab);
  final strengthRows = <StrengthRow>[];
  for (final r in strengthTab.skip(1)) {
    if (r.isEmpty) {
      anomaly('strength: empty row');
      continue;
    }
    final date = parseSheetDate(cell(r, sHead['Date']));
    if (date == null) {
      anomaly('strength: missing/unparseable Date');
      continue;
    }
    final exercise = cell(r, sHead['Exercise']);
    if (exercise.isEmpty) {
      anomaly('strength: empty Exercise');
      continue;
    }
    final weight = double.tryParse(cell(r, sHead['Weight']));
    final reps = double.tryParse(cell(r, sHead['Reps']));
    if (mainLiftByExercise.containsKey(exercise) &&
        (weight == null || reps == null)) {
      anomaly('strength: main lift missing weight/reps');
      continue;
    }
    final rpeText = cell(r, sHead['RPE']);
    final rpe = rpeText.isEmpty ? null : double.tryParse(rpeText);
    if (rpeText.isNotEmpty && rpe == null) {
      anomaly('strength: unparseable RPE "$rpeText"');
    }
    strengthRows.add(
      StrengthRow(
        date: date,
        exercise: exercise,
        weight: weight ?? 0,
        reps: (reps ?? 0).round(),
        rpe: rpe,
      ),
    );
  }

  final wHead = headerIndex(weightTab);
  final weightRows = <WeightRow>[];
  for (final r in weightTab.skip(1)) {
    final date = parseSheetDate(cell(r, wHead['date']));
    final lbs = double.tryParse(cell(r, wHead['weight_lbs']));
    if (date == null || lbs == null) {
      anomaly('weight: missing date or weight_lbs');
      continue;
    }
    weightRows.add(WeightRow(date: date, weightLbs: lbs));
  }

  // 4x4 rows: the tab holds 4x4 intervals plus a few plain cardio rows once
  // the Type column appeared. A row counts as a 4x4 when Type is blank
  // (legacy rows predate the column; the tab existed only for 4x4s) or a
  // machine modality (treadmill / bike / stairmaster). 'outdoor running'
  // rows are excluded — they're runs, not 4x4 intervals.
  final cHead = headerIndex(cardioTab);
  final fourByFours = <FourByFourRow>[];
  for (final r in cardioTab.skip(1)) {
    final date = parseSheetDate(cell(r, cHead['Date']));
    if (date == null) {
      anomaly('4x4: missing/unparseable Date');
      continue;
    }
    final type = cell(r, cHead['Type']).toLowerCase();
    if (type.isNotEmpty &&
        !const {'treadmill', 'bike', 'stairmaster'}.contains(type)) {
      anomaly('4x4: non-4x4 row excluded (type=$type)');
      continue;
    }
    // work_rate_or_speed: whichever speed column is populated.
    final speed = double.tryParse(cell(r, cHead['Treadmill Speed'])) ??
        double.tryParse(cell(r, cHead['Stairmaster Speed']));
    fourByFours.add(
      FourByFourRow(
        date: date,
        maxHr: double.tryParse(cell(r, cHead['Max Heart Rate'])),
        workRateOrSpeed: speed,
      ),
    );
  }

  final kHead = headerIndex(climbTab);
  final climbingDates = <DateTime>[];
  for (final r in climbTab.skip(1)) {
    final date = parseSheetDate(cell(r, kHead['date']));
    if (date == null) {
      anomaly('kaya_ascents: missing/unparseable date');
      continue;
    }
    climbingDates.add(date);
  }

  // daily_notes has no `cause` field historically → PAIN_NOTE can't fire;
  // notes are not loaded.

  // -------------------------------------------------------------------------
  // Metrics
  // -------------------------------------------------------------------------
  final graded = gradeSets(strengthRows);
  final weeks = weeklyRollup(
    graded,
    weights: weightRows,
    fourByFours: fourByFours,
    climbingDates: climbingDates,
    // PINNED to Monday-keyed ISO weeks, deliberately ignoring the
    // program's v7 `week_start: saturday` (amendment 2026-09-22): the
    // §6 acceptance numbers were validated against Monday weeks and
    // this backtest is historical — rekeying would invalidate the
    // validated flag counts without telling us anything new.
    weekStartDay: DateTime.monday,
  );
  final flags = evaluateFlags(weeks);
  final byMonday = {for (final w in weeks) w.weekStart: w};

  print('# Coach backtest — spec §6 acceptance');
  print('');
  print('Inputs: ${strengthRows.length} strength rows '
      '(${graded.length} main-lift sets), ${weightRows.length} weigh-ins, '
      '${fourByFours.length} 4x4 rows, ${climbingDates.length} climbing '
      'ascents. ${weeks.length} ISO weeks '
      '(${ymd(weeks.first.weekStart)} .. ${ymd(weeks.last.weekStart)}).');
  print('');
  print('Row anomalies (skipped/noted):');
  if (anomalies.isEmpty) print('  none');
  for (final e in anomalies.entries) {
    print('  ${e.value}\t${e.key}');
  }
  print('');
  print('Week-window convention: a window selects ISO weeks fully contained '
      'in it (Mon >= start, Sun <= end). Where §6 names a Monday as the end '
      'date (checks 1 and 4) the boundary week is excluded and its numbers '
      'are shown as a note.');

  var allPass = true;
  void check(int n, String label, bool pass, String detail) {
    if (!pass) allPass = false;
    print('');
    print('## Check $n — ${pass ? 'PASS' : 'FAIL'}: $label');
    print(detail);
  }

  bool fires(String monday, String id) =>
      (flags[DateTime.parse(monday)] ?? []).any((f) => f.id == id);

  // Weeks fully contained in [from, to].
  List<DateTime> mondays(String from, String to) {
    final start = DateTime.parse(from);
    final end = DateTime.parse(to);
    return [
      for (final w in weeks)
        if (!w.weekStart.isBefore(start) && !w.weekSunday.isAfter(end))
          w.weekStart,
    ];
  }

  String weekNote(String monday, String Function(WeeklyMetrics) render) {
    final w = byMonday[DateTime.parse(monday)];
    return w == null ? 'no data' : render(w);
  }

  // Check 1 — NEAR_MAX_LOW / LONG_SETS in the 2025 collapse; quiet in 2024.
  final mustFire = ['2025-05-12', '2025-05-19', '2025-05-26', '2025-06-09'];
  final nmlHits = [for (final m in mustFire) fires(m, 'NEAR_MAX_LOW')];
  final lsHits = [for (final m in mustFire) fires(m, 'LONG_SETS')];
  final quiet2024 = mondays('2024-04-22', '2024-06-24');
  final falsePositives = [
    for (final m in quiet2024)
      if ((flags[m] ?? []).any((f) => f.id == 'NEAR_MAX_LOW')) m,
  ];
  final c1 = !nmlHits.contains(false) &&
      lsHits.where((h) => h).length >= 3 &&
      falsePositives.isEmpty;
  check(
    1,
    'NEAR_MAX_LOW weeks of May 12/19/26 + Jun 9 2025; LONG_SETS in >= 3; '
        'no NEAR_MAX_LOW Apr 22 – Jun 24 2024',
    c1,
    [
      for (var i = 0; i < mustFire.length; i++)
        '  week ${mustFire[i]}: NEAR_MAX_LOW=${nmlHits[i]} '
            '(near_max_sets='
            '${byMonday[DateTime.parse(mustFire[i])]?.nearMaxSets}), '
            'LONG_SETS=${lsHits[i]} (long_failure_sets='
            '${byMonday[DateTime.parse(mustFire[i])]?.longFailureSets})',
      '  2024 window (${quiet2024.length} weeks, '
          '${ymd(quiet2024.first)}..${ymd(quiet2024.last)}): NEAR_MAX_LOW '
          'fired in '
          '${falsePositives.isEmpty ? 'none' : falsePositives.map(ymd).join(', ')}',
      '  note — boundary week of 2024-06-24 (ends Jun 30, outside the '
          'window): ${weekNote('2024-06-24', (w) => 'near_max_sets='
              '${w.nearMaxSets} → NEAR_MAX_LOW would fire under a '
              'Monday-inclusive reading')}',
      // For any expected-fire week that didn't fire, show its near-max sets.
      for (var i = 0; i < mustFire.length; i++)
        if (!nmlHits[i])
          '  near-max sets of week ${mustFire[i]}:\n${[
            for (final s in graded)
              if (s.nearMax &&
                  mondayOf(s.date) == DateTime.parse(mustFire[i]))
                '    ${ymd(s.date)} ${s.lift} ${s.weight}x${s.reps} '
                    'e1rm=${s.e1rm.toStringAsFixed(1)} '
                    'ref=${s.reference!.toStringAsFixed(1)} '
                    'effort=${s.effort!.toStringAsFixed(3)}'
                    '${s.longFailureSet ? ' (long-failure)' : ''}',
          ].join('\n')}',
    ].join('\n'),
  );

  // Check 2 — WEIGHT_FAST at least twice Apr 21 – Jun 22 2025.
  final wfWeeks = [
    for (final m in mondays('2025-04-21', '2025-06-22'))
      if ((flags[m] ?? []).any((f) => f.id == 'WEIGHT_FAST')) m,
  ];
  check(
    2,
    'WEIGHT_FAST fires at least twice between Apr 21 and Jun 22 2025',
    wfWeeks.length >= 2,
    '  fired ${wfWeeks.length}x: '
        '${wfWeeks.map((m) => '${ymd(m)} '
            '(rate=${fmt(byMonday[m]?.bwRateLbWk)})').join(', ')}',
  );

  // Check 3 — working_sets averages.
  double avgOf(List<DateTime> ms, int Function(WeeklyMetrics) f) => ms.isEmpty
      ? double.nan
      : ms.map((m) => f(byMonday[m]!)).reduce((a, b) => a + b) / ms.length;
  final w2024 = mondays('2024-04-29', '2024-07-28');
  final w2025 = mondays('2025-04-21', '2025-06-22');
  final avg2024 = avgOf(w2024, (w) => w.workingSets);
  final avg2025 = avgOf(w2025, (w) => w.workingSets);
  check(
    3,
    'working_sets averages: Apr 29 – Jul 28 2024 in 22–26; '
        'Apr 21 – Jun 22 2025 in 12–16',
    avg2024 >= 22 && avg2024 <= 26 && avg2025 >= 12 && avg2025 <= 16,
    '  2024 window: ${w2024.length} weeks, avg working_sets = '
        '${avg2024.toStringAsFixed(2)} '
        '[${w2024.map((m) => byMonday[m]!.workingSets).join(', ')}]\n'
        '  2025 window: ${w2025.length} weeks, avg working_sets = '
        '${avg2025.toStringAsFixed(2)} '
        '[${w2025.map((m) => byMonday[m]!.workingSets).join(', ')}]',
  );

  // Check 4 — near_max_sets average Dec 2 2024 – Feb 10 2025.
  final w4 = mondays('2024-12-02', '2025-02-10');
  final avg4 = avgOf(w4, (w) => w.nearMaxSets);
  check(
    4,
    'near_max_sets Dec 2 2024 – Feb 10 2025 averages 12–16',
    avg4 >= 12 && avg4 <= 16,
    '  ${w4.length} weeks, avg near_max_sets = ${avg4.toStringAsFixed(2)} '
        '[${w4.map((m) => byMonday[m]!.nearMaxSets).join(', ')}]\n'
        '  note — boundary week of 2025-02-10 (ends Feb 16, outside the '
        'window): ${weekNote('2025-02-10', (w) => 'near_max_sets='
            '${w.nearMaxSets}; including it the avg is still in range')}',
  );

  // Check 5 — RPE sanity by effort band (±0.4).
  final bands = <(String, double, double, double)>[
    ('0.85–0.90', 0.85, 0.90, 7.3),
    ('0.90–0.95', 0.90, 0.95, 7.8),
    ('>=0.95', 0.95, double.infinity, 8.5),
  ];
  var c5 = true;
  final bandLines = <String>[];
  bandLines.add('  band       | sets | avg RPE | expected | delta');
  for (final (label, lo, hi, expected) in bands) {
    final rpes = [
      for (final s in graded)
        if (s.rpe != null &&
            s.effort != null &&
            s.effort! >= lo &&
            s.effort! < hi)
          s.rpe!,
    ];
    final avg = rpes.isEmpty
        ? double.nan
        : rpes.reduce((a, b) => a + b) / rpes.length;
    final ok = rpes.isNotEmpty && (avg - expected).abs() <= 0.4;
    if (!ok) c5 = false;
    bandLines.add(
      '  ${label.padRight(10)} | ${rpes.length.toString().padLeft(4)} | '
      '${avg.toStringAsFixed(2).padLeft(7)} | ${expected.toString().padLeft(8)} | '
      '${rpes.isEmpty ? '—' : (avg - expected).toStringAsFixed(2)}'
      '${ok ? '' : '  << out of ±0.4'}',
    );
  }
  check(
    5,
    'sets with logged RPE by effort band within ±0.4 of '
        '(0.85–0.90 → 7.3, 0.90–0.95 → 7.8, >=0.95 → 8.5)',
    c5,
    bandLines.join('\n'),
  );

  print('');
  print('Check 6 (get_coach_context slice/size) is a later task (A/B).');
  print('');
  print('GATE (checks 1–5): ${allPass ? 'PASS' : 'FAIL'}');

  // -------------------------------------------------------------------------
  // Weekly tables for the §6 windows.
  // -------------------------------------------------------------------------
  final windows = <(String, String, String)>[
    ('Apr–Jul 2024', '2024-04-01', '2024-07-31'),
    ('Dec 2024 – Feb 2025', '2024-12-01', '2025-02-28'),
    ('Apr–Jun 2025', '2025-04-01', '2025-06-30'),
  ];
  // Tables show every week whose Monday falls in the window (informational).
  List<DateTime> tableWeeks(String from, String to) {
    final start = DateTime.parse(from);
    final end = DateTime.parse(to);
    return [
      for (final w in weeks)
        if (!w.weekStart.isBefore(start) && !w.weekStart.isAfter(end))
          w.weekStart,
    ];
  }

  for (final (label, from, to) in windows) {
    print('');
    print('## Weekly metrics — $label');
    print(
      '| week (Mon) | sess | sets | work | hard | nmax | longF | avgReps | '
      'bench_d | climb | bw_7d | rate | flags |',
    );
    print('|---|---|---|---|---|---|---|---|---|---|---|---|---|');
    for (final m in tableWeeks(from, to)) {
      final w = byMonday[m]!;
      final ids = (flags[m] ?? []).map((f) => f.id).join(' ');
      print(
        '| ${ymd(m)} | ${w.sessions} | ${w.setsTotal} | ${w.workingSets} | '
        '${w.hardSets} | ${w.nearMaxSets} | ${w.longFailureSets} | '
        '${w.avgRepsWorking?.toStringAsFixed(1) ?? '—'} | ${w.benchDays} | '
        '${w.climbingSessions} | ${fmt(w.bw7dAvg)} | ${fmt(w.bwRateLbWk)} | '
        '$ids |',
      );
    }
  }
  exit(allPass ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Helpers (coach_dump.dart pattern)
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

String fmt(double? v) => v == null ? '—' : v.toStringAsFixed(1);
