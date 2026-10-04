import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:airledger/services/config_source/github_auth.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  group('GithubDeviceFlow', () {
    test('start posts client id + scope and parses the code', () async {
      late http.Request seen;
      final flow = GithubDeviceFlow(
        clientId: 'Iv1.abc',
        httpClient: MockClient((req) async {
          seen = req;
          return _json({
            'device_code': 'dev',
            'user_code': 'WDJB-MJHT',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          });
        }),
      );
      final code = await flow.start();
      expect(seen.url.toString(), 'https://github.com/login/device/code');
      expect(seen.headers['Accept'], 'application/json');
      expect(seen.bodyFields, {'client_id': 'Iv1.abc', 'scope': 'repo'});
      expect(code.userCode, 'WDJB-MJHT');
      expect(code.interval, const Duration(seconds: 5));
      expect(code.expiresIn, const Duration(seconds: 900));
    });

    test('start surfaces device_flow_disabled', () async {
      final flow = GithubDeviceFlow(
        clientId: 'x',
        httpClient: MockClient((_) async => _json({
              'error': 'device_flow_disabled',
              'error_description': 'Device flow is disabled',
            })),
      );
      await expectLater(
          flow.start(),
          throwsA(isA<GithubAuthException>()
              .having((e) => e.code, 'code', 'device_flow_disabled')));
    });

    const code = GithubDeviceCode(
      deviceCode: 'dev',
      userCode: 'U',
      verificationUri: 'https://github.com/login/device',
      expiresIn: Duration(minutes: 15),
      interval: Duration(seconds: 5),
    );

    test('poll waits through pending + slow_down, then returns the token',
        () async {
      final replies = [
        {'error': 'authorization_pending'},
        {'error': 'slow_down', 'interval': 10},
        {'error': 'authorization_pending'},
        {'access_token': 'gho_123', 'token_type': 'bearer', 'scope': 'repo'},
      ];
      final sleeps = <Duration>[];
      final bodies = <Map<String, String>>[];
      final flow = GithubDeviceFlow(
        clientId: 'cid',
        sleep: (d) async => sleeps.add(d),
        httpClient: MockClient((req) async {
          expect(req.url.toString(),
              'https://github.com/login/oauth/access_token');
          bodies.add(req.bodyFields);
          return _json(replies.removeAt(0));
        }),
      );
      expect(await flow.poll(code), 'gho_123');
      expect(sleeps, [
        const Duration(seconds: 5),
        const Duration(seconds: 5),
        const Duration(seconds: 10),
        const Duration(seconds: 10),
      ]);
      expect(bodies.first, {
        'client_id': 'cid',
        'device_code': 'dev',
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
    });

    test('slow_down without an interval adds 5 s', () async {
      final replies = [
        {'error': 'slow_down'},
        {'access_token': 't'},
      ];
      final sleeps = <Duration>[];
      final flow = GithubDeviceFlow(
        clientId: 'c',
        sleep: (d) async => sleeps.add(d),
        httpClient: MockClient((_) async => _json(replies.removeAt(0))),
      );
      await flow.poll(code);
      expect(sleeps.last, const Duration(seconds: 10));
    });

    for (final err in ['access_denied', 'expired_token']) {
      test('poll throws on $err', () async {
        final flow = GithubDeviceFlow(
          clientId: 'c',
          sleep: (_) async {},
          httpClient: MockClient((_) async => _json({'error': err})),
        );
        await expectLater(flow.poll(code),
            throwsA(isA<GithubAuthException>().having((e) => e.code, 'code', err)));
      });
    }

    test('poll stops at the local expiry deadline', () async {
      var t = DateTime(2026, 10, 3);
      final flow = GithubDeviceFlow(
        clientId: 'c',
        now: () => t,
        sleep: (d) async => t = t.add(const Duration(minutes: 10)),
        httpClient:
            MockClient((_) async => _json({'error': 'authorization_pending'})),
      );
      await expectLater(
          flow.poll(code),
          throwsA(isA<GithubAuthException>()
              .having((e) => e.code, 'code', 'expired_token')));
    });

    test('poll honours cancellation', () async {
      var cancel = false;
      final flow = GithubDeviceFlow(
        clientId: 'c',
        sleep: (_) async => cancel = true,
        httpClient: MockClient((_) async => _json({'access_token': 'x'})),
      );
      await expectLater(
          flow.poll(code, cancelled: () => cancel),
          throwsA(isA<GithubAuthException>()
              .having((e) => e.code, 'code', 'cancelled')));
    });
  });

  group('GithubAccountApi', () {
    test('login reads /user with the bearer token', () async {
      final api = GithubAccountApi('tok', httpClient: MockClient((req) async {
        expect(req.url.path, '/user');
        expect(req.headers['Authorization'], 'Bearer tok');
        return _json({'login': 'friend'});
      }));
      expect(await api.login(), 'friend');
    });

    test('login: 401 → bad_token', () async {
      final api = GithubAccountApi('bad',
          httpClient: MockClient((_) async => _json({}, 401)));
      await expectLater(
          api.login(),
          throwsA(isA<GithubAuthException>()
              .having((e) => e.code, 'code', 'bad_token')));
    });

    test('repos paginates until a short page', () async {
      final pages = <String>[];
      final api = GithubAccountApi('t', httpClient: MockClient((req) async {
        final page = req.url.queryParameters['page']!;
        pages.add(page);
        final n = page == '1' ? 100 : 3;
        return _json([
          for (var i = 0; i < n; i++)
            {
              'name': 'r$page-$i',
              'owner': {'login': 'u'},
              'default_branch': 'trunk',
              'private': true,
            },
        ]);
      }));
      final repos = await api.repos();
      expect(pages, ['1', '2']);
      expect(repos, hasLength(103));
      expect(repos.first.fullName, 'u/r1-0');
      expect(repos.first.defaultBranch, 'trunk');
      expect(repos.first.isPrivate, isTrue);
    });

    test('branches lists names', () async {
      final api = GithubAccountApi('t',
          httpClient: MockClient((req) async {
            expect(req.url.path, '/repos/u/r/branches');
            return _json([
              {'name': 'main'},
              {'name': 'dev'},
            ]);
          }));
      expect(await api.branches('u', 'r'), ['main', 'dev']);
    });

    MockClient repo({required bool views, required bool program, int? fail}) =>
        MockClient((req) async {
          if (fail != null) return _json({'message': 'x'}, fail);
          final p = req.url.path;
          expect(req.url.queryParameters['ref'], 'main');
          if (p.endsWith('/contents/cfg/views')) {
            return views
                ? _json([
                    {'name': 'strength.view.yml', 'type': 'file'},
                  ])
                : _json({'message': 'Not Found'}, 404);
          }
          if (p.endsWith('/contents/cfg/coach/program.yaml')) {
            return program
                ? _json({'content': '', 'sha': 's'})
                : _json({'message': 'Not Found'}, 404);
          }
          return _json({'message': 'unexpected $p'}, 500);
        });

    test('validate: views + program → ok', () async {
      final c = await GithubAccountApi('t',
              httpClient: repo(views: true, program: true))
          .validate('u', 'r', 'main', 'cfg');
      expect(c.ok, isTrue);
      expect(c.problem, isNull);
    });

    test('validate: missing program → not ok, says so', () async {
      final c = await GithubAccountApi('t',
              httpClient: repo(views: true, program: false))
          .validate('u', 'r', 'main', 'cfg');
      expect(c.ok, isFalse);
      expect(c.hasViews, isTrue);
      expect(c.problem, contains('coach/program.yaml'));
    });

    test('validate: empty repo → not a Ledger config', () async {
      final c = await GithubAccountApi('t',
              httpClient: repo(views: false, program: false))
          .validate('u', 'r', 'main', 'cfg');
      expect(c.problem, contains('does not look like a Ledger config'));
    });

    test('validate: 403 → access error, never throws', () async {
      final c = await GithubAccountApi('t',
              httpClient: repo(views: true, program: true, fail: 403))
          .validate('u', 'r', 'main', 'cfg');
      expect(c.ok, isFalse);
      expect(c.error, contains('403'));
    });
  });
}
