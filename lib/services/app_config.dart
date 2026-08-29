import 'package:flutter/services.dart' show rootBundle;
import 'package:yaml/yaml.dart';

import '../models/github_config.dart';
import '../models/model_config.dart';
import '../models/quickbooks_config.dart';

/// Runtime config bundled in the APK at `assets/config.yaml`.
/// Baked at build time by `tool/brand.dart` from the schemas repo's
/// `config.yml` + `.env`.
class AppConfig {
  final String spreadsheetId;
  final List<ModelConfig> models;

  /// Top-level kill-switch for post-log LLM hooks. When true, the timeline
  /// skips the post-log hook even if a view has one defined and a model is
  /// configured. Set via `disable_post_log: true` in the repo `config.yml`.
  /// Useful for builds (e.g. Poke House) that want every other piece of
  /// the LLM plumbing inert.
  final bool disablePostLog;

  /// Optional GitHub config — drives the schema hot-reload + chat assistant.
  /// Null when the build has no `github:` block; the relevant features
  /// stay inert.
  final GithubConfig? github;

  /// When non-null, the app boots straight into the timeline for the view
  /// matching this name — skipping the home screen and most chrome (chat,
  /// sync, reload). For single-purpose client-facing builds (Poke House
  /// inventory on a fleet of iPads) where employees only ever log into
  /// one view and shouldn't see the rest of the surface. Set via
  /// `kiosk_view: <view_name>` in the repo `config.yml`.
  final String? kioskView;

  /// Optional QuickBooks Online config — drives the "Update" push button +
  /// per-transaction push-status badges. Null when the build has no
  /// `quickbooks:` block; the feature stays inert.
  final QuickBooksConfig? quickbooks;

  /// Optional Withings integration credentials — drives the Withings
  /// card on the Integrations page. Null when the build has no
  /// `integrations.withings` block; the card shows a setup hint.
  final WithingsConfig? withings;

  AppConfig({
    required this.spreadsheetId,
    required this.models,
    this.disablePostLog = false,
    this.github,
    this.kioskView,
    this.quickbooks,
    this.withings,
  });

  static Future<AppConfig> load() async {
    final raw = await rootBundle.loadString('assets/config.yaml');
    final node = loadYaml(raw);
    if (node is! YamlMap) {
      throw const ConfigException(
        'assets/config.yaml: top-level must be a map',
      );
    }
    final spreadsheetId = node['spreadsheet_id'] as String?;
    if (spreadsheetId == null) {
      throw const ConfigException(
        'assets/config.yaml: missing spreadsheet_id',
      );
    }
    final modelsNode = node['models'];
    final models = <ModelConfig>[];
    if (modelsNode is YamlList) {
      for (final entry in modelsNode) {
        if (entry is! YamlMap) continue;
        models.add(ModelConfig.fromYaml(_yamlMapToJson(entry)));
      }
    }
    return AppConfig(
      spreadsheetId: spreadsheetId,
      models: models,
      disablePostLog: (node['disable_post_log'] as bool?) ?? false,
      github: node['github'] is YamlMap
          ? GithubConfig.fromYaml(_yamlMapToJson(node['github'] as YamlMap))
          : null,
      kioskView: node['kiosk_view'] as String?,
      quickbooks: node['quickbooks'] is YamlMap
          ? QuickBooksConfig.fromYaml(node['quickbooks'] as YamlMap)
          : null,
      withings: node['integrations'] is YamlMap &&
              (node['integrations'] as YamlMap)['withings'] is YamlMap
          ? WithingsConfig.fromYaml(_yamlMapToJson(
              (node['integrations'] as YamlMap)['withings'] as YamlMap))
          : null,
    );
  }
}

class WithingsConfig {
  const WithingsConfig({required this.clientId, required this.clientSecret});

  final String clientId;
  final String clientSecret;

  /// False while the .env still carries the SET_ME placeholders —
  /// the Integrations page shows a setup hint instead of Connect.
  bool get isConfigured =>
      clientId.isNotEmpty &&
      clientSecret.isNotEmpty &&
      clientId != 'SET_ME' &&
      clientSecret != 'SET_ME';

  static WithingsConfig fromYaml(Map<String, dynamic> m) => WithingsConfig(
        clientId: (m['client_id'] ?? '').toString(),
        clientSecret: (m['client_secret'] ?? '').toString(),
      );
}

Map<String, dynamic> _yamlMapToJson(YamlMap m) => {
      for (final entry in m.entries) entry.key.toString(): entry.value,
    };

class ConfigException implements Exception {
  final String message;
  const ConfigException(this.message);
  @override
  String toString() => message;
}
