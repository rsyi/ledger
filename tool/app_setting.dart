// ignore_for_file: avoid_print

import 'dart:io';

import 'package:airledger/services/app_settings_tab.dart';
import 'package:airledger/services/week_start.dart';

import 'coach_dump.dart' as dump;

/// Read / write the synced `app_settings` tab (2026-10-03) — the same
/// rows the app's Settings screen writes and the nightly + MCP read.
///
///   dart run tool/app_setting.dart                       # print all
///   dart run tool/app_setting.dart week_start saturday   # upsert
///
/// `week_start` values are validated (a weekday name) and stored in the
/// lowercase form the app writes. Writes go through writeAppSetting's
/// header guard (explicit ranges, never values.append).
Future<void> main(List<String> args) async {
  final config = dump.readConfig();
  final api = await dump.sheetsApi(config.keyPath);
  if (args.isEmpty) {
    final all = await readAppSettings(api, config.spreadsheetId);
    if (all.isEmpty) print('(app_settings is empty or missing)');
    all.forEach((k, v) => print('$k = $v'));
    exit(0);
  }
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/app_setting.dart [<key> <value>]');
    exit(1);
  }
  var value = args[1].trim();
  if (args[0] == weekStartSettingKey) {
    final day = parseWeekday(value);
    if (day == null) {
      stderr.writeln('week_start must be a weekday name (got "$value")');
      exit(1);
    }
    value = weekdayKey(day);
  }
  await writeAppSetting(api, config.spreadsheetId, args[0], value);
  final back = await readAppSettings(api, config.spreadsheetId);
  print('${args[0]} = ${back[args[0]]}');
  exit(0);
}
