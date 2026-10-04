/// GitHub sign-in for users WITHOUT baked config (multi-user sub-project 1).
///
/// Two paths, both ending in a bearer token kept in secure storage:
///   * OAuth DEVICE FLOW ([GithubDeviceFlow]) — needs only a public
///     client id (assets config `github.oauth_client_id`); no client
///     secret ever ships. The user enters a short code at
///     github.com/login/device.
///   * Fine-grained PAT paste — the fallback when no client id is baked.
///
/// [GithubAccountApi] then lists the user's repos/branches and validates a
/// chosen repo/branch/root looks like a Ledger config (views/ +
/// coach/program.yaml).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class GithubAuthException implements Exception {
  /// GitHub's error code (`expired_token`, `access_denied`, …) or a local
  /// one (`http_<status>`, `bad_response`, `cancelled`).
  final String code;
  final String message;
  const GithubAuthException(this.code, this.message);

  @override
  String toString() => message;
}

/// The device-flow code the user types at [verificationUri].
class GithubDeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final Duration expiresIn;
  final Duration interval;

  const GithubDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });
}

/// RFC 8628 device authorization against github.com.
class GithubDeviceFlow {
  final String clientId;

  /// OAuth-App scope. `repo` is the narrowest OAuth-App scope that can
  /// read AND write a PRIVATE repo's contents (GitHub has no per-repo
  /// OAuth-App scope). Ignored when [clientId] belongs to a GitHub App,
  /// whose per-repo installation permissions apply instead.
  final String scope;
  final http.Client _http;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  GithubDeviceFlow({
    required this.clientId,
    this.scope = 'repo',
    http.Client? httpClient,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  })  : _http = httpClient ?? http.Client(),
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _now = now ?? DateTime.now;

  static const _headers = {
    'Accept': 'application/json',
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  Future<Map<String, dynamic>> _post(String url, Map<String, String> body) async {
    final resp = await _http
        .post(Uri.parse(url), headers: _headers, body: body)
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw GithubAuthException(
          'http_${resp.statusCode}', 'GitHub sign-in failed (${resp.statusCode})');
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
    } catch (_) {
      throw const GithubAuthException(
          'bad_response', 'GitHub sign-in returned an unexpected response');
    }
  }

  /// Step 1: request a device + user code.
  Future<GithubDeviceCode> start() async {
    final m = await _post('https://github.com/login/device/code',
        {'client_id': clientId, 'scope': scope});
    if (m['error'] != null) {
      throw GithubAuthException(m['error'].toString(),
          (m['error_description'] ?? m['error']).toString());
    }
    final device = m['device_code'], user = m['user_code'];
    if (device is! String || user is! String) {
      throw const GithubAuthException(
          'bad_response', 'GitHub sign-in returned no device code');
    }
    return GithubDeviceCode(
      deviceCode: device,
      userCode: user,
      verificationUri:
          (m['verification_uri'] as String?) ?? 'https://github.com/login/device',
      expiresIn: Duration(seconds: (m['expires_in'] as num?)?.toInt() ?? 900),
      interval: Duration(seconds: (m['interval'] as num?)?.toInt() ?? 5),
    );
  }

  /// Step 2: poll until the user approves (→ access token), denies, or the
  /// code expires. Honors `slow_down` (+5 s). [cancelled] is checked
  /// before every poll.
  Future<String> poll(GithubDeviceCode code, {bool Function()? cancelled}) async {
    var interval = code.interval;
    final deadline = _now().add(code.expiresIn);
    while (true) {
      if (cancelled?.call() ?? false) {
        throw const GithubAuthException('cancelled', 'Sign-in cancelled');
      }
      if (_now().isAfter(deadline)) {
        throw const GithubAuthException(
            'expired_token', 'The code expired — start again');
      }
      await _sleep(interval);
      if (cancelled?.call() ?? false) {
        throw const GithubAuthException('cancelled', 'Sign-in cancelled');
      }
      final m = await _post('https://github.com/login/oauth/access_token', {
        'client_id': clientId,
        'device_code': code.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      final token = m['access_token'];
      if (token is String && token.isNotEmpty) return token;
      switch (m['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          final next = (m['interval'] as num?)?.toInt();
          interval = next != null
              ? Duration(seconds: next)
              : interval + const Duration(seconds: 5);
          continue;
        case 'expired_token':
          throw const GithubAuthException(
              'expired_token', 'The code expired — start again');
        case 'access_denied':
          throw const GithubAuthException(
              'access_denied', 'Access was denied on GitHub');
        default:
          throw GithubAuthException((m['error'] ?? 'bad_response').toString(),
              (m['error_description'] ?? 'GitHub sign-in failed').toString());
      }
    }
  }
}

class GithubRepoSummary {
  final String owner;
  final String name;
  final String defaultBranch;
  final bool isPrivate;

  const GithubRepoSummary({
    required this.owner,
    required this.name,
    required this.defaultBranch,
    this.isPrivate = false,
  });

  String get fullName => '$owner/$name';
}

/// Outcome of [GithubAccountApi.validate].
class ConfigRepoCheck {
  /// `<root>/views` exists and holds at least one `.yml`.
  final bool hasViews;

  /// `<root>/coach/program.yaml` exists.
  final bool hasProgram;

  /// Set when the check itself failed (no access, network).
  final String? error;

  const ConfigRepoCheck(
      {required this.hasViews, required this.hasProgram, this.error});

  bool get ok => error == null && hasViews && hasProgram;

  /// Plain-language problem line (null when [ok]).
  String? get problem {
    if (error != null) return error;
    if (!hasViews && !hasProgram) {
      return 'No views/ folder or coach/program.yaml here — this does not '
          'look like a Ledger config.';
    }
    if (!hasViews) return 'No views/*.yml found — the app needs its trackers.';
    if (!hasProgram) {
      return 'No coach/program.yaml — the program, plan and goals stay '
          'empty until one exists.';
    }
    return null;
  }
}

/// The signed-in user's view of GitHub (any token: device-flow or PAT).
class GithubAccountApi {
  final String token;
  final http.Client _http;

  GithubAccountApi(this.token, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Future<http.Response> _get(String path) => _http
      .get(Uri.parse('https://api.github.com$path'), headers: _headers)
      .timeout(const Duration(seconds: 30));

  /// The token's login. Throws [GithubAuthException] on a bad token.
  Future<String> login() async {
    final r = await _get('/user');
    if (r.statusCode == 401) {
      throw const GithubAuthException(
          'bad_token', 'GitHub rejected the token (expired or revoked?)');
    }
    if (r.statusCode != 200) {
      throw GithubAuthException(
          'http_${r.statusCode}', 'GitHub /user failed (${r.statusCode})');
    }
    final m = jsonDecode(r.body) as Map;
    return m['login'] as String;
  }

  /// Repos the token can see, most recently updated first (≤ [maxPages]
  /// pages of 100).
  Future<List<GithubRepoSummary>> repos({int maxPages = 3}) async {
    final out = <GithubRepoSummary>[];
    for (var page = 1; page <= maxPages; page++) {
      final r = await _get('/user/repos?per_page=100&sort=updated&page=$page');
      if (r.statusCode != 200) {
        throw GithubAuthException(
            'http_${r.statusCode}', 'Listing repos failed (${r.statusCode})');
      }
      final list = jsonDecode(r.body) as List;
      for (final e in list) {
        final m = e as Map;
        out.add(GithubRepoSummary(
          owner: (m['owner'] as Map)['login'] as String,
          name: m['name'] as String,
          defaultBranch: (m['default_branch'] as String?) ?? 'main',
          isPrivate: (m['private'] as bool?) ?? false,
        ));
      }
      if (list.length < 100) break;
    }
    return out;
  }

  Future<List<String>> branches(String owner, String repo) async {
    final r = await _get('/repos/$owner/$repo/branches?per_page=100');
    if (r.statusCode != 200) {
      throw GithubAuthException(
          'http_${r.statusCode}', 'Listing branches failed (${r.statusCode})');
    }
    return [
      for (final e in jsonDecode(r.body) as List) (e as Map)['name'] as String,
    ];
  }

  /// Checks [owner]/[repo]@[branch] under [root] for `views/*.yml` and
  /// `coach/program.yaml`. Never throws.
  Future<ConfigRepoCheck> validate(
      String owner, String repo, String branch, String root) async {
    final base = root.isEmpty ? '' : '$root/';
    String contents(String p) => '/repos/$owner/$repo/contents/$base$p'
        '?ref=${Uri.encodeQueryComponent(branch)}';
    try {
      final v = await _get(contents('views'));
      var hasViews = false;
      if (v.statusCode == 200) {
        final body = jsonDecode(v.body);
        hasViews = body is List &&
            body.any((e) =>
                e is Map &&
                e['type'] == 'file' &&
                (e['name'] as String).endsWith('.yml'));
      } else if (v.statusCode != 404) {
        return ConfigRepoCheck(
            hasViews: false,
            hasProgram: false,
            error: 'Could not read the repo (${v.statusCode}) — check the '
                "token's access to $owner/$repo.");
      }
      final p = await _get(contents('coach/program.yaml'));
      if (p.statusCode != 200 && p.statusCode != 404) {
        return ConfigRepoCheck(
            hasViews: hasViews,
            hasProgram: false,
            error: 'Could not read coach/program.yaml (${p.statusCode}).');
      }
      return ConfigRepoCheck(hasViews: hasViews, hasProgram: p.statusCode == 200);
    } catch (e) {
      return ConfigRepoCheck(
          hasViews: false, hasProgram: false, error: 'Network error: $e');
    }
  }
}
