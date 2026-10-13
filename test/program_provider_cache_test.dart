// Perf #1 (2026-10-12): program.yaml is parsed ONCE per content change —
// the parsed map is cached keyed on the raw text, and a refetch that
// returns identical text reuses it. Parsed docs are deep plain +
// unmodifiable (sendable from the parse isolate).
import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/program_provider.dart';

void main() {
  setUp(() {
    ProgramProvider.clearCache();
    ProgramProvider.debugClearParsed();
  });

  test('identical raw text → one parse, the same parsed instance', () async {
    var text = 'version: 1\nroutine:\n  week:\n    mon: [squat, bench]\n';
    Future<String?> fetch(String p) async =>
        p == 'coach/program.yaml' ? text : null;

    final a = await ProgramProvider(fetch).load();
    // Bust the RAW cache: the refetch returns equal text (a new String).
    ProgramProvider.clearCache();
    text = 'version: 1\nroutine:\n  week:\n    mon: [squat, bench]\n'
        .split('')
        .join();
    final b = await ProgramProvider(fetch).load();
    expect(ProgramProvider.debugParseCount, 1);
    expect(identical(a.program, b.program), isTrue);
    expect(a.phase, isNull);

    // New content → re-parse.
    ProgramProvider.clearCache();
    text = 'version: 2\n';
    final c = await ProgramProvider(fetch).load();
    expect(ProgramProvider.debugParseCount, 2);
    expect(c.program!['version'], 2);
  });

  test('parsed docs are deep plain + unmodifiable; isolate parse equals '
      'inline parse', () async {
    const raw = 'a:\n  b: [1, {c: 2}]\n  8: {5: 0.811}\n';
    final inline = parsePlainYamlMap(raw)!;
    final a = inline['a'] as Map;
    expect(a['b'], [1, {'c': 2}]);
    expect((a[8] as Map)[5], 0.811); // int keys survive
    expect(() => inline['x'] = 1, throwsUnsupportedError);
    expect(() => (a['b'] as List).add(3), throwsUnsupportedError);
    expect(parsePlainYamlMap('- not a map'), isNull);
    expect(parsePlainYamlMap('a: [unclosed'), isNull);

    // Force the worker-isolate path (off under flutter test by default).
    final saved = ProgramProvider.isolateThresholdBytes;
    ProgramProvider.isolateThresholdBytes = 0;
    addTearDown(() => ProgramProvider.isolateThresholdBytes = saved);
    final docs = await ProgramProvider(
            (p) async => p == 'coach/program.yaml' ? raw : null)
        .load();
    expect(docs.program, inline);
  });
}
