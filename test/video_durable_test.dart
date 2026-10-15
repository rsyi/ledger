import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/video_durable.dart';
import 'package:airledger/services/video_frames.dart';
import 'package:airledger/services/video_ref.dart';

// Offline durable extras captured at attach: the budgeted synced
// thumbnail, recording-metadata parsing, and the sibling fields written
// (only the dims the view declares).

/// Fake extractor whose JPEG size scales with (side² × quality) — the
/// ladder must walk down until the budget fits.
class _FakeExtractor implements FrameExtractor {
  _FakeExtractor({this.bytesPerUnit = 1.0, this.probeResult, this.fail = false});
  final double bytesPerUnit;
  final Map<String, Object?>? probeResult;
  final bool fail;
  final calls = <(int?, int)>[];

  @override
  Future<int> durationMs(String path) async =>
      (probeResult?['durationMs'] as int?) ?? 0;

  @override
  Future<Map<String, Object?>> probe(String path) async {
    if (fail) throw Exception('gone');
    return probeResult ?? const {};
  }

  @override
  Future<List<Uint8List>> framesAt(String path, List<int> timestampsMs,
      {int maxWidth = 512, int? maxSide, int quality = 70}) async {
    calls.add((maxSide, quality));
    if (fail) return const [];
    final side = maxSide ?? maxWidth;
    final n = (side * side * quality / 1000 * bytesPerUnit).round();
    return [Uint8List(n)];
  }
}

void main() {
  group('durable thumbnail budget', () {
    test('design target 200 px @ q70 when it fits ≤ 10 KB', () async {
      final x = _FakeExtractor(bytesPerUnit: 0.3); // 200²·70/1000·.3 = 840 B
      final t = await durableThumbJpeg(x, 'src', durationMs: 4000);
      expect(t, isNotNull);
      expect(t!.length, lessThanOrEqualTo(kThumbMaxBytes));
      expect(x.calls, [(200, 70)]);
    });

    test('walks the ladder down until the budget fits', () async {
      // 200@70 = 11.2 KB (over), 200@55 = 8.8 KB (fits).
      final x = _FakeExtractor(bytesPerUnit: 4.0);
      final t = await durableThumbJpeg(x, 'src', durationMs: 4000);
      expect(t!.length, lessThanOrEqualTo(kThumbMaxBytes));
      expect(x.calls, [(200, 70), (200, 55)]);
    });

    test('nothing fits → null (no oversized cell is ever written)',
        () async {
      final x = _FakeExtractor(bytesPerUnit: 100);
      expect(await durableThumbJpeg(x, 'src', durationMs: 4000), isNull);
      expect(x.calls, hasLength(kThumbLadder.length));
    });

    test('unreadable clip → null after one try', () async {
      final x = _FakeExtractor(fail: true);
      expect(await durableThumbJpeg(x, 'src', durationMs: 0), isNull);
      expect(x.calls, hasLength(1));
    });

    test('every ladder rung bounds the LONG side ≤ 200 px', () {
      for (final (side, q) in kThumbLadder) {
        expect(side, lessThanOrEqualTo(200));
        expect(q, inInclusiveRange(30, 70));
      }
    });
  });

  group('clip metadata parsing', () {
    test('MediaStore DATE_TAKEN + DURATION win', () {
      final ms = DateTime.utc(2026, 10, 12, 0, 41, 5).millisecondsSinceEpoch;
      final m = clipMetadataFrom(
        dateTakenMs: ms,
        pickerDurationMs: 18450,
        sizeBytes: 31000000,
        probe: {'durationMs': 18000, 'date': '20200101T000000.000Z'},
      );
      expect(m.takenAt, DateTime.fromMillisecondsSinceEpoch(ms));
      expect(m.takenAt!.isUtc, isFalse); // local wall clock
      expect(m.durationMs, 18450);
      expect(m.sizeBytes, 31000000);
    });

    test('falls back to the container date + probed duration', () {
      final m = clipMetadataFrom(
        probe: {'durationMs': 9001, 'date': '20261012T004105.000Z'},
      );
      expect(m.takenAt, DateTime.utc(2026, 10, 12, 0, 41, 5).toLocal());
      expect(m.durationMs, 9001);
    });

    test('retriever date variants; epoch-zero placeholders rejected', () {
      expect(parseRetrieverDate('20261012T004105Z'),
          DateTime.utc(2026, 10, 12, 0, 41, 5).toLocal());
      expect(parseRetrieverDate('20261012T004105'),
          DateTime.utc(2026, 10, 12, 0, 41, 5).toLocal());
      expect(parseRetrieverDate('20261012T004105.5Z'),
          DateTime.utc(2026, 10, 12, 0, 41, 5, 500).toLocal());
      expect(parseRetrieverDate('19040101T000000.000Z'), isNull);
      expect(parseRetrieverDate('19700101T000000.000Z'), isNull);
      expect(parseRetrieverDate('garbage'), isNull);
      expect(parseRetrieverDate(null), isNull);
    });

    test('zero / negative values are honest nulls', () {
      final m = clipMetadataFrom(
          dateTakenMs: 0, pickerDurationMs: 0, sizeBytes: -1,
          probe: {'durationMs': 0});
      expect(m.takenAt, isNull);
      expect(m.durationMs, isNull);
      expect(m.sizeBytes, isNull);
    });
  });

  group('captureDurableExtras → sibling fields', () {
    test('writes thumb data URI + taken_at + duration for declared dims',
        () async {
      final x = _FakeExtractor(
          bytesPerUnit: 0.3,
          probeResult: {'durationMs': 12000, 'date': '20261012T004105Z'});
      final e = await captureDurableExtras(extractor: x, source: 'src');
      final f = e.fieldsFor('video_url', (_) => true);
      expect(f['video_thumb'], startsWith(kThumbDataUriPrefix));
      expect(decodeThumbDataUri(f['video_thumb'] as String), e.thumbJpeg);
      expect(f['video_taken_at'], DateTime.utc(2026, 10, 12, 0, 41, 5).toLocal());
      expect(f['video_duration_ms'], 12000);
      expect(f.containsKey('video_photos_url'), isFalse);
    });

    test('an old schema without the siblings gets nothing', () async {
      final x = _FakeExtractor(probeResult: {'durationMs': 1000});
      final e = await captureDurableExtras(extractor: x, source: 'src');
      expect(e.fieldsFor('video_url', (d) => d == 'video_media_id'), isEmpty);
    });

    test('never throws on a dead clip — just empty extras', () async {
      final e = await captureDurableExtras(
          extractor: _FakeExtractor(fail: true), source: 'src');
      expect(e.thumbJpeg, isNull);
      expect(e.metadata.takenAt, isNull);
      expect(e.fieldsFor('video_url', (_) => true), isEmpty);
    });

    test('durableSiblingFields lists every app-written sibling', () {
      expect(durableSiblingFields('video_url'), [
        'video_thumb',
        'video_taken_at',
        'video_duration_ms',
        'video_photos_url',
      ]);
    });
  });
}
