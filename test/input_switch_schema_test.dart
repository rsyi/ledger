import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/input_parser.dart';
import 'package:airledger/services/engine_schema_adapter.dart';
import 'package:airledger/models/view_schema.dart';

// Coverage for `widget: switch` — the tri-state boolean toggle used by
// the strength equipment fields (paused/belted/wrist_wraps/knee_sleeves).
// Value contract: nullable bool; blank = not recorded (never false).

const _strength = '''
target: strength.view.yml
fields:
  belted:
    widget: switch
    autofill: false
    show_when:
      exercise:
        in: [Barbell Squat, Barbell Deadlift]
  paused:
    widget: switch
''';

ViewSchema _minimalView({required List<Dimension> dimensions}) {
  return ViewSchema(
    name: 'test',
    datasource: 'gsheets',
    table: 'test_table',
    entities: [],
    dimensions: dimensions,
    measures: [],
  );
}

void main() {
  group('input_parser: switch widget', () {
    test('parses widget: switch', () {
      final overlay = parseInputOverlay(_strength);
      expect(
        overlay.dimensions['belted']!.input!.widget,
        WidgetType.switch_,
      );
      expect(overlay.dimensions['belted']!.input!.autofill, isFalse);
      expect(
        overlay.dimensions['paused']!.input!.widget,
        WidgetType.switch_,
      );
    });

    test('show_when { exercise: { in: [...] } } gates a switch field', () {
      final overlay = parseInputOverlay(_strength);
      final dim = Dimension(
        name: 'belted',
        type: DimensionType.boolean,
        expr: 'Belted',
        input: overlay.dimensions['belted']!.input,
        showWhen: overlay.dimensions['belted']!.showWhen,
      );
      expect(dim.isVisibleGiven({'exercise': 'Barbell Squat'}), isTrue);
      expect(dim.isVisibleGiven({'exercise': 'Barbell Deadlift'}), isTrue);
      expect(
        dim.isVisibleGiven({'exercise': 'Flat Barbell Bench Press'}),
        isFalse,
      );
      expect(dim.isVisibleGiven({}), isFalse);
    });
  });

  group('engine_schema_adapter round-trip: switch', () {
    final view = _minimalView(dimensions: [
      Dimension(
        name: 'belted',
        type: DimensionType.boolean,
        expr: 'Belted',
        input: InputSpec(widget: WidgetType.switch_, autofill: false),
      ),
    ]);

    test('emits "switch" and round-trips back to WidgetType.switch_', () {
      final json = viewSchemaToEngineJson(view);
      final dims = json['dimensions'] as List;
      expect((dims[0]['input'] as Map)['widget'], 'switch');
      final back = viewSchemaFromEngineJson(json);
      expect(back.dimensions[0].input!.widget, WidgetType.switch_);
    });
  });
}
