import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:airledger/models/model_config.dart';
import 'package:airledger/services/llm_client.dart';
import 'package:airledger/services/video_rpe.dart';

// AI RPE estimation — pure parts (frame plan, prompt, parse, history
// lines, coach-log outcome) + the Anthropic vision request shape via a
// mock http client. PROPOSE-ONLY contract: nothing in these paths
// writes rpe; the form's accept tap is the only bridge.

void main() {
  group('frameTimestampsMs', () {
    test('evenly spaced, inset from the ends, monotonic', () {
      final ts = frameTimestampsMs(30000);
      expect(ts.length, 14);
      expect(ts.first, 1200); // 4% of 30s
      expect(ts.last, 28800); // 96%
      for (var i = 1; i < ts.length; i++) {
        expect(ts[i], greaterThan(ts[i - 1]));
      }
    });

    test('degenerate durations collapse safely', () {
      expect(frameTimestampsMs(0), [0]);
      expect(frameTimestampsMs(-5), [0]);
      expect(frameTimestampsMs(10, count: 5), [5]);
      expect(frameTimestampsMs(30000, count: 1), [15000]);
    });

    test('count clamps to 20', () {
      expect(frameTimestampsMs(60000, count: 99).length, 20);
    });
  });

  group('recentRpeLines', () {
    final rows = <Map<String, Object?>>[
      {'date': '2026-09-20', 'exercise': 'Barbell Squat', 'weight': 220, 'reps': 5, 'rpe': 8},
      {'date': '2026-09-25', 'exercise': 'Barbell Squat', 'weight': 225, 'reps': 5, 'rpe': 8.5},
      {'date': '2026-09-24', 'exercise': 'Barbell Squat', 'weight': 135, 'reps': 5, 'rpe': ''},
      {'date': '2026-09-23', 'exercise': 'Overhead Press', 'weight': 95, 'reps': 5, 'rpe': 7},
    ];

    test('filters by exercise + rpe presence, newest first', () {
      final lines = recentRpeLines(rows, exercise: 'Barbell Squat');
      expect(lines, [
        '2026-09-25: 225×5 @ RPE 8.5',
        '2026-09-20: 220×5 @ RPE 8',
      ]);
    });

    test('no exercise → empty; cap respected', () {
      expect(recentRpeLines(rows, exercise: null), isEmpty);
      expect(
        recentRpeLines(rows, exercise: 'Barbell Squat', cap: 1).length,
        1,
      );
    });
  });

  group('buildRpePrompt', () {
    final prompt = buildRpePrompt(
      ctx: const RpeRowContext(
        exercise: 'Barbell Squat',
        weight: 225,
        reps: 5,
        setType: 'heavy',
        recentHistory: ['2026-09-25: 225×5 @ RPE 8.5'],
      ),
      timestampsMs: [1200, 15000, 28800],
      durationMs: 30000,
    );

    test('carries context, calibration history, frame times', () {
      expect(prompt, contains('Barbell Squat'));
      expect(prompt, contains('225 lb × 5 reps'));
      expect(prompt, contains('Set intent: heavy'));
      expect(prompt, contains('2026-09-25: 225×5 @ RPE 8.5'));
      expect(prompt, contains('0:01, 0:15, 0:28'));
      expect(prompt, contains('0:30'));
    });

    test('asks for strict JSON with band + one-line reasoning, and an '
        'honest null when not discernible', () {
      expect(prompt, contains('STRICT JSON'));
      expect(prompt, contains('"band"'));
      expect(prompt, contains('null if not discernible'));
      expect(prompt, contains('do NOT invent'));
    });

    test('unknown fields say unknown instead of guessing', () {
      final p = buildRpePrompt(
        ctx: const RpeRowContext(),
        timestampsMs: [500],
        durationMs: 1000,
      );
      expect(p, contains('Exercise: unknown'));
      expect(p, contains('unknown lb'));
      expect(p, isNot(contains('calibrate against')));
    });
  });

  group('parseRpeEstimate', () {
    test('plain JSON', () {
      final est = parseRpeEstimate(
          '{"rpe": 8.5, "band": [8, 9], "bar_speed": "slowing", '
          '"last_rep": "grind", "reasoning": "Third rep slowed sharply."}');
      expect(est.rpe, 8.5);
      expect(est.low, 8);
      expect(est.high, 9);
      expect(est.barSpeed, 'slowing');
      expect(est.reasoning, 'Third rep slowed sharply.');
      expect(est.display, '~8.5 (8–9)');
    });

    test('tolerates fences and surrounding prose', () {
      final est = parseRpeEstimate(
          'Here you go:\n```json\n{"rpe": 7, "reasoning": "ok"}\n```');
      expect(est.rpe, 7);
      expect(est.display, '~7');
    });

    test('null rpe = honest not-discernible', () {
      final est =
          parseRpeEstimate('{"rpe": null, "reasoning": "camera angle"}');
      expect(est.rpe, isNull);
      expect(est.display, 'not discernible');
    });

    test('garbage / out-of-range throws (never a fabricated number)', () {
      expect(() => parseRpeEstimate('no json here'),
          throwsFormatException);
      expect(() => parseRpeEstimate('{"rpe": "hard"}'),
          throwsFormatException);
      expect(() => parseRpeEstimate('{"rpe": 14}'), throwsFormatException);
    });

    test('malformed band is dropped, not fatal', () {
      final est = parseRpeEstimate(
          '{"rpe": 8, "band": [9, 7], "reasoning": "x"}');
      expect(est.rpe, 8);
      expect(est.low, isNull);
      expect(est.display, '~8');
    });

    test('round-trips through toJson/fromJson', () {
      final est = parseRpeEstimate(
          '{"rpe": 8.5, "band": [8, 9], "reasoning": "r"}');
      final back = RpeEstimate.fromJson(
          (jsonDecode(jsonEncode(est.toJson())) as Map)
              .cast<String, dynamic>());
      expect(back.rpe, est.rpe);
      expect(back.low, est.low);
      expect(back.reasoning, est.reasoning);
    });
  });

  group('coach log entries', () {
    test('rpeLogEntry shape + applyRpeOutcome accepted/overridden', () {
      final entry = rpeLogEntry(
        mediaId: 'm1',
        ctx: const RpeRowContext(
            exercise: 'Barbell Squat', weight: 225, reps: 5),
        estimate: const RpeEstimate(
            rpe: 8.5, low: 8, high: 9, reasoning: 'slowed'),
        at: DateTime.utc(2026, 9, 28, 10),
      );
      expect(entry['media_id'], 'm1');
      expect(entry['estimate'], 8.5);
      expect(entry['band'], [8, 9]);
      expect(entry['final_rpe'], isNull);

      final log = <dynamic>[entry];
      expect(applyRpeOutcome(log, mediaId: 'm1', finalRpe: 8.5), isTrue);
      expect((log.first as Map)['final_rpe'], 8.5);
      // Override with the user's own number.
      expect(applyRpeOutcome(log, mediaId: 'm1', finalRpe: '9'), isTrue);
      expect((log.first as Map)['final_rpe'], 9);
      expect(
          applyRpeOutcome(log, mediaId: 'nope', finalRpe: 5), isFalse);
    });
  });

  group('LlmClient.completeVision', () {
    ModelConfig cfg() => ModelConfig(
          name: 'sonnet',
          vendor: ModelVendor.anthropic,
          modelRef: 'claude-sonnet-test',
          apiKey: 'k',
          apiUrl: 'https://api.anthropic.com/v1',
        );

    test('sends images (chronological) before the text block', () async {
      late Map<String, dynamic> sent;
      final client = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': '{"rpe": 8, "reasoning": "x"}'}
            ]
          }),
          200,
        );
      });
      final llm = LlmClient([cfg()], httpClient: client);
      final reply = await llm.completeVision(
        'sonnet',
        'prompt text',
        [
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3, 4]),
        ],
      );
      expect(reply, contains('"rpe": 8'));
      final content =
          ((sent['messages'] as List).first as Map)['content'] as List;
      expect(content.length, 3);
      expect((content[0] as Map)['type'], 'image');
      expect(
        ((content[0] as Map)['source'] as Map)['data'],
        base64Encode([1, 2]),
      );
      expect((content[1] as Map)['type'], 'image');
      expect((content[2] as Map)['type'], 'text');
      expect((content[2] as Map)['text'], 'prompt text');
      expect(sent['max_tokens'], 1024);
    });

    test('non-anthropic vendor is refused', () async {
      final llm = LlmClient([
        ModelConfig(
          name: 'oai',
          vendor: ModelVendor.openai,
          modelRef: 'gpt-x',
          apiKey: 'k',
          apiUrl: 'https://api.openai.com/v1',
        )
      ]);
      expect(
        () => llm.completeVision('oai', 'p', [Uint8List(0)]),
        throwsUnsupportedError,
      );
    });

    test('visionModelName prefers sonnet, else first anthropic', () {
      final llm = LlmClient([cfg()]);
      expect(llm.visionModelName(), 'sonnet');
      final other = LlmClient([
        ModelConfig(
          name: 'haiku',
          vendor: ModelVendor.anthropic,
          modelRef: 'claude-haiku-test',
          apiKey: 'k',
          apiUrl: 'https://api.anthropic.com/v1',
        )
      ]);
      expect(other.visionModelName(), 'haiku');
      expect(LlmClient([]).visionModelName(), isNull);
    });
  });
}
