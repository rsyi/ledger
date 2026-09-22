/// Injectable seam between KayaGmailIntegration and Google auth + the
/// Gmail REST API — the HealthConnectGateway pattern: platform-channel
/// (google_sign_in) and network calls live behind [GmailGateway], the
/// thin [GoogleSignInGmailGateway] adapter is the only code that touches
/// the plugin, and everything downstream (message selection, attachment
/// extraction, CSV import) is pure Dart tested with fakes.
///
/// Scope discipline: gmail.readonly ONLY. Nothing in this file (or the
/// integration) can send, modify, or delete mail — the gateway exposes
/// exactly two read endpoints (messages search + attachment download).
library;

import 'dart:convert';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

/// The single OAuth scope this feature ever requests.
const kGmailReadonlyScope = 'https://www.googleapis.com/auth/gmail.readonly';

// ---------------------------------------------------------------- pure

/// Gmail search query for Kaya logbook export emails.
String kayaExportQuery({int newerThanDays = 1}) =>
    'from:kayaclimb.com subject:"KAYA Logbook Export" '
    'newer_than:${newerThanDays}d has:attachment';

/// Message receipt time from Gmail's `internalDate` (epoch millis,
/// serialized as a string in the REST JSON). Null when absent/garbled.
DateTime? gmailInternalDate(Map<String, dynamic> message) {
  final raw = message['internalDate'];
  final ms = raw is int ? raw : int.tryParse('$raw');
  if (ms == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

/// Picks the newest export email STRICTLY newer than [newerThan] (null
/// floor = any). Strictness is the guard against re-importing
/// yesterday's export when the user triggers a guided sync: only an
/// email that arrived after sync-start counts. Messages without a
/// parseable internalDate are ignored.
Map<String, dynamic>? newestExportMessage(
  List<Map<String, dynamic>> messages, {
  DateTime? newerThan,
}) {
  Map<String, dynamic>? best;
  DateTime? bestAt;
  for (final m in messages) {
    final at = gmailInternalDate(m);
    if (at == null) continue;
    if (newerThan != null && !at.isAfter(newerThan)) continue;
    if (bestAt == null || at.isAfter(bestAt)) {
      best = m;
      bestAt = at;
    }
  }
  return best;
}

/// A CSV attachment found in a Gmail message payload: either a body
/// `attachmentId` to fetch via the attachments endpoint, or small
/// attachments' inline base64url `data`.
class GmailCsvAttachment {
  const GmailCsvAttachment({this.attachmentId, this.inlineData, this.filename});
  final String? attachmentId;
  final String? inlineData;
  final String? filename;
}

/// Walks a Gmail `payload` tree (message part: {filename, mimeType,
/// body: {attachmentId | data}, parts: [...]}) and returns the first
/// part that looks like a CSV attachment — filename ending in .csv or
/// mimeType text/csv. Null when the message has no CSV.
GmailCsvAttachment? findCsvAttachment(Map<String, dynamic>? payload) {
  if (payload == null) return null;
  final filename = '${payload['filename'] ?? ''}';
  final mime = '${payload['mimeType'] ?? ''}'.toLowerCase();
  final isCsv =
      filename.toLowerCase().endsWith('.csv') || mime == 'text/csv';
  if (isCsv) {
    final body = payload['body'];
    if (body is Map) {
      final attachmentId = body['attachmentId'];
      final data = body['data'];
      if (attachmentId is String && attachmentId.isNotEmpty) {
        return GmailCsvAttachment(
            attachmentId: attachmentId, filename: filename);
      }
      if (data is String && data.isNotEmpty) {
        return GmailCsvAttachment(inlineData: data, filename: filename);
      }
    }
  }
  final parts = payload['parts'];
  if (parts is List) {
    for (final p in parts) {
      if (p is! Map) continue;
      final found = findCsvAttachment(p.cast<String, dynamic>());
      if (found != null) return found;
    }
  }
  return null;
}

/// Decodes Gmail's base64url body data (RFC 4648 §5: `-`/`_` alphabet,
/// padding frequently stripped) to text.
String decodeGmailBody(String data) {
  return utf8.decode(base64Url.decode(base64Url.normalize(data)));
}

// ------------------------------------------------------------- gateway

/// Minimal Gmail surface the Kaya integration needs. Read-only by
/// construction.
abstract class GmailGateway {
  /// Email of the signed-in Google account, restoring a previous
  /// session silently if possible. Null = not connected.
  Future<String?> signedInEmail();

  /// Interactive Google sign-in requesting gmail.readonly. Returns the
  /// account email. Throws on cancel/config errors.
  Future<String> signIn();

  /// Drops the local session (does not revoke the grant, so reconnect
  /// is one tap).
  Future<void> signOut();

  /// `users.messages.list` with [query], each hit hydrated via
  /// `users.messages.get` (format=full) — returns full message maps
  /// (id, internalDate, payload…). Throws on auth/network errors.
  Future<List<Map<String, dynamic>>> searchMessages(String query,
      {int maxResults = 5});

  /// `users.messages.attachments.get` — returns the base64url `data`.
  Future<String> attachmentData({
    required String messageId,
    required String attachmentId,
  });
}

/// Real adapter: google_sign_in 7.x (Credential Manager era — the
/// singleton `GoogleSignIn.instance` + initialize/authenticate/
/// authorizationClient API) over the Gmail REST endpoints. Requires
/// `serverClientId` = the WEB OAuth client id from the same GCP project
/// that holds the Android OAuth client (package + SHA-1); see the
/// KayaGmail setup hint for the exact console steps.
class GoogleSignInGmailGateway implements GmailGateway {
  GoogleSignInGmailGateway({
    required this.serverClientId,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String serverClientId;
  final http.Client _http;

  static const _base = 'https://gmail.googleapis.com/gmail/v1/users/me';

  /// GoogleSignIn.instance is app-global and must be initialized exactly
  /// once per process.
  static Future<void>? _initialized;
  GoogleSignInAccount? _account;

  Future<void> _ensureInit() {
    return _initialized ??=
        GoogleSignIn.instance.initialize(serverClientId: serverClientId);
  }

  @override
  Future<String?> signedInEmail() async {
    await _ensureInit();
    if (_account == null) {
      final attempt = GoogleSignIn.instance.attemptLightweightAuthentication();
      if (attempt != null) _account = await attempt;
    }
    return _account?.email;
  }

  @override
  Future<String> signIn() async {
    await _ensureInit();
    final account = await GoogleSignIn.instance
        .authenticate(scopeHint: const [kGmailReadonlyScope]);
    // Surface the scope consent immediately at connect time, not on the
    // first sync: authorizationHeaders(promptIfNecessary) shows the
    // incremental-auth sheet if gmail.readonly wasn't granted yet.
    final headers = await account.authorizationClient.authorizationHeaders(
      const [kGmailReadonlyScope],
      promptIfNecessary: true,
    );
    if (headers == null) {
      throw StateError('Gmail read access was not granted');
    }
    _account = account;
    return account.email;
  }

  @override
  Future<void> signOut() async {
    await _ensureInit();
    _account = null;
    await GoogleSignIn.instance.signOut();
  }

  Future<Map<String, String>> _authHeaders() async {
    final email = await signedInEmail();
    if (email == null || _account == null) {
      throw StateError('Not connected to Google — tap Connect first');
    }
    var headers = await _account!.authorizationClient
        .authorizationHeaders(const [kGmailReadonlyScope]);
    // A lapsed cached authorization returns null; re-prompt before
    // giving up. Every pull trigger is foreground (app-start, resume,
    // local write, manual), so the one-tap sheet is acceptable here.
    headers ??= await _account!.authorizationClient.authorizationHeaders(
      const [kGmailReadonlyScope],
      promptIfNecessary: true,
    );
    if (headers == null) {
      throw StateError(
          'Gmail authorization expired — disconnect and reconnect');
    }
    return headers;
  }

  Future<Map<String, dynamic>> _getJson(
      Uri uri, Map<String, String> headers) async {
    final resp = await _http.get(uri, headers: headers);
    if (resp.statusCode != 200) {
      throw StateError('Gmail API ${resp.statusCode}: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  @override
  Future<List<Map<String, dynamic>>> searchMessages(String query,
      {int maxResults = 5}) async {
    final headers = await _authHeaders();
    final list = await _getJson(
      Uri.parse('$_base/messages').replace(queryParameters: {
        'q': query,
        'maxResults': '$maxResults',
      }),
      headers,
    );
    final hits = (list['messages'] as List?) ?? const [];
    final out = <Map<String, dynamic>>[];
    for (final h in hits) {
      if (h is! Map) continue;
      final id = h['id'];
      if (id is! String) continue;
      out.add(await _getJson(
        Uri.parse('$_base/messages/$id').replace(
          queryParameters: {'format': 'full'},
        ),
        headers,
      ));
    }
    return out;
  }

  @override
  Future<String> attachmentData({
    required String messageId,
    required String attachmentId,
  }) async {
    final headers = await _authHeaders();
    final body = await _getJson(
      Uri.parse('$_base/messages/$messageId/attachments/$attachmentId'),
      headers,
    );
    final data = body['data'];
    if (data is! String || data.isEmpty) {
      throw StateError('Gmail attachment $attachmentId came back empty');
    }
    return data;
  }
}
