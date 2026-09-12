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

/// Coach chat message tool — posts and inspects the `coach_chat` tab.
///
///   echo 'text' | dart run tool/coach_msg.dart post --role coach --kind reply
///   dart run tool/coach_msg.dart pending
///   dart run tool/coach_msg.dart briefing-exists --date YYYY-MM-DD
///
/// `post` appends one row (id=UUID, date=today, ts=now ISO, role, kind,
/// text from stdin), creating the tab with headers if missing.
/// `pending` prints the full chat history and exits 0 when the newest
/// message is from the user (i.e. a reply is owed); otherwise exits 3.
/// `briefing-exists` exits 0 if a coach briefing row exists for the given
/// date, else 3.
final home = Platform.environment['HOME']!;
final viewsDir = '$home/repos/airledger-fitness/views';
final configPath = '$home/.config/airledger/config.yaml';
const uuid = Uuid();

Future<void> main(List<String> args) async {
  if (args.isEmpty) abort('usage: coach_msg.dart <post|pending|briefing-exists> ...');
  final cmd = args.first;
  final rest = args.sublist(1);
  switch (cmd) {
    case 'post':
      await post(rest);
    case 'pending':
      await pending(rest);
    case 'briefing-exists':
      await briefingExists(rest);
    default:
      abort('unknown subcommand: $cmd');
  }
}

// ---------------------------------------------------------------------------
// Subcommands
// ---------------------------------------------------------------------------

Future<void> post(List<String> args) async {
  String? role;
  String? kind;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--role':
        role = args[++i];
      case '--kind':
        kind = args[++i];
      default:
        abort('unknown arg: ${args[i]}');
    }
  }
  if (role == null || !{'coach', 'user'}.contains(role)) {
    abort('post requires --role coach|user');
  }
  if (kind == null || !{'briefing', 'reply', 'user'}.contains(kind)) {
    abort('post requires --kind briefing|reply|user');
  }

  final text = (await stdin.transform(utf8.decoder).join()).trim();
  if (text.isEmpty) abort('empty message text on stdin');

  final view = loadView('coach_chat');
  if (view == null) abort('coach_chat schema missing from $viewsDir');
  final config = readConfig();
  final api = await sheetsApi(config.keyPath);
  final spreadsheetId = view.spreadsheetId ?? config.spreadsheetId;

  final now = DateTime.now();
  final resolved = await resolveHeaders(api, spreadsheetId, view);
  final row = placeByHeader(view, resolved, {
    'id': uuid.v4(),
    'date': DateFormat('yyyy-MM-dd').format(now),
    'ts': now.toIso8601String(),
    'role': role,
    'kind': kind,
    'text': text,
  }, 'coach_chat');

  if (resolved.create) {
    try {
      await api.spreadsheets.batchUpdate(
        gsheets.BatchUpdateSpreadsheetRequest(
          requests: [
            gsheets.Request(
              addSheet: gsheets.AddSheetRequest(
                properties: gsheets.SheetProperties(title: view.table),
              ),
            ),
          ],
        ),
        spreadsheetId,
      );
    } on gsheets.DetailedApiRequestError catch (e) {
      // A manually created blank tab reaches here with create=true
      // (it still needs its header row); tolerate "already exists".
      if (e.status != 400) rethrow;
    }
    await api.spreadsheets.values.update(
      gsheets.ValueRange(values: [resolved.headers]),
      spreadsheetId,
      "'${view.table}'!A1",
      valueInputOption: 'RAW',
    );
  }
  await api.spreadsheets.values.append(
    gsheets.ValueRange(values: [row]),
    spreadsheetId,
    "'${view.table}'!A1",
    valueInputOption: 'RAW',
  );
  print('posted $kind (${text.length} chars)');
  exit(0);
}

Future<void> pending(List<String> args) async {
  if (args.isNotEmpty) abort('unknown arg: ${args.first}');
  final messages = await readMessages();
  if (messages.isEmpty) exit(3);
  if (messages.last.role != 'user') exit(3);
  for (final m in messages) {
    print('[${m.ts}] ${m.role}: ${m.text}');
  }
  exit(0);
}

Future<void> briefingExists(List<String> args) async {
  String? date;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--date':
        date = args[++i];
      default:
        abort('unknown arg: ${args[i]}');
    }
  }
  if (date == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
    abort('briefing-exists requires --date YYYY-MM-DD');
  }
  final messages = await readMessages();
  final found = messages.any(
    (m) => m.role == 'coach' && m.kind == 'briefing' && m.date == date,
  );
  exit(found ? 0 : 3);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class Msg {
  final String date, ts, role, kind, text;
  Msg(this.date, this.ts, this.role, this.kind, this.text);
}

/// Reads all coach_chat rows sorted by ts. Missing/empty tab → empty list.
Future<List<Msg>> readMessages() async {
  final view = loadView('coach_chat');
  if (view == null) abort('coach_chat schema missing from $viewsDir');
  final config = readConfig();
  final api = await sheetsApi(config.keyPath);
  final spreadsheetId = view.spreadsheetId ?? config.spreadsheetId;

  final rows = await readTab(api, spreadsheetId, view.table);
  if (rows == null || rows.length < 2) return [];
  final headers = rows.first.map((e) => e.toString()).toList();
  int col(String name) => headers.indexOf(view.dimensionByName(name)!.expr);
  final dateCol = col('date');
  final tsCol = col('ts');
  final roleCol = col('role');
  final kindCol = col('kind');
  final textCol = col('text');

  final messages = <Msg>[];
  for (final row in rows.skip(1)) {
    final ts = cellAt(row, tsCol);
    final role = cellAt(row, roleCol);
    if (ts.isEmpty && role.isEmpty) continue; // blank row
    messages.add(Msg(
      cellAt(row, dateCol),
      ts,
      role,
      cellAt(row, kindCol),
      cellAt(row, textCol),
    ));
  }
  messages.sort((a, b) => a.ts.compareTo(b.ts));
  return messages;
}

Never abort(String reason) {
  stderr.writeln('abort: $reason');
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

String cellAt(List<Object?> row, int i) =>
    i < 0 || i >= row.length ? '' : (row[i]?.toString() ?? '').trim();

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
