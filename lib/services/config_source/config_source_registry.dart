/// Resolves + holds the ACTIVE [ConfigSource] (multi-user sub-project 1).
///
/// Resolution at bootstrap:
///   1. a user-connected GitHub source (secure storage) — an explicit
///      choice made in Settings / onboarding; absent on the owner's
///      device unless he connects one, so his build is unchanged;
///   2. else the BAKED source (assets/config.yaml `github:` with a token);
///   3. else none → the "Connect your program" placeholder.
/// Signing out of a user source falls back to the baked one when the
/// build has it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../models/github_config.dart';
import '../coach_brain.dart';
import '../doc_cache.dart';
import '../schema_sync.dart';
import 'config_source.dart';
import 'github_config_source.dart';

/// Minimal secret key-value seam (secure storage on device; a map in
/// tests — the plugin has no test registry).
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  const SecureSecretStore();
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// A user-connected GitHub config location + its credential.
class GithubSourceSettings {
  final String token;
  final String owner;
  final String repo;
  final String branch;
  final String root;

  /// GitHub login the token belongs to (display only).
  final String? login;

  /// 'device' (OAuth device flow) or 'pat' (pasted token).
  final String method;

  const GithubSourceSettings({
    required this.token,
    required this.owner,
    required this.repo,
    this.branch = 'main',
    this.root = '',
    this.login,
    this.method = 'device',
  });

  Map<String, Object?> toJson() => {
        'token': token,
        'owner': owner,
        'repo': repo,
        'branch': branch,
        'root': root,
        'login': login,
        'method': method,
      };

  /// Null on any malformed payload (treated as "not connected").
  static GithubSourceSettings? fromJson(Object? j) {
    if (j is! Map) return null;
    final token = j['token'], owner = j['owner'], repo = j['repo'];
    if (token is! String || token.isEmpty) return null;
    if (owner is! String || owner.isEmpty) return null;
    if (repo is! String || repo.isEmpty) return null;
    return GithubSourceSettings(
      token: token,
      owner: owner,
      repo: repo,
      branch: (j['branch'] as String?) ?? 'main',
      root: (j['root'] as String?) ?? '',
      login: j['login'] as String?,
      method: (j['method'] as String?) ?? 'device',
    );
  }

  GitHubConfigSource toSource({http.Client? httpClient}) => GitHubConfigSource(
        GithubConfig(
            token: token, owner: owner, repo: repo, defaultBranch: branch),
        root: root,
        account: login,
        httpClient: httpClient,
      );
}

class ConfigSourceRegistry {
  ConfigSourceRegistry._();

  static const storageKey = 'config_source.github.v1';

  /// The active source; null → not connected. The app root listens and
  /// re-bootstraps (keyed on [ConfigSource.id]) when it changes.
  static final active = ValueNotifier<ConfigSource?>(null);

  /// True once [init] ran (the gate shows a spinner until then).
  static bool initialized = false;

  static SecretStore _store = const SecureSecretStore();
  static GithubConfig? _baked;

  /// Sign-in settings from the assets config (`github.oauth_client_id`,
  /// `github.template_repo`) — read by the connect screen wherever it is
  /// opened from (onboarding gate, Settings → Change).
  static String? oauthClientId;
  static String templateRepo = 'rsyi/ledger-template';

  /// Pure resolution (see library doc). Tests call this directly.
  static Future<ConfigSource?> resolve({
    required GithubConfig? baked,
    required SecretStore store,
    http.Client? httpClient,
  }) async {
    final user = await loadSettings(store);
    if (user != null) return user.toSource(httpClient: httpClient);
    if (baked != null) return BakedGitHubSource(baked, httpClient: httpClient);
    return null;
  }

  static Future<GithubSourceSettings?> loadSettings(SecretStore store) async {
    try {
      final raw = await store.read(storageKey);
      if (raw == null || raw.isEmpty) return null;
      return GithubSourceSettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// Bootstrap: resolves and publishes the active source.
  static Future<ConfigSource?> init({
    required GithubConfig? baked,
    SecretStore? store,
    String? oauthClientId,
    String? templateRepo,
  }) async {
    if (store != null) _store = store;
    _baked = baked;
    ConfigSourceRegistry.oauthClientId = oauthClientId;
    if (templateRepo != null) ConfigSourceRegistry.templateRepo = templateRepo;
    final s = await resolve(baked: baked, store: _store);
    _publish(s);
    initialized = true;
    return s;
  }

  /// The user's stored settings (null when on the baked source / none).
  static Future<GithubSourceSettings?> userSettings() => loadSettings(_store);

  /// Whether the build has baked config to fall back to.
  static bool get hasBaked => _baked != null;

  /// Persists + activates a user-connected GitHub source.
  static Future<void> connect(GithubSourceSettings settings) async {
    await _store.write(storageKey, jsonEncode(settings.toJson()));
    _publish(settings.toSource());
  }

  /// Forgets the user source (token included) → baked or none.
  static Future<void> signOut() async {
    await _store.delete(storageKey);
    _publish(_baked == null ? null : BakedGitHubSource(_baked!));
  }

  /// Test hook.
  @visibleForTesting
  static void reset() {
    active.value = null;
    initialized = false;
    _store = const SecureSecretStore();
    _baked = null;
    oauthClientId = null;
    templateRepo = 'rsyi/ledger-template';
  }

  static void _publish(ConfigSource? s) {
    final prev = active.value;
    if (prev != null && s != null && prev.id == s.id) {
      active.value = s; // same location (e.g. re-signed-in): no cache drop
      return;
    }
    if (prev != null) {
      // A different location: config cached from the old one must not
      // leak into the new one's UI.
      DocCache.clear();
      CoachBrain.clearDocCache();
      unawaited(SchemaSync.clearCache());
    }
    active.value = s;
  }
}
