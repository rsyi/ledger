/// The user's Google identity for DATA (multi-user sub-project 2): Google
/// sign-in (google_sign_in 7.x, the app-global singleton shared with the
/// Kaya Gmail import — same web client id) requesting the Sheets +
/// drive.file scopes, and the [AccessTokenSource] every non-owner Sheets
/// path authenticates through.
///
/// Token refresh: google_sign_in's authorization client (Play Services
/// AuthorizationClient on Android) returns a valid token for already-
/// granted scopes WITHOUT UI; we cache it ~45 min (tokens live 60) and
/// re-authorize after that or after a 401 ([invalidate] also clears the
/// platform cache via clearAuthorizationToken).
library;

import 'package:google_sign_in/google_sign_in.dart';

import '../integrations/google_signin_bootstrap.dart';
import 'sheets_auth.dart';

const kSheetsScope = 'https://www.googleapis.com/auth/spreadsheets';
const kDriveFileScope = 'https://www.googleapis.com/auth/drive.file';

/// The data scopes requested at sign-in: read/write the user's sheets +
/// create files (the "Ledger" workbook) in their Drive.
const kDataScopes = [kSheetsScope, kDriveFileScope];

/// Seam between the app and Google sign-in (fakes in tests).
abstract class GoogleAccountGateway implements AccessTokenSource {
  /// Signed-in email, restoring a previous session silently if possible.
  /// Null = not signed in.
  Future<String?> signedInEmail();

  /// Interactive sign-in + consent for [kDataScopes]. Returns the email;
  /// throws on cancel / config errors.
  Future<String> signIn();

  /// Drops the local session (the grant stays — re-sign-in is one tap).
  Future<void> signOut();
}

class GoogleSignInIdentity implements GoogleAccountGateway {
  GoogleSignInIdentity({required this.serverClientId});

  /// The WEB OAuth client id (google_sign_in 7.x on Android requires it;
  /// Play Services finds the Android client by package + SHA-1).
  final String serverClientId;

  static const _tokenTtl = Duration(minutes: 45);

  GoogleSignInAccount? _account;
  String? _token;
  DateTime? _tokenAt;

  bool get isConfigured =>
      serverClientId.isNotEmpty && serverClientId != 'SET_ME';

  Future<void> _ensureInit() => ensureGoogleSignInInit(serverClientId);

  @override
  Future<String?> signedInEmail() async {
    if (!isConfigured) return null;
    try {
      await _ensureInit();
      if (_account == null) {
        final attempt = GoogleSignIn.instance
            .attemptLightweightAuthentication();
        if (attempt != null) _account = await attempt;
      }
    } catch (_) {
      /* no restorable session → not signed in */
    }
    return _account?.email;
  }

  @override
  Future<String> signIn() async {
    if (!isConfigured) {
      throw StateError(
        'Google sign-in is not configured for this build (no web client id)',
      );
    }
    await _ensureInit();
    final account = await GoogleSignIn.instance.authenticate(
      scopeHint: kDataScopes,
    );
    // Consent for the data scopes NOW (not on the first sync).
    final authz = await account.authorizationClient.authorizeScopes(
      kDataScopes,
    );
    _account = account;
    _token = authz.accessToken;
    _tokenAt = DateTime.now();
    return account.email;
  }

  @override
  Future<void> signOut() async {
    _account = null;
    _token = null;
    _tokenAt = null;
    if (!isConfigured) return;
    await _ensureInit();
    await GoogleSignIn.instance.signOut();
  }

  @override
  Future<String?> accessToken() async {
    final at = _tokenAt;
    if (_token != null &&
        at != null &&
        DateTime.now().difference(at) < _tokenTtl) {
      return _token;
    }
    if (await signedInEmail() == null) return null;
    try {
      final authz = await _account!.authorizationClient.authorizationForScopes(
        kDataScopes,
      );
      if (authz == null) return null; // grant lapsed → re-sign-in
      _token = authz.accessToken;
      _tokenAt = DateTime.now();
      return _token;
    } catch (_) {
      return null; // surfaces as "sign in with Google" on the caller
    }
  }

  @override
  Future<void> invalidate(String token) async {
    if (_token == token) {
      _token = null;
      _tokenAt = null;
    }
    try {
      await _account?.authorizationClient.clearAuthorizationToken(
        accessToken: token,
      );
    } catch (_) {
      /* best-effort: the cache drop above still forces refetch */
    }
  }
}
