import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/integrations/photos_picker_gateway.dart';
import 'package:airledger/services/video_attach.dart';

// Photos Picker attach flow — pure helpers + the orchestration loop
// against a fake gateway. Wire shapes follow the Picker API reference
// (sessions / mediaItems.list / PickedMediaItem; NO productUrl).

Map<String, dynamic> _session({
  String id = 's1',
  bool set = false,
  Map<String, dynamic>? polling,
}) =>
    {
      'id': id,
      'pickerUri': 'https://photos.google.com/picker/abc',
      'mediaItemsSet': set,
      'pollingConfig': ?polling,
    };

Map<String, dynamic> _item({
  String id = 'm1',
  String type = 'VIDEO',
  String baseUrl = 'https://lh3.googleusercontent.com/base',
}) =>
    {
      'id': id,
      'type': type,
      'createTime': '2026-09-28T10:00:00Z',
      'mediaFile': {
        'baseUrl': baseUrl,
        'mimeType': type == 'VIDEO' ? 'video/mp4' : 'image/jpeg',
        'filename': type == 'VIDEO' ? 'squat.mp4' : 'pic.jpg',
      },
    };

class FakePickerGateway implements PhotosPickerGateway {
  FakePickerGateway({
    required this.sessions,
    this.items = const [],
    this.createError,
  });

  /// Successive getSession responses (last one repeats).
  final List<Map<String, dynamic>> sessions;
  final List<dynamic> items;
  final Object? createError;

  int gets = 0;
  final deleted = <String>[];

  @override
  Future<Map<String, dynamic>> createSession() async {
    final err = createError;
    if (err != null) throw err;
    return sessions.first;
  }

  @override
  Future<Map<String, dynamic>> getSession(String sessionId) async {
    gets++;
    final idx = gets < sessions.length ? gets : sessions.length - 1;
    return sessions[idx];
  }

  @override
  Future<List<dynamic>> listMediaItems(String sessionId) async => items;

  @override
  Future<void> deleteSession(String sessionId) async =>
      deleted.add(sessionId);

  @override
  Future<Uint8List> download(String url) async => Uint8List(0);

  @override
  Future<String?> signedInEmail() async => 'x@y.z';

  @override
  Future<String> signIn() async => 'x@y.z';
}

VideoAttachFlow _flow(FakePickerGateway gw) => VideoAttachFlow(
      gateway: gw,
      launchPicker: (_) async {},
      defaultPollInterval: const Duration(milliseconds: 1),
      maxWait: const Duration(milliseconds: 10),
    );

void main() {
  group('parseGoogleDuration', () {
    test('parses fractional and whole seconds', () {
      expect(parseGoogleDuration('3.5s'),
          const Duration(milliseconds: 3500));
      expect(parseGoogleDuration('300s'), const Duration(seconds: 300));
    });

    test('rejects garbage', () {
      expect(parseGoogleDuration(null), isNull);
      expect(parseGoogleDuration('5'), isNull);
      expect(parseGoogleDuration('abcs'), isNull);
      expect(parseGoogleDuration('-2s'), isNull);
    });
  });

  group('PickerSession.fromJson', () {
    test('parses id, uri, pollingConfig', () {
      final s = PickerSession.fromJson(_session(
        polling: {'pollInterval': '1.5s', 'timeoutIn': '120s'},
      ));
      expect(s.id, 's1');
      expect(s.pickerUri, contains('picker'));
      expect(s.mediaItemsSet, isFalse);
      expect(s.pollInterval, const Duration(milliseconds: 1500));
      expect(s.timeoutIn, const Duration(seconds: 120));
    });

    test('missing id throws loudly', () {
      expect(() => PickerSession.fromJson({'pickerUri': 'x'}),
          throwsStateError);
    });
  });

  group('firstVideoItem', () {
    test('skips photos, returns first video', () {
      final v = firstVideoItem([
        _item(id: 'p1', type: 'PHOTO'),
        _item(id: 'v1'),
        _item(id: 'v2'),
      ]);
      expect(v!.mediaId, 'v1');
      expect(v.baseUrl, contains('googleusercontent'));
      expect(v.mimeType, 'video/mp4');
      expect(v.filename, 'squat.mp4');
    });

    test('photo-only or empty → null', () {
      expect(firstVideoItem([_item(type: 'PHOTO')]), isNull);
      expect(firstVideoItem([]), isNull);
    });

    test('video without baseUrl is skipped (wire drift guard)', () {
      final broken = _item();
      (broken['mediaFile'] as Map).remove('baseUrl');
      expect(firstVideoItem([broken]), isNull);
    });
  });

  test('url builders', () {
    expect(photosProductUrl('abc'), 'https://photos.google.com/lr/photo/abc');
    expect(videoDownloadUrl('https://x/base'), 'https://x/base=dv');
  });

  group('VideoAttachFlow.pickVideo', () {
    test('polls until mediaItemsSet, returns deep link + id, deletes '
        'session', () async {
      final gw = FakePickerGateway(
        sessions: [_session(), _session(), _session(set: true)],
        items: [_item(id: 'p1', type: 'PHOTO'), _item(id: 'vid9')],
      );
      final res = await _flow(gw).pickVideo();
      expect(res.mediaId, 'vid9');
      expect(res.url, 'https://photos.google.com/lr/photo/vid9');
      expect(res.baseUrl, contains('googleusercontent'));
      expect(gw.gets, greaterThanOrEqualTo(2));
      expect(gw.deleted, ['s1']);
    });

    test('photo-only pick errors (and still cleans up)', () async {
      final gw = FakePickerGateway(
        sessions: [_session(set: true)],
        items: [_item(type: 'PHOTO')],
      );
      await expectLater(
        _flow(gw).pickVideo(),
        throwsA(predicate(
            (e) => '$e'.contains('choose a video'))),
      );
      expect(gw.deleted, ['s1']);
    });

    test('timeout errors after the budget and cleans up', () async {
      final gw = FakePickerGateway(sessions: [_session()]);
      await expectLater(
        _flow(gw).pickVideo(),
        throwsA(predicate((e) => '$e'.contains('Timed out'))),
      );
      expect(gw.deleted, ['s1']);
    });

    test('cancel() surfaces VideoAttachCancelled', () async {
      final gw = FakePickerGateway(sessions: [_session()]);
      final flow = VideoAttachFlow(
        gateway: gw,
        launchPicker: (_) async {},
        defaultPollInterval: const Duration(milliseconds: 5),
        maxWait: const Duration(seconds: 1),
      );
      final future = flow.pickVideo();
      flow.cancel();
      await expectLater(
          future, throwsA(isA<VideoAttachCancelled>()));
    });

    test('403 on session create appends the one-time setup hint',
        () async {
      final gw = FakePickerGateway(
        sessions: [_session()],
        createError: StateError(
            'Photos Picker API 403: SERVICE_DISABLED'),
      );
      await expectLater(
        _flow(gw).pickVideo(),
        throwsA(predicate(
            (e) => '$e'.contains('Google Photos Picker API'))),
      );
    });
  });
}
