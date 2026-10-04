/// Auth-client provider for every direct Sheets path (multi-user
/// sub-project 2).
///
/// Two modes, chosen once at bootstrap by [selectSheetsAuth]:
///  - [ServiceAccountSheetsAuth] — the owner build: the baked
///    `assets/service-account.json` (unchanged behavior);
///  - [TokenSheetsAuth] — everyone else: a Google-sign-in OAuth access
///    token ([AccessTokenSource], real impl = GoogleIdentity) sent as
///    `Authorization: Bearer …` by [BearerClient], which refreshes +
///    replays once on a 401.
///
/// The engine ledger (Rust) has its own bearer mode; the app pushes the
/// token into it before each sync via [syncWithTokenRefresh].
library;

import 'dart:convert';

import 'package:airledger_engine/airledger_engine.dart'
    show kUnauthorizedMarker;
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

/// Supplies OAuth access tokens without UI (a lapsed grant → null; the
/// user re-signs-in from Settings).
abstract class AccessTokenSource {
  /// A currently-valid token (cached or freshly authorized), or null
  /// when not signed in / not authorized.
  Future<String?> accessToken();

  /// Drop [token] from every cache (it was rejected with a 401); the
  /// next [accessToken] fetches a fresh one.
  Future<void> invalidate(String token);
}

/// Thrown when a Sheets call needs Google sign-in that hasn't happened.
class SheetsAuthRequired implements Exception {
  const SheetsAuthRequired([this.message = 'Sign in with Google first']);
  final String message;
  @override
  String toString() => 'SheetsAuthRequired: $message';
}

/// Authenticated-client factory for direct Sheets API calls.
abstract class SheetsAuth {
  /// A client that authenticates every request. Caller closes it.
  /// [readOnly] narrows the service-account scope (token mode: the
  /// token's granted scopes apply as-is).
  Future<http.Client> client({bool readOnly = false});

  /// True for the baked service-account (owner) mode.
  bool get isServiceAccount;

  /// Convenience: run [fn] with a SheetsApi over a fresh client, closing
  /// it afterwards.
  Future<T> withApi<T>(
    Future<T> Function(sheets.SheetsApi api) fn, {
    bool readOnly = false,
  }) async {
    final c = await client(readOnly: readOnly);
    try {
      return await fn(sheets.SheetsApi(c));
    } finally {
      c.close();
    }
  }
}

class ServiceAccountSheetsAuth extends SheetsAuth {
  ServiceAccountSheetsAuth(this.keyJson);
  final String keyJson;

  @override
  bool get isServiceAccount => true;

  @override
  Future<http.Client> client({bool readOnly = false}) =>
      clientViaServiceAccount(ServiceAccountCredentials.fromJson(keyJson), [
        readOnly
            ? sheets.SheetsApi.spreadsheetsReadonlyScope
            : sheets.SheetsApi.spreadsheetsScope,
      ]);
}

class TokenSheetsAuth extends SheetsAuth {
  TokenSheetsAuth(this.tokens, {this.innerFactory});
  final AccessTokenSource tokens;

  /// Test seam: the transport under the bearer layer.
  final http.Client Function()? innerFactory;

  @override
  bool get isServiceAccount => false;

  @override
  Future<http.Client> client({bool readOnly = false}) async =>
      BearerClient(tokens, inner: innerFactory?.call());
}

/// True when [raw] is a usable service-account key (JSON object with
/// `client_email` + `private_key`). Non-owner builds ship `{}` / empty.
bool hasServiceAccountKey(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return false;
    final email = j['client_email'], key = j['private_key'];
    return email is String &&
        email.isNotEmpty &&
        key is String &&
        key.contains('PRIVATE KEY');
  } catch (_) {
    return false;
  }
}

/// Mode selection: a baked key wins (owner build — unchanged); otherwise
/// the user's Google identity.
SheetsAuth selectSheetsAuth({
  required String bakedKeyJson,
  required AccessTokenSource google,
}) => hasServiceAccountKey(bakedKeyJson)
    ? ServiceAccountSheetsAuth(bakedKeyJson)
    : TokenSheetsAuth(google);

/// `Authorization: Bearer <token>` on every request. A 401 invalidates
/// the token and replays the request ONCE with a fresh one (the body is
/// buffered so POST/PUT replays are faithful). No token at all →
/// [SheetsAuthRequired] before any network.
class BearerClient extends http.BaseClient {
  BearerClient(this.tokens, {http.Client? inner})
    : _inner = inner ?? http.Client();

  final AccessTokenSource tokens;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = await tokens.accessToken();
    if (token == null || token.isEmpty) throw const SheetsAuthRequired();
    final body = await request.finalize().toBytes();
    final first = await _inner.send(_copy(request, body, token));
    if (first.statusCode != 401) return first;
    await tokens.invalidate(token);
    final fresh = await tokens.accessToken();
    if (fresh == null || fresh.isEmpty || fresh == token) return first;
    await first.stream.drain<void>();
    return _inner.send(_copy(request, body, fresh));
  }

  http.Request _copy(http.BaseRequest r, List<int> body, String token) {
    final c = http.Request(r.method, r.url)
      ..headers.addAll(r.headers)
      ..headers['Authorization'] = 'Bearer $token'
      ..followRedirects = r.followRedirects
      ..maxRedirects = r.maxRedirects
      ..persistentConnection = r.persistentConnection;
    if (body.isNotEmpty) c.bodyBytes = body;
    return c;
  }

  @override
  void close() => _inner.close();
}

/// Engine-ledger sync in bearer mode: push the current token, sync; if
/// any view reports [kUnauthorizedMarker], invalidate, push a fresh
/// token and sync ONCE more (dirty rows survive the failed round, so a
/// re-sync is idempotent). Not signed in → pushes '' and returns the
/// engine's unauthorized results as-is.
Future<List<Map<String, dynamic>>> syncWithTokenRefresh({
  required AccessTokenSource tokens,
  required void Function(String token) setToken,
  required Future<List<Map<String, dynamic>>> Function() runSync,
}) async {
  final token = await tokens.accessToken() ?? '';
  setToken(token);
  final res = await runSync();
  final unauthorized = res.any(
    (r) => '${r['error'] ?? ''}'.contains(kUnauthorizedMarker),
  );
  if (!unauthorized || token.isEmpty) return res;
  await tokens.invalidate(token);
  final fresh = await tokens.accessToken();
  if (fresh == null || fresh.isEmpty || fresh == token) return res;
  setToken(fresh);
  return runSync();
}
