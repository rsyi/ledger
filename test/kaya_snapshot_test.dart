import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/integrations/kaya_snapshot.dart';

void main() {
  test('summarizes count and latest ascent date', () {
    final rows = [
      ['date', 'grade', 'gym'],
      ['2026-09-15', 'v5', 'Movement Belmont'],
      ['2026-09-11', 'v4', 'Touchstone Hyperion'],
      ['2024-08-29', 'v2', 'Movement Belmont'],
    ];
    expect(
      kayaSnapshotStatus(rows),
      'Snapshot · 3 ascents · latest 2026-09-15 · refresh: export in Kaya',
    );
  });

  test('missing tab reads as no snapshot with instructions', () {
    expect(kayaSnapshotStatus(null),
        'No snapshot yet — Export Logbook in Kaya, then kaya_import');
    expect(kayaSnapshotStatus([]),
        'No snapshot yet — Export Logbook in Kaya, then kaya_import');
  });

  test('header-only tab reads as empty snapshot', () {
    expect(
      kayaSnapshotStatus([
        ['date', 'grade']
      ]),
      'Snapshot · 0 ascents · refresh: export in Kaya',
    );
  });

  test('tolerates missing date column and junk dates', () {
    expect(
      kayaSnapshotStatus([
        ['grade', 'gym'],
        ['v5', 'Movement'],
      ]),
      'Snapshot · 1 ascents · refresh: export in Kaya',
    );
    expect(
      kayaSnapshotStatus([
        ['date'],
        ['not-a-date'],
        ['2026-01-02'],
      ]),
      'Snapshot · 2 ascents · latest 2026-01-02 · refresh: export in Kaya',
    );
  });
}
