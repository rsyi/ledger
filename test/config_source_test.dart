import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:airledger/models/github_config.dart';
import 'package:airledger/services/config_source/config_source.dart';
import 'package:airledger/services/config_source/github_config_source.dart';
import 'package:airledger/services/github_client.dart';

/// Records every request (method, url, headers, body) and serves a tiny
/// contents API over [files] (repo path → body).
MockClient _api(Map<String, String> files, List<String> log) {
  String sha(String path) => 'sha-${path.hashCode}';
  return MockClient((req) async {
    final hdrs = (req.headers.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key}=${e.value}')
        .join(',');
    log.add('${req.method} ${req.url} [$hdrs] ${req.body}');
    final m = RegExp(r'^/repos/[^/]+/[^/]+/contents/(.*)$')
        .firstMatch(req.url.path);
    if (m == null) return http.Response('{"message":"nope"}', 500);
    final path = m.group(1)!;
    if (req.method == 'PUT') {
      return http.Response(jsonEncode({'commit': {'sha': 'commit-1'}}), 201);
    }
    if (files.containsKey(path)) {
      return http.Response(
          jsonEncode({
            'content': base64.encode(utf8.encode(files[path]!)),
            'sha': sha(path),
          }),
          200);
    }
    final children = [
      for (final k in files.keys)
        if (k.startsWith('$path/') && !k.substring(path.length + 1).contains('/'))
          {
            'name': k.split('/').last,
            'path': k,
            'type': 'file',
            'sha': sha(k),
          },
    ];
    if (children.isNotEmpty) return http.Response(jsonEncode(children), 200);
    return http.Response('{"message":"Not Found"}', 404);
  });
}

final _owner = GithubConfig(
  token: 'tok',
  owner: 'rsyi',
  repo: 'airledger-fitness',
  defaultBranch: 'main',
);

const _files = {
  'views/strength.view.yml': 'name: strength',
  'views/strength.input.yml': 'view: strength',
  'views/README.md': 'docs',
  'coach/program.yaml': 'version: 13',
  'app/dashboards.yaml': 'domains: []',
};

void main() {
  group('BakedGitHubSource (owner build regression)', () {
    test('doc reads are byte-identical to the pre-abstraction fetcher',
        () async {
      // Old path: CoachBrain.githubFetcher = GithubClient(cfg).readFile.
      final oldLog = <String>[];
      final old = GithubClient(_owner, httpClient: _api(_files, oldLog));
      final newLog = <String>[];
      final src = BakedGitHubSource(_owner, httpClient: _api(_files, newLog));

      for (final path in [
        'coach/program.yaml',
        'coach/phase.yaml', // missing → null on both
        'app/dashboards.yaml',
      ]) {
        final a = (await old.readFile(path))?.content;
        final b = await src.docFetcher(path);
        expect(b, a, reason: path);
      }
      expect(newLog, oldLog);
      expect(newLog.first,
          contains('https://api.github.com/repos/rsyi/airledger-fitness/'
              'contents/coach/program.yaml?ref=main'));
      expect(newLog.first, contains('Authorization=Bearer tok'));
    });

    test('views listing + signature match the old SchemaSync format',
        () async {
      final oldLog = <String>[];
      final old = GithubClient(_owner, httpClient: _api(_files, oldLog));
      final entries = await old.listDir(_owner.viewsPath);
      final oldSig = ([
        for (final e in entries)
          if (e.type == 'file' && e.path.endsWith('.yml'))
            '${e.name}:${e.sha ?? ''}',
      ]..sort())
          .join('|');

      final newLog = <String>[];
      final src = BakedGitHubSource(_owner, httpClient: _api(_files, newLog));
      expect(await src.signature(src.viewsPath), oldSig);
      expect(newLog, oldLog);
      final listed = await src.listDir('views');
      expect(listed.map((e) => e.path),
          ['views/strength.view.yml', 'views/strength.input.yml',
            'views/README.md']);
    });

    test('baked is not sign-out-able, keeps poll + views path from config',
        () {
      final cfg = GithubConfig(
          token: 't', owner: 'o', repo: 'r', viewsPath: 'v', pollSeconds: 0);
      final src = BakedGitHubSource(cfg);
      expect(src.canSignOut, isFalse);
      expect(src.viewsPath, 'v');
      expect(src.pollInterval, isNull);
      expect(src.displayName, 'o/r@main');
      expect(src.id, startsWith('baked:'));
    });
  });

  group('GitHubConfigSource', () {
    test('a rooted source maps paths on the wire and strips them back',
        () async {
      final log = <String>[];
      final files = {
        for (final e in _files.entries) 'cfg/ledger/${e.key}': e.value,
      };
      final src = GitHubConfigSource(
        GithubConfig(token: 't', owner: 'u', repo: 'r', defaultBranch: 'dev'),
        root: '/cfg/ledger/',
        account: 'friend',
        httpClient: _api(files, log),
      );
      expect(src.root, 'cfg/ledger');
      expect(src.displayName, 'u/r@dev/cfg/ledger');
      expect(src.account, 'friend');
      expect(src.canSignOut, isTrue);

      final listed = await src.listDir('views');
      expect(listed.first.path, 'views/strength.view.yml');
      final f = await src.readFile(listed.first.path);
      expect(f!.content, 'name: strength');
      expect(await src.docFetcher('coach/program.yaml'), 'version: 13');
      expect(log.first,
          contains('/repos/u/r/contents/cfg/ledger/views?ref=dev'));
    });

    test('writeFile updates with the existing sha on the branch', () async {
      final log = <String>[];
      final src = GitHubConfigSource(
          GithubConfig(token: 't', owner: 'u', repo: 'r', defaultBranch: 'b'),
          httpClient: _api(_files, log));
      final v = await src.writeFile('coach/program.yaml', 'version: 14',
          message: 'bump');
      expect(v, 'commit-1');
      final put = log.last;
      expect(put, startsWith('PUT '));
      expect(put, contains('"branch":"b"'));
      expect(put, contains('"sha":"sha-${'coach/program.yaml'.hashCode}"'));
    });

    test('signature is null when the listing fails', () async {
      final src = GitHubConfigSource(
        GithubConfig(token: 't', owner: 'u', repo: 'r'),
        httpClient: MockClient((_) async => http.Response('boom', 500)),
      );
      expect(await src.signature('views'), isNull);
    });
  });

  test('configDocFetcher(null) always misses', () async {
    expect(await configDocFetcher(null)('coach/program.yaml'), isNull);
  });
}
