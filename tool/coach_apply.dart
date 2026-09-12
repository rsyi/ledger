// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/input_parser.dart';
import 'package:airledger/services/schema_parser.dart';
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

/// Reads nightly-coach JSON from stdin and writes draft rows + a coach_log
/// entry to the ledger workbook.
///
///   echo '&lt;json&gt;' | dart run tool/coach_apply.dart [--dry-run]
///
/// Input contract:
///   {
///     "summary": "...",
///     "drafted": "cardio: Treadmill 4x4\nstrength: ...",
///     "plan": [
///       {"view": "cardio",
///        "rows": [{"date": "<planning target>", "type": "treadmill", ...}]}
///     ]
///   }
///
/// Validation is STRICT against the fitness-repo schemas: unknown view or
/// unknown field name aborts (exit 1, nothing written); every plan row must
/// carry date == the planning target (see [planningTarget]). Idempotence: if
/// coach_log already has a row for the target date, exits 0 without writing.
/// Draft rows get a fresh UUID id, a
/// derived day_of_week where the view has one, and a BLANK plannable
/// log_field (drafts must be unlogged).
final home = Platform.environment['HOME']!;
final viewsDir = '$home/repos/airledger-fitness/views';
final configPath = '$home/.config/airledger/config.yaml';
const uuid = Uuid();

Future<void> main(List<String> args) async {
  final dryRun = args.contains('--dry-run');
  for (final a in args) {
    if (a != '--dry-run') abort('unknown arg: $a');
  }

  final now = DateTime.now();
  final target = planningTarget(now);
  final targetStr = DateFormat('yyyy-MM-dd').format(target);
  final weekday = DateFormat('EEEE').format(target);

  // -------------------------------------------------------------------------
  // 1. Parse + validate strictly against the schemas. Nothing is written
  //    (or even connected) until validation passes.
  // -------------------------------------------------------------------------
  final input = stdin.transform(utf8.decoder).join();
  final dynamic doc;
  try {
    doc = jsonDecode(await input);
  } catch (e) {
    abort('stdin is not valid JSON: $e');
  }
  if (doc is! Map<String, dynamic>) abort('top-level JSON must be an object');
  final summary = doc['summary'];
  final drafted = doc['drafted'];
  if (summary is! String || summary.isEmpty) {
    abort('missing/empty "summary" string');
  }
  if (drafted is! String || drafted.isEmpty) {
    abort('missing/empty "drafted" string');
  }
  final plan = doc['plan'];
  if (plan is! List) abort('missing "plan" list');
  final unknownKeys = doc.keys.toSet()..removeAll({'summary', 'drafted', 'plan'});
  if (unknownKeys.isNotEmpty) abort('unknown top-level keys: $unknownKeys');

  final coachLog = loadView('coach_log');
  if (coachLog == null) abort('coach_log schema missing from $viewsDir');

  // view name -> (schema, validated row maps)
  final planViews = <String, ViewSchema>{};
  final planRows = <String, List<Map<String, dynamic>>>{};
  for (final entry in plan) {
    if (entry is! Map<String, dynamic>) abort('plan entries must be objects');
    final viewName = entry['view'];
    if (viewName is! String) abort('plan entry missing "view"');
    final view = planViews[viewName] ?? loadView(viewName);
    if (view == null) abort('unknown view: $viewName');
    planViews[viewName] = view;
    final rows = entry['rows'];
    if (rows is! List || rows.isEmpty) {
      abort('plan entry for $viewName missing non-empty "rows"');
    }
    final dimNames = view.dimensions.map((d) => d.name).toSet();
    for (final row in rows) {
      if (row is! Map<String, dynamic>) abort('$viewName rows must be objects');
      for (final field in row.keys) {
        if (!dimNames.contains(field)) {
          abort('unknown field "$field" for view $viewName '
              '(known: ${dimNames.join(', ')})');
        }
      }
      if (row['id'] != null) abort('$viewName row must not carry an id');
      final date = row['date'];
      if (date != targetStr) {
        abort('$viewName row date "$date" != planning target ($targetStr) — '
            'plan rows must all be for the planning target');
      }
      planRows.putIfAbsent(viewName, () => []).add(row);
    }
  }

  final config = readConfig();
  final api = await sheetsApi(config.keyPath);

  // -------------------------------------------------------------------------
  // 2. Idempotence guard: bail if coach_log already has a row for the
  //    planning target.
  // -------------------------------------------------------------------------
  final logSpreadsheetId = coachLog.spreadsheetId ?? config.spreadsheetId;
  final existingLog = await readTab(api, logSpreadsheetId, coachLog.table);
  if (existingLog != null && existingLog.length > 1) {
    final headers = existingLog.first.map((e) => e.toString()).toList();
    final dateExpr = coachLog.dimensionByName('date')?.expr ?? 'date';
    final dateCol = headers.indexOf(dateExpr);
    if (dateCol >= 0 &&
        existingLog.skip(1).any(
              (r) =>
                  dateCol < r.length &&
                  (r[dateCol]?.toString().trim() ?? '') == targetStr,
            )) {
      print('already ran for $targetStr');
      exit(0);
    }
  }

  // -------------------------------------------------------------------------
  // 3. Build all cell rows up front (resolving headers per tab) so any
  //    missing-header error aborts before a single append happens.
  // -------------------------------------------------------------------------
  final writes = <_TabWrite>[];
  var draftCount = 0;
  for (final viewName in planRows.keys) {
    final view = planViews[viewName]!;
    final spreadsheetId = view.spreadsheetId ?? config.spreadsheetId;
    final headers = await resolveHeaders(api, spreadsheetId, view);
    final logField = view.plannable?.logField;
    final hasDow = view.dimensionByName('day_of_week') != null;

    final cellRows = <List<Object?>>[];
    for (final row in planRows[viewName]!) {
      final byName = <String, Object?>{...row, 'id': uuid.v4()};
      if (hasDow) byName['day_of_week'] = weekday;
      // Drafts must be unlogged: blank the log field even if supplied.
      if (logField != null) byName.remove(logField);
      cellRows.add(placeByHeader(view, headers, byName, viewName));
      draftCount++;
    }
    writes.add(
      _TabWrite(view, spreadsheetId, headers.create, headers.headers, cellRows),
    );
  }

  // coach_log entry.
  final logHeaders = await resolveHeaders(api, logSpreadsheetId, coachLog);
  final logRow = placeByHeader(coachLog, logHeaders, {
    'id': uuid.v4(),
    'date': targetStr,
    'generated_at': DateTime.now().toIso8601String(),
    'summary': summary,
    'drafted': drafted,
  }, 'coach_log');
  writes.add(
    _TabWrite(
      coachLog,
      logSpreadsheetId,
      logHeaders.create,
      logHeaders.headers,
      [logRow],
    ),
  );

  // -------------------------------------------------------------------------
  // 4. Dry run: print exactly what would be appended, write nothing.
  // -------------------------------------------------------------------------
  if (dryRun) {
    print('DRY RUN — nothing will be written\n');
    for (final w in writes) {
      final action = w.createTab
          ? 'create tab "${w.view.table}" + append'
          : 'append to "${w.view.table}"';
      print('${w.view.name}: $action (${w.rows.length} row(s))');
      print('  headers: ${jsonEncode(w.headers)}');
      for (final r in w.rows) {
        print('  ${jsonEncode(r)}');
      }
    }
    print('\nwould apply: $draftCount draft rows across '
        '${planRows.length} views + coach_log for $targetStr');
    exit(0);
  }

  // -------------------------------------------------------------------------
  // 5. Write: create missing tabs (headers first), then values.append.
  // -------------------------------------------------------------------------
  for (final w in writes) {
    if (w.createTab) {
      print('creating tab ${w.view.table} ...');
      try {
        await api.spreadsheets.batchUpdate(
          gsheets.BatchUpdateSpreadsheetRequest(
            requests: [
              gsheets.Request(
                addSheet: gsheets.AddSheetRequest(
                  properties: gsheets.SheetProperties(title: w.view.table),
                ),
              ),
            ],
          ),
          w.spreadsheetId,
        );
      } on gsheets.DetailedApiRequestError catch (e) {
        // A manually created blank tab reaches here with createTab=true
        // (it still needs its header row); tolerate "already exists".
        if (e.status != 400) rethrow;
      }
      await api.spreadsheets.values.update(
        gsheets.ValueRange(values: [w.headers]),
        w.spreadsheetId,
        "'${w.view.table}'!A1",
        valueInputOption: 'RAW',
      );
    }
    print('appending ${w.rows.length} row(s) to ${w.view.table} ...');
    await api.spreadsheets.values.append(
      gsheets.ValueRange(values: w.rows),
      w.spreadsheetId,
      "'${w.view.table}'!A1",
      valueInputOption: 'RAW',
    );
  }

  print('applied: $draftCount draft rows across ${planRows.length} views '
      '+ coach_log for $targetStr');
  exit(0);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Planning target: the next training day. Before noon we're planning
/// TODAY (a just-after-midnight or on-wake run); from noon on we're
/// planning TOMORROW (the normal ~23:30 nightly run).
DateTime planningTarget(DateTime now) =>
    now.hour < 12 ? DateTime(now.year, now.month, now.day)
                  : DateTime(now.year, now.month, now.day + 1);

class _TabWrite {
  final ViewSchema view;
  final String spreadsheetId;
  final bool createTab;
  final List<String> headers;
  final List<List<Object?>> rows;
  _TabWrite(
    this.view,
    this.spreadsheetId,
    this.createTab,
    this.headers,
    this.rows,
  );
}

Never abort(String reason) {
  print('abort: $reason');
  exit(1);
}

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
    abort('no spreadsheet_id in $configPath');
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

ViewSchema? loadView(String name) {
  final viewFile = File('$viewsDir/$name.view.yml');
  if (!viewFile.existsSync()) return null;
  var view = parseViewSchema(viewFile.readAsStringSync());
  final inputFile = File('$viewsDir/$name.input.yml');
  if (inputFile.existsSync()) {
    view = applyInputOverlay(
      view,
      parseInputOverlay(inputFile.readAsStringSync()),
    );
  }
  return view;
}

/// Returns all values of a tab, or null if the tab doesn't exist.
Future<List<List<Object?>>?> readTab(
  gsheets.SheetsApi api,
  String spreadsheetId,
  String table,
) async {
  try {
    final resp = await api.spreadsheets.values.get(spreadsheetId, "'$table'");
    return resp.values ?? [];
  } on gsheets.DetailedApiRequestError catch (e) {
    if (e.status == 400) return null; // tab missing
    rethrow;
  }
}

/// (headers, create): the actual header row of the tab, or the schema's
/// exprs when the tab is missing and will be created.
Future<({List<String> headers, bool create})> resolveHeaders(
  gsheets.SheetsApi api,
  String spreadsheetId,
  ViewSchema view,
) async {
  final existing = await readTab(api, spreadsheetId, view.table);
  if (existing == null || existing.isEmpty) {
    // Missing tab OR a manually created blank tab: both need the header
    // row written before append.
    return (
      headers: view.dimensions.map((d) => d.expr).toList(),
      create: true,
    );
  }
  return (
    headers: existing.first.map((e) => e.toString()).toList(),
    create: false,
  );
}

/// Maps dimension-name → value into a cell row ordered by the tab's actual
/// headers (dimension `expr` == header). Aborts if a header is missing for
/// any value we need to write.
List<Object?> placeByHeader(
  ViewSchema view,
  ({List<String> headers, bool create}) resolved,
  Map<String, Object?> byName,
  String viewName,
) {
  final headers = resolved.headers;
  final row = List<Object?>.filled(headers.length, '');
  for (final e in byName.entries) {
    final dim = view.dimensionByName(e.key)!;
    final col = headers.indexOf(dim.expr);
    if (col < 0) {
      abort('sheet tab "${view.table}" has no header "${dim.expr}" '
          '(needed for $viewName.${e.key}); headers: $headers');
    }
    row[col] = e.value ?? '';
  }
  return row;
}
