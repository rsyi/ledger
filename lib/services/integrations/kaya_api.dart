/// Kaya climbing-app HTTP client — UNOFFICIAL reverse-engineered API.
///
/// Kaya has no public developer programme. The `Origin`/`Referer` headers
/// exist because their server 403s any request that doesn't look like the
/// browser app. The verbatim GraphQL query strings (`kAscentsQuery` /
/// `kSessionsQuery`) are sent exactly as the web client sends them.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Public query constants (consumers use these to avoid typos).
// ---------------------------------------------------------------------------

const kAscentsQuery =
    'query ascentsForUser(\$user_id: ID!, \$offset: Int!, \$count: Int!) '
    '{ ascentsForUser(user_id: \$user_id, offset: \$offset, count: \$count) '
    '{ id session_id date comment rating stiffness attempts '
    'ascent_type { id name } '
    'gym { id name address city region country latitude longitude } '
    'climb { id name lead climb_type { id name } '
    'grade { id name climb_type_group } '
    'gym { id name address city region country latitude longitude } } } }';

const kSessionsQuery =
    'query sessionsForUser(\$user_id: ID!, \$offset: Int!, \$count: Int!) '
    '{ sessionsForUser(user_id: \$user_id, offset: \$offset, count: \$count) '
    '{ id start_time end_time notes '
    'gym { id name address city region country latitude longitude } '
    'board { id name latitude longitude } '
    'destination { id name latitude longitude } } }';

// ---------------------------------------------------------------------------
// Exceptions / value types
// ---------------------------------------------------------------------------

/// Thrown when the GraphQL endpoint returns 401 (bearer token rejected).
class KayaAuthException implements Exception {
  const KayaAuthException([this.message = 'Kaya bearer token rejected']);
  final String message;
  @override
  String toString() => 'KayaAuthException: $message';
}

/// Immutable auth bundle returned by [KayaApi.login] / [KayaApi.refresh].
class KayaAuth {
  const KayaAuth({
    required this.token,
    required this.refreshToken,
    required this.userId,
  });

  final String token;
  final String refreshToken;
  final String userId;
}

// ---------------------------------------------------------------------------
// API client
// ---------------------------------------------------------------------------

const _kBase = 'https://kaya-beta.kayaclimb.com';

/// Shared headers that mimic the Kaya browser app; the server 403s without
/// the Origin + Referer pair.
const _kBrowserHeaders = {
  'Content-Type': 'application/json',
  'Origin': 'https://kaya-app.kayaclimb.com',
  'Referer': 'https://kaya-app.kayaclimb.com/',
};

class KayaApi {
  KayaApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  // -------------------------------------------------------------------------
  // login
  // -------------------------------------------------------------------------

  /// Authenticate with email/password. Coerces numeric `user.id` to String.
  Future<KayaAuth> login(String email, String password) async {
    final res = await _client.post(
      Uri.parse('$_kBase/api/user/login'),
      headers: _kBrowserHeaders,
      body: jsonEncode({'email': email, 'password': password}),
    );

    if (res.statusCode != 200) {
      throw StateError('Kaya login failed (${res.statusCode})');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final token = json['token'];
    final refreshToken = json['refresh_token'];
    final userId = (json['user'] as Map<String, dynamic>?)?['id'];

    if (token == null || refreshToken == null || userId == null) {
      throw StateError('Kaya login: unexpected response shape');
    }

    return KayaAuth(
      token: token as String,
      refreshToken: refreshToken as String,
      userId: userId.toString(), // API returns a number
    );
  }

  // -------------------------------------------------------------------------
  // refresh-token
  // -------------------------------------------------------------------------

  /// Exchange a refresh token for a new bearer token. Returns only the
  /// new access token (the API does not issue a new refresh token).
  Future<String> refresh(String refreshToken) async {
    final res = await _client.post(
      Uri.parse('$_kBase/api/user/refresh-token'),
      headers: _kBrowserHeaders,
      body: jsonEncode({'refresh_token': refreshToken}),
    );

    if (res.statusCode != 200) {
      throw StateError('Kaya refresh failed (${res.statusCode})');
    }

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final token = json['token'];
    if (token == null) {
      throw StateError('Kaya refresh: unexpected response shape');
    }
    return token as String;
  }

  // -------------------------------------------------------------------------
  // GraphQL pages
  // -------------------------------------------------------------------------

  /// Fetch one page of ascents. [offset] is the 0-based row offset.
  Future<List<Map<String, dynamic>>> ascentsPage({
    required String token,
    required String userId,
    required int offset,
    int count = 100,
  }) =>
      _graphqlPage(
        queryName: 'ascentsForUser',
        query: kAscentsQuery,
        token: token,
        userId: userId,
        offset: offset,
        count: count,
      );

  /// Fetch one page of sessions.
  Future<List<Map<String, dynamic>>> sessionsPage({
    required String token,
    required String userId,
    required int offset,
    int count = 100,
  }) =>
      _graphqlPage(
        queryName: 'sessionsForUser',
        query: kSessionsQuery,
        token: token,
        userId: userId,
        offset: offset,
        count: count,
      );

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Shared GraphQL paging helper.
  ///
  /// - 429: honours `Retry-After` header (fallback: 5 << attempt seconds),
  ///   up to 3 retries total.
  /// - 401: throws [KayaAuthException].
  /// - other non-200: throws [StateError].
  /// - 200 with non-empty `errors` list: throws [StateError] with the first
  ///   error's JSON.
  Future<List<Map<String, dynamic>>> _graphqlPage({
    required String queryName,
    required String query,
    required String token,
    required String userId,
    required int offset,
    required int count,
  }) async {
    final uri = Uri.parse('$_kBase/graphql');
    final body = jsonEncode({
      'query': query,
      'variables': {'user_id': userId, 'offset': offset, 'count': count},
    });
    final headers = {
      ..._kBrowserHeaders,
      'Authorization': 'Bearer $token',
    };

    http.Response res;
    for (var attempt = 0; attempt < 4; attempt++) {
      res = await _client.post(uri, headers: headers, body: body);

      if (res.statusCode == 429) {
        if (attempt >= 3) break; // exhausted retries → fall through
        final retryAfter = _parseRetryAfter(res.headers['retry-after'],
            fallback: 5 << attempt);
        if (retryAfter > Duration.zero) {
          await Future<void>.delayed(retryAfter);
        }
        continue;
      }

      if (res.statusCode == 401) throw const KayaAuthException();

      if (res.statusCode != 200) {
        throw StateError('Kaya GraphQL failed (${res.statusCode})');
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;

      final errors = json['errors'];
      if (errors is List && errors.isNotEmpty) {
        throw StateError('Kaya GraphQL error: ${jsonEncode(errors.first)}');
      }

      final data = json['data'] as Map<String, dynamic>?;
      final rows = data?[queryName];
      if (rows == null) return const [];
      return (rows as List).cast<Map<String, dynamic>>();
    }

    throw StateError('Kaya GraphQL: rate-limited after 3 retries');
  }

  Duration _parseRetryAfter(String? header, {required int fallback}) {
    if (header != null) {
      final secs = int.tryParse(header.trim());
      if (secs != null) return Duration(seconds: secs);
    }
    return Duration(seconds: fallback);
  }
}
