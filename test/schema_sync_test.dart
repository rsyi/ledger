import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:airledger/models/github_config.dart';
import 'package:airledger/services/config_source/github_config_source.dart';
import 'package:airledger/services/schema_sync.dart';

/// Fake GitHub contents API over [files] (name → yaml body). Files in
/// [missing] appear in the directory listing but 404 on read — the shape a
/// mid-refresh push (rename/delete) or API blip produces. [gate], when set,
/// delays every response until completed. [requests] records request paths.
MockClient _githubApi({
  required Map<String, String> files,
  Set<String> missing = const {},
  Future<void>? gate,
  List<String>? requests,
}) {
  String sha(String name) => 'sha-$name-${files[name].hashCode}';
  return MockClient((req) async {
    if (gate != null) await gate;
    requests?.add(req.url.path);
    final path = req.url.path; // /repos/o/r/contents/views[/file]
    const prefix = '/repos/o/r/contents/views';
    if (path == prefix) {
      final listing = [
        for (final name in files.keys)
          {
            'name': name,
            'path': 'views/$name',
            'type': 'file',
            'sha': sha(name),
          },
      ];
      return http.Response(jsonEncode(listing), 200);
    }
    if (path.startsWith('$prefix/')) {
      final name = path.substring(prefix.length + 1);
      if (!files.containsKey(name) || missing.contains(name)) {
        return http.Response('{"message": "Not Found"}', 404);
      }
      return http.Response(
        jsonEncode({
          'content': base64.encode(utf8.encode(files[name]!)),
          'sha': sha(name),
        }),
        200,
      );
    }
    return http.Response('{"message": "unexpected ${req.url}"}', 500);
  });
}

SchemaSync _sync(MockClient client) => SchemaSync(BakedGitHubSource(
      GithubConfig(token: 't', owner: 'o', repo: 'r'),
      httpClient: client,
    ));

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('schema_sync_test');
    SchemaSync.docsDir = () async => tmp;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  List<String> cachedFiles() {
    final d = Directory(p.join(tmp.path, 'synced_schemas'));
    if (!d.existsSync()) return [];
    return d
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toList()
      ..sort();
  }

  const v1 = {
    'strength.view.yml': 'name: strength',
    'strength.input.yml': 'view: strength',
  };

  test('refresh fetches all listed files and records a full signature',
      () async {
    final sync = _sync(_githubApi(files: v1));
    final result = await sync.refresh();

    expect(result.ok, isTrue);
    expect(result.fetched, 2);
    expect(cachedFiles(),
        ['.sig', 'strength.input.yml', 'strength.view.yml']);
    expect(await SchemaSync.cachedSignature(), result.signature);
    // Signature matches what remoteSignature() computes for the same state.
    expect(await sync.remoteSignature(), result.signature);
  });

  test('refresh aborts and keeps the old cache when a listed file 404s',
      () async {
    // Seed a good cache first.
    final good = await _sync(_githubApi(files: v1)).refresh();
    expect(good.ok, isTrue);

    // Remote now lists a second view whose read 404s (push raced the sync).
    final sync = _sync(_githubApi(
      files: {...v1, 'cardio.view.yml': 'name: cardio'},
      missing: {'cardio.view.yml'},
    ));
    final result = await sync.refresh();

    expect(result.ok, isFalse, reason: 'partial fetch must not succeed');
    expect(
      cachedFiles(),
      ['.sig', 'strength.input.yml', 'strength.view.yml'],
      reason: 'old complete cache must survive a failed refresh',
    );
    expect(await SchemaSync.cachedSignature(), good.signature,
        reason: 'signature must still describe the cache contents');
  });

  test('concurrent refreshes coalesce into one fetch', () async {
    final gate = Completer<void>();
    final requestsA = <String>[];
    final requestsB = <String>[];
    final syncA =
        _sync(_githubApi(files: v1, gate: gate.future, requests: requestsA));
    final syncB = _sync(_githubApi(files: v1, requests: requestsB));

    final futureA = syncA.refresh();
    final futureB = syncB.refresh(); // starts while A is in flight
    gate.complete();
    final resultA = await futureA;
    final resultB = await futureB;

    expect(resultA.ok, isTrue);
    expect(resultB.signature, resultA.signature,
        reason: 'second caller should receive the in-flight result');
    expect(requestsB, isEmpty,
        reason: 'second refresh must not fetch on its own');
    expect(cachedFiles(),
        ['.sig', 'strength.input.yml', 'strength.view.yml']);
  });

  group('ensureFresh', () {
    test('refreshes an empty cache and returns the new signature', () async {
      final sig = await _sync(_githubApi(files: v1)).ensureFresh();
      expect(sig, isNotNull);
      expect(sig, await SchemaSync.cachedSignature());
      expect(cachedFiles(),
          ['.sig', 'strength.input.yml', 'strength.view.yml']);
    });

    test('skips the download when the cache already matches remote',
        () async {
      await _sync(_githubApi(files: v1)).refresh();
      final requests = <String>[];
      final sig =
          await _sync(_githubApi(files: v1, requests: requests)).ensureFresh();
      expect(sig, await SchemaSync.cachedSignature());
      expect(requests, ['/repos/o/r/contents/views'],
          reason: 'only the listing call — no file bodies');
    });

    test('re-fetches when the remote changed', () async {
      await _sync(_githubApi(files: v1)).refresh();
      final v2 = {...v1, 'cardio.view.yml': 'name: cardio'};
      final sig = await _sync(_githubApi(files: v2)).ensureFresh();
      expect(sig, await SchemaSync.cachedSignature());
      expect(cachedFiles(), [
        '.sig',
        'cardio.view.yml',
        'strength.input.yml',
        'strength.view.yml',
      ]);
    });

    test('returns the cached signature when the network is down', () async {
      final good = await _sync(_githubApi(files: v1)).refresh();
      final offline =
          _sync(MockClient((_) async => throw http.ClientException('down')));
      expect(await offline.ensureFresh(), good.signature,
          reason: 'UI can still catch up to the cache while offline');
    });

    test('returns the old signature when the refresh fails', () async {
      final good = await _sync(_githubApi(files: v1)).refresh();
      // Remote changed, but the new file 404s on read — refresh aborts.
      final sync = _sync(_githubApi(
        files: {...v1, 'cardio.view.yml': 'name: cardio'},
        missing: {'cardio.view.yml'},
      ));
      expect(await sync.ensureFresh(), good.signature);
      expect(await SchemaSync.cachedSignature(), good.signature);
    });
  });
}
