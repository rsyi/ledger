import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/image_hash.dart';
import 'package:airledger/services/integrations/photos_picker_gateway.dart';
import 'package:airledger/services/photos_verify.dart';
import 'package:airledger/services/video_frames.dart';

// Link verification: the check codec, the decision table, the image
// comparison (incl. rotation + aspect), and evidence collection against
// fakes (thumbnail only — never video bytes; cloud thumb saved locally).

const _dir = 'test/fixtures/clip_verify';
Uint8List _b(String n) => File('$_dir/$n.jpg').readAsBytesSync();
Future<GrayImage> _g(String n) async => (await decodeGray(_b(n)))!;

class _Frames implements FrameExtractor {
  _Frames(this.byTs, {this.fail = false});
  final Map<int, String> byTs;
  final bool fail;
  final calls = <List<int>>[];
  @override
  Future<int> durationMs(String path) async => 8000;
  @override
  Future<Map<String, Object?>> probe(String path) async => const {};
  @override
  Future<List<Uint8List>> framesAt(String path, List<int> ts,
      {int maxWidth = 512, int? maxSide, int quality = 70}) async {
    if (fail) throw StateError('gone');
    calls.add(ts);
    expect(maxSide, kVerifyThumbPx);
    return [for (final t in ts) _b(byTs[t]!)];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LinkCheck codec', () {
    test('round-trips every status', () {
      for (final c in const [
        LinkCheck(LinkStatus.verified, bits: 4),
        LinkCheck(LinkStatus.unverified),
        LinkCheck(LinkStatus.manual),
        LinkCheck(LinkStatus.manual, bits: 23),
        LinkCheck(LinkStatus.mismatch, bits: 31, itemId: 'AF1Qip_x-Y'),
        LinkCheck(LinkStatus.mismatch, itemId: 'AF1'),
      ]) {
        expect(LinkCheck.parse(c.encode()), c, reason: c.encode());
      }
      expect(const LinkCheck(LinkStatus.verified, bits: 4).encode(),
          'verified:4');
      expect(LinkCheck.parse(''), isNull);
      expect(LinkCheck.parse('bogus:1'), isNull);
      expect(const LinkCheck(LinkStatus.mismatch, bits: 3).needsReview, isTrue);
      expect(const LinkCheck(LinkStatus.unverified).needsReview, isTrue);
      expect(const LinkCheck(LinkStatus.manual).needsReview, isFalse);
    });
  });

  group('decision table', () {
    const id = 'P1';
    test('no time match → review, nothing stored', () {
      final d = decideLink(
          timeMatched: false,
          itemId: id,
          comparison: const ImageComparison(bits: 0));
      expect(d.action, LinkAction.review);
      expect(d.check, isNull);
    });
    test('time match + no image evidence → link, unverified', () {
      final d = decideLink(timeMatched: true, itemId: id);
      expect(d.action, LinkAction.link);
      expect(d.check!.encode(), 'unverified');
    });
    test('time match + flat frames (inconclusive) → link, unverified', () {
      final d = decideLink(
          timeMatched: true,
          itemId: id,
          comparison: const ImageComparison(bits: 0, confident: 3));
      expect(d.action, LinkAction.link);
      expect(d.check!.status, LinkStatus.unverified);
    });
    test('time match + image match → link, verified:<bits>', () {
      for (final bits in [0, 12]) {
        final d = decideLink(
            timeMatched: true,
            itemId: id,
            comparison: ImageComparison(bits: bits));
        expect(d.action, LinkAction.link);
        expect(d.check!.encode(), 'verified:$bits');
      }
    });
    test('time match + image mismatch → review, mismatch keeps the id', () {
      final d = decideLink(
          timeMatched: true,
          itemId: id,
          comparison: const ImageComparison(bits: 13));
      expect(d.action, LinkAction.review);
      expect(d.check!.encode(), 'mismatch:13:P1');
      final a = decideLink(
          timeMatched: true,
          itemId: id,
          comparison: const ImageComparison(aspectMismatch: true));
      expect(a.action, LinkAction.review);
      expect(a.check!.encode(), 'mismatch:-:P1');
    });
    test('re-check keeps the link: verified / mismatch / no evidence', () {
      expect(recheckResult(itemId: id, comparison: const ImageComparison(bits: 2))
          .encode(), 'verified:2');
      expect(recheckResult(itemId: id, comparison: const ImageComparison(bits: 40))
          .encode(), 'mismatch:40:P1');
      expect(recheckResult(itemId: id).encode(), 'unverified');
      expect(
          recheckResult(
                  itemId: id,
                  previous: const LinkCheck(LinkStatus.manual))
              .encode(),
          'manual');
    });
  });

  group('compareClipImages (fixtures)', () {
    Future<List<GrayImage>> local(String c) async =>
        [for (final p in [0, 10, 50]) await _g('${c}_local_$p')];

    test('same clip matches; other scene does not', () async {
      final same = compareClipImages(await _g('gymA_cloud'), await local('gymA'));
      expect(same.matches, isTrue);
      expect(same.bits, lessThanOrEqualTo(4));
      final other =
          compareClipImages(await _g('gymB_cloud'), await local('gymA'));
      expect(other.matches, isFalse);
      expect(other.bits, greaterThan(kVerifyMaxBits));
    });

    test('portrait vs landscape is an aspect mismatch', () async {
      final c = compareClipImages(await _g('gymP_cloud'), await local('gymA'));
      // gymA frames turned 90° are 9:16 too — so they ARE compared, and
      // the content still decides (no false verify).
      expect(c.matches, isFalse);
      final square = GrayImage(64, 64, Uint8List(64 * 64));
      final a = compareClipImages(square, await local('gymA'));
      expect(a.aspectMismatch, isTrue);
      expect(a.matches, isFalse);
    });

    test('a frame missing its rotation still verifies (turned 90°)',
        () async {
      final c = compareClipImages(
          await _g('gymP_cloud'), [await _g('gymP_local_0_unrotated')]);
      expect(c.rotated, isTrue);
      expect(c.matches, isTrue);
    });

    test('black frames are inconclusive, never verified', () async {
      final c = compareClipImages(
          await _g('black_cloud'), [await _g('black_local')]);
      expect(c.inconclusive, isTrue);
      expect(c.matches, isFalse);
    });
  });

  group('ClipVerifier', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('pthumbs'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('0/10/50 % frames + w256 thumb → verified evidence; thumb saved',
        () async {
      final frames = _Frames(
          {0: 'gymA_local_0', 800: 'gymA_local_10', 4000: 'gymA_local_50'});
      final urls = <String>[];
      final store = PhotosThumbStore(dir: () async => tmp);
      final v = ClipVerifier(
        frames: frames,
        thumbStore: store,
        download: (u) async {
          urls.add(u);
          return _b('gymA_cloud');
        },
      );
      final e = await v.evidence(
          const PickedMediaItem(id: 'AF1', isVideo: true, baseUrl: 'https://lh3/b'),
          localSource: 'content://x',
          durationMs: 8000);
      expect(urls, ['https://lh3/b=w256-h256']);
      expect(urls.any((u) => u.contains('=dv')), isFalse);
      expect(frames.calls.single, [0, 800, 4000]);
      expect(e.comparison!.matches, isTrue);
      expect(e.bestLocalFrame, isNotNull);
      expect(await store.load('AF1'), _b('gymA_cloud'));
    });

    test('no local clip → no comparison (unverified), cloud thumb kept',
        () async {
      final v = ClipVerifier(
        frames: _Frames(const {}, fail: true),
        thumbStore: PhotosThumbStore(dir: () async => tmp),
        download: (_) async => _b('gymA_cloud'),
      );
      final none = await v.evidence(
          const PickedMediaItem(id: 'A', isVideo: true, baseUrl: 'https://b'));
      expect(none.comparison, isNull);
      expect(none.cloudThumb, isNotNull);
      final gone = await v.evidence(
          const PickedMediaItem(id: 'A', isVideo: true, baseUrl: 'https://b'),
          localSource: 'content://revoked');
      expect(gone.comparison, isNull);
      expect(decideLink(timeMatched: true, itemId: 'A', comparison: gone.comparison)
          .check!.status, LinkStatus.unverified);
    });

    test('expired baseUrl falls back to the stored thumbnail', () async {
      final store = PhotosThumbStore(dir: () async => tmp);
      await store.save('A', _b('gymB_cloud'));
      final v = ClipVerifier(
        frames: _Frames(const {}),
        thumbStore: store,
        download: (_) async => throw StateError('403'),
      );
      expect(await v.cloudThumb(
              const PickedMediaItem(id: 'A', isVideo: true, baseUrl: 'https://b')),
          _b('gymB_cloud'));
    });

    test('timestamps: 0/10/50 %, just 0 when the duration is unknown', () {
      expect(verifyTimestampsMs(15000), [0, 1500, 7500]);
      expect(verifyTimestampsMs(null), [0]);
      expect(verifyTimestampsMs(0), [0]);
    });
  });
}
