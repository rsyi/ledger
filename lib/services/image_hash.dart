/// Perceptual image hashing for clip-link VERIFICATION (2026-10-14).
///
/// photos_verify.dart compares the Google Photos thumbnail of a picked
/// item with frames of the row's local clip. Both sides are re-encoded
/// JPEGs at different sizes/qualities (Photos' own thumbnail pipeline vs
/// MediaMetadataRetriever), so an exact byte/pixel compare is useless;
/// a 64-bit difference hash (dHash) on a 9×8 area-averaged grayscale is
/// robust to scaling, recompression and mild tone shifts, and cheap
/// enough to run on a handful of ≤256 px frames per clip.
///
/// Pure Dart over decoded pixels ([GrayImage]); the only platform piece
/// is [decodeGray] (dart:ui's codec — no `image` package dependency).
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

/// A luma plane (0..255 per pixel, row-major).
class GrayImage {
  GrayImage(this.width, this.height, this.luma)
      : assert(luma.length == width * height);

  final int width;
  final int height;
  final Uint8List luma;

  double get aspect => width / height;

  /// From RGBA bytes (dart:ui rawRgba). BT.601 luma.
  factory GrayImage.fromRgba(Uint8List rgba, int width, int height) {
    final out = Uint8List(width * height);
    for (var i = 0, p = 0; i < out.length; i++, p += 4) {
      out[i] = ((rgba[p] * 299 + rgba[p + 1] * 587 + rgba[p + 2] * 114) ~/
              1000)
          .clamp(0, 255);
    }
    return GrayImage(width, height, out);
  }

  /// Rotated 90° clockwise ([clockwise]) or counter-clockwise — for a
  /// local frame whose rotation flag the extractor didn't apply.
  GrayImage rotated90({bool clockwise = true}) {
    final w = width, h = height;
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = luma[y * w + x];
        // New image is h wide, w tall.
        final nx = clockwise ? h - 1 - y : y;
        final ny = clockwise ? x : w - 1 - x;
        out[ny * h + nx] = v;
      }
    }
    return GrayImage(h, w, out);
  }

  /// Area-averaged downscale to [tw]×[th] (box filter with fractional
  /// edge coverage — no aliasing from point sampling).
  List<double> areaResize(int tw, int th) {
    final out = List<double>.filled(tw * th, 0);
    final sx = width / tw, sy = height / th;
    for (var ty = 0; ty < th; ty++) {
      final y0 = ty * sy, y1 = (ty + 1) * sy;
      for (var tx = 0; tx < tw; tx++) {
        final x0 = tx * sx, x1 = (tx + 1) * sx;
        var sum = 0.0, area = 0.0;
        for (var y = y0.floor(); y < y1.ceil() && y < height; y++) {
          final wy = _overlap(y0, y1, y.toDouble());
          if (wy <= 0) continue;
          for (var x = x0.floor(); x < x1.ceil() && x < width; x++) {
            final wx = _overlap(x0, x1, x.toDouble());
            if (wx <= 0) continue;
            sum += luma[y * width + x] * wx * wy;
            area += wx * wy;
          }
        }
        out[ty * tw + tx] = area == 0 ? 0 : sum / area;
      }
    }
    return out;
  }

  static double _overlap(double a0, double a1, double p) {
    final lo = a0 > p ? a0 : p;
    final hi = a1 < p + 1 ? a1 : p + 1;
    return hi - lo;
  }
}

/// 64-bit horizontal difference hash: 9×8 area-averaged luma; bit
/// (row r, col c) = left pixel brighter than its right neighbour.
int dHash64(GrayImage img) {
  final g = img.areaResize(9, 8);
  var h = 0;
  for (var r = 0; r < 8; r++) {
    for (var c = 0; c < 8; c++) {
      h <<= 1;
      if (g[r * 9 + c] > g[r * 9 + c + 1]) h |= 1;
    }
  }
  return h;
}

/// Luma step (0..255 scale, on the 9×8 average) below which a dHash bit
/// is NOISE, not structure: flat walls / blown-out whites / black frames
/// flip bits on recompression alone. Evidence (2026-10-14, real clips):
/// unmasked, flat same-clip pairs scored 14/64; masking at 2 brought
/// every same-clip pair to ≤ 10 while different scenes stayed ≥ 15.
const kHashNoiseEps = 2.0;

/// dHash + its CONFIDENCE mask (bits whose neighbour difference clears
/// [kHashNoiseEps]) + the source aspect ratio.
class ClipSignature {
  const ClipSignature(this.hash, this.mask, this.aspect);

  factory ClipSignature.of(GrayImage img) {
    final g = img.areaResize(9, 8);
    var h = 0, m = 0;
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        h <<= 1;
        m <<= 1;
        final d = g[r * 9 + c] - g[r * 9 + c + 1];
        if (d > 0) h |= 1;
        if (d.abs() >= kHashNoiseEps) m |= 1;
      }
    }
    return ClipSignature(h, m, img.aspect);
  }

  final int hash;
  final int mask;
  final double aspect;
}

/// Differing bits among the bits that are confident on EITHER side
/// ([confident] = how many bits were compared at all — near zero means
/// both images are flat and the distance proves nothing).
({int bits, int confident}) signatureDistance(
    ClipSignature a, ClipSignature b) {
  final m = a.mask | b.mask;
  return (
    bits: hammingDistance((a.hash ^ b.hash) & m, 0),
    confident: hammingDistance(m, 0),
  );
}

/// Number of differing bits between two 64-bit hashes.
int hammingDistance(int a, int b) {
  var x = a ^ b;
  var n = 0;
  while (x != 0) {
    x &= x - 1;
    n++;
  }
  return n;
}

/// Decodes JPEG/PNG [bytes] to a [GrayImage]; null when undecodable.
/// [maxSide] caps the decode size (hashing needs ~9 px; 64 keeps a
/// little detail for the area average without decoding full frames).
Future<GrayImage?> decodeGray(Uint8List bytes, {int maxSide = 64}) async {
  try {
    final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(buf);
    final w = desc.width, h = desc.height;
    final long = w > h ? w : h;
    int? tw, th;
    if (long > maxSide) {
      tw = (w * maxSide / long).round().clamp(1, maxSide);
      th = (h * maxSide / long).round().clamp(1, maxSide);
    }
    final codec = await desc.instantiateCodec(targetWidth: tw, targetHeight: th);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final iw = img.width, ih = img.height;
    img.dispose();
    codec.dispose();
    desc.dispose();
    buf.dispose();
    if (data == null) return null;
    // Aspect from the ORIGINAL dimensions (the scaled decode rounds).
    final gray = GrayImage.fromRgba(data.buffer.asUint8List(), iw, ih);
    return _WithAspect(gray, w / h);
  } catch (_) {
    return null;
  }
}

/// A decoded image that remembers its pre-downscale aspect ratio.
class _WithAspect extends GrayImage {
  _WithAspect(GrayImage g, this._aspect) : super(g.width, g.height, g.luma);
  final double _aspect;
  @override
  double get aspect => _aspect;
}
