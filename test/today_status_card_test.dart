import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/model_config.dart';
import 'package:airledger/services/day_synthesis_service.dart';
import 'package:airledger/services/llm_client.dart';
import 'package:airledger/ui/widgets/today_status_card.dart';

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
}
