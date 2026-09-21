// Undo-logging mapping round-trip: rowId → planned-entry JSON persisted
// through PlanStore (same shared_preferences backing as the plan itself),
// pruned after 14 days and dropped on removeUndo.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:airledger/models/planned_entry.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/plan_store.dart';

ViewSchema _view() => ViewSchema(
      name: 'strength',
      datasource: 'gsheets',
      table: 'strength',
      entities: const [],
      measures: const [],
      dateField: 'date',
      dimensions: [
        Dimension(name: 'id', type: DimensionType.string, expr: 'id'),
        Dimension(name: 'date', type: DimensionType.date, expr: 'Date'),
        Dimension(
            name: 'exercise', type: DimensionType.string, expr: 'Exercise'),
        Dimension(name: 'weight', type: DimensionType.number, expr: 'Weight'),
        Dimension(name: 'reps', type: DimensionType.number, expr: 'Reps'),
      ],
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final t0 = DateTime(2026, 9, 21, 8, 30);

  PlannedEntry entry(ViewSchema view) => PlannedEntry.create(
        view: view,
        date: DateTime(2026, 9, 21),
        values: {'exercise': 'Barbell Squat', 'reps': 1, 'weight': 290},
        templateName: 'program: week plan',
      );

  test('put → load round-trips the full planned entry', () async {
    final view = _view();
    final e = entry(view);
    await PlanStore.putUndo(view, 'row-1', e, now: t0);

    final mappings = await PlanStore.undoMappings(view, now: t0);
    expect(mappings.keys, ['row-1']);
    final back = mappings['row-1']!;
    expect(back.localId, e.localId);
    expect(back.date, e.date);
    expect(back.templateName, 'program: week plan');
    expect(back.values['exercise'], 'Barbell Squat');
    expect(back.values['reps'], 1);
    expect(back.values['weight'], 290);
  });

  test('removeUndo drops exactly the one mapping', () async {
    final view = _view();
    await PlanStore.putUndo(view, 'row-1', entry(view), now: t0);
    await PlanStore.putUndo(view, 'row-2', entry(view), now: t0);
    await PlanStore.removeUndo(view, 'row-1');
    final mappings = await PlanStore.undoMappings(view, now: t0);
    expect(mappings.keys, ['row-2']);
  });

  test('mappings older than 14 days are pruned (and prune persists)',
      () async {
    final view = _view();
    await PlanStore.putUndo(view, 'old', entry(view), now: t0);
    await PlanStore.putUndo(view, 'fresh', entry(view),
        now: t0.add(const Duration(days: 10)));

    final later = t0.add(const Duration(days: 15));
    final mappings = await PlanStore.undoMappings(view, now: later);
    expect(mappings.keys, ['fresh']);

    // Prune persisted: even asking "as of t0" again, `old` stays gone.
    final again = await PlanStore.undoMappings(view, now: t0);
    expect(again.keys, ['fresh']);
  });

  test('restore path: entry re-added to the plan lands on its date',
      () async {
    final view = _view();
    final e = entry(view);
    await PlanStore.putUndo(view, 'row-1', e, now: t0);
    final restored = (await PlanStore.undoMappings(view, now: t0))['row-1']!;
    await PlanStore.addAll(view, [restored]);
    await PlanStore.removeUndo(view, 'row-1');

    final planned = await PlanStore.loadForDate(view, DateTime(2026, 9, 21));
    expect(planned.map((p) => p.localId), [e.localId]);
    expect(await PlanStore.undoMappings(view, now: t0), isEmpty);
  });
}
