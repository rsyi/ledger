import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/services/input_parser.dart';
import 'package:airledger/services/engine_schema_adapter.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/video_rpe.dart' show mediaIdFieldFor;

// Coverage for `widget: video` — the video-attach affordance used by
// the strength form (video_url). Value contract: a Google Photos deep
// link written by the app's picker flow, never typed; blank = no video.
// autofill stays false — carrying a past set's video forward would
// attach the wrong footage (fabricated data).

const _strength = '''
target: strength.view.yml
fields:
  video_url:
    widget: video
    autofill: false
  video_media_id:
    editable: false
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
  group('input_parser: video widget', () {
    test('parses widget: video with autofill opt-out', () {
      final overlay = parseInputOverlay(_strength);
      expect(
        overlay.dimensions['video_url']!.input!.widget,
        WidgetType.video,
      );
      expect(overlay.dimensions['video_url']!.input!.autofill, isFalse);
      // Paired media-id column is app-written only.
      expect(
        overlay.dimensions['video_media_id']!.input!.editable,
        isFalse,
      );
    });
  });

  group('engine_schema_adapter round-trip: video', () {
    final view = _minimalView(dimensions: [
      Dimension(
        name: 'video_url',
        type: DimensionType.string,
        expr: 'Video URL',
        input: InputSpec(widget: WidgetType.video, autofill: false),
      ),
    ]);

    test('emits "video" and round-trips back to WidgetType.video', () {
      final json = viewSchemaToEngineJson(view);
      final dims = json['dimensions'] as List;
      expect((dims[0]['input'] as Map)['widget'], 'video');
      final back = viewSchemaFromEngineJson(json);
      expect(back.dimensions[0].input!.widget, WidgetType.video);
    });
  });

  group('media-id sibling convention', () {
    test('video_url maps to video_media_id; bare names get _media_id', () {
      expect(mediaIdFieldFor('video_url'), 'video_media_id');
      expect(mediaIdFieldFor('clip'), 'clip_media_id');
    });
  });
}
