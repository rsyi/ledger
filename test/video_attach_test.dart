import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/video_attach.dart';
import 'package:airledger/services/video_ref.dart';

// Local attach flow (Android system photo picker) against a fake
// picker: cancel, non-video, persisted grant (reference only), and the
// copy-into-app-storage fallback when the grant can't be persisted.

const _uri =
    'content://media/picker/0/com.android.providers.media.photopicker/media/77';

class _FakePicker implements LocalVideoPicker {
  _FakePicker(this.result, {this.copyError});
  final PickedLocalVideo? result;
  final Object? copyError;
  final copies = <(String, String)>[];

  @override
  Future<PickedLocalVideo?> pick() async => result;

  @override
  Future<void> copyTo(String uri, String destPath) async {
    if (copyError != null) throw copyError!;
    copies.add((uri, destPath));
  }
}

void main() {
  Future<String> dest(String mediaId) async => '/cache/$mediaId.mp4';

  test('cancel → VideoAttachCancelled', () async {
    final flow = VideoAttachFlow(picker: _FakePicker(null), cachePathFor: dest);
    expect(flow.pickVideo(), throwsA(isA<VideoAttachCancelled>()));
  });

  test('persisted grant: stores the content URI, derived media id, no copy',
      () async {
    final p = _FakePicker(const PickedLocalVideo(
        uri: _uri, persisted: true, mimeType: 'video/mp4', name: 'a.mp4'));
    final res = await VideoAttachFlow(picker: p, cachePathFor: dest)
        .pickVideo();
    expect(res.url, _uri);
    expect(res.mediaId, localMediaIdFor(_uri));
    expect(res.cachedPath, isNull);
    expect(res.frameSource, _uri);
    expect(p.copies, isEmpty);
  });

  test('grant not persistable: copies into app storage, still refs the URI',
      () async {
    final p = _FakePicker(const PickedLocalVideo(
        uri: _uri, persisted: false, mimeType: 'video/mp4'));
    final res = await VideoAttachFlow(picker: p, cachePathFor: dest)
        .pickVideo();
    final mid = localMediaIdFor(_uri);
    expect(res.url, _uri);
    expect(p.copies, [(_uri, '/cache/$mid.mp4')]);
    expect(res.cachedPath, '/cache/$mid.mp4');
    expect(res.frameSource, '/cache/$mid.mp4');
  });

  test('copy failure without a grant is a clear, retryable error', () async {
    final p = _FakePicker(
        const PickedLocalVideo(uri: _uri, persisted: false),
        copyError: Exception('disk full'));
    expect(
      VideoAttachFlow(picker: p, cachePathFor: dest).pickVideo(),
      throwsA(isA<VideoAttachException>()
          .having((e) => e.message, 'message', contains('try again'))
          .having((e) => e.message, 'message', contains('disk full'))),
    );
  });

  test('a picked photo is refused', () async {
    final p = _FakePicker(const PickedLocalVideo(
        uri: _uri, persisted: true, mimeType: 'image/jpeg'));
    expect(
      VideoAttachFlow(picker: p, cachePathFor: dest).pickVideo(),
      throwsA(isA<VideoAttachException>()
          .having((e) => e.message, 'message', contains('video'))),
    );
  });

  test('unknown mime is accepted (some providers omit it)', () async {
    final p =
        _FakePicker(const PickedLocalVideo(uri: _uri, persisted: true));
    final res = await VideoAttachFlow(picker: p, cachePathFor: dest)
        .pickVideo();
    expect(res.url, _uri);
  });

  test('PickedLocalVideo.fromChannel parses the platform map', () {
    final v = PickedLocalVideo.fromChannel({
      'uri': _uri,
      'persisted': true,
      'mimeType': 'video/mp4',
      'name': 'x.mp4',
      'size': 1234,
    });
    expect(v.uri, _uri);
    expect(v.persisted, isTrue);
    expect(v.name, 'x.mp4');
    expect(v.sizeBytes, 1234);
    expect(() => PickedLocalVideo.fromChannel({'persisted': true}),
        throwsA(isA<VideoAttachException>()));
  });
}
