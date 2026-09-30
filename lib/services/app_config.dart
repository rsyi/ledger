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

  /// Optional Kaya Gmail-import config — drives the Kaya card's
  /// Connect/Sync flow. Null (or placeholder) when the build has no
  /// `integrations.kaya_gmail` block; the card shows the GCP setup hint.
  final KayaGmailConfig? kayaGmail;

  /// Optional Whoop API credentials — drives the "Whoop (sleep)" card on
  /// the Integrations page (distinct from the BLE live-HR Whoop card).
  /// Null when the build has no `integrations.whoop_api` block; the card
  /// shows a setup hint.
  final WhoopApiConfig? whoopApi;

  AppConfig({
    required this.spreadsheetId,
    required this.models,
    this.disablePostLog = false,
    this.github,
    this.kioskView,
    this.quickbooks,
    this.withings,
    this.kayaGmail,
    this.whoopApi,
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
      kayaGmail: node['integrations'] is YamlMap &&
              (node['integrations'] as YamlMap)['kaya_gmail'] is YamlMap
          ? KayaGmailConfig.fromYaml(_yamlMapToJson(
              (node['integrations'] as YamlMap)['kaya_gmail'] as YamlMap))
          : null,
      whoopApi: node['integrations'] is YamlMap &&
              (node['integrations'] as YamlMap)['whoop_api'] is YamlMap
          ? WhoopApiConfig.fromYaml(_yamlMapToJson(
              (node['integrations'] as YamlMap)['whoop_api'] as YamlMap))
          : null,
    );
  }
}

/// `integrations.whoop_api` — Whoop developer-app OAuth credentials
/// (created at developer.whoop.com). [clientId] is public; [clientSecret]
/// ships in the APK (Whoop's auth-code flow requires it at token
/// exchange). Empty / SET_ME → the card shows a setup hint, button-less.
class WhoopApiConfig {
  const WhoopApiConfig({required this.clientId, required this.clientSecret});

  final String clientId;
  final String clientSecret;

  bool get isConfigured =>
      clientId.isNotEmpty &&
      clientSecret.isNotEmpty &&
      clientId != 'SET_ME' &&
      clientSecret != 'SET_ME';

  static WhoopApiConfig fromYaml(Map<String, dynamic> m) => WhoopApiConfig(
        clientId: (m['client_id'] ?? '').toString(),
        clientSecret: (m['client_secret'] ?? '').toString(),
      );
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

/// `integrations.kaya_gmail` — the Google sign-in half of the Kaya
/// import flow. [serverClientId] must be the WEB-type OAuth client id
/// from the GCP project that also holds the Android OAuth client
/// (package + signing SHA-1): google_sign_in 7.x on Android requires
/// the web client id at initialize() while Play Services matches the
/// Android client by package + SHA-1 automatically. Any Google account
/// can then sign in — nothing here is account-specific.
class KayaGmailConfig {
  const KayaGmailConfig({required this.serverClientId});

  final String serverClientId;

  /// False while config.yml still lacks the block / carries the SET_ME
  /// placeholder — the card shows the GCP setup hint instead of Connect.
  bool get isConfigured =>
      serverClientId.isNotEmpty && serverClientId != 'SET_ME';

  static KayaGmailConfig fromYaml(Map<String, dynamic> m) => KayaGmailConfig(
        serverClientId: (m['server_client_id'] ?? '').toString(),
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
