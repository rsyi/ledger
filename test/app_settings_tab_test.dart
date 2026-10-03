// app_settings_tab.dart — writeAppSetting's HEADER GUARD + upsert, over a
// fake Sheets backend (package:http MockClient). The program_moves tab
// once lost its header to `values.append` at an empty A1; this tab is
// only ever written at explicit ranges, header first.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:airledger/services/app_settings_tab.dart';
import 'package:airledger/services/week_start.dart';

/// Minimal in-memory Sheets: one spreadsheet, tabs as 2-D string grids.
class _FakeSheets {
  final tabs = <String, List<List<String>>>{};
  final log = <String>[];
  var nextSheetId = 100;
  final ids = <String, int>{};

  http.Client get client => MockClient((req) async {
    final path = Uri.decodeComponent(req.url.path);
    Map<String, dynamic> body() =>
        req.body.isEmpty ? {} : jsonDecode(req.body) as Map<String, dynamic>;
    http.Response json(Object o, [int status = 200]) => http.Response(
      jsonEncode(o),
      status,
      headers: {'content-type': 'application/json'},
    );

    if (req.method == 'POST' && path.endsWith(':batchUpdate')) {
      final replies = <Object>[];
      for (final r in (body()['requests'] as List)) {
        final m = r as Map<String, dynamic>;
        if (m['addSheet'] != null) {
          final title = m['addSheet']['properties']['title'] as String;
          tabs[title] = [];
          ids[title] = nextSheetId++;
          log.add('addSheet $title');
          replies.add({
            'addSheet': {
              'properties': {'title': title, 'sheetId': ids[title]},
            },
          });
        } else if (m['insertDimension'] != null) {
          final sid = m['insertDimension']['range']['sheetId'];
          final title = ids.entries.firstWhere((e) => e.value == sid).key;
          tabs[title]!.insert(0, <String>[]);
          log.add('insertRow0 $title');
          replies.add({});
        }
      }
      return json({'replies': replies});
    }
    if (req.method == 'GET' && path.contains('/values/')) {
      final range = path.split('/values/').last;
      final title = range.replaceAll("'", '');
      final t = tabs[title];
      if (t == null) {
        return json({
          'error': {'code': 400, 'message': 'Unable to parse range'},
        }, 400);
      }
      // Sheets trims trailing empty rows.
      final rows = [...t];
      while (rows.isNotEmpty && rows.last.every((c) => c.isEmpty)) {
        rows.removeLast();
      }
      return json({'range': range, 'values': rows});
    }
    if (req.method == 'PUT' && path.contains('/values/')) {
      final range = path.split('/values/').last; // 'app_settings'!A2
      final m = RegExp(r"^'(.+)'!A(\d+)$").firstMatch(range)!;
      final title = m[1]!;
      final row = int.parse(m[2]!) - 1;
      final values = (body()['values'] as List).first as List;
      final t = tabs[title]!;
      while (t.length <= row) {
        t.add(<String>[]);
      }
      t[row] = [for (final v in values) '$v'];
      log.add('write $title!A${row + 1}');
      return json({'updatedRange': range});
    }
    if (req.method == 'GET') {
      return json({
        'spreadsheetId': 'sid',
        'sheets': [
          for (final e in ids.entries)
            {
              'properties': {'title': e.key, 'sheetId': e.value},
            },
        ],
      });
    }
    return http.Response('unhandled ${req.method} $path', 500);
  });
}

void main() {
  final now = DateTime.utc(2026, 10, 3, 12);

  test(
    'missing tab → created, header written at A1 FIRST, row at A2',
    () async {
      final fake = _FakeSheets();
      final api = sheets.SheetsApi(fake.client);
      await writeAppSetting(api, 'sid', 'week_start', 'saturday', now: now);
      expect(fake.log, [
        'addSheet app_settings',
        'write app_settings!A1',
        'write app_settings!A2',
      ]);
      expect(fake.tabs['app_settings'], [
        appSettingsHeaders,
        ['week_start', 'saturday', '2026-10-03T12:00:00.000Z'],
      ]);
      expect(await readAppSettings(api, 'sid'), {'week_start': 'saturday'});
    },
  );

  test('existing key → updated IN PLACE (no duplicate row)', () async {
    final fake = _FakeSheets()
      ..tabs['app_settings'] = [
        [...appSettingsHeaders],
        ['other', 'x', ''],
        ['week_start', 'monday', ''],
      ]
      ..ids['app_settings'] = 7;
    final api = sheets.SheetsApi(fake.client);
    await writeAppSetting(api, 'sid', 'week_start', 'saturday', now: now);
    expect(fake.log, ['write app_settings!A3']);
    expect(fake.tabs['app_settings']![2].take(2), ['week_start', 'saturday']);
    expect(fake.tabs['app_settings'], hasLength(3));
  });

  test('stray data in row 1 (header eaten) → a header row is INSERTED '
      'above it, never written over it', () async {
    final fake = _FakeSheets()
      ..tabs['app_settings'] = [
        ['week_start', 'monday', 'x'],
      ]
      ..ids['app_settings'] = 7;
    final api = sheets.SheetsApi(fake.client);
    await writeAppSetting(api, 'sid', 'week_start', 'saturday', now: now);
    expect(fake.log.first, 'insertRow0 app_settings');
    expect(fake.tabs['app_settings']!.first, appSettingsHeaders);
    // The stray row survives as data (now row 2) and, being the same key,
    // is updated in place.
    expect(fake.tabs['app_settings'], hasLength(2));
    expect(fake.tabs['app_settings']![1].take(2), ['week_start', 'saturday']);
  });

  test(
    'readWeekStart: synced row wins; missing tab → program default',
    () async {
      final empty = sheets.SheetsApi(_FakeSheets().client);
      final r0 = await readWeekStart(
        empty,
        'sid',
        programVersion: {'week_start': 'saturday'},
      );
      expect(r0.day, DateTime.saturday);
      expect(r0.source, WeekStartSource.program);

      final fake = _FakeSheets()
        ..tabs['app_settings'] = [
          [...appSettingsHeaders],
          ['week_start', 'sunday', ''],
        ]
        ..ids['app_settings'] = 7;
      final r1 = await readWeekStart(
        sheets.SheetsApi(fake.client),
        'sid',
        programVersion: {'week_start': 'saturday'},
      );
      expect(r1.day, DateTime.sunday);
      expect(r1.source, WeekStartSource.setting);
    },
  );
}
