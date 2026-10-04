import 'dart:convert';

import 'package:airledger/services/google_auth/sheets_auth.dart';
import 'package:airledger/services/google_auth/spreadsheet_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Scripted token source: hands out tokens in order, records invalidations.
class _Tokens implements AccessTokenSource {
  _Tokens(this.tokens);
  final List<String?> tokens;
  final invalidated = <String>[];
  int calls = 0;

  @override
  Future<String?> accessToken() async {
    final t = calls < tokens.length ? tokens[calls] : tokens.last;
    calls++;
    return t;
  }

  @override
  Future<void> invalidate(String token) async => invalidated.add(token);
}

const _realishKey =
    '{"type":"service_account","client_email":"a@b.iam.'
    'gserviceaccount.com","private_key":"-----BEGIN PRIVATE KEY-----\\nx\\n'
    '-----END PRIVATE KEY-----\\n","token_uri":"https://oauth2.googleapis.com/token"}';

void main() {
  group('hasServiceAccountKey', () {
    test('a real-shaped key counts as baked', () {
      expect(hasServiceAccountKey(_realishKey), isTrue);
    });
    test('empty / {} / garbage / missing private_key do not', () {
      expect(hasServiceAccountKey(''), isFalse);
      expect(hasServiceAccountKey('{}'), isFalse);
      expect(hasServiceAccountKey('not json'), isFalse);
      expect(hasServiceAccountKey('{"client_email":"x"}'), isFalse);
      expect(hasServiceAccountKey('[]'), isFalse);
    });
  });

  group('selectSheetsAuth', () {
    test('baked key → service account (owner build unchanged)', () {
      final auth = selectSheetsAuth(
        bakedKeyJson: _realishKey,
        google: _Tokens(['t']),
      );
      expect(auth, isA<ServiceAccountSheetsAuth>());
      expect(auth.isServiceAccount, isTrue);
    });
    test('no baked key → Google-sign-in token auth', () {
      final tokens = _Tokens(['t']);
      final auth = selectSheetsAuth(bakedKeyJson: '{}', google: tokens);
      expect(auth, isA<TokenSheetsAuth>());
      expect(auth.isServiceAccount, isFalse);
      expect((auth as TokenSheetsAuth).tokens, same(tokens));
    });
  });

  group('BearerClient', () {
    test('sends the current token as Authorization: Bearer', () async {
      final seen = <String?>[];
      final inner = MockClient((req) async {
        seen.add(req.headers['Authorization']);
        return http.Response('{}', 200);
      });
      final c = BearerClient(_Tokens(['tok-1']), inner: inner);
      final r = await c.get(Uri.parse('https://sheets.example/x'));
      expect(r.statusCode, 200);
      expect(seen, ['Bearer tok-1']);
    });

    test('401 → invalidate, refresh, replay once (body preserved)', () async {
      final seen = <(String?, String)>[];
      var n = 0;
      final inner = MockClient((req) async {
        seen.add((req.headers['Authorization'], req.body));
        return http.Response('{}', n++ == 0 ? 401 : 200);
      });
      final tokens = _Tokens(['stale', 'fresh']);
      final c = BearerClient(tokens, inner: inner);
      final r = await c.post(
        Uri.parse('https://sheets.example/x'),
        body: jsonEncode({'a': 1}),
      );
      expect(r.statusCode, 200);
      expect(tokens.invalidated, ['stale']);
      expect(seen, [('Bearer stale', '{"a":1}'), ('Bearer fresh', '{"a":1}')]);
    });

    test('401 with no different token → 401 returned, no loop', () async {
      var n = 0;
      final inner = MockClient((req) async {
        n++;
        return http.Response('{}', 401);
      });
      final c = BearerClient(_Tokens(['same']), inner: inner);
      final r = await c.get(Uri.parse('https://sheets.example/x'));
      expect(r.statusCode, 401);
      expect(n, 1);
    });

    test(
      'not signed in (null token) → SheetsAuthRequired, no request',
      () async {
        var n = 0;
        final inner = MockClient((req) async {
          n++;
          return http.Response('{}', 200);
        });
        final c = BearerClient(_Tokens([null]), inner: inner);
        await expectLater(
          c.get(Uri.parse('https://sheets.example/x')),
          throwsA(isA<SheetsAuthRequired>()),
        );
        expect(n, 0);
      },
    );
  });

  group('syncWithTokenRefresh', () {
    test('pushes the token before syncing', () async {
      final pushed = <String>[];
      final res = await syncWithTokenRefresh(
        tokens: _Tokens(['t1']),
        setToken: pushed.add,
        runSync: () async => [
          {'view': 'weight', 'error': null},
        ],
      );
      expect(pushed, ['t1']);
      expect(res.single['error'], isNull);
    });

    test(
      'an unauthorized result refreshes the token and re-syncs once',
      () async {
        final pushed = <String>[];
        var runs = 0;
        final tokens = _Tokens(['old', 'new']);
        final res = await syncWithTokenRefresh(
          tokens: tokens,
          setToken: pushed.add,
          runSync: () async {
            runs++;
            return [
              {
                'view': 'weight',
                'error': runs == 1
                    ? 'ensure: unauthorized (401): expired'
                    : null,
              },
            ];
          },
        );
        expect(runs, 2);
        expect(pushed, ['old', 'new']);
        expect(tokens.invalidated, ['old']);
        expect(res.single['error'], isNull);
      },
    );

    test(
      'not signed in → pushes empty token, sync reports unauthorized',
      () async {
        final pushed = <String>[];
        var runs = 0;
        final res = await syncWithTokenRefresh(
          tokens: _Tokens([null]),
          setToken: pushed.add,
          runSync: () async {
            runs++;
            return [
              {
                'view': 'weight',
                'error': 'unauthorized (401): no access token',
              },
            ];
          },
        );
        expect(pushed, ['']);
        expect(runs, 1); // no fresh token to retry with
        expect(res.single['error'], contains('unauthorized'));
      },
    );
  });

  group('parseSpreadsheetId', () {
    const id = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';
    test('bare id', () => expect(parseSpreadsheetId(id), id));
    test('trims whitespace', () => expect(parseSpreadsheetId('  $id \n'), id));
    test('edit URL with gid', () {
      expect(
        parseSpreadsheetId(
          'https://docs.google.com/spreadsheets/d/$id/edit#gid=0',
        ),
        id,
      );
    });
    test('multi-account /u/1/ URL', () {
      expect(
        parseSpreadsheetId(
          'https://docs.google.com/spreadsheets/u/1/d/$id/edit?usp=sharing',
        ),
        id,
      );
    });
    test('URL without trailing path', () {
      expect(parseSpreadsheetId('docs.google.com/spreadsheets/d/$id'), id);
    });
    test('rejects junk', () {
      expect(parseSpreadsheetId(''), isNull);
      expect(parseSpreadsheetId('hello world'), isNull);
      expect(parseSpreadsheetId('short'), isNull);
      expect(parseSpreadsheetId('https://example.com/foo'), isNull);
      expect(
        parseSpreadsheetId('https://docs.google.com/document/d/$id/edit'),
        isNull,
      );
    });
  });
}
