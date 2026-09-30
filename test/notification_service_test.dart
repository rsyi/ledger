import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/notification_service.dart';

void main() {
  group('composePostLogNotification', () {
    test('what-only when no training tally', () {
      expect(
        composePostLogNotification(what: 'lunch — 620 kcal'),
        'Logged: lunch — 620 kcal.',
      );
    });

    test('lifts-hit tally', () {
      expect(
        composePostLogNotification(
          what: 'squat 5×260',
          liftsHit: 2,
          liftsPlanned: 4,
        ),
        'Logged: squat 5×260. 2 of 4 lifts hit today.',
      );
    });

    test('lifts-hit with climb still to come', () {
      expect(
        composePostLogNotification(
          what: 'squat 5×260',
          liftsHit: 2,
          liftsPlanned: 4,
          climbToCome: true,
        ),
        'Logged: squat 5×260. 2 of 4 lifts hit today; climbing still to '
        'come.',
      );
    });

    test('climb-to-come without a lift tally', () {
      expect(
        composePostLogNotification(what: 'lunch — 620 kcal', climbToCome: true),
        'Logged: lunch — 620 kcal. Climbing still to come.',
      );
    });

    test('zero planned lifts falls back to what-only', () {
      expect(
        composePostLogNotification(
          what: 'row 3×10',
          liftsHit: 0,
          liftsPlanned: 0,
        ),
        'Logged: row 3×10.',
      );
    });
  });

  group('restDoneBody', () {
    test('names whole-minute presets', () {
      expect(restDoneBody(const Duration(minutes: 3)),
          'Your 3-minute rest is up — back to it.');
      expect(restDoneBody(const Duration(minutes: 5)),
          'Your 5-minute rest is up — back to it.');
    });

    test('generic for odd durations', () {
      expect(restDoneBody(const Duration(seconds: 90)),
          'Rest is up — back to it.');
    });
  });
}
