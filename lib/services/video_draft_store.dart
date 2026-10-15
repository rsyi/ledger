/// Persists the LAST attached video per view so an accidental back-press
/// (or leaving the form) doesn't throw away the picker + AI-RPE
/// work. Unlike ordinary fields, a video is slow and painful to re-attach,
/// so it auto-saves the moment it lands and restores when the form reopens.
///
/// Scoped per view name; cleared when the row is saved or the video is
/// removed. The video_url is a local content:// reference with a
/// persisted read grant (or a legacy Google Photos link), so there is no
/// expiry.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class VideoDraft {
  final String url;
  final String? mediaId;

  /// Durable sibling values captured at attach (video_durable.dart):
  /// field name → value (the taken-at DateTime is stored ISO and comes
  /// back as a DateTime).
  final Map<String, Object?> extras;
  const VideoDraft(this.url, this.mediaId, {this.extras = const {}});
}

class VideoDraftStore {
  VideoDraftStore._();

  static String _key(String view) => 'video_draft:$view';

  static Future<void> save(String view, String url, String? mediaId,
      {Map<String, Object?> extras = const {}}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _key(view),
        jsonEncode({
          'url': url,
          'mediaId': mediaId,
          'extras': {
            for (final e in extras.entries)
              e.key: e.value is DateTime
                  ? {'dt': (e.value as DateTime).toIso8601String()}
                  : e.value,
          },
        }));
  }

  static Future<VideoDraft?> load(String view) async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_key(view));
    if (s == null) return null;
    try {
      final m = jsonDecode(s) as Map;
      final url = m['url'] as String?;
      if (url == null || url.isEmpty) return null;
      final raw = m['extras'];
      final extras = <String, Object?>{};
      if (raw is Map) {
        raw.forEach((k, v) {
          extras['$k'] = v is Map && v['dt'] is String
              ? DateTime.tryParse(v['dt'] as String)
              : v;
        });
      }
      return VideoDraft(url, m['mediaId'] as String?, extras: extras);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear(String view) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_key(view));
  }
}
