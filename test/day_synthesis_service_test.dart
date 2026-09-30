import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/model_config.dart';
import 'package:airledger/services/day_synthesis_service.dart';
import 'package:airledger/services/llm_client.dart';

ModelConfig _anthropic() => ModelConfig(
      name: 'sonnet',
      vendor: ModelVendor.anthropic,
      modelRef: 'claude-x',
      apiKey: 'k',
      apiUrl: 'https://api.anthropic.com/v1',
    );

http.Client _reply(String text) => MockClient((_) async => http.Response(
      jsonEncode({
        'content': [
          {'type': 'text', 'text': text},
        ],
      }),
      200,
    ));

DaySynthesisService _svc(LlmClient? llm, {String? model = 'sonnet'}) =>
    DaySynthesisService(
      llm: llm,
      modelName: llm == null ? null : model,
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('disabled (no llm) returns null and reports not enabled', () async {
    final svc = _svc(null);
    expect(svc.enabled, isFalse);
    expect(await svc.generate(), isNull);
  });

  test('generate calls the LLM, returns and caches the synthesis', () async {
    final llm = LlmClient([_anthropic()], httpClient: _reply('Solid start.'));
    final svc = _svc(llm);
    final r = await svc.generate();
    expect(r, isNotNull);
    expect(r!.text, 'Solid start.');
    // Cached for the same day.
    final c = await svc.cached();
    expect(c, isNotNull);
    expect(c!.text, 'Solid start.');
  });

  test('cached returns null on a different day', () async {
    final llm = LlmClient([_anthropic()], httpClient: _reply('Today.'));
    final svc = _svc(llm);
    await svc.generate();
    // A service anchored to a later day sees no cache for its day.
    final tomorrow = DaySynthesisService(
      llm: llm,
      modelName: 'sonnet',
      mealsView: null,
      mealsRepo: null,
      strengthView: null,
      strengthRepo: null,
      cardioView: null,
      cardioRepo: null,
      climbingView: null,
      climbingRepo: null,
      provider: null,
      now: () => DateTime(2026, 10, 1, 15),
    );
    expect(await tomorrow.cached(), isNull);
  });

  test('cached ignores a pre-versioning cache from the SAME day '
      '(macro-target fix invalidation)', () async {
    // A synthesis stored the old way (no `v` key) — e.g. the "no macro
    // targets set today" text written before commit 7573f0c. Same day, so
    // the day check alone would have returned it; the version gate must
    // drop it.
    SharedPreferences.setMockInitialValues({
      'day_synthesis': jsonEncode({
        'day': '2026-09-30',
        'result': {
          'text': 'No macro targets set today.',
          'generated_at': '2026-09-30T09:00:00.000',
          'lifts_hit': 0,
          'lifts_planned': 0,
          'climb_to_come': false,
        },
      }),
    });
    final llm = LlmClient([_anthropic()], httpClient: _reply('Fresh.'));
    final svc = _svc(llm);
    // The stale cache is ignored (version mismatch), not served.
    expect(await svc.cached(), isNull);
  });

  test('a freshly generated (versioned) cache is served back same day',
      () async {
    final llm = LlmClient([_anthropic()], httpClient: _reply('Versioned.'));
    final svc = _svc(llm);
    await svc.generate();
    final c = await svc.cached();
    expect(c, isNotNull);
    expect(c!.text, 'Versioned.');
    // The stored payload carries the version tag.
    final prefs = await SharedPreferences.getInstance();
    final m = jsonDecode(prefs.getString('day_synthesis')!)
        as Map<String, Object?>;
    expect(m['v'], isNotNull);
  });

  test('LLM failure returns null (keeps the previous synthesis)', () async {
    final failing = LlmClient(
      [_anthropic()],
      httpClient: MockClient((_) async => http.Response('boom', 500)),
    );
    final svc = _svc(failing);
    expect(await svc.generate(), isNull);
  });
}
