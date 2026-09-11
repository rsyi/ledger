import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/hr_session.dart';

void main() {
  group('decodeHeartRate', () {
    test('uint8 format (flags bit 0 clear)', () {
      expect(decodeHeartRate([0x00, 142]), 142);
    });
    test('uint16 little-endian format (flags bit 0 set)', () {
      expect(decodeHeartRate([0x01, 0x2C, 0x01]), 300);
    });
    test('other flag bits (energy/RR present) do not affect decode', () {
      expect(decodeHeartRate([0x16, 155, 0x10, 0x02]), 155);
    });
    test('malformed payloads return null', () {
      expect(decodeHeartRate([]), isNull);
      expect(decodeHeartRate([0x00]), isNull);
      expect(decodeHeartRate([0x01, 0x2C]), isNull);
    });
  });

  group('HrSession', () {
    const z4 =
        TimerLadder(label: 'Zone 4', target: 'zone4_reached', hrPct: 80);
    const z5 =
        TimerLadder(label: 'Zone 5', target: 'zone5_reached', hrPct: 90);

    test('fires each ladder once, at its threshold', () {
      final s = HrSession(maxHr: 200, ladders: const [z4, z5]);
      expect(s.onSample(150), isEmpty); // 75% of 200 — below zone 4
      expect(s.onSample(160).map((l) => l.target), ['zone4_reached']);
      expect(s.onSample(165), isEmpty); // zone 4 already fired
      expect(s.onSample(185).map((l) => l.target), ['zone5_reached']);
      expect(s.onSample(190), isEmpty);
    });

    test('one spike can fire both zones in a single sample', () {
      final s = HrSession(maxHr: 200, ladders: const [z4, z5]);
      expect(s.onSample(185).map((l) => l.target),
          ['zone4_reached', 'zone5_reached']);
    });

    test('tracks session max across samples', () {
      final s = HrSession(maxHr: 200, ladders: const [z4]);
      s.onSample(120);
      s.onSample(171);
      s.onSample(155);
      expect(s.sessionMax, 171);
    });

    test('null maxHr disables zone firing but still tracks max', () {
      final s = HrSession(maxHr: null, ladders: const [z4, z5]);
      expect(s.onSample(190), isEmpty);
      expect(s.sessionMax, 190);
    });

    test('ladders without hr_pct are ignored', () {
      const manual = TimerLadder(label: 'M', target: 'manual_field');
      final s = HrSession(maxHr: 200, ladders: const [manual, z4]);
      expect(s.onSample(190).map((l) => l.target), ['zone4_reached']);
    });

    test('bpm 0 (contact loss) is ignored entirely', () {
      final s = HrSession(maxHr: 200, ladders: const [z4]);
      expect(s.onSample(0), isEmpty);
      expect(s.sessionMax, isNull);
      s.onSample(120);
      s.onSample(0);
      expect(s.sessionMax, 120);
    });

    test('maxHr 0 never fires ladders but still tracks max', () {
      final s = HrSession(maxHr: 0, ladders: const [z4, z5]);
      expect(s.onSample(190), isEmpty);
      expect(s.sessionMax, 190);
    });
  });
}
