import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/input_parser.dart';
import 'package:airledger/services/engine_schema_adapter.dart';
import 'package:airledger/models/view_schema.dart';

// Coverage for the per-field `autofill` input-overlay key.
// `autofill: false` opts a field out of exercise-history autofill in
// the form (subjective per-set fields like rpe/notes must never carry
// over from a previous session).

const _strength = '''
target: strength.view.yml
fields:
  rpe:
    widget: number
    autofill: false
  weight:
    widget: number
    required: true
''';

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

void main() {
  group('input_parser: autofill', () {
    test('parses autofill: false; absent defaults to true', () {
      final overlay = parseInputOverlay(_strength);
      expect(overlay.dimensions['rpe']!.input!.autofill, isFalse);
      expect(overlay.dimensions['weight']!.input!.autofill, isTrue);
    });

    test('autofill alone marks the field as having form config', () {
      final overlay = parseInputOverlay('''
target: strength.view.yml
fields:
  notes:
    autofill: false
''');
      expect(overlay.dimensions['notes']!.input, isNotNull);
      expect(overlay.dimensions['notes']!.input!.autofill, isFalse);
    });
  });

  group('engine_schema_adapter round-trip: autofill', () {
    final view = _minimalView(dimensions: [
      Dimension(
        name: 'rpe',
        type: DimensionType.number,
        expr: 'rpe',
        input: InputSpec(widget: WidgetType.number, autofill: false),
      ),
      Dimension(
        name: 'weight',
        type: DimensionType.number,
        expr: 'weight',
        input: InputSpec(widget: WidgetType.number),
      ),
    ]);

    test('viewSchemaToEngineJson emits autofill', () {
      final json = viewSchemaToEngineJson(view);
      final dims = json['dimensions'] as List;
      expect((dims[0]['input'] as Map)['autofill'], isFalse);
      expect((dims[1]['input'] as Map)['autofill'], isTrue);
    });

    test('round-trips autofill through viewSchemaFromEngineJson', () {
      final back = viewSchemaFromEngineJson(viewSchemaToEngineJson(view));
      expect(back.dimensions[0].input!.autofill, isFalse);
      expect(back.dimensions[1].input!.autofill, isTrue);
    });

    test('engine JSON without the key defaults to true', () {
      // Older engine dylibs / cached view JSON won't carry the key.
      final json = viewSchemaToEngineJson(view);
      final dims = json['dimensions'] as List;
      (dims[1]['input'] as Map).remove('autofill');
      final back = viewSchemaFromEngineJson(json);
      expect(back.dimensions[1].input!.autofill, isTrue);
    });
  });
}
