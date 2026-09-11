import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/input_parser.dart';
import 'package:airledger/services/engine_schema_adapter.dart';
import 'package:airledger/models/view_schema.dart';

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

// ---------------------------------------------------------------------------
// Minimal ViewSchema helpers
// ---------------------------------------------------------------------------

ViewSchema _minimalView({required List<Dimension> dimensions}) {
  return ViewSchema(
    name: 'test',
    datasource: 'bigquery',
    table: 'test_table',
    entities: [],
    dimensions: dimensions,
    measures: [],
  );
}

Dimension _timerDimension({required InputSpec input}) {
  return Dimension(
    name: 'start_time',
    type: DimensionType.datetime,
    expr: 'start_time',
    input: input,
  );
}

// ---------------------------------------------------------------------------

void main() {
  test('parses hr_pct and hr_max_target', () {
    final overlay = parseInputOverlay(_cardio);
    final spec = overlay.dimensions['start_time']!.input!;
    expect(spec.hrMaxTarget, 'max_hr');
    expect(spec.ladders![0].hrPct, 80);
    expect(spec.ladders![0].hrPct, isA<double>());
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

  group('engine_schema_adapter round-trip: hr_pct / hr_max_target', () {
    // Build a ViewSchema with HR fields and round-trip it through the adapter.
    final hrSpec = InputSpec(
      widget: WidgetType.timer,
      hrMaxTarget: 'max_hr',
      ladders: [
        const TimerLadder(label: 'Zone 4 reached', target: 'zone4_reached', hrPct: 80),
        const TimerLadder(label: 'Zone 5 reached', target: 'zone5_reached'),
      ],
    );

    final hrView = _minimalView(
      dimensions: [_timerDimension(input: hrSpec)],
    );

    // Build a ViewSchema WITHOUT HR fields for the "absent == None" contract.
    final noHrSpec = InputSpec(
      widget: WidgetType.timer,
      ladders: [
        const TimerLadder(label: 'Zone 4 reached', target: 'zone4_reached'),
      ],
    );

    final noHrView = _minimalView(
      dimensions: [_timerDimension(input: noHrSpec)],
    );

    test('viewSchemaToEngineJson emits hr_pct and hr_max_target', () {
      final json = viewSchemaToEngineJson(hrView);
      final dims = json['dimensions'] as List;
      final inputMap = dims[0]['input'] as Map<String, dynamic>;
      final ladders = inputMap['ladders'] as List;

      // ladder[0] has hrPct
      expect(ladders[0]['hr_pct'], 80.0);

      // ladder[1] must NOT contain the key at all (Rust serde absent == None)
      expect((ladders[1] as Map<String, dynamic>).containsKey('hr_pct'), isFalse);

      // top-level input map contains hr_max_target
      expect(inputMap['hr_max_target'], 'max_hr');
    });

    test('viewSchemaToEngineJson omits hr keys entirely when absent', () {
      final json = viewSchemaToEngineJson(noHrView);
      final dims = json['dimensions'] as List;
      final inputMap = dims[0]['input'] as Map<String, dynamic>;
      final ladders = inputMap['ladders'] as List;

      expect((ladders[0] as Map<String, dynamic>).containsKey('hr_pct'), isFalse);
      expect(inputMap.containsKey('hr_max_target'), isFalse);
    });

    test('round-trips HR spec through viewSchemaFromEngineJson', () {
      final json = viewSchemaToEngineJson(hrView);
      final roundTripped = viewSchemaFromEngineJson(json);

      final dim = roundTripped.dimensions[0];
      final spec = dim.input!;

      expect(spec.hrMaxTarget, 'max_hr');
      expect(spec.ladders![0].hrPct, 80.0);
      expect(spec.ladders![0].hrPct, isA<double>());
      expect(spec.ladders![1].hrPct, isNull);
    });

    test('round-trips no-HR spec to nulls through viewSchemaFromEngineJson', () {
      final json = viewSchemaToEngineJson(noHrView);
      final roundTripped = viewSchemaFromEngineJson(json);

      final dim = roundTripped.dimensions[0];
      final spec = dim.input!;

      expect(spec.hrMaxTarget, isNull);
      expect(spec.ladders![0].hrPct, isNull);
    });
  });
}
