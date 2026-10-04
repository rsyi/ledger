import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/app_config.dart';

void main() {
  test('owner block (token+owner+repo) → baked, unchanged parse', () {
    final g = parseGithubSetup({
      'owner': 'rsyi',
      'repo': 'airledger-fitness',
      'default_branch': 'main',
      'views_path': 'views',
      'token': 'tok',
    });
    expect(g.baked!.repoFullName, 'rsyi/airledger-fitness');
    expect(g.baked!.token, 'tok');
    expect(g.baked!.pollSeconds, 300);
    expect(g.oauthClientId, isNull);
    expect(g.templateRepo, kDefaultTemplateRepo);
  });

  test('client-id-only block → no baked source, sign-in configured', () {
    final g = parseGithubSetup(
        {'oauth_client_id': 'Ov23li', 'template_repo': 'me/tmpl'});
    expect(g.baked, isNull);
    expect(g.oauthClientId, 'Ov23li');
    expect(g.templateRepo, 'me/tmpl');
  });

  test('SET_ME client id counts as absent (PAT fallback)', () {
    expect(parseGithubSetup({'oauth_client_id': 'SET_ME'}).oauthClientId,
        isNull);
    expect(parseGithubSetup(null).baked, isNull);
  });

  test('a half-configured repo block still fails loudly', () {
    expect(() => parseGithubSetup({'owner': 'o', 'repo': 'r'}),
        throwsFormatException);
  });
}
