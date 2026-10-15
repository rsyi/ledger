import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/image_hash.dart';

// Perceptual hash behaviour on synthetic-but-real-pipeline fixtures
// (test/fixtures/clip_verify — 8 s ffmpeg clips of a textured static
// "tripod" scene with a moving dark figure; LOCAL frames emulate
// MediaMetadataRetriever at 0/10/50 % (long side 256, bilinear, q≈75),
// CLOUD frames emulate the Photos =w256-h256 thumbnail (lanczos, gamma
// 1.06, saturation 1.1, q≈55)).

const _dir = 'test/fixtures/clip_verify';

Future<GrayImage> _g(String name) async =>
    (await decodeGray(File('$_dir/$name.jpg').readAsBytesSync()))!;

Future<ClipSignature> _s(String name) async => ClipSignature.of(await _g(name));

int _best(ClipSignature cloud, List<ClipSignature> local) => local
    .map((l) => signatureDistance(cloud, l).bits)
    .reduce((a, b) => a < b ? a : b);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pure hashing', () {
    GrayImage ramp(int w, int h, {bool rising = true}) => GrayImage(
        w,
        h,
        Uint8List.fromList([
          for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
              rising ? (x * 255 ~/ (w - 1)) : 255 - (x * 255 ~/ (w - 1)),
        ]));

    test('left-brighter bits: a falling ramp is all ones, rising all zeros',
        () {
      expect(dHash64(ramp(90, 80, rising: false)), -1); // all 64 bits set
      expect(dHash64(ramp(90, 80)), 0);
      expect(hammingDistance(0, -1), 64);
      expect(hammingDistance(0x0F, 0x0E), 1);
    });

    test('flat regions are masked out (no confident bits)', () {
      final flat = GrayImage(64, 36, Uint8List(64 * 36)..fillRange(0, 64 * 36, 7));
      final s = ClipSignature.of(flat);
      expect(s.mask, 0);
      expect(signatureDistance(s, s).confident, 0);
    });

    test('area resize averages (no point sampling)', () {
      final img = GrayImage(2, 1, Uint8List.fromList([0, 200]));
      expect(img.areaResize(1, 1).single, 100);
    });

    test('rotation swaps dimensions and preserves content', () {
      final img = GrayImage(3, 2, Uint8List.fromList([1, 2, 3, 4, 5, 6]));
      final cw = img.rotated90();
      expect((cw.width, cw.height), (2, 3));
      expect(cw.luma, [4, 1, 5, 2, 6, 3]);
      expect(cw.rotated90(clockwise: false).luma, img.luma);
    });
  });

  group('fixtures (same clip ≤ threshold, different scene ≥ 20)', () {
    test('same clip: cloud thumb vs local 0/10/50 % frames', () async {
      final local = [
        for (final p in [0, 10, 50]) await _s('gymA_local_$p'),
      ];
      final d0 = _best(await _s('gymA_cloud'), local);
      final d1 = _best(await _s('gymA_cloud_1s'), local);
      expect(d0, lessThanOrEqualTo(4));
      expect(d1, lessThanOrEqualTo(10));
      final portrait = [
        for (final p in [0, 10, 50]) await _s('gymP_local_$p'),
      ];
      expect(_best(await _s('gymP_cloud'), portrait), lessThanOrEqualTo(4));
    });

    test('different scene is far', () async {
      final local = [
        for (final p in [0, 10, 50]) await _s('gymA_local_$p'),
      ];
      expect(_best(await _s('gymB_cloud'), local), greaterThanOrEqualTo(20));
    });

    test('aspect ratio survives the downscaled decode', () async {
      expect((await _g('gymA_cloud')).aspect, closeTo(16 / 9, 0.02));
      expect((await _g('gymP_local_0')).aspect, closeTo(9 / 16, 0.02));
    });
  });
}
