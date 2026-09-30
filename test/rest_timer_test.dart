import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/rest_timer.dart';

void main() {
  final t0 = DateTime(2026, 9, 30, 12, 0, 0);

  group('RestTimer', () {
    test('starts idle', () {
      final rt = RestTimer();
      expect(rt.state, RestTimerState.idle);
      expect(rt.remaining(t0), Duration.zero);
      expect(rt.progress(t0), 0);
    });

    test('start sets running with full remaining', () {
      final rt = RestTimer()..start(const Duration(minutes: 3), now: t0);
      expect(rt.state, RestTimerState.running);
      expect(rt.remaining(t0), const Duration(minutes: 3));
      expect(rt.endsAt, t0.add(const Duration(minutes: 3)));
    });

    test('remaining decreases with the clock (survives skipped ticks)', () {
      final rt = RestTimer()..start(const Duration(minutes: 3), now: t0);
      // Jump 2m30 forward — as if the app was backgrounded and no ticks
      // fired. Remaining is derived from wall clock, not a tick count.
      final later = t0.add(const Duration(seconds: 150));
      expect(rt.remaining(later), const Duration(seconds: 30));
    });

    test('remaining floors at zero past the end', () {
      final rt = RestTimer()..start(const Duration(minutes: 3), now: t0);
      final after = t0.add(const Duration(minutes: 5));
      expect(rt.remaining(after), Duration.zero);
    });

    test('progress runs 0..1', () {
      final rt = RestTimer()..start(const Duration(seconds: 100), now: t0);
      expect(rt.progress(t0), 0);
      expect(rt.progress(t0.add(const Duration(seconds: 50))), 0.5);
      expect(rt.progress(t0.add(const Duration(seconds: 200))), 1);
    });

    test('isComplete fires once then flips state to done', () {
      final rt = RestTimer()..start(const Duration(minutes: 3), now: t0);
      final during = t0.add(const Duration(minutes: 1));
      expect(rt.isComplete(during), isFalse);
      final after = t0.add(const Duration(minutes: 3, seconds: 1));
      expect(rt.isComplete(after), isTrue); // first detection
      expect(rt.state, RestTimerState.done);
      expect(rt.isComplete(after), isFalse); // no longer running
    });

    test('stop clears back to idle', () {
      final rt = RestTimer()..start(const Duration(minutes: 3), now: t0);
      rt.stop();
      expect(rt.state, RestTimerState.idle);
      expect(rt.remaining(t0), Duration.zero);
      expect(rt.endsAt, isNull);
    });

    test('zero/negative duration is a no-op idle', () {
      final rt = RestTimer()..start(Duration.zero, now: t0);
      expect(rt.state, RestTimerState.idle);
    });
  });

  group('formatting', () {
    test('formatRestRemaining renders M:SS', () {
      expect(formatRestRemaining(const Duration(minutes: 3)), '3:00');
      expect(formatRestRemaining(const Duration(seconds: 65)), '1:05');
      expect(formatRestRemaining(const Duration(seconds: 5)), '0:05');
      expect(formatRestRemaining(const Duration(seconds: -3)), '0:00');
    });

    test('restPresetLabel', () {
      expect(restPresetLabel(180), '3 min');
      expect(restPresetLabel(300), '5 min');
      expect(restPresetLabel(45), '45s');
    });

    test('presets are 3 and 5 minutes', () {
      expect(kRestTimerPresetsSec, [180, 300]);
    });
  });
}
