// Pins every `kind` tag emitted by integration transforms against the
// engine's CellValue serde enum (~/repos/airledger/src/value.rs):
//
//   #[serde(tag = "kind", content = "value")]
//   #[serde(rename_all = "snake_case")]
//   enum CellValue { Null, Bool, Int, Float, String, Date, DateTime }
//
// i.e. the ONLY legal tags are: null, bool, int, float, string, date,
// date_time. Anything else fails engine-side batch ingest with
// `EngineError: batch json: unknown variant` — which is exactly how the
// Macrofactor `datetime` (should be `date_time`) bug surfaced on
// device. This test statically scans the transform sources so any new
// or renamed tag is caught at test time, not on the phone.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The engine's CellValue variant tags, snake_cased by serde.
const engineKinds = {
  'null',
  'bool',
  'int',
  'float',
  'string',
  'date',
  'date_time',
};

void main() {
  // Every transform that builds kind-tagged ingest records.
  final sources = [
    'lib/services/integrations/kaya.dart',
    'lib/services/integrations/macrofactor.dart',
    'lib/services/integrations/withings.dart',
  ];

  // Any `'kind': '<tag>'` or `"kind": "<tag>"` literal.
  final kindRe = RegExp('''['"]kind['"]\\s*:\\s*['"]([^'"]+)['"]''');

  for (final path in sources) {
    test('$path emits only engine CellValue kind tags', () {
      final src = File(path).readAsStringSync();
      final tags =
          kindRe.allMatches(src).map((m) => m.group(1)!).toSet();
      expect(tags, isNotEmpty,
          reason: '$path should emit kind-tagged records — if the '
              'transform moved, update the sources list in this test');
      for (final tag in tags) {
        expect(engineKinds, contains(tag),
            reason: '$path emits kind "$tag" which is not a CellValue '
                'serde variant — the engine will reject the batch with '
                '"unknown variant". Legal tags: $engineKinds. '
                '(Common trap: `datetime` must be `date_time`.)');
      }
    });
  }

  test('no integration source anywhere emits the bad `datetime` tag', () {
    final dir = Directory('lib/services/integrations');
    final bad = <String>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      for (final m in kindRe.allMatches(f.readAsStringSync())) {
        if (!engineKinds.contains(m.group(1))) {
          bad.add('${f.path}: kind "${m.group(1)}"');
        }
      }
    }
    expect(bad, isEmpty);
  });
}
