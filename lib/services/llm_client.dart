import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/model_config.dart';

/// Routes prompts to a [ModelConfig] by name. Supports OpenAI's
/// chat-completions endpoint and Anthropic's messages endpoint. Adding
/// a new vendor is a switch arm + a request shape.
class LlmClient {
  final Map<String, ModelConfig> _byName;
  final http.Client _http;

  LlmClient(List<ModelConfig> models, {http.Client? httpClient})
      : _byName = {for (final m in models) m.name: m},
        _http = httpClient ?? http.Client();

  bool get isEmpty => _byName.isEmpty;
  bool has(String name) => _byName.containsKey(name);

  /// Name of the model the vision path should use: prefers the entry
  /// named `sonnet` (the post-log hooks' configured Anthropic model —
  /// all current Claude 3.5+ models are vision-capable), else the
  /// first Anthropic entry. Null when no Anthropic model is configured.
  String? visionModelName() {
    if (_byName['sonnet']?.vendor == ModelVendor.anthropic) return 'sonnet';
    for (final m in _byName.values) {
      if (m.vendor == ModelVendor.anthropic) return m.name;
    }
    return null;
  }

  /// Sends [prompt] to the model named [modelName] and returns its
  /// response as a plain string. Throws if the model isn't registered
  /// or the API call fails.
  Future<String> complete(String modelName, String prompt) async {
    final cfg = _byName[modelName];
    if (cfg == null) {
      throw StateError(
        'Model "$modelName" not configured. Add an entry to config.yml '
        'models:. Known: ${_byName.keys.join(', ')}',
      );
    }
    return switch (cfg.vendor) {
      ModelVendor.openai => _openai(cfg, prompt),
      ModelVendor.anthropic => _anthropic(cfg, prompt),
    };
  }

  /// Vision completion: [jpegImages] (chronological) + [prompt] in one
  /// user turn. Anthropic-only — the app has no OpenAI vision use and
  /// the request shapes differ; extend the switch if that changes.
  Future<String> completeVision(
    String modelName,
    String prompt,
    List<Uint8List> jpegImages, {
    int maxTokens = 1024,
  }) async {
    final cfg = _byName[modelName];
    if (cfg == null) {
      throw StateError(
        'Model "$modelName" not configured. Add an entry to config.yml '
        'models:. Known: ${_byName.keys.join(', ')}',
      );
    }
    if (cfg.vendor != ModelVendor.anthropic) {
      throw UnsupportedError(
          'completeVision supports Anthropic models only ("$modelName" is '
          '${cfg.vendor.name})');
    }
    final uri = Uri.parse('${cfg.apiUrl}/messages');
    final resp = await _http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': cfg.apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': cfg.modelRef,
        'max_tokens': maxTokens,
        'messages': [
          {
            'role': 'user',
            'content': [
              for (final img in jpegImages)
                {
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': 'image/jpeg',
                    'data': base64Encode(img),
                  },
                },
              {'type': 'text', 'text': prompt},
            ],
          },
        ],
      }),
    );
    return _anthropicText(resp);
  }

  Future<String> _openai(ModelConfig cfg, String prompt) async {
    final uri = Uri.parse('${cfg.apiUrl}/chat/completions');
    final resp = await _http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${cfg.apiKey}',
      },
      body: jsonEncode({
        'model': cfg.modelRef,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    );
    if (resp.statusCode != 200) {
      throw LlmCallException(
        vendor: 'OpenAI',
        status: resp.statusCode,
        body: resp.body,
      );
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final choices = body['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw LlmCallException(
        vendor: 'OpenAI',
        status: 200,
        body: 'no choices in response',
      );
    }
    final msg = (choices.first as Map)['message'] as Map?;
    return (msg?['content'] as String?)?.trim() ?? '';
  }

  Future<String> _anthropic(ModelConfig cfg, String prompt) async {
    final uri = Uri.parse('${cfg.apiUrl}/messages');
    final resp = await _http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': cfg.apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': cfg.modelRef,
        'max_tokens': 512,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    );
    return _anthropicText(resp);
  }

  String _anthropicText(http.Response resp) {
    if (resp.statusCode != 200) {
      throw LlmCallException(
        vendor: 'Anthropic',
        status: resp.statusCode,
        body: resp.body,
      );
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final content = body['content'] as List?;
    if (content == null || content.isEmpty) {
      throw LlmCallException(
        vendor: 'Anthropic',
        status: 200,
        body: 'no content in response',
      );
    }
    final first = content.first as Map;
    return (first['text'] as String?)?.trim() ?? '';
  }
}

/// Thrown when a vendor call fails. Stringifies into a tile-friendly,
/// single-line summary (the response body is truncated) so the post-log
/// hook's `cache.putError` displays something useful inline instead of an
/// uninformative "Bad state".
class LlmCallException implements Exception {
  final String vendor;
  final int status;
  final String body;

  LlmCallException({
    required this.vendor,
    required this.status,
    required this.body,
  });

  /// Pulls a short human-readable error out of the body if it's JSON in the
  /// shape `{"error": {"message": "..."}}` (both OpenAI + Anthropic use
  /// that). Falls back to the raw body, truncated.
  String get shortBody {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] is String) return err['message'];
        if (err is String) return err;
      }
    } catch (_) {}
    final s = body.replaceAll('\n', ' ').trim();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  @override
  String toString() => '$vendor $status: $shortBody';
}
