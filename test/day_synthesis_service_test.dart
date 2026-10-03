import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/model_config.dart';
import 'package:airledger/services/day_synthesis_service.dart';
import 'package:airledger/services/llm_client.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/warehouse_connector.dart';

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

final _mealsView = ViewSchema(
  name: 'meals',
  datasource: 'gsheets',
  table: 'meals',
  entities: const [],
  measures: const [],
  dimensions: const [],
);

class _Meals implements WarehouseConnector {
  final List<Map<String, Object?>> rows;
  _Meals(this.rows);
  @override
  Future<List<Map<String, Object?>>> list(ViewSchema view,
          {DateTime? onDate}) async =>
      [...rows];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

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

  test('a pre-status (v5) cache is ignored — its read may nudge a DONE item',
      () async {
    SharedPreferences.setMockInitialValues({
      'day_synthesis': jsonEncode({
        'v': 5,
        'day': '2026-09-30',
        'result': {
          'text': 'Make sure that PM light climbing session happens.',
          'generated_at': '2026-09-30T15:00:00.000',
          'lifts_hit': 4,
          'lifts_planned': 4,
          'climb_to_come': false,
        },
      }),
    });
    final llm = LlmClient([_anthropic()], httpClient: _reply('Fresh.'));
    expect(await _svc(llm).cached(), isNull);
  });

  test('refreshIfStale: same context → no LLM call; a changed context '
      '(new meal) → regenerates', () async {
    var calls = 0;
    final llm = LlmClient([_anthropic()],
        httpClient: MockClient((_) async {
          calls++;
          return http.Response(
              jsonEncode({
                'content': [
                  {'type': 'text', 'text': 'Read $calls.'},
                ],
              }),
              200);
        }));
    final meals = _Meals([]);
    final svc = DaySynthesisService(
      llm: llm,
      modelName: 'sonnet',
      mealsView: _mealsView,
      mealsRepo: meals,
      strengthView: null,
      strengthRepo: null,
      cardioView: null,
      cardioRepo: null,
      climbingView: null,
      climbingRepo: null,
      provider: null,
      now: () => DateTime(2026, 9, 30, 15),
    );
    final first = await svc.refreshIfStale();
    expect(first?.text, 'Read 1.');
    expect(first!.fingerprint, isNotEmpty);
    expect(await svc.refreshIfStale(), isNull); // fresh — no call
    expect(calls, 1);
    meals.rows.add({
      'eaten_at': '2026-09-30T12:00:00',
      'protein_g': 50,
      'calories': 600,
    });
    final second = await svc.refreshIfStale();
    expect(second?.text, 'Read 2.');
    expect(calls, 2);
  });

  test('LLM failure returns null (keeps the previous synthesis)', () async {
    final failing = LlmClient(
      [_anthropic()],
      httpClient: MockClient((_) async => http.Response('boom', 500)),
    );
    final svc = _svc(failing);
    expect(await svc.generate(), isNull);
  });

  group('buildSynthRecovery (recovery/sleep context assembly)', () {
    final clock = DateTime(2026, 9, 30, 15);

    test('picks last night (most recent row at/before today) + 7d avg', () {
      final r = buildSynthRecovery([
        {
          'date': '2026-09-28',
          'sleep_hours': 6.0,
          'recovery_score': 60,
          'hrv_ms': 55,
        },
        {
          'date': '2026-09-30',
          'sleep_hours': 7.4,
          'recovery_score': 80,
          'hrv_ms': 65,
        },
        {
          'date': '2026-09-29',
          'sleep_hours': 7.0,
          'recovery_score': 82,
          'hrv_ms': 70,
        },
      ], clock);
      // Latest row wins the "last night" fields.
      expect(r.day, '2026-09-30');
      expect(r.sleepHours, 7.4);
      expect(r.recoveryScore, 80);
      expect(r.hrvMs, 65);
      // 7d avg over the three in-window scores (60+80+82)/3 = 74.
      expect(r.recoveryScore7dAvg, closeTo(74, 0.01));
      expect(r.hasData, isTrue);
    });

    test('ignores future-dated rows', () {
      final r = buildSynthRecovery([
        {'date': '2026-10-05', 'recovery_score': 99}, // future — skipped
        {'date': '2026-09-29', 'recovery_score': 70},
      ], clock);
      expect(r.day, '2026-09-29');
      expect(r.recoveryScore, 70);
    });

    test('empty rows → empty recovery (no line)', () {
      final r = buildSynthRecovery(const [], clock);
      expect(r.hasData, isFalse);
      expect(r.day, isNull);
    });

    test('string-typed numbers parse (sheets round-trip)', () {
      final r = buildSynthRecovery([
        {'date': '2026-09-30', 'sleep_hours': '7.5', 'recovery_score': '66'},
      ], clock);
      expect(r.sleepHours, 7.5);
      expect(r.recoveryScore, 66);
    });

    test('a 7d-window drop excludes an older score from the average', () {
      final r = buildSynthRecovery([
        {'date': '2026-09-30', 'recovery_score': 80},
        {'date': '2026-09-20', 'recovery_score': 10}, // >6d before latest
      ], clock);
      // Only the latest score is inside the 7-day window.
      expect(r.recoveryScore7dAvg, 80);
    });
  });
}
