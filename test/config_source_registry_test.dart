import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/github_config.dart';
import 'package:airledger/services/config_source/config_source_registry.dart';
import 'package:airledger/services/config_source/github_config_source.dart';
import 'package:airledger/services/doc_cache.dart';

final _baked = GithubConfig(token: 'baked', owner: 'rsyi', repo: 'fit');

const _user = GithubSourceSettings(
  token: 'gho_x',
  owner: 'friend',
  repo: 'my-ledger',
  branch: 'main',
  root: 'config',
  login: 'friend',
  method: 'device',
);

void main() {
  setUp(ConfigSourceRegistry.reset);
  tearDown(ConfigSourceRegistry.reset);

  test('baked config + nothing stored → BakedGitHubSource', () async {
    final s = await ConfigSourceRegistry.resolve(
        baked: _baked, store: MemorySecretStore());
    expect(s, isA<BakedGitHubSource>());
    expect(s!.displayName, 'rsyi/fit@main');
    expect((s as BakedGitHubSource).config.token, 'baked');
  });

  test('no baked + nothing stored → none (onboarding)', () async {
    expect(
        await ConfigSourceRegistry.resolve(
            baked: null, store: MemorySecretStore()),
        isNull);
  });

  test('a stored user source wins and round-trips every field', () async {
    final store = MemorySecretStore()
      ..values[ConfigSourceRegistry.storageKey] = jsonEncode(_user.toJson());
    final s = await ConfigSourceRegistry.resolve(baked: _baked, store: store);
    expect(s, isA<GitHubConfigSource>());
    expect(s, isNot(isA<BakedGitHubSource>()));
    final g = s as GitHubConfigSource;
    expect(g.config.token, 'gho_x');
    expect(g.root, 'config');
    expect(g.account, 'friend');
    expect(g.displayName, 'friend/my-ledger@main/config');
    expect(g.canSignOut, isTrue);
  });

  test('malformed storage is ignored (falls through to baked)', () async {
    final store = MemorySecretStore()
      ..values[ConfigSourceRegistry.storageKey] = '{"token": ""}';
    expect(await ConfigSourceRegistry.resolve(baked: _baked, store: store),
        isA<BakedGitHubSource>());
    store.values[ConfigSourceRegistry.storageKey] = 'not json';
    expect(await ConfigSourceRegistry.resolve(baked: null, store: store),
        isNull);
  });

  test('connect persists + activates; sign-out reverts to baked', () async {
    final store = MemorySecretStore();
    await ConfigSourceRegistry.init(baked: _baked, store: store);
    expect(ConfigSourceRegistry.active.value, isA<BakedGitHubSource>());
    expect(ConfigSourceRegistry.initialized, isTrue);

    var notified = 0;
    ConfigSourceRegistry.active.addListener(() => notified++);
    await ConfigSourceRegistry.connect(_user);
    expect(store.values[ConfigSourceRegistry.storageKey], isNotNull);
    expect(ConfigSourceRegistry.active.value!.id,
        'github:friend/my-ledger@main/config');
    expect((await ConfigSourceRegistry.userSettings())!.login, 'friend');

    await ConfigSourceRegistry.signOut();
    expect(store.values, isEmpty);
    expect(ConfigSourceRegistry.active.value, isA<BakedGitHubSource>());
    expect(notified, 2);
  });

  test('sign-out without baked config → none', () async {
    final store = MemorySecretStore();
    await ConfigSourceRegistry.init(baked: null, store: store);
    expect(ConfigSourceRegistry.active.value, isNull);
    await ConfigSourceRegistry.connect(_user);
    await ConfigSourceRegistry.signOut();
    expect(ConfigSourceRegistry.active.value, isNull);
  });

  test('switching location drops the shared doc cache', () async {
    final store = MemorySecretStore();
    await ConfigSourceRegistry.init(baked: _baked, store: store);
    await DocCache.fetch('coach/program.yaml', (_) async => 'old');
    await ConfigSourceRegistry.connect(_user);
    expect(await DocCache.fetch('coach/program.yaml', (_) async => 'new'),
        'new');
  });
}
