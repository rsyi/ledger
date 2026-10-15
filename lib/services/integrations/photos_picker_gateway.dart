/// Injectable seam over Google auth + the Photos Picker API — the
/// GmailGateway pattern: platform-channel (google_sign_in) and network
/// calls live behind [PhotosPickerGateway]; the thin
/// [GoogleSignInPhotosPickerGateway] adapter is the only code touching
/// the plugin, and everything downstream (session polling, matching,
/// thumbnail fetch) is pure Dart tested with fakes.
///
/// RESTORED 2026-10-14 for RETROACTIVE LINKING only (photos_link.dart):
/// attach stays offline on the local system picker; this flow lets the
/// user multi-select the already-backed-up clips in Google Photos so
/// rows gain a durable photos.google.com link. It NEVER downloads or
/// uploads a video — the only bytes fetched are small thumbnails
/// (`baseUrl=w200-h200`) for rows that lack a synced one.
///
/// Why the PICKER API: the Photos Library API's third-party media
/// access was shut down 2025-03-31 — the Picker API
/// (photospicker.googleapis.com) is the sanctioned path. Scope
/// discipline: photospicker.mediaitems.readonly ONLY.
///
/// Shape notes (REST reference):
///   - sessions.create → { id, pickerUri, pollingConfig: { pollInterval:
///     "3.5s", timeoutIn: "300s" }, mediaItemsSet, expireTime }
///   - mediaItems.list?sessionId= → { mediaItems: [ PickedMediaItem ],
///     nextPageToken } with PickedMediaItem = { id, createTime, type:
///     PHOTO|VIDEO, mediaFile: { baseUrl, mimeType, filename,
///     mediaFileMetadata: { width, height, videoMetadata: { fps, … } } } }.
///     createTime = when the item was CREATED (captured), not uploaded.
///     There is NO duration and NO productUrl on picked items — we
///     build the deep link from the persistent item id.
///   - baseUrl bytes require the OAuth token in the Authorization
///     header and expire ~60 minutes after the pick.
library;

import 'dart:convert';
import 'dart:io' show SocketException;
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

/// One picked media item, reduced to what linking needs.
class PickedMediaItem {
  const PickedMediaItem({
    required this.id,
    required this.isVideo,
    this.createTime,
    this.baseUrl,
    this.mimeType,
    this.filename,
  });

  /// Persistent media-item id (stable across sessions).
  final String id;
  final bool isVideo;

  /// Capture time, UTC (null when absent/garbled).
  final DateTime? createTime;

  /// Short-lived (~60 min) byte base; thumbnails only here.
  final String? baseUrl;
  final String? mimeType;
  final String? filename;

  static PickedMediaItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final id = m['id'];
    if (id is! String || id.isEmpty) return null;
    final file = m['mediaFile'];
    final mime = file is Map ? file['mimeType'] as String? : null;
    final type = '${m['type'] ?? ''}'.toUpperCase();
    final ct = DateTime.tryParse('${m['createTime'] ?? ''}');
    final base = file is Map ? file['baseUrl'] : null;
    return PickedMediaItem(
      id: id,
      isVideo: type == 'VIDEO' || (mime?.startsWith('video/') ?? false),
      createTime: ct?.toUtc(),
      baseUrl: base is String && base.isNotEmpty ? base : null,
      mimeType: mime,
      filename: file is Map ? file['filename'] as String? : null,
    );
  }
}

/// Every parseable item of a mediaItems.list response (photos included —
/// the matcher drops non-videos).
List<PickedMediaItem> parsePickedItems(List<dynamic> mediaItems) => [
      for (final raw in mediaItems) ?PickedMediaItem.fromJson(raw),
    ];

/// Thumbnail URL for a picked item: `baseUrl=w<px>-h<px>` (for a VIDEO
/// this returns a still image, never the video bytes). Valid ~60 min.
String thumbnailUrl(String baseUrl, {int px = 200}) => '$baseUrl=w$px-h$px';

/// The persistent item id inside a constructed Photos deep link
/// (inverse of [photosProductUrl]); null for any other URL.
String? photosItemIdOf(String? url) {
  final u = Uri.tryParse(url?.trim() ?? '');
  if (u == null || u.host != 'photos.google.com') return null;
  final segs = u.pathSegments;
  final i = segs.indexOf('photo');
  if (i < 0 || i + 1 >= segs.length || segs[i + 1].isEmpty) return null;
  return segs[i + 1];
}

/// pickerUri with Google's `/autoclose` suffix so the Photos picker
/// closes itself once the user taps Done (back to the app).
String autoclosePickerUri(String pickerUri) {
  final s = pickerUri.trim();
  if (s.isEmpty || s.endsWith('/autoclose')) return s;
  return s.endsWith('/') ? '${s}autoclose' : '$s/autoclose';
}

/// Google Photos deep link for a media item. The Picker API does NOT
/// return the Library API's productUrl, but the picked item id is "a
/// persistent identifier that can be used between sessions" and the
/// Library productUrl shape is `photos.google.com/lr/photo/<id>` — we
/// construct that link so the sheet cell opens the video for the
/// owning account.
String photosProductUrl(String mediaId) =>
    'https://photos.google.com/lr/photo/$mediaId';

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

  /// GET [url] with the OAuth Authorization header (baseUrl fetches
  /// require it). Used ONLY for thumbnail URLs ([thumbnailUrl]) — this
  /// feature never downloads video bytes. Throws on non-200.
  Future<Uint8List> download(String url);
}

/// Real adapter: google_sign_in 7.x over the Photos Picker REST API.
/// Reuses the app's web OAuth client id (AppConfig.googleServerClientId:
/// `google.server_client_id`, else `integrations.kaya_gmail.
/// server_client_id`) — same GCP project + consent screen; only the
/// scope differs.
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

  /// Retries transient network failures (DNS "Failed host lookup",
  /// dropped connections, timeouts — common on mobile during a wifi/LTE
  /// handoff) a few times with short backoff. HTTP 4xx/5xx are NOT
  /// transient and surface immediately. A persistent network failure is
  /// rewrapped with a plain-language message.
  // 6 tries with growing backoff ≈ 10.5 s total. Generous on purpose:
  // the picker backgrounds the app while the user browses Photos, and on
  // return Android often drops DNS/socket state — the first call(s) fail
  // to resolve until the network warms back up (the "worked when I was
  // faster" symptom). We wait it out rather than give up.
  Future<T> _retry<T>(Future<T> Function() op, {int tries = 6}) async {
    var attempt = 0;
    while (true) {
      try {
        return await op();
      } catch (e) {
        attempt++;
        final s = e.toString();
        final transient = e is SocketException ||
            e is http.ClientException ||
            s.contains('Failed host lookup') ||
            s.contains('Connection') ||
            s.contains('timed out');
        if (!transient) rethrow;
        if (attempt >= tries) {
          throw StateError(
            "Couldn't reach Google Photos (network hiccup — the server "
            "didn't resolve). Check your connection and try again.",
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
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
    return _json(await _retry(() => _http.post(
          Uri.parse('$_base/sessions'),
          headers: {...headers, 'Content-Type': 'application/json'},
          body: '{}',
        )));
  }

  @override
  Future<Map<String, dynamic>> getSession(String sessionId) async {
    final headers = await _authHeaders();
    return _json(await _retry(() =>
        _http.get(Uri.parse('$_base/sessions/$sessionId'), headers: headers)));
  }

  @override
  Future<List<dynamic>> listMediaItems(String sessionId) async {
    final headers = await _authHeaders();
    final out = <dynamic>[];
    String? pageToken;
    do {
      final body = _json(await _retry(() => _http.get(
            Uri.parse('$_base/mediaItems').replace(queryParameters: {
              'sessionId': sessionId,
              'pageSize': '100',
              'pageToken': ?pageToken,
            }),
            headers: headers,
          )));
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
    final resp = await _retry(() => _http.get(Uri.parse(url), headers: headers));
    if (resp.statusCode != 200) {
      throw StateError(
          'Thumbnail fetch failed (${resp.statusCode}) — the picker link '
          'may have expired (~60 min).');
    }
    return resp.bodyBytes;
  }
}
