import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/model_config.dart';
import 'package:airledger/services/day_synthesis_service.dart';
import 'package:airledger/services/integrations/integration.dart';
import 'package:airledger/services/integrations/registry.dart';
import 'package:airledger/services/llm_client.dart';
import 'package:airledger/ui/widgets/today_status_card.dart';

/// A no-op integration that records force-pulls — enough to assert the
/// gated refresh fired the quiet syncs.
class _FakeIntegration implements Integration {
  _FakeIntegration(this.id);
  @override
  final String id;
  int pulls = 0;
  @override
  String get displayName => id;
  @override
  String get targetDescription => '';
  @override
  bool get isConfigured => true;
  @override
  Future<bool> get isConnected async => true;
  @override
  Future<String> get statusLine async => 'ok';
  @override
  Map<String, Future<void> Function(BuildContext)> get extraMenuActions =>
      const {};
  @override
  Future<void> connect(BuildContext context) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> pull({bool force = false, bool fullReconcile = false}) async {
    pulls++;
  }
}

DaySynthesisService _svc(LlmClient? llm) => DaySynthesisService(
      llm: llm,
      modelName: llm == null ? null : 'sonnet',
      mealsView: null,
      mealsRepo: null,
      strengthView: null,
      strengthRepo: null,
      cardioView: null,
      cardioRepo: null,
      climbingView: null,
      climbingRepo: null,
      provider: null,
      now: () => DateTime(2026, 9, 30, 15),
    );

Widget _host(TodayStatusCard card) =>
    MaterialApp(home: Scaffold(body: card));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('disabled synthesis → static two-line fallback', (tester) async {
    await tester.pumpWidget(_host(TodayStatusCard(
      mealsView: null,
      mealsRepo: null,
      strengthView: null,
      strengthRepo: null,
      provider: null,
      synthesis: _svc(null), // disabled
      onOpen: () {},
    )));
    await tester.pumpAndSettle();
    // Fallback path renders the static training line (rest day, no data).
    expect(find.textContaining('Training:'), findsOneWidget);
    // The AI header icon is absent on the fallback path.
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });

  testWidgets('enabled synthesis renders the LLM read', (tester) async {
    final llm = LlmClient(
      [
        ModelConfig(
          name: 'sonnet',
          vendor: ModelVendor.anthropic,
          modelRef: 'claude-x',
          apiKey: 'k',
          apiUrl: 'https://api.anthropic.com/v1',
        ),
      ],
      httpClient: MockClient((_) async => http.Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'Grab carbs before climbing.'},
              ],
            }),
            200,
          )),
    );
    await tester.pumpWidget(_host(TodayStatusCard(
      mealsView: null,
      mealsRepo: null,
      strengthView: null,
      strengthRepo: null,
      provider: null,
      synthesis: _svc(llm),
      onOpen: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    expect(find.text('Grab carbs before climbing.'), findsOneWidget);
  });

  LlmClient _llm() => LlmClient(
        [
          ModelConfig(
            name: 'sonnet',
            vendor: ModelVendor.anthropic,
            modelRef: 'claude-x',
            apiKey: 'k',
            apiUrl: 'https://api.anthropic.com/v1',
          ),
        ],
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({
                'content': [
                  {'type': 'text', 'text': 'Read.'},
                ],
              }),
              200,
            )),
      );

  testWidgets('gated refresh: dialog 1 offers Sync & update / Just update',
      (tester) async {
    final withings = _FakeIntegration('withings');
    IntegrationRegistry.init(integrations: [withings]);
    await tester.pumpWidget(_host(TodayStatusCard(
      mealsView: null,
      mealsRepo: null,
      strengthView: null,
      strengthRepo: null,
      provider: null,
      synthesis: _svc(_llm()),
      registry: IntegrationRegistry.instance,
      onOpen: () {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(find.text('Sync latest first?'), findsOneWidget);
    expect(find.text('Sync & update'), findsOneWidget);
    expect(find.text('Just update'), findsOneWidget);
  });

  testWidgets('Sync & update force-pulls the quiet sources', (tester) async {
    final withings = _FakeIntegration('withings');
    final macro = _FakeIntegration('macrofactor');
    final whoop = _FakeIntegration('whoop_api');
    // kaya is NOT a GuidedSyncIntegration here → the Kaya prompt is
    // skipped, keeping this test focused on the quiet-sync path.
    IntegrationRegistry.init(integrations: [withings, macro, whoop]);
    await tester.pumpWidget(_host(TodayStatusCard(
      mealsView: null,
      mealsRepo: null,
      strengthView: null,
      strengthRepo: null,
      provider: null,
      synthesis: _svc(_llm()),
      registry: IntegrationRegistry.instance,
      onOpen: () {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync & update'));
    await tester.pumpAndSettle();

    expect(withings.pulls, 1);
    expect(macro.pulls, 1);
    expect(whoop.pulls, 1);
  });

  testWidgets('Just update skips the sync (no force-pull)', (tester) async {
    final withings = _FakeIntegration('withings');
    IntegrationRegistry.init(integrations: [withings]);
    await tester.pumpWidget(_host(TodayStatusCard(
      mealsView: null,
      mealsRepo: null,
      strengthView: null,
      strengthRepo: null,
      provider: null,
      synthesis: _svc(_llm()),
      registry: IntegrationRegistry.instance,
      onOpen: () {},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Just update'));
    await tester.pumpAndSettle();

    expect(withings.pulls, 0);
  });
}
