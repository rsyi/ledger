/// GitHub-backed [ConfigSource]s over the existing [GithubClient] (its
/// request shapes, timeout wrapper and error type are unchanged).
library;

import 'package:http/http.dart' as http;

import '../../models/github_config.dart';
import '../github_client.dart';
import 'config_source.dart';

/// A repo + branch (+ optional subdirectory [root]) the config lives in.
/// Root-relative paths in, root-relative paths out: `views/x.yml` maps to
/// `<root>/views/x.yml` on the wire and listings strip the prefix back.
class GitHubConfigSource extends ConfigSource {
  /// The underlying client — exposed for GitHub-only features (the chat's
  /// branch/PR tools) that have no generic config-source equivalent.
  final GithubClient client;

  /// Repo subdirectory holding views/ + coach/ ('' = repo root).
  final String root;

  @override
  final String? account;

  GitHubConfigSource(
    GithubConfig config, {
    String root = '',
    this.account,
    http.Client? httpClient,
  })  : client = GithubClient(config, httpClient: httpClient),
        root = _normalizeRoot(root);

  GithubConfig get config => client.config;

  static String _normalizeRoot(String r) {
    var s = r.trim();
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  @override
  String get id =>
      'github:${config.repoFullName}@${config.defaultBranch}'
      '${root.isEmpty ? '' : '/$root'}';

  @override
  String get displayName =>
      '${config.repoFullName}@${config.defaultBranch}'
      '${root.isEmpty ? '' : '/$root'}';

  @override
  bool get canSignOut => true;

  @override
  String get viewsPath => config.viewsPath;

  @override
  Duration? get pollInterval => config.pollSeconds > 0
      ? Duration(seconds: config.pollSeconds)
      : null;

  String _wire(String path) => root.isEmpty ? path : '$root/$path';

  String _relative(String wirePath) =>
      root.isNotEmpty && wirePath.startsWith('$root/')
          ? wirePath.substring(root.length + 1)
          : wirePath;

  @override
  Future<List<ConfigEntry>> listDir(String path) async {
    final entries = await client.listDir(_wire(path));
    return [
      for (final e in entries)
        ConfigEntry(
          name: e.name,
          path: _relative(e.path),
          isFile: e.type == 'file',
          version: e.sha,
        ),
    ];
  }

  @override
  Future<ConfigFile?> readFile(String path) async {
    final f = await client.readFile(_wire(path));
    return f == null ? null : ConfigFile(content: f.content, version: f.sha);
  }

  @override
  Future<String> writeFile(String path, String content,
      {required String message}) async {
    final existing = await client.readFile(_wire(path));
    return client.putFile(
      path: _wire(path),
      content: content,
      branch: config.defaultBranch,
      message: message,
      sha: existing?.sha,
    );
  }
}

/// The owner build: the repo + token baked into assets/config.yaml by
/// brand.dart. Same wire requests as the pre-abstraction app (pinned by
/// test/config_source_test.dart); not sign-out-able.
class BakedGitHubSource extends GitHubConfigSource {
  BakedGitHubSource(super.config, {super.httpClient});

  @override
  String get id => 'baked:${super.id}';

  @override
  bool get canSignOut => false;
}
