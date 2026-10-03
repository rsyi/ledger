// Settings → "Week starts on" (2026-10-03): shows the effective day +
// its source, and picking a day writes the synced setting.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/services/app_settings.dart';
import 'package:airledger/services/program_provider.dart';
import 'package:airledger/ui/settings_screen.dart';

const _program = '''
versions:
  - version: 1
    week_start: saturday
''';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProgramProvider.clearCache();
    AppSettings.debugSet(null);
    debugForgetProgramDefault();
  });
  tearDown(() {
    AppSettings.debugSet(null);
    AppSettings.debugWriter = null;
  });

  Future<void> pump(WidgetTester tester, {bool withProgram = true}) async {
    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(
        programProvider: withProgram
            ? ProgramProvider((p) async =>
                p == 'coach/program.yaml' ? _program : null)
            : null,
      ),
    ));
    await tester.pumpAndSettle();
  }

  String source(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('week-start-source')))
      .data!;

  testWidgets('no setting → the program default, labelled as such',
      (tester) async {
    await pump(tester);
    expect(source(tester), 'Saturday · from program default');
    expect(find.textContaining('Weeks run Saturday–Friday'), findsOneWidget);
    expect(find.textContaining('expires at the end of Friday'),
        findsOneWidget);
  });

  testWidgets('no program, no setting → Monday default', (tester) async {
    await pump(tester, withProgram: false);
    expect(source(tester), 'Monday · default');
  });

  testWidgets('picking a day writes the synced setting → "set here"',
      (tester) async {
    final writes = <(String, String)>[];
    AppSettings.debugWriter = (k, v) async => writes.add((k, v));
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('week-start-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sunday').last);
    await tester.pumpAndSettle();
    expect(writes, [('week_start', 'sunday')]);
    expect(AppSettings.weekStartSetting.value, 'sunday');
    expect(source(tester), 'Sunday · set here');
    expect(find.textContaining('Weeks run Sunday–Saturday'), findsOneWidget);
  });
}
