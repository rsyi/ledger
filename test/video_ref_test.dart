import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/video_ref.dart';

// Pure parsing of the `video_url` value: on-device references (content
// URIs from the Android photo picker / file paths) vs legacy Google
// Photos deep links, the derived media id, and playback resolution.

const _picker =
    'content://media/picker/0/com.android.providers.media.photopicker/media/1000012345';
const _docs =
    'content://com.android.providers.media.documents/document/video%3A4242';
const _photos = 'https://photos.google.com/lr/photo/AF1QipAbC-123';

void main() {
  group('videoRefKind', () {
    test('content / file URIs and absolute paths are local', () {
      expect(videoRefKind(_picker), VideoRefKind.local);
      expect(videoRefKind(_docs), VideoRefKind.local);
      expect(videoRefKind('file:///data/x.mp4'), VideoRefKind.local);
      expect(videoRefKind('/data/user/0/x/app_flutter/a.mp4'),
          VideoRefKind.local);
      expect(isLocalVideoRef(_picker), isTrue);
    });

    test('photos.google.com links are legacy Google Photos refs', () {
      expect(videoRefKind(_photos), VideoRefKind.googlePhotos);
      expect(videoRefKind('https://photos.app.goo.gl/xyz'),
          VideoRefKind.googlePhotos);
      expect(isLocalVideoRef(_photos), isFalse);
    });

    test('other / blank', () {
      expect(videoRefKind('https://youtu.be/abc'), VideoRefKind.other);
      expect(videoRefKind(''), VideoRefKind.none);
      expect(videoRefKind(null), VideoRefKind.none);
      expect(videoRefKind('   '), VideoRefKind.none);
    });
  });

  group('localMediaIdFor', () {
    test('deterministic, prefixed, filename-safe, keeps the item id', () {
      final a = localMediaIdFor(_picker);
      expect(a, localMediaIdFor(_picker));
      expect(a, startsWith('local_1000012345_'));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a), isTrue);
    });

    test('decodes + sanitizes document ids', () {
      final b = localMediaIdFor(_docs);
      expect(b, startsWith('local_video_4242_'));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(b), isTrue);
    });

    test('same last segment from different providers never collides', () {
      const other =
          'content://com.example.provider/media/1000012345';
      expect(localMediaIdFor(other), isNot(localMediaIdFor(_picker)));
    });

    test('long segments are truncated', () {
      final id = localMediaIdFor('content://x/${'a' * 200}');
      expect(id.length, lessThanOrEqualTo(64));
    });
  });

  test('fnv1a32Hex known vectors', () {
    expect(fnv1a32Hex(''), '811c9dc5');
    expect(fnv1a32Hex('a'), 'e40c292c');
    expect(fnv1a32Hex('foobar'), 'bf9cf968');
  });

  group('videoRefLabel', () {
    test('describes where the clip lives', () {
      expect(videoRefLabel(_picker), 'on this phone');
      expect(videoRefLabel(_photos), 'Google Photos');
      expect(videoRefLabel('https://youtu.be/abc'), 'youtu.be');
    });
  });

  group('resolvePlayback (fallback order)', () {
    VideoPlayback r(String? ref,
            {bool readable = false, bool cached = false, String? photos}) =>
        resolvePlayback(
            ref: ref,
            localReadable: readable,
            hasCachedFile: cached,
            photosUrl: photos);

    test('1. the on-device clip wins while it still opens', () {
      expect(r(_picker, readable: true, cached: true, photos: _photos),
          VideoPlayback.localUri);
    });

    test('2. then the app-storage copy', () {
      expect(r(_picker, cached: true, photos: _photos),
          VideoPlayback.cachedFile);
      // Legacy Photos rows with a clip cached at attach time.
      expect(r(_photos, cached: true), VideoPlayback.cachedFile);
    });

    test('3. then the Google Photos link (row link or legacy video_url)',
        () {
      expect(r(_picker, photos: _photos), VideoPlayback.photos);
      expect(r(_photos), VideoPlayback.photos);
    });

    test('4. else thumbnail-only (gone from the phone, never linked)', () {
      expect(r(_picker), VideoPlayback.thumbnailOnly);
      expect(r(_picker, photos: '  '), VideoPlayback.thumbnailOnly);
    });

    test('other links open externally; blank → none', () {
      expect(r('https://youtu.be/abc'), VideoPlayback.external);
      expect(r(''), VideoPlayback.none);
      expect(r(null), VideoPlayback.none);
    });
  });

  group('durable siblings', () {
    test('field names follow <base>_* off video_url', () {
      expect(thumbFieldFor('video_url'), 'video_thumb');
      expect(takenAtFieldFor('video_url'), 'video_taken_at');
      expect(durationFieldFor('video_url'), 'video_duration_ms');
      expect(photosUrlFieldFor('video_url'), 'video_photos_url');
      expect(thumbFieldFor('clip'), 'clip_thumb');
      expect(isBlobDim('video_thumb'), isTrue);
      expect(isBlobDim('video_url'), isFalse);
    });

    test('thumb data URI round-trips and is Sheets-safe', () {
      final bytes = List<int>.generate(300, (i) => (i * 37) & 0xff)
        ..setAll(0, [0xff, 0xd8, 0xff]);
      final cell = encodeThumbDataUri(bytes);
      expect(cell, startsWith('data:image/jpeg;base64,'));
      // USER_ENTERED never sees a formula / sign / number-shaped value.
      expect(cell[0], isNot(anyOf('=', '+', '-', '@')));
      expect(decodeThumbDataUri(cell), bytes);
      // Bare base64 (hand-pasted) also decodes; garbage → null.
      expect(decodeThumbDataUri(cell.split(',').last), bytes);
      expect(decodeThumbDataUri('data:image/jpeg;base64,@@@'), isNull);
      expect(decodeThumbDataUri(''), isNull);
      expect(decodeThumbDataUri(null), isNull);
    });

    test('a full-budget thumb stays far under the 50k Sheets cell cap', () {
      final cell = encodeThumbDataUri(List.filled(kThumbMaxBytes, 7));
      expect(cell.length, lessThan(14000));
      expect(cell.length, lessThan(50000));
    });

    test('linked = row photos link OR legacy Photos video_url', () {
      expect(isClipLinked({'video_url': _picker}, 'video_url'), isFalse);
      expect(
          isClipLinked({'video_url': _picker, 'video_photos_url': _photos},
              'video_url'),
          isTrue);
      expect(isClipLinked({'video_url': _photos}, 'video_url'), isTrue);
    });

    test('"N clips not linked" counts distinct clips, not rows', () {
      final rows = [
        {'video_url': _picker, 'video_media_id': 'a'},
        {'video_url': _picker, 'video_media_id': 'a'}, // same clip
        {'video_url': _docs, 'video_media_id': 'b'},
        {'video_url': _docs, 'video_media_id': 'c', 'video_photos_url': _photos},
        {'video_url': _photos}, // legacy, linked
        {'video_url': ''},
        {'exercise': 'Bench'},
      ];
      expect(unlinkedClipCount(rows, 'video_url'), 2);
      expect(unlinkedClips(rows, 'video_url')['mid:a'], hasLength(2));
    });
  });

  group('frameSourceFor', () {
    test('prefers the cached copy, else the local ref, else null', () {
      expect(frameSourceFor(ref: _picker, cachedPath: '/c/a.mp4'),
          '/c/a.mp4');
      expect(frameSourceFor(ref: _picker), _picker);
      expect(frameSourceFor(ref: _photos), isNull);
      expect(frameSourceFor(ref: _photos, cachedPath: '/c/b.mp4'),
          '/c/b.mp4');
    });
  });
}
