import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/log_event_bus.dart';
import 'package:airledger/services/post_log_notifier.dart';

LogEvent ev(String view, Map<String, Object?> record) => LogEvent(view, record);

void main() {
  test('only creates notify — edits and deletes stay quiet', () {
    const row = {'exercise': 'Squat', 'reps': 5, 'weight': 260.0};
    expect(PostLogNotifier.notifies(const LogEvent('strength', row)), isTrue);
    expect(
        PostLogNotifier.notifies(const LogEvent('strength', row,
            kind: LogEventKind.deleted)),
        isFalse);
    expect(
        PostLogNotifier.notifies(const LogEvent('strength', row,
            kind: LogEventKind.updated)),
        isFalse);
    expect(PostLogNotifier.notifies(const LogEvent('program_moves', row)),
        isFalse);
  });

  group('describeLogBatch', () {
    test('single strength set names exercise reps×weight', () {
      expect(
        describeLogBatch([
          ev('strength', {'exercise': 'Squat', 'reps': 5, 'weight': 260.0}),
        ]),
        'Squat 5×260',
      );
    });

    test('single meal names meal + kcal', () {
      expect(
        describeLogBatch([
          ev('meals', {'meal': 'Lunch', 'calories': 620}),
        ]),
        'Lunch — 620 kcal',
      );
    });

    test('multiple strength sets roll up with the first exercise', () {
      expect(
        describeLogBatch([
          ev('strength', {'exercise': 'Bench', 'reps': 5, 'weight': 185.0}),
          ev('strength', {'exercise': 'Bench', 'reps': 5, 'weight': 185.0}),
          ev('strength', {'exercise': 'Bench', 'reps': 5, 'weight': 185.0}),
        ]),
        '3 sets (Bench)',
      );
    });

    test('mixed batch names the domains', () {
      expect(
        describeLogBatch([
          ev('strength', {'exercise': 'Squat', 'reps': 5, 'weight': 260.0}),
          ev('meals', {'meal': 'Snack', 'calories': 200}),
        ]),
        'meals + strength',
      );
    });

    test('cardio names its type', () {
      expect(describeLogBatch([ev('cardio', {'type': '4x4'})]), '4x4');
    });

    test('climbing', () {
      expect(describeLogBatch([ev('climbing', {'grade': 'V5'})]), 'a climb');
    });

    test('empty is a safe fallback', () {
      expect(describeLogBatch([]), 'an entry');
    });

    test('strength set with missing detail degrades to the exercise', () {
      expect(
        describeLogBatch([ev('strength', {'exercise': 'Row'})]),
        'Row',
      );
    });
  });
}
