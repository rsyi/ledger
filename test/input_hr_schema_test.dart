import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/input_parser.dart';

const _cardio = '''
target: cardio.view.yml
fields:
  start_time:
    widget: timer
    hr_max_target: max_hr
    ladders:
      - { label: "Zone 4 reached", target: zone4_reached, hr_pct: 80 }
      - { label: "Zone 5 reached", target: zone5_reached }
    stop_target: total_time
''';

void main() {
  test('parses hr_pct and hr_max_target', () {
    final overlay = parseInputOverlay(_cardio);
    final spec = overlay.dimensions['start_time']!.input!;
    expect(spec.hrMaxTarget, 'max_hr');
    expect(spec.ladders![0].hrPct, 80);
    expect(spec.ladders![1].hrPct, isNull);
  });

  test('absent hr keys stay null', () {
    final overlay = parseInputOverlay('''
target: cardio.view.yml
fields:
  start_time:
    widget: timer
    ladders:
      - { label: Z4, target: zone4_reached }
''');
    final spec = overlay.dimensions['start_time']!.input!;
    expect(spec.hrMaxTarget, isNull);
    expect(spec.ladders![0].hrPct, isNull);
  });
}
