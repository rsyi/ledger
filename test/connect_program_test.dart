// Multi-user sub-project 1 UI: the "Connect your program" flow (PAT +
// device flow over a fake GitHub), the app-root gate, and Settings'
// "Program config" section.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/github_config.dart';
import 'package:airledger/services/app_config.dart';
import 'package:airledger/services/app_settings.dart';
import 'package:airledger/services/config_source/config_source_registry.dart';
import 'package:airledger/services/config_source/github_config_source.dart';
import 'package:airledger/ui/config_gate.dart';
import 'package:airledger/ui/connect_program_screen.dart';
import 'package:airledger/ui/settings_screen.dart';

http.Response _json(Object b, [int s = 200]) => http.Response(jsonEncode(b), s);

/// Fake github.com + api.github.com. [program] toggles coach/program.yaml.
MockClient _github({bool program = true, List<String>? log}) =>
    MockClient((req) async {
      log?.add('${req.method} ${req.url}');
      final u = req.url;
      if (u.host == 'github.com' && u.path == '/login/device/code') {
        return _json({
          'device_code': 'dev',
          'user_code': 'ABCD-1234',
          'verification_uri': 'https://github.com/login/device',
          'expires_in': 900,
          'interval': 5,
        });
      }
      if (u.host == 'github.com' && u.path == '/login/oauth/access_token') {
        return _json({'access_token': 'gho_device'});
      }
      switch (u.path) {
        case '/user':
          return _json({'login': 'friend'});
        case '/user/repos':
          return _json([
            {
              'name': 'my-ledger',
              'owner': {'login': 'friend'},
              'default_branch': 'main',
              'private': true,
            },
            {
              'name': 'dotfiles',
              'owner': {'login': 'friend'},
              'default_branch': 'master',
              'private': false,
            },
          ]);
        case '/repos/friend/my-ledger/branches':
          return _json([
            {'name': 'main'},
            {'name': 'dev'},
          ]);
        case '/repos/friend/my-ledger/contents/cfg/views':
          return _json([
            {'name': 'strength.view.yml', 'type': 'file'},
          ]);
        case '/repos/friend/my-ledger/contents/cfg/coach/program.yaml':
          return program
              ? _json({'content': '', 'sha': 's'})
              : _json({'message': 'Not Found'}, 404);
      }
      return _json({'message': 'unexpected $u'}, 500);
    });

void main() {
  late MemorySecretStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppSettings.debugSet(null);
    ConfigSourceRegistry.reset();
    store = MemorySecretStore();
    await ConfigSourceRegistry.init(baked: null, store: store);
  });
  tearDown(ConfigSourceRegistry.reset);

  Future<void> pumpConnect(WidgetTester tester,
      {String? clientId, bool program = true, List<String>? opened}) async {
    await tester.pumpWidget(MaterialApp(
      home: ConnectProgramScreen(
        oauthClientId: clientId,
        templateRepo: 'rsyi/ledger-template',
        httpClient: _github(program: program),
        openUrl: (u) async => opened?.add(u),
        sleep: (_) async {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pickRepoAndConnect(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('repo-friend/my-ledger')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('root-field')), '/cfg/');
    await tester.tap(find.byKey(const ValueKey('connect-repo')));
    await tester.pumpAndSettle();
  }

  testWidgets('no client id → PAT only; paste → repos → connect stores it',
      (tester) async {
    await pumpConnect(tester);
    expect(find.byKey(const ValueKey('github-sign-in')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('use-token')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Contents: Read and write'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('pat-field')), ' github_pat_xyz ');
    await tester.tap(find.byKey(const ValueKey('pat-continue')));
    await tester.pumpAndSettle();
    expect(find.text('Signed in as friend'), findsOneWidget);
    expect(find.text('friend/dotfiles'), findsOneWidget);

    await pickRepoAndConnect(tester);
    final saved = await ConfigSourceRegistry.userSettings();
    expect(saved!.token, 'github_pat_xyz');
    expect(saved.method, 'pat');
    expect(saved.root, 'cfg');
    expect(saved.branch, 'main');
    expect(ConfigSourceRegistry.active.value!.displayName,
        'friend/my-ledger@main/cfg');
  });

  testWidgets('device flow: shows the code, opens GitHub, connects',
      (tester) async {
    final opened = <String>[];
    await pumpConnect(tester, clientId: 'Ov23li', opened: opened);
    await tester.tap(find.byKey(const ValueKey('github-sign-in')));
    await tester.pumpAndSettle();
    // Fake sleep → the poll resolves at once; we land on the repo list.
    expect(find.text('Signed in as friend'), findsOneWidget);
    await pickRepoAndConnect(tester);
    final saved = await ConfigSourceRegistry.userSettings();
    expect(saved!.token, 'gho_device');
    expect(saved.method, 'device');
    expect(saved.login, 'friend');
  });

  testWidgets('missing program.yaml → problem + template + connect anyway',
      (tester) async {
    final opened = <String>[];
    await pumpConnect(tester, program: false, opened: opened);
    await tester.tap(find.byKey(const ValueKey('use-token')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pat-field')), 't');
    await tester.tap(find.byKey(const ValueKey('pat-continue')));
    await tester.pumpAndSettle();
    await pickRepoAndConnect(tester);
    expect(ConfigSourceRegistry.active.value, isNull);
    expect(find.byKey(const ValueKey('check-problem')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('open-template')));
    await tester.tap(find.byKey(const ValueKey('open-template')));
    expect(opened, ['https://github.com/rsyi/ledger-template']);
    await tester.ensureVisible(find.byKey(const ValueKey('connect-anyway')));
    await tester.tap(find.byKey(const ValueKey('connect-anyway')));
    await tester.pumpAndSettle();
    expect(ConfigSourceRegistry.active.value, isNotNull);
  });

  group('ConfigGate', () {
    AppConfig cfg({GithubConfig? github, String? kiosk}) => AppConfig(
        spreadsheetId: 's', models: const [], github: github, kioskView: kiosk);

    Widget gate(AppConfig c) => MaterialApp(
          home: ConfigGate(
            loadConfig: () async => c,
            store: store,
            home: (key) => Text('HOME', key: key),
          ),
        );

    testWidgets('baked config → straight to home', (tester) async {
      await tester.pumpWidget(gate(cfg(
          github: GithubConfig(token: 't', owner: 'rsyi', repo: 'fit'))));
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
      expect(ConfigSourceRegistry.active.value, isA<BakedGitHubSource>());
    });

    testWidgets('nothing configured → Connect screen; skip → home',
        (tester) async {
      await tester.pumpWidget(gate(cfg()));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectProgramScreen), findsOneWidget);
      await tester.tap(find.text('Continue without a program'));
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('kiosk builds never see the Connect screen', (tester) async {
      await tester.pumpWidget(gate(cfg(kiosk: 'inventory')));
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('connecting swaps in a freshly keyed home', (tester) async {
      await tester.pumpWidget(gate(cfg()));
      await tester.pumpAndSettle();
      await ConfigSourceRegistry.connect(const GithubSourceSettings(
          token: 't', owner: 'friend', repo: 'my-ledger'));
      await tester.pumpAndSettle();
      final home = tester.widget<Text>(find.text('HOME'));
      expect(home.key, const ValueKey('home:github:friend/my-ledger@main'));
    });
  });

  group('Settings → Program config', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();
    }

    String text(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(ValueKey(key))).data!;

    testWidgets('baked source: shown, sign-out disabled', (tester) async {
      await ConfigSourceRegistry.init(
          baked: GithubConfig(token: 't', owner: 'rsyi', repo: 'fit'),
          store: store);
      await pumpSettings(tester);
      expect(text(tester, 'config-source-name'), 'rsyi/fit@main');
      expect(text(tester, 'config-source-account'),
          'GitHub · built into this app');
      final signOut = tester.widget<TextButton>(
          find.byKey(const ValueKey('config-source-sign-out')));
      expect(signOut.onPressed, isNull);
    });

    testWidgets('user source: signed-in line; sign out reverts to baked',
        (tester) async {
      await ConfigSourceRegistry.init(
          baked: GithubConfig(token: 't', owner: 'rsyi', repo: 'fit'),
          store: store);
      await ConfigSourceRegistry.connect(const GithubSourceSettings(
          token: 'x', owner: 'friend', repo: 'my-ledger', login: 'friend'));
      await pumpSettings(tester);
      expect(text(tester, 'config-source-name'), 'friend/my-ledger@main');
      expect(text(tester, 'config-source-account'),
          'GitHub · signed in as friend');
      await tester.tap(find.byKey(const ValueKey('config-source-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-sign-out')));
      await tester.pumpAndSettle();
      expect(store.values, isEmpty);
      expect(text(tester, 'config-source-name'), 'rsyi/fit@main');
    });

    testWidgets('Change opens the connect flow', (tester) async {
      await pumpSettings(tester);
      expect(text(tester, 'config-source-name'), 'No program connected');
      await tester.tap(find.byKey(const ValueKey('config-source-change')));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectProgramScreen), findsOneWidget);
    });
  });
}
