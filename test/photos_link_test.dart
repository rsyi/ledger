import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/integrations/photos_picker_gateway.dart';
import 'package:airledger/services/photos_link.dart';
import 'package:airledger/services/photos_verify.dart';
import 'package:airledger/services/video_durable.dart';
import 'package:airledger/services/video_frames.dart';

// Retroactive Google Photos linking: candidate building, the one-to-one
// matcher (the clip's OWN recording time only — the logged set time is
// never evidence; no-timestamp clips are review-only), the pure apply /
// check / unlink / backfill steps, and the picker flow against a fake
// gateway (multi-select; thumbnails only — never video bytes).

const _uriA = 'content://media/picker/0/x/media/101';
const _uriB = 'content://media/picker/0/x/media/102';
const _uriC = 'content://media/picker/0/x/media/103';

PickedMediaItem _item(String id, DateTime local,
        {bool video = true, String? base}) =>
    PickedMediaItem(
      id: id,
      isVideo: video,
      createTime: local.toUtc(),
      baseUrl: base ?? 'https://lh3/base_$id',
      mimeType: video ? 'video/mp4' : 'image/jpeg',
    );

Map<String, Object?> _row(String uri, String mid,
        {DateTime? taken,
        int? duration,
        String date = '2026-10-12',
        String? start,
        String exercise = 'Barbell Squat',
        String? thumb,
        String? photos,
        String? check}) =>
    {
      'id': 'row_$mid',
      'date': DateTime.parse(date),
      'exercise': exercise,
      'weight': 315,
      'reps': 3,
      'start_time': ?start,
      'video_url': uri,
      'video_media_id': mid,
      'video_taken_at': ?taken,
      'video_duration_ms': ?duration,
      'video_thumb': ?thumb,
      'video_photos_url': ?photos,
      'video_photos_check': ?check,
    };

void main() {
  final t0 = DateTime(2026, 10, 12, 17, 41, 5); // local

  group('linkCandidates', () {
    test('groups rows per clip, skips linked, reads metadata + check', () {
      final rows = [
        _row(_uriA, 'a', taken: t0, duration: 15000, thumb: 'data:x'),
        _row(_uriA, 'a', taken: t0, duration: 15000),
        _row(_uriB, 'b', start: '5:30:00 PM', check: 'mismatch:30:P9'),
        _row(_uriC, 'c',
            photos: 'https://photos.google.com/lr/photo/P1',
            check: 'verified:3'), // linked
      ];
      final c = linkCandidates(rows, 'video_url');
      expect(c.map((e) => e.key), ['mid:a', 'mid:b']);
      expect(c[0].rows, hasLength(2));
      expect(c[0].takenAt, t0);
      expect(c[0].durationMs, 15000);
      expect(c[0].hasThumb, isTrue);
      expect(c[0].label, 'Barbell Squat 315×3 (2 sets) · Oct 12, 5:41 PM');
      expect(c[1].takenAt, isNull); // start_time is NOT a recording time
      expect(c[1].check!.status, LinkStatus.mismatch);
      expect(c[1].label, 'Barbell Squat 315×3 · Oct 12');
      expect(linkedItemIds(rows, 'video_url'), {'P1'});
      final linked = linkedClipsByItemId(rows, 'video_url');
      expect(linked.keys, ['P1']);
      expect(linked['P1']!.check, const LinkCheck(LinkStatus.verified, bits: 3));
    });
  });

  group('matchPickedClips', () {
    test('exact metadata match within ±2 min links automatically', () {
      final clips = linkCandidates([
        _row(_uriA, 'a', taken: t0, duration: 15000),
        _row(_uriB, 'b', taken: t0.add(const Duration(minutes: 6))),
      ], 'video_url');
      final r = matchPickedClips([
        _item('P1', t0.add(const Duration(seconds: 3))),
        _item('P2', t0.add(const Duration(minutes: 6, seconds: -40))),
      ], clips);
      expect(r.matched.map((m) => '${m.item.id}->${m.clip.key}'),
          unorderedEquals(['P1->mid:a', 'P2->mid:b']));
      expect(r.matched.every((m) => m.basis == MatchBasis.metadata), isTrue);
      expect(r.ambiguous, isEmpty);
      expect(r.unmatched, isEmpty);
    });

    test('outside ±2 min is not a metadata match', () {
      final clips = linkCandidates(
          [_row(_uriA, 'a', taken: t0)], 'video_url');
      final r = matchPickedClips(
          [_item('P1', t0.add(const Duration(minutes: 3)))], clips);
      expect(r.matched, isEmpty);
      expect(r.unmatched.single.id, 'P1');
    });

    test('duration mismatch > 1 s vetoes when both durations are known', () {
      final clips = linkCandidates(
          [_row(_uriA, 'a', taken: t0, duration: 15000)], 'video_url');
      final veto = matchPickedClips([_item('P1', t0)], clips,
          itemDurationsMs: {'P1': 17000});
      expect(veto.matched, isEmpty);
      final ok = matchPickedClips([_item('P1', t0)], clips,
          itemDurationsMs: {'P1': 15600});
      expect(ok.matched.single.clip.key, 'mid:a');
    });

    test('the logged set time is never evidence: no video timestamp → '
        'review only, even seconds from the set time', () {
      final clips = linkCandidates([
        _row(_uriA, 'a', start: '5:35:00 PM'),
        _row(_uriB, 'b', start: '6:30:00 PM'),
      ], 'video_url');
      final r = matchPickedClips([
        _item('P1', DateTime(2026, 10, 12, 17, 35, 2)),
        _item('P2', DateTime(2026, 10, 13, 17, 35)), // next day
      ], clips);
      expect(r.matched, isEmpty);
      final amb = r.ambiguous.single;
      expect(amb.item.id, 'P1');
      expect(amb.candidates.map((c) => c.basis).toSet(),
          {MatchBasis.noTimestamp});
      expect(r.unmatched.single.id, 'P2');
    });

    test('two clips recorded seconds apart → ambiguous, offered for review',
        () {
      final clips = linkCandidates([
        _row(_uriA, 'a', taken: t0),
        _row(_uriB, 'b',
            taken: t0.add(const Duration(seconds: 10)),
            exercise: 'Bench Press'),
      ], 'video_url');
      final r = matchPickedClips(
          [_item('P1', t0.add(const Duration(seconds: 4)))], clips);
      expect(r.matched, isEmpty);
      final amb = r.ambiguous.single;
      expect(amb.item.id, 'P1');
      expect(amb.candidates.map((c) => c.clip.key), ['mid:a', 'mid:b']);
    });

    test('one-to-one: two items for one clip — the clearly closer wins',
        () {
      final clips = linkCandidates(
          [_row(_uriA, 'a', taken: t0)], 'video_url');
      final r = matchPickedClips([
        _item('P1', t0.add(const Duration(seconds: 70))),
        _item('P2', t0.add(const Duration(seconds: 2))),
      ], clips);
      expect(r.matched.single.item.id, 'P2');
      // P1's only candidate is taken → unmatched, never double-linked.
      expect(r.unmatched.single.id, 'P1');
    });

    test('one-to-one: near-tied items for one clip → review, not a guess',
        () {
      final clips = linkCandidates(
          [_row(_uriA, 'a', taken: t0)], 'video_url');
      final r = matchPickedClips([
        _item('P1', t0.add(const Duration(seconds: 5))),
        _item('P2', t0.add(const Duration(seconds: 9))),
      ], clips);
      expect(r.matched, isEmpty);
      expect(r.ambiguous.map((a) => a.item.id), ['P1', 'P2']);
    });

    test('a metadata-ambiguous item never auto-links via a no-timestamp clip',
        () {
      final clips = linkCandidates([
        _row(_uriA, 'a', taken: t0),
        _row(_uriB, 'b', taken: t0.add(const Duration(seconds: 6))),
        _row(_uriC, 'c', start: '5:41:00 PM'),
      ], 'video_url');
      final r = matchPickedClips(
          [_item('P1', t0.add(const Duration(seconds: 3)))], clips);
      expect(r.matched, isEmpty);
      expect(r.ambiguous.single.candidates.first.basis, MatchBasis.metadata);
    });

    test('same-day clip with no video timestamp → review only', () {
      final clips = linkCandidates([_row(_uriA, 'a')], 'video_url');
      final r = matchPickedClips(
          [_item('P1', DateTime(2026, 10, 12, 9))], clips);
      expect(r.matched, isEmpty);
      expect(r.ambiguous.single.candidates.single.basis,
          MatchBasis.noTimestamp);
    });

    test('photos, duplicates and already-linked items are set aside', () {
      final clips = linkCandidates(
          [_row(_uriA, 'a', taken: t0)], 'video_url');
      final r = matchPickedClips([
        _item('IMG', t0, video: false),
        _item('OLD', t0),
        _item('P1', t0),
        _item('P1', t0),
      ], clips, alreadyLinkedIds: {'OLD'});
      expect(r.nonVideo, 1);
      expect(r.alreadyLinked.single.id, 'OLD');
      expect(r.matched.single.item.id, 'P1');
    });
  });

  group('linkedRows (apply)', () {
    test('writes the deep link on every row; thumb only where missing', () {
      final clip = linkCandidates([
        _row(_uriA, 'a', taken: t0, thumb: 'data:keep'),
        _row(_uriA, 'a', taken: t0),
      ], 'video_url').single;
      final out = linkedRows(clip, _item('AF1Qip_x', t0), 'video_url',
          hasDim: (_) => true, thumbDataUri: 'data:new');
      expect(out.map((r) => r['video_photos_url']), [
        'https://photos.google.com/lr/photo/AF1Qip_x',
        'https://photos.google.com/lr/photo/AF1Qip_x',
      ]);
      expect(out[0]['video_thumb'], 'data:keep');
      expect(out[1]['video_thumb'], 'data:new');
      // video_media_id keeps its device-cache meaning.
      expect(out.every((r) => r['video_media_id'] == 'a'), isTrue);
      expect(photosItemIdOf(out[0]['video_photos_url'] as String), 'AF1Qip_x');
    });

    test('the check is written with the link when the view declares it',
        () {
      final clip = linkCandidates(
          [_row(_uriA, 'a', taken: t0)], 'video_url').single;
      final out = linkedRows(clip, _item('P', t0), 'video_url',
          hasDim: (_) => true,
          check: const LinkCheck(LinkStatus.verified, bits: 4));
      expect(out.single['video_photos_check'], 'verified:4');
      final noDim = linkedRows(clip, _item('P', t0), 'video_url',
          hasDim: (d) => d != 'video_photos_check',
          check: const LinkCheck(LinkStatus.verified, bits: 4));
      expect(noDim.single.containsKey('video_photos_check'), isFalse);
    });

    test('checkedRows writes only the check; unlinkedRows clears link+check',
        () {
      final clip = linkedClipsByItemId([
        _row(_uriA, 'a',
            taken: t0,
            thumb: 'data:t',
            photos: 'https://photos.google.com/lr/photo/P1',
            check: 'verified:2'),
        _row(_uriA, 'a',
            taken: t0, photos: 'https://photos.google.com/lr/photo/P1'),
      ], 'video_url')['P1']!;
      final c = checkedRows(clip, 'video_url',
          const LinkCheck(LinkStatus.mismatch, bits: 40, itemId: 'P1'),
          hasDim: (_) => true);
      expect(c.map((r) => r['video_photos_check']),
          ['mismatch:40:P1', 'mismatch:40:P1']);
      expect(c.first['video_photos_url'], isNotNull);
      expect(checkedRows(clip, 'video_url', null, hasDim: (_) => false),
          isEmpty);
      final u = unlinkedRows(clip, 'video_url', hasDim: (_) => true);
      expect(u.every((r) => r['video_photos_url'] == null), isTrue);
      expect(u.every((r) => r['video_photos_check'] == null), isTrue);
      expect(u.first['video_thumb'], 'data:t'); // describes the local clip
      // Unlinked rows are candidates again.
      expect(linkCandidates(u, 'video_url').single.key, 'mid:a');
    });

    test('a schema without the siblings is left untouched', () {
      final clip = linkCandidates(
          [_row(_uriA, 'a', taken: t0)], 'video_url').single;
      final out = linkedRows(clip, _item('P', t0), 'video_url',
          hasDim: (_) => false, thumbDataUri: 'data:new');
      expect(out.single.containsKey('video_photos_url'), isFalse);
      expect(out.single.containsKey('video_thumb'), isFalse);
    });
  });

  group('timestamp backfill (pre-metadata clips)', () {
    test('probe: MediaStore dateTaken wins, container date falls back, '
        'sentinels rejected', () async {
      final taken = DateTime(2026, 10, 1, 18, 2, 3);
      expect(
          (await probeClipMetadata(
                  _Probe({'dateTaken': taken.millisecondsSinceEpoch,
                      'durationMs': 9000}), 'content://x'))!
              .takenAt,
          taken);
      final c = await probeClipMetadata(
          _Probe({'date': '20261001T010203.000Z', 'durationMs': 9000}),
          '/cache/x.mp4');
      expect(c!.takenAt, DateTime.utc(2026, 10, 1, 1, 2, 3).toLocal());
      expect(c.durationMs, 9000);
      for (final sentinel in [
        {'date': '19040101T000000.000Z'},
        {'date': '19700101T000000.000Z'},
        {'dateTaken': 0},
      ]) {
        expect((await probeClipMetadata(_Probe(sentinel), 'x'))!.takenAt,
            isNull);
      }
      expect(await probeClipMetadata(_Probe(null), 'content://gone'), isNull);
    });

    test('backfill writes taken_at (+ blank duration) on every clip row',
        () {
      final clip = linkCandidates([
        _row(_uriA, 'a'),
        _row(_uriA, 'a', duration: 5000),
      ], 'video_url').single;
      final when = DateTime(2026, 10, 12, 17, 41);
      final out = timestampBackfillRows(
          clip, ClipMetadata(takenAt: when, durationMs: 9000), 'video_url',
          hasDim: (_) => true)!;
      expect(out.map((r) => r['video_taken_at']), [when, when]);
      expect(out.map((r) => r['video_duration_ms']), [9000, 5000]);
      expect(
          timestampBackfillRows(clip, const ClipMetadata(), 'video_url',
              hasDim: (_) => true),
          isNull);
      expect(
          timestampBackfillRows(clip, ClipMetadata(takenAt: when), 'video_url',
              hasDim: (_) => false),
          isNull);
      // Backfilled rows then match on recording time.
      final r = matchPickedClips([_item('P1', when.add(const Duration(seconds: 5)))],
          linkCandidates(out, 'video_url'));
      expect(r.matched.single.basis, MatchBasis.metadata);
    });
  });

  group('picker parsing', () {
    test('parses createTime/type/baseUrl; autoclose; thumbnail URL', () {
      final items = parsePickedItems([
        {
          'id': 'V1',
          'createTime': '2026-10-13T00:41:05Z',
          'type': 'VIDEO',
          'mediaFile': {'baseUrl': 'https://lh3/b', 'mimeType': 'video/mp4'},
        },
        {'id': 'I1', 'type': 'PHOTO', 'mediaFile': {'mimeType': 'image/jpeg'}},
        {'nope': true},
      ]);
      expect(items.map((i) => i.id), ['V1', 'I1']);
      expect(items[0].isVideo, isTrue);
      expect(items[0].createTime, DateTime.utc(2026, 10, 13, 0, 41, 5));
      expect(items[1].isVideo, isFalse);
      expect(autoclosePickerUri('https://photos.google.com/picker/abc'),
          'https://photos.google.com/picker/abc/autoclose');
      expect(autoclosePickerUri('https://p/x/autoclose'), 'https://p/x/autoclose');
      expect(thumbnailUrl('https://lh3/b'), 'https://lh3/b=w200-h200');
      expect(photosItemIdOf('https://youtu.be/x'), isNull);
    });
  });

  group('PhotosLinkFlow (fake gateway)', () {
    test('session → launch (autoclose) → poll → list → cleanup', () async {
      final g = _FakeGateway(pollsUntilSet: 2, items: [
        {
          'id': 'V1',
          'createTime': '2026-10-13T00:41:05Z',
          'type': 'VIDEO',
          'mediaFile': {'baseUrl': 'https://lh3/b1'},
        },
        {
          'id': 'V2',
          'createTime': '2026-10-13T00:45:05Z',
          'type': 'VIDEO',
          'mediaFile': {'baseUrl': 'https://lh3/b2'},
        },
      ]);
      String? launched;
      final flow = PhotosLinkFlow(
        gateway: g,
        launchPicker: (u) async => launched = u,
        defaultPollInterval: Duration.zero,
      );
      final items = await flow.pick();
      expect(items.map((i) => i.id), ['V1', 'V2']); // multi-select
      expect(launched, 'https://photos.google.com/picker/s1/autoclose');
      expect(g.deleted, ['s1']);
    });

    test('cancel stops the wait and still cleans up', () async {
      final g = _FakeGateway(pollsUntilSet: 1000);
      final flow = PhotosLinkFlow(
          gateway: g,
          launchPicker: (_) async {},
          defaultPollInterval: const Duration(milliseconds: 1));
      final f = flow.pick();
      flow.cancel();
      await expectLater(f, throwsA(isA<PhotosLinkCancelled>()));
      expect(g.deleted, ['s1']);
    });

    test('thumbnail fetch: 200 px, 120 px if over budget — never =dv',
        () async {
      final g = _FakeGateway(thumbSizes: {200: 20000, 120: 6000});
      final flow = PhotosLinkFlow(gateway: g, launchPicker: (_) async {});
      final t = await flow.fetchThumb(_item('V', t0, base: 'https://lh3/b'));
      expect(t!.length, 6000);
      expect(g.downloads, ['https://lh3/b=w200-h200', 'https://lh3/b=w120-h120']);
      expect(g.downloads.any((u) => u.contains('=dv')), isFalse);
      expect(await flow.fetchThumb(const PickedMediaItem(id: 'x', isVideo: true)),
          isNull);
    });
  });
}

class _Probe implements FrameExtractor {
  _Probe(this.result);
  final Map<String, Object?>? result;
  @override
  Future<int> durationMs(String path) async => 0;
  @override
  Future<Map<String, Object?>> probe(String path) async =>
      result ?? (throw StateError('no grant'));
  @override
  Future<List<Uint8List>> framesAt(String path, List<int> ts,
          {int maxWidth = 512, int? maxSide, int quality = 70}) async =>
      const [];
}

class _FakeGateway implements PhotosPickerGateway {
  _FakeGateway({
    this.pollsUntilSet = 0,
    this.items = const [],
    this.thumbSizes = const {},
  });
  final int pollsUntilSet;
  final List<dynamic> items;
  final Map<int, int> thumbSizes;
  int _polls = 0;
  final deleted = <String>[];
  final downloads = <String>[];

  @override
  Future<String?> signedInEmail() async => 'me@x';
  @override
  Future<String> signIn() async => 'me@x';
  @override
  Future<Map<String, dynamic>> createSession() async => {
        'id': 's1',
        'pickerUri': 'https://photos.google.com/picker/s1',
        'mediaItemsSet': false,
      };
  @override
  Future<Map<String, dynamic>> getSession(String id) async =>
      {'id': id, 'mediaItemsSet': ++_polls >= pollsUntilSet};
  @override
  Future<List<dynamic>> listMediaItems(String id) async => items;
  @override
  Future<void> deleteSession(String id) async => deleted.add(id);
  @override
  Future<Uint8List> download(String url) async {
    downloads.add(url);
    final px = int.parse(RegExp(r'=w(\d+)').firstMatch(url)!.group(1)!);
    return Uint8List(thumbSizes[px] ?? 100);
  }
}
