/// Injectable seam over Google auth + the Photos Picker API — the
/// GmailGateway pattern: platform-channel (google_sign_in) and network
/// calls live behind [PhotosPickerGateway], the thin
/// [GoogleSignInPhotosPickerGateway] adapter is the only code touching
/// the plugin, and everything downstream (session polling, item
/// selection, byte download) is pure Dart tested with fakes.
///
/// Why the PICKER API: the Photos Library API's third-party media
/// access was shut down 2025-03-31 — the Picker API
/// (photospicker.googleapis.com) is the sanctioned path. The user picks
/// items in the Google Photos app/web UI; the app only ever sees what
/// was explicitly picked. Scope discipline:
/// photospicker.mediaitems.readonly ONLY.
///
/// Shape notes (verified against the REST reference 2026-09-28):
///   - sessions.create → { id, pickerUri, pollingConfig: { pollInterval:
///     "3.5s", timeoutIn: "300s" }, mediaItemsSet, expireTime }
///   - mediaItems.list?sessionId= → { mediaItems: [ PickedMediaItem ] }
///     with PickedMediaItem = { id, createTime, type: PHOTO|VIDEO,
///     mediaFile: { baseUrl, mimeType, filename, mediaFileMetadata } }.
///     There is NO productUrl on picked items (Library-API-only field) —
///     we build the deep link from the persistent item id instead.
///   - baseUrl bytes require the OAuth token in the Authorization
///     header and expire ~60 minutes after the pick — download
///     immediately at attach time.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'google_signin_bootstrap.dart';

/// The single OAuth scope this feature ever requests.
const kPhotosPickerScope =
    'https://www.googleapis.com/auth/photospicker.mediaitems.readonly';

// ---------------------------------------------------------------- pure

/// Parses Google's protobuf-JSON Duration string ("3.5s", "300s").
/// Null/garbled → null (callers fall back to a default).
Duration? parseGoogleDuration(Object? raw) {
  if (raw is! String || !raw.endsWith('s')) return null;
  final secs = double.tryParse(raw.substring(0, raw.length - 1));
  if (secs == null || secs < 0) return null;
  return Duration(milliseconds: (secs * 1000).round());
}

/// Parsed picker session (subset the flow needs).
class PickerSession {
  const PickerSession({
    required this.id,
    required this.pickerUri,
    required this.mediaItemsSet,
    this.pollInterval,
    this.timeoutIn,
  });

  final String id;
  final String pickerUri;
  final bool mediaItemsSet;
  final Duration? pollInterval;
  final Duration? timeoutIn;

  static PickerSession fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw StateError('Picker session response has no id: $json');
    }
    final polling = json['pollingConfig'];
    return PickerSession(
      id: id,
      pickerUri: '${json['pickerUri'] ?? ''}',
      mediaItemsSet: json['mediaItemsSet'] == true,
      pollInterval: polling is Map
          ? parseGoogleDuration(polling['pollInterval'])
          : null,
      timeoutIn:
          polling is Map ? parseGoogleDuration(polling['timeoutIn']) : null,
    );
  }
}

/// One picked video, reduced to what the attach flow stores/uses.
class PickedVideo {
  const PickedVideo({
    required this.mediaId,
    required this.baseUrl,
    this.mimeType,
    this.filename,
  });

  final String mediaId;
  final String baseUrl;
  final String? mimeType;
  final String? filename;
}

/// Extracts the first VIDEO item from a mediaItems.list response list.
/// Null when the user picked no video (e.g. only photos).
PickedVideo? firstVideoItem(List<dynamic> mediaItems) {
  for (final item in mediaItems) {
    if (item is! Map) continue;
    final m = item.cast<String, dynamic>();
    if ('${m['type']}'.toUpperCase() != 'VIDEO') continue;
    final file = m['mediaFile'];
    final id = m['id'];
    if (file is! Map || id is! String || id.isEmpty) continue;
    final baseUrl = file['baseUrl'];
    if (baseUrl is! String || baseUrl.isEmpty) continue;
    return PickedVideo(
      mediaId: id,
      baseUrl: baseUrl,
      mimeType: file['mimeType'] as String?,
      filename: file['filename'] as String?,
    );
  }
  return null;
}

/// Google Photos deep link for a media item. The Picker API does NOT
/// return the Library API's productUrl, but the picked item id is "a
/// persistent identifier that can be used between sessions" and the
/// Library productUrl shape is `photos.google.com/lr/photo/<id>` — we
/// construct that link so the sheet cell opens the video for the
/// owning account.
String photosProductUrl(String mediaId) =>
    'https://photos.google.com/lr/photo/$mediaId';

/// Download URL for the full video bytes: baseUrl + the `=dv` param.
/// Valid ~60 minutes post-pick; requires the OAuth Authorization header.
String videoDownloadUrl(String baseUrl) => '$baseUrl=dv';

// ------------------------------------------------------------- gateway

/// Minimal Photos Picker surface the attach flow needs. Read-only by
/// construction (sessions are the picker's own bookkeeping objects).
abstract class PhotosPickerGateway {
  /// Email of the signed-in Google account (silent restore). Null = not
  /// connected.
  Future<String?> signedInEmail();

  /// Interactive sign-in requesting the picker scope. Returns the
  /// account email. Throws on cancel / config errors / scope denial.
  Future<String> signIn();

  /// sessions.create → session JSON.
  Future<Map<String, dynamic>> createSession();

  /// sessions.get → session JSON.
  Future<Map<String, dynamic>> getSession(String sessionId);

  /// mediaItems.list for [sessionId] → the raw item maps.
  Future<List<dynamic>> listMediaItems(String sessionId);

  /// sessions.delete — best-effort cleanup after the flow finishes.
  Future<void> deleteSession(String sessionId);

  /// GET [url] with the OAuth Authorization header (baseUrl downloads
  /// require it). Throws on non-200.
  Future<Uint8List> download(String url);
}

/// Real adapter: google_sign_in 7.x over the Photos Picker REST API.
/// Reuses the app's existing web OAuth client id
/// (`integrations.kaya_gmail.server_client_id`) — same GCP project,
/// same consent screen; only the scope is new.
class GoogleSignInPhotosPickerGateway implements PhotosPickerGateway {
  GoogleSignInPhotosPickerGateway({
    required this.serverClientId,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String serverClientId;
  final http.Client _http;

  static const _base = 'https://photospicker.googleapis.com/v1';

  GoogleSignInAccount? _account;

  Future<void> _ensureInit() => ensureGoogleSignInInit(serverClientId);

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
        .authenticate(scopeHint: const [kPhotosPickerScope]);
    final headers = await account.authorizationClient.authorizationHeaders(
      const [kPhotosPickerScope],
      promptIfNecessary: true,
    );
    if (headers == null) {
      throw StateError('Google Photos access was not granted');
    }
    _account = account;
    return account.email;
  }

  Future<Map<String, String>> _authHeaders() async {
    final email = await signedInEmail();
    if (email == null || _account == null) {
      // Not signed in yet — run the interactive flow inline; attach is
      // always a foreground user gesture.
      await signIn();
    }
    var headers = await _account!.authorizationClient
        .authorizationHeaders(const [kPhotosPickerScope]);
    headers ??= await _account!.authorizationClient.authorizationHeaders(
      const [kPhotosPickerScope],
      promptIfNecessary: true,
    );
    if (headers == null) {
      throw StateError('Google Photos authorization expired — try again');
    }
    return headers;
  }

  Map<String, dynamic> _json(http.Response resp) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('Photos Picker API ${resp.statusCode}: ${resp.body}');
    }
    final body = resp.body.isEmpty ? '{}' : resp.body;
    return jsonDecode(body) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> createSession() async {
    final headers = await _authHeaders();
    return _json(await _http.post(
      Uri.parse('$_base/sessions'),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: '{}',
    ));
  }

  @override
  Future<Map<String, dynamic>> getSession(String sessionId) async {
    final headers = await _authHeaders();
    return _json(
        await _http.get(Uri.parse('$_base/sessions/$sessionId'), headers: headers));
  }

  @override
  Future<List<dynamic>> listMediaItems(String sessionId) async {
    final headers = await _authHeaders();
    final out = <dynamic>[];
    String? pageToken;
    do {
      final body = _json(await _http.get(
        Uri.parse('$_base/mediaItems').replace(queryParameters: {
          'sessionId': sessionId,
          'pageSize': '100',
          'pageToken': ?pageToken,
        }),
        headers: headers,
      ));
      out.addAll((body['mediaItems'] as List?) ?? const []);
      pageToken = body['nextPageToken'] as String?;
    } while (pageToken != null && pageToken.isNotEmpty);
    return out;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    final headers = await _authHeaders();
    await _http.delete(Uri.parse('$_base/sessions/$sessionId'),
        headers: headers);
  }

  @override
  Future<Uint8List> download(String url) async {
    final headers = await _authHeaders();
    final resp = await _http.get(Uri.parse(url), headers: headers);
    if (resp.statusCode != 200) {
      throw StateError(
          'Video download failed (${resp.statusCode}) — the picker link '
          'may have expired (~60 min); re-attach the video.');
    }
    return resp.bodyBytes;
  }
}
