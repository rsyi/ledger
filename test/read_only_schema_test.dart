// ignore_for_file: avoid_print
/// Tests for `read_only` flag on ViewSchema:
///   1. Pure-Dart overlay parser (input_parser.dart)
///   2. Engine adapter round-trip (engine_schema_adapter.dart)
///
/// Run RED first (before the implementation), then GREEN after.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/input_parser.dart';
import 'package:airledger/services/engine_schema_adapter.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ViewSchema _baseView() => ViewSchema(
      name: 'ascents',
      datasource: 'gsheets',
      table: 'kaya_ascents',
      entities: [],
      dimensions: const [],
      measures: const [],
    );

// ---------------------------------------------------------------------------
// 1. Pure-Dart overlay path
// ---------------------------------------------------------------------------

void main() {
  group('input_parser: read_only overlay', () {
    test('read_only: true is parsed and applied to view', () {
      const yaml = '''
target: ascents.view.yml
read_only: true
''';
      final overlay = parseInputOverlay(yaml);
      final view = applyInputOverlay(_baseView(), overlay);
      expect(view.readOnly, isTrue);
      expect(view.hasInputOverlay, isTrue);
    });

    test('read_only absent defaults to false', () {
      const yaml = '''
target: ascents.view.yml
''';
      final overlay = parseInputOverlay(yaml);
      final view = applyInputOverlay(_baseView(), overlay);
      expect(view.readOnly, isFalse);
    });

    test('read_only: false is explicit-false', () {
      const yaml = '''
target: ascents.view.yml
read_only: false
''';
      final overlay = parseInputOverlay(yaml);
      final view = applyInputOverlay(_baseView(), overlay);
      expect(view.readOnly, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Engine adapter round-trip
  // ---------------------------------------------------------------------------

  group('engine_schema_adapter: read_only round-trip', () {
    test('viewSchemaToEngineJson emits read_only: true', () {
      final view = ViewSchema(
        name: 'ascents',
        datasource: 'gsheets',
        table: 'kaya_ascents',
        entities: const [],
        dimensions: const [],
        measures: const [],
        hasInputOverlay: true,
        readOnly: true,
      );
      final json = viewSchemaToEngineJson(view);
      expect(json['read_only'], isTrue);
    });

    test('viewSchemaToEngineJson emits read_only: false when not set', () {
      final view = ViewSchema(
        name: 'ascents',
        datasource: 'gsheets',
        table: 'kaya_ascents',
        entities: const [],
        dimensions: const [],
        measures: const [],
      );
      final json = viewSchemaToEngineJson(view);
      expect(json['read_only'], isFalse);
    });

    test('viewSchemaFromEngineJson reads read_only: true', () {
      final json = <String, dynamic>{
        'name': 'ascents',
        'datasource': 'gsheets',
        'table': 'kaya_ascents',
        'dimensions': <dynamic>[],
        'has_input_overlay': true,
        'read_only': true,
      };
      final view = viewSchemaFromEngineJson(json);
      expect(view.readOnly, isTrue);
    });

    test('viewSchemaFromEngineJson defaults read_only to false when absent', () {
      final json = <String, dynamic>{
        'name': 'ascents',
        'datasource': 'gsheets',
        'table': 'kaya_ascents',
        'dimensions': <dynamic>[],
        'has_input_overlay': false,
      };
      final view = viewSchemaFromEngineJson(json);
      expect(view.readOnly, isFalse);
    });

    test('round-trip preserves read_only: true', () {
      final original = ViewSchema(
        name: 'ascents',
        datasource: 'gsheets',
        table: 'kaya_ascents',
        entities: const [],
        dimensions: const [],
        measures: const [],
        hasInputOverlay: true,
        readOnly: true,
      );
      final json = viewSchemaToEngineJson(original);
      final roundTripped = viewSchemaFromEngineJson(json);
      expect(roundTripped.readOnly, isTrue);
    });

    test('round-trip preserves read_only: false', () {
      final original = ViewSchema(
        name: 'ascents',
        datasource: 'gsheets',
        table: 'kaya_ascents',
        entities: const [],
        dimensions: const [],
        measures: const [],
      );
      final json = viewSchemaToEngineJson(original);
      final roundTripped = viewSchemaFromEngineJson(json);
      expect(roundTripped.readOnly, isFalse);
    });
  });
}
