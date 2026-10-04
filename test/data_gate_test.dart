import 'package:airledger/models/github_config.dart';
import 'package:airledger/services/app_config.dart';
import 'package:airledger/services/config_source/config_source_registry.dart';
import 'package:airledger/services/google_auth/data_account.dart';
import 'package:airledger/ui/config_gate.dart';
import 'package:airledger/ui/data_account_card.dart';
import 'package:airledger/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data_account_test.dart' show FakeGoogle;

const _ownerKey =
    '{"client_email":"a@b.iam.gserviceaccount.com",'
    '"private_key":"-----BEGIN PRIVATE KEY-----\\nx\\n-----END PRIVATE KEY-----\\n"}';
const _sid = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';

void main() {
  late MemorySecretStore store;
  late FakeGoogle google;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = MemorySecretStore();
    google = FakeGoogle();
    ConfigSourceRegistry.reset();
    DataAccountRegistry.reset();
  });

  Widget gate({required String key}) => MaterialApp(
    home: ConfigGate(
      loadConfig: () async => AppConfig(
        spreadsheetId: 'owner-sheet',
        models: const [],
        github: GithubConfig(token: 't', owner: 'rsyi', repo: 'fit'),
      ),
      store: store,
      loadServiceAccountKey: () async => key,
      google: (_) => google,
      home: (k) => Text('HOME', key: k),
    ),
  );

  testWidgets('owner build (baked key) → home, key unchanged', (t) async {
    await t.pumpWidget(gate(key: _ownerKey));
    await t.pumpAndSettle();
    final home = t.widget<Text>(find.text('HOME'));
    expect(home.key, const ValueKey('home:baked:github:rsyi/fit@main'));
    expect(DataAccountRegistry.current.value!.spreadsheetId, 'owner-sheet');
    expect(google.signIns, 0);
  });

  testWidgets('no key → sign in → paste URL → home keyed on the sheet', (
    t,
  ) async {
    await t.pumpWidget(gate(key: '{}'));
    await t.pumpAndSettle();
    expect(find.byType(DataSetupScreen), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('google-sign-in')));
    await t.pumpAndSettle();
    expect(find.text('Google · friend@gmail.com'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('spreadsheet-use-existing')));
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const ValueKey('spreadsheet-id-field')),
      'https://docs.google.com/spreadsheets/d/$_sid/edit',
    );
    await t.tap(find.byKey(const ValueKey('spreadsheet-id-save')));
    await t.pumpAndSettle();
    final home = t.widget<Text>(find.text('HOME'));
    expect(
      home.key,
      const ValueKey('home:baked:github:rsyi/fit@main|google:$_sid'),
    );
    expect(store.values[DataAccountRegistry.spreadsheetKey], _sid);
  });

  testWidgets('bad paste shows an error, stays on setup', (t) async {
    google.email = 'friend@gmail.com';
    await t.pumpWidget(gate(key: ''));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('spreadsheet-use-existing')));
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const ValueKey('spreadsheet-id-field')),
      'nope',
    );
    await t.tap(find.byKey(const ValueKey('spreadsheet-id-save')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('data-account-error')), findsOneWidget);
    expect(find.byType(DataSetupScreen), findsOneWidget);
  });

  testWidgets('skip lets the user in offline', (t) async {
    await t.pumpWidget(gate(key: '{}'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('data-setup-skip')));
    await t.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('Settings shows the Account & spreadsheet card', (t) async {
    google.email = 'friend@gmail.com';
    store.values[DataAccountRegistry.spreadsheetKey] = _sid;
    await DataAccountRegistry.init(
      bakedKeyJson: '',
      bakedSpreadsheetId: '',
      store: store,
      google: google,
    );
    await t.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await t.pumpAndSettle();
    expect(find.text('Google · friend@gmail.com'), findsOneWidget);
    expect(find.text('Spreadsheet $_sid'), findsOneWidget);
  });

  testWidgets('Settings, owner build: read-only card', (t) async {
    await DataAccountRegistry.init(
      bakedKeyJson: _ownerKey,
      bakedSpreadsheetId: 'owner-sheet',
      store: store,
      google: google,
    );
    await t.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await t.pumpAndSettle();
    expect(find.text('Built into this app'), findsOneWidget);
    expect(find.byKey(const ValueKey('google-sign-in')), findsNothing);
  });
}
