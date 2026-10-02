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

  group('playbackTargetFor', () {
    test('cached file always wins (legacy picker downloads + copies)', () {
      expect(playbackTargetFor(ref: _photos, hasCachedFile: true),
          VideoPlayback.cachedFile);
      expect(playbackTargetFor(ref: _picker, hasCachedFile: true),
          VideoPlayback.cachedFile);
    });

    test('local refs play in-app straight from the URI', () {
      expect(playbackTargetFor(ref: _picker, hasCachedFile: false),
          VideoPlayback.localUri);
    });

    test('legacy Photos links open externally', () {
      expect(playbackTargetFor(ref: _photos, hasCachedFile: false),
          VideoPlayback.external);
    });

    test('blank → none', () {
      expect(playbackTargetFor(ref: '', hasCachedFile: false),
          VideoPlayback.none);
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
