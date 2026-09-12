// ignore_for_file: avoid_print

import 'dart:io';

import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/input_parser.dart';
import 'package:airledger/services/schema_parser.dart';
import 'package:googleapis/sheets/v4.dart' as gsheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:intl/intl.dart';

/// Emits a markdown context dump of recent ledger data to stdout, for the
/// nightly AI coach.
///
///   dart run tool/coach_dump.dart [--days N] [--views a,b,c]
///
/// Defaults: --days 28, --views strength,cardio,weight,daily_notes,coach_log.
///
/// For each view it parses the live schema from the fitness repo
/// (`~/repos/airledger-fitness/views/&lt;view&gt;.view.yml` + .input.yml), reads the
/// sheet tab named by `table:`, keeps rows whose date falls within the last
/// N days (future/planned rows are kept too — they're coach context), and
/// prints one markdown table per view. Missing tabs print `no data yet`.
final home = Platform.environment['HOME']!;
final viewsDir = '$home/repos/airledger-fitness/views';
final configPath = '$home/.config/airledger/config.yaml';

Future<void> main(List<String> args) async {
  var days = 28;
  var views = ['strength', 'cardio', 'weight', 'daily_notes', 'coach_log'];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--days':
        days = int.parse(args[++i]);
      case '--views':
        views = args[++i]
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      default:
        print('unknown arg: ${args[i]}');
        exit(1);
    }
  }

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = planningTarget(now);
  final ymd = DateFormat('yyyy-MM-dd');
  print('TODAY: ${ymd.format(today)}');
  print('PLANNING TARGET: ${ymd.format(target)} '
      '(${DateFormat('EEEE').format(target)})');

  final config = readConfig();
  final api = await sheetsApi(config.keyPath);
  final cutoff = today.subtract(Duration(days: days - 1));

  for (final viewName in views) {
    final view = loadView(viewName);
    if (view == null) {
      print('\n## $viewName\nno schema found in $viewsDir');
      continue;
    }
    final spreadsheetId = view.spreadsheetId ?? config.spreadsheetId;

    List<List<Object?>> rows;
    try {
      final resp = await api.spreadsheets.values.get(
        spreadsheetId,
        "'${view.table}'",
      );
      rows = resp.values ?? [];
    } on gsheets.DetailedApiRequestError catch (e) {
      if (e.status == 400) {
        // Tab doesn't exist yet (e.g. coach_log / daily_notes).
        print('\n## $viewName (last $days days, 0 rows)\nno data yet');
        continue;
      }
      rethrow;
    }
    if (rows.length < 2) {
      print('\n## $viewName (last $days days, 0 rows)\nno data yet');
      continue;
    }

    final headers = rows.first.map((e) => e.toString()).toList();
    // Columns = all view dimensions in schema order, except id.
    final dims = view.dimensions.where((d) => d.name != 'id').toList();
    final colIdx = [for (final d in dims) headers.indexOf(d.expr)];

    final dateDim =
        view.dimensionByName(view.dateField ?? 'date') ??
        view.dimensions.firstWhere(
          (d) => d.type == DimensionType.date,
          orElse: () => view.dimensions.first,
        );
    final dateCol = headers.indexOf(dateDim.expr);
    if (dateCol < 0) {
      print('\n## $viewName (last $days days, 0 rows)');
      print('date column "${dateDim.expr}" not found in headers: $headers');
      continue;
    }

    final selected = <(DateTime, List<Object?>)>[];
    for (final row in rows.skip(1)) {
      final d = parseSheetDate(cellAt(row, dateCol));
      if (d == null || d.isBefore(cutoff)) continue;
      selected.add((d, row));
    }
    selected.sort((a, b) => a.$1.compareTo(b.$1));

    print('\n## $viewName (last $days days, ${selected.length} rows)');
    if (selected.isEmpty) {
      print('no data yet');
      continue;
    }
    print('| ${dims.map((d) => d.name).join(' | ')} |');
    print('|${List.filled(dims.length, ' --- ').join('|')}|');
    for (final (_, row) in selected) {
      final cells = [
        for (final i in colIdx) i < 0 ? '' : mdCell(cellAt(row, i)),
      ];
      print('| ${cells.join(' | ')} |');
    }
  }
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

/// Parses the view schema (+ optional .input.yml overlay for date_field /
/// spreadsheet_id) from the fitness repo. Returns null if the view file
/// doesn't exist.
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

String cellAt(List<Object?> row, int i) =>
    i < 0 || i >= row.length ? '' : (row[i]?.toString() ?? '').trim();

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

String mdCell(String s) =>
    s.replaceAll('\n', ' ').replaceAll('|', r'\|').trim();
