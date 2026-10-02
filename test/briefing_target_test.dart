import 'package:airledger/services/briefing_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('evening run plans tomorrow', () {
    expect(briefingTargetDay(DateTime(2026, 10, 1, 23, 30)),
        DateTime(2026, 10, 2));
  });
  test('morning run plans today', () {
    expect(briefingTargetDay(DateTime(2026, 10, 2, 7, 5)),
        DateTime(2026, 10, 2));
  });
}
