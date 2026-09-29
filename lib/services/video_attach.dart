/// Photos Picker attach flow for `widget: video` fields.
///
/// Orchestration only — every network/platform touch goes through the
/// injectable [PhotosPickerGateway] + [launchPicker] seams so the whole
/// flow is testable with fakes:
///
///   attach tap → sessions.create → launch pickerUri (Photos app/web)
///   → poll sessions.get until mediaItemsSet (interval/timeout from the
///   session's pollingConfig, capped) → mediaItems.list → first VIDEO
///   → best-effort sessions.delete → [VideoAttachResult].
///
/// The stored URL is the constructed Photos deep link (the Picker API
/// has no productUrl — see photos_picker_gateway.dart); the media id
/// rides along for re-fetch. The baseUrl is only valid ~60 min, so the
/// RPE estimator downloads bytes immediately after attach.
library;

import 'dart:async';

import 'package:android_intent_plus/android_intent.dart';

import 'integrations/photos_picker_gateway.dart';

/// Card/snackbar hint when the picker scope/API isn't set up yet.
const kVideoAttachSetupHint =
    'Google Photos picker needs one-time setup — GCP console '
    '(ryi-data-entry): enable the "Google Photos Picker API", add the '
    'photospicker.mediaitems.readonly scope to the OAuth consent screen, '
    'and retry. Uses the same OAuth clients as the Kaya Gmail import '
    '(integrations.kaya_gmail.server_client_id).';

/// User closed the picker / never picked — not an error.
class VideoAttachCancelled implements Exception {
  const VideoAttachCancelled();
  @override
  String toString() => 'Video attach cancelled';
}

class VideoAttachResult {
  const VideoAttachResult({
    required this.mediaId,
    required this.url,
    required this.baseUrl,
    this.mimeType,
    this.filename,
  });

  /// Persistent picker media-item id (→ `video_media_id`).
  final String mediaId;

  /// Google Photos deep link (→ `video_url`).
  final String url;

  /// Short-lived download base (append `=dv` for bytes; ~60 min).
  final String baseUrl;

  final String? mimeType;
  final String? filename;
}

class VideoAttachFlow {
  VideoAttachFlow({
    required this.gateway,
    Future<void> Function(String pickerUri)? launchPicker,
    this.defaultPollInterval = const Duration(seconds: 3),
    this.maxWait = const Duration(minutes: 5),
  }) : _launchPicker = launchPicker ?? _launchViaIntent;

  final PhotosPickerGateway gateway;
  final Future<void> Function(String pickerUri) _launchPicker;

  /// Poll cadence when the session's pollingConfig is absent.
  final Duration defaultPollInterval;

  /// Hard ceiling on the whole wait, regardless of what pollingConfig
  /// suggests (mirrors the Kaya guided sync's ~5 min budget).
  final Duration maxWait;

  bool _cancelled = false;

  /// Abandons the current pickVideo() wait (e.g. the form was closed).
  /// The in-flight future completes with [VideoAttachCancelled].
  void cancel() => _cancelled = true;

  /// Runs the full picker flow. Throws [VideoAttachCancelled] on
  /// cancel, [StateError] on timeout / photo-only pick / API errors
  /// (a 403 SERVICE_DISABLED-style error gets the setup hint appended).
  Future<VideoAttachResult> pickVideo() async {
    _cancelled = false;
    final PickerSession session;
    try {
      session = PickerSession.fromJson(await gateway.createSession());
    } catch (e) {
      // Most common first-run failure: API not enabled / scope missing
      // from the consent screen. Surface the one-time setup steps.
      final s = '$e';
      if (s.contains('403') || s.contains('SERVICE_DISABLED')) {
        throw StateError('$e\n\n$kVideoAttachSetupHint');
      }
      rethrow;
    }
    if (session.pickerUri.isEmpty) {
      throw StateError('Picker session came back without a pickerUri');
    }
    await _launchPicker(session.pickerUri);

    final interval = session.pollInterval ?? defaultPollInterval;
    var budget = session.timeoutIn ?? maxWait;
    if (budget > maxWait) budget = maxWait;

    var waited = Duration.zero;
    var set = session.mediaItemsSet;
    while (!set) {
      if (_cancelled) {
        await _cleanup(session.id);
        throw const VideoAttachCancelled();
      }
      if (waited >= budget) {
        await _cleanup(session.id);
        throw StateError(
            'Timed out waiting for a pick — tap Attach to try again.');
      }
      await Future<void>.delayed(interval);
      waited += interval;
      set = PickerSession.fromJson(await gateway.getSession(session.id))
          .mediaItemsSet;
    }

    final items = await gateway.listMediaItems(session.id);
    final video = firstVideoItem(items);
    await _cleanup(session.id);
    if (video == null) {
      throw StateError(
          'No video in the pick — choose a video (not a photo).');
    }
    return VideoAttachResult(
      mediaId: video.mediaId,
      url: photosProductUrl(video.mediaId),
      baseUrl: video.baseUrl,
      mimeType: video.mimeType,
      filename: video.filename,
    );
  }

  Future<void> _cleanup(String sessionId) async {
    try {
      await gateway.deleteSession(sessionId);
    } catch (_) {/* best-effort */}
  }

  static Future<void> _launchViaIntent(String pickerUri) {
    return AndroidIntent(
      action: 'android.intent.action.VIEW',
      data: pickerUri,
    ).launch();
  }
}
