import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:airledger/services/integrations/kaya_api.dart';

void main() {
  // ---------------------------------------------------------------------------
  // login
  // ---------------------------------------------------------------------------

  test('login returns tokens and coerces numeric user id to string', () async {
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode({
          'message': 'ok',
          'token': 'tok123',
          'refresh_token': 'ref456',
          'user': {'id': 42},
        }),
        200,
      );
    });

    final api = KayaApi(client: client);
    final auth = await api.login('user@example.com', 'secret');

    expect(auth.token, 'tok123');
    expect(auth.refreshToken, 'ref456');
    expect(auth.userId, '42'); // numeric id coerced to string
    expect(captured.url.toString(),
        'https://kaya-beta.kayaclimb.com/api/user/login');
    expect(captured.headers['Origin'], 'https://kaya-app.kayaclimb.com');
    expect(captured.headers['Referer'], 'https://kaya-app.kayaclimb.com/');
    expect(captured.headers['Content-Type'], contains('application/json'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['email'], 'user@example.com');
    expect(body['password'], 'secret');
  });

  test('login surfaces non-200 as StateError', () async {
    final client = MockClient(
        (_) async => http.Response('{"message":"Unauthorized"}', 401));
    final api = KayaApi(client: client);

    expect(() => api.login('a@b.com', 'bad'), throwsA(isA<StateError>()));
  });

  test('login surfaces missing fields as StateError', () async {
    // Missing refresh_token
    final client = MockClient((_) async => http.Response(
          jsonEncode({'message': 'ok', 'token': 'tok', 'user': {'id': 1}}),
          200,
        ));
    final api = KayaApi(client: client);

    expect(() => api.login('a@b.com', 'pw'), throwsA(isA<StateError>()));
  });

  // ---------------------------------------------------------------------------
  // refresh
  // ---------------------------------------------------------------------------

  test('refresh returns new token', () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode({'message': 'ok', 'token': 'newTok'}),
          200,
        ));
    final api = KayaApi(client: client);
    final token = await api.refresh('ref456');
    expect(token, 'newTok');
  });

  // ---------------------------------------------------------------------------
  // ascentsPage
  // ---------------------------------------------------------------------------

  test('ascentsPage sends bearer, verbatim query, variables, and parses list',
      () async {
    final fakeAscents = [
      {'id': '1', 'date': '2026-01-01'},
      {'id': '2', 'date': '2026-01-02'},
    ];
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode({'data': {'ascentsForUser': fakeAscents}}),
        200,
      );
    });

    final api = KayaApi(client: client);
    final result = await api.ascentsPage(
      token: 'mytoken',
      userId: '99',
      offset: 0,
      count: 50,
    );

    expect(result, fakeAscents);
    expect(captured.url.toString(),
        'https://kaya-beta.kayaclimb.com/graphql');
    expect(captured.headers['Authorization'], 'Bearer mytoken');
    expect(captured.headers['Origin'], 'https://kaya-app.kayaclimb.com');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['query'], kAscentsQuery);
    final vars = body['variables'] as Map<String, dynamic>;
    expect(vars['user_id'], '99');
    expect(vars['offset'], 0);
    expect(vars['count'], 50);
  });

  // ---------------------------------------------------------------------------
  // sessionsPage
  // ---------------------------------------------------------------------------

  test('sessionsPage hits sessionsForUser and parses its list', () async {
    final fakeSessions = [
      {'id': '10', 'start_time': '2026-01-01T09:00:00'},
    ];
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(
        jsonEncode({'data': {'sessionsForUser': fakeSessions}}),
        200,
      );
    });

    final api = KayaApi(client: client);
    final result = await api.sessionsPage(
      token: 'mytoken',
      userId: '77',
      offset: 10,
    );

    expect(result, fakeSessions);
    expect(captured.url.toString(),
        'https://kaya-beta.kayaclimb.com/graphql');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['query'], kSessionsQuery);
    final vars = body['variables'] as Map<String, dynamic>;
    expect(vars['user_id'], '77');
    expect(vars['offset'], 10);
  });

  // ---------------------------------------------------------------------------
  // 429 retry
  // ---------------------------------------------------------------------------

  test('429 with retry-after:0 then success returns page, exactly 2 calls',
      () async {
    var callCount = 0;
    final fakeData = [
      {'id': '5'}
    ];
    final client = MockClient((req) async {
      callCount++;
      if (callCount == 1) {
        return http.Response('', 429,
            headers: {'retry-after': '0'});
      }
      return http.Response(
        jsonEncode({'data': {'ascentsForUser': fakeData}}),
        200,
      );
    });

    final api = KayaApi(client: client);
    final result = await api.ascentsPage(
      token: 'tok',
      userId: '1',
      offset: 0,
    );

    expect(result, fakeData);
    expect(callCount, 2);
  });

  // ---------------------------------------------------------------------------
  // 401 → KayaAuthException
  // ---------------------------------------------------------------------------

  test('401 from graphql throws KayaAuthException', () async {
    final client = MockClient(
        (_) async => http.Response('{"message":"Unauthorized"}', 401));
    final api = KayaApi(client: client);

    expect(
      () => api.ascentsPage(token: 'expired', userId: '1', offset: 0),
      throwsA(isA<KayaAuthException>()),
    );
  });

  // ---------------------------------------------------------------------------
  // GraphQL errors list → StateError
  // ---------------------------------------------------------------------------

  test('200 with GraphQL errors list throws StateError', () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode({
            'data': null,
            'errors': [
              {'message': 'some gql error'}
            ],
          }),
          200,
        ));
    final api = KayaApi(client: client);

    expect(
      () => api.ascentsPage(token: 'tok', userId: '1', offset: 0),
      throwsA(isA<StateError>()),
    );
  });
}
