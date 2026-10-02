// ignore_for_file: avoid_print

import 'dart:io';

import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/intent_docs.dart';
import 'package:airledger/services/missed_work.dart';
import 'package:airledger/services/prescribed_exercises.dart';
import 'package:airledger/services/program_moves.dart';
import 'package:airledger/services/program_week.dart';
import 'package:airledger/services/whoop_activity.dart';
import 'package:airledger/services/working_sets.dart';
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:yaml/yaml.dart';

import 'coach_dump.dart' as dump;

/// Missed-work report for the nightly coach briefing (spec
/// 2026-10-02-missed-work-carryover-design §3/§5). READ-ONLY.
///
///   dart run tool/missed_work.dart [--date YYYY-MM-DD]   (default today)
///
/// `--date` is the day being planned ("today" for the detector): items
/// due strictly before it and not covered by the week's logs are missed.
/// Loads program/phase/strategy.yaml from ~/repos/airledger-fitness/coach,
/// reads the strength, cardio (4x4), whoop_workouts, kaya_ascents and
/// program_moves tabs (missing tab = no data, never fails), and prints:
///
///   MISSED THIS WEEK:   one line per item + the exact item name /
///                       from_date / period a ```moves block must copy
///   MOVES THIS WEEK:    active moves (item: Wed 9/30 → Fri 10/2 (source))
///   REMAINING DAYS:     each day --date..Sun with its effective items
///   EXPIRING TONIGHT:   (Sunday only) what expires at the end of the week
///   EXPIRED LAST WEEK:  (Monday only) last week's unplaced misses —
///                       judged through Saturday (Sunday = rest day)
final coachDir = '${dump.home}/repos/airledger-fitness/coach';

const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _label(DateTime d) => '${_wd[d.weekday - 1]} ${d.month}/${d.day}';
String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Future<void> main(List<String> args) async {
  final now = DateTime.now();
  var date = DateTime(now.year, now.month, now.day);
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--date':
        final raw = i + 1 < args.length ? args[++i] : '';
        final p = DateTime.tryParse(raw);
        if (p == null) {
          stderr.writeln('invalid --date "$raw" (expected YYYY-MM-DD)');
          exit(1);
        }
        date = DateTime(p.year, p.month, p.day);
      default:
        stderr.writeln('unknown arg: ${args[i]}');
        exit(1);
    }
  }

  final docs = loadCoachDocs();
  if (docs.program == null) {
    stderr.writeln('program.yaml not found under $coachDir');
    exit(1);
  }

  final config = dump.readConfig();
  final api = await dump.sheetsApi(config.keyPath);
  Future<List<Map<String, Object?>>> rows(String view) =>
      readRecords(api, config.spreadsheetId, view);

  final strength = await rows('strength');
  final cardio = await rows('cardio');
  final whoop = await rows('whoop_workouts');
  final kaya = await rows('climbing'); // kaya_ascents tab
  final moveRows = await rows('program_moves');

  final allMoves = [for (final r in moveRows) ?ProgramMove.fromRecord(r)];
  // Working sets only — warm-ups never credit prescribed items.
  final strengthSets = <({DateTime date, String exercise})>[
    for (final r in workingSetRecords(strength))
      if (_day(r['date']) case final d?)
        if ((r['exercise'] ?? '').toString().trim() case final ex
            when ex.isNotEmpty)
          (date: d, exercise: ex),
  ];
  // 4x4 days — same type filter as the Goals tab / program day card
  // (blank type counts).
  const fourByFourTypes = {'treadmill', 'bike', 'stairmaster'};
  final cardioDays = <DateTime>{
    for (final r in cardio)
      if (_day(r['date']) case final d?)
        if (_isFourByFour(r['type'], fourByFourTypes)) d,
  };
  final climbDays = climbDaysUnion(
    [for (final r in kaya) ?_day(r['date'])],
    whoopClimbDays(whoopActivitiesFromRecords(whoop)),
  );

  ({MissedWork missed, Map<String, ProgramMove> moves,
      Map<DateTime, List<EffectiveItem>> week}) evaluate(DateTime today) {
    final moves = activeMoves(allMoves, mondayOf(today));
    final week = effectiveWeek(prescribedWeek(docs, today), moves);
    final missed = detectMissedWork(
      week: week,
      strengthRows: strengthSets,
      climbDays: climbDays,
      cardio4x4Days: cardioDays,
      today: today,
    );
    return (missed: missed, moves: moves, week: week);
  }

  final r = evaluate(date);
  print('DATE: ${_ymd(date)} (${_label(date)}) — week of '
      '${_label(mondayOf(date))}');

  print('\nMISSED THIS WEEK:');
  _printMissed(r.missed);

  print('\nMOVES THIS WEEK:');
  if (r.moves.isEmpty) {
    print('none');
  } else {
    final ms = r.moves.values.toList()
      ..sort((a, b) => a.from.compareTo(b.from));
    for (final m in ms) {
      final src = m.source.isEmpty ? '' : ' (${m.source})';
      final note = m.note.isEmpty ? '' : ' — ${m.note}';
      print('- ${m.item}: ${_label(m.from)} → ${_label(m.to)}$src$note');
    }
  }

  print('\nREMAINING DAYS:');
  for (final d in r.missed.remainingDays) {
    final items = [
      for (final e in r.week[d] ?? const <EffectiveItem>[])
        if (!e.isGhost) e,
    ];
    if (items.isEmpty) {
      print('- ${_label(d)}: rest / nothing prescribed');
      continue;
    }
    print('- ${_label(d)}:');
    for (final e in items) {
      final tag =
          e.movedFrom == null ? '' : ' (moved from ${_wd[e.movedFrom!.weekday - 1]})';
      print('    ${_itemLine(e.item)}$tag');
    }
  }

  if (date.weekday == DateTime.sunday) {
    print('\nEXPIRING TONIGHT:');
    print('(unplaced work expires at the end of ${_label(date)}; next week '
        'starts clean)');
    _printMissed(r.missed, withKeys: false);
  }
  if (date.weekday == DateTime.monday) {
    final lastSunday = DateTime(date.year, date.month, date.day - 1);
    print('\nEXPIRED LAST WEEK:');
    print('(week of ${_label(mondayOf(lastSunday))}, judged through Sat)');
    _printMissed(evaluate(lastSunday).missed, withKeys: false);
  }
  exit(0);
}

/// Missed lines: the compact prompt line, then the exact keys a moves
/// block must copy (from_date = the program's ORIGINAL day, which is
/// what program_moves keys on).
void _printMissed(MissedWork mw, {bool withKeys = true}) {
  if (mw.isEmpty) {
    print('none');
    return;
  }
  final lines = mw.toPromptLines().split('\n');
  for (var i = 0; i < mw.missed.length; i++) {
    final m = mw.missed[i];
    final moved = m.day == m.home ? '' : ' (moved from ${_label(m.home)})';
    print('${lines[i]}$moved');
    if (withKeys) {
      print('    item="${m.item.name}" from_date=${_ymd(m.home)} '
          'period=${m.item.period.isEmpty ? '-' : m.item.period}');
    }
  }
}

String _itemLine(PrescribedItem i) {
  final p = i.period.isEmpty ? '' : '${i.period} ';
  final scheme = i.scheme.trim();
  final s = scheme.length > 60 ? '${scheme.substring(0, 59)}…' : scheme;
  return '$p${i.name}${s.isEmpty ? '' : ' — $s'}';
}

bool _isFourByFour(Object? type, Set<String> types) {
  final t = (type ?? '').toString().trim().toLowerCase();
  return t.isEmpty || types.contains(t);
}

DateTime? _day(Object? v) => v == null ? null : dump.parseSheetDate('$v');

/// program/phase/strategy.yaml from [coachDir] (missing/bad file = null).
/// Shared with tool/coach_msg.dart's --split-moves validation.
IntentDocs loadCoachDocs() {
  Map<Object?, Object?>? load(String name) {
    final f = File('$coachDir/$name');
    if (!f.existsSync()) return null;
    try {
      final y = loadYaml(f.readAsStringSync());
      return y is Map ? Map<Object?, Object?>.from(y) : null;
    } catch (_) {
      return null;
    }
  }

  return (
    program: load('program.yaml'),
    phase: load('phase.yaml'),
    strategy: load('strategy.yaml'),
  );
}

/// All rows of [viewName]'s tab as dimension-name → cell maps. A missing
/// schema or tab yields []; date dims are normalised to yyyy-mm-dd.
/// Shared with tool/coach_msg.dart.
Future<List<Map<String, Object?>>> readRecords(
  gsheets.SheetsApi api,
  String defaultSpreadsheetId,
  String viewName,
) async {
  final view = dump.loadView(viewName);
  if (view == null) return const [];
  List<List<Object?>> rows;
  try {
    final resp = await api.spreadsheets.values
        .get(view.spreadsheetId ?? defaultSpreadsheetId, "'${view.table}'");
    rows = resp.values ?? const [];
  } on gsheets.DetailedApiRequestError catch (e) {
    if (e.status == 400) return const []; // tab not created yet
    rethrow;
  }
  if (rows.length < 2) return const [];
  final headers = rows.first.map((e) => e.toString()).toList();
  final cols = [
    for (final d in view.dimensions) (d, headers.indexOf(d.expr)),
  ];
  final out = <Map<String, Object?>>[];
  for (final row in rows.skip(1)) {
    final rec = <String, Object?>{};
    for (final (d, i) in cols) {
      if (i < 0) continue;
      final s = dump.cellAt(row, i);
      if (s.isEmpty) continue;
      if (d.type == DimensionType.date) {
        final day = dump.parseSheetDate(s);
        rec[d.name] = day == null ? s : _ymd(day);
      } else {
        rec[d.name] = s;
      }
    }
    if (rec.isNotEmpty) out.add(rec);
  }
  return out;
}
