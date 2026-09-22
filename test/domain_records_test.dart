import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/domain_config.dart';
import 'package:airledger/services/domain_records.dart';

ViewSchema view({ListDisplay? listDisplay}) => ViewSchema(
      name: 'climbing',
      datasource: 'gsheets',
      table: 'kaya_ascents',
      dateField: 'date',
      entities: const [],
      dimensions: [
        Dimension(name: 'date', type: DimensionType.date, expr: 'date'),
        Dimension(name: 'grade', type: DimensionType.string, expr: 'grade'),
      ],
      measures: const [],
      listDisplay: listDisplay,
    );

void main() {
  group('groupRecordsByDay', () {
    test('newest day first; within a day newest timestamp first', () {
      final groups = groupRecordsByDay([
        {'eaten_at': '2026-09-20 08:00:00', 'meal': 'oats'},
        {'eaten_at': '2026-09-21 12:00:00', 'meal': 'salad'},
        {'eaten_at': '2026-09-20 19:30:00', 'meal': 'steak'},
        {'meal': 'undated'}, // no date → dropped
      ], dateKey: 'eaten_at');
      expect(groups, hasLength(2));
      expect(groups[0].day, DateTime.utc(2026, 9, 21));
      expect(groups[0].records.single['meal'], 'salad');
      expect(groups[1].day, DateTime.utc(2026, 9, 20));
      expect(
        groups[1].records.map((r) => r['meal']),
        ['steak', 'oats'],
      );
    });

    test('date-only strings group fine (climbing rows)', () {
      final groups = groupRecordsByDay([
        {'date': '2026-09-21', 'grade': 'v5'},
        {'date': '2026-09-21', 'grade': 'v3'},
      ], dateKey: 'date');
      expect(groups.single.records, hasLength(2));
    });
  });

  group('recordLineParts', () {
    test('configured fields in order; blanks skipped; units appended', () {
      final parts = recordLineParts(
        view(),
        const [
          DomainListField(field: 'meal'),
          DomainListField(field: 'calories', unit: 'kcal'),
          DomainListField(field: 'protein_g', unit: 'g'),
        ],
        {'meal': 'oats', 'calories': 222.0, 'protein_g': '', 'x': 1},
      );
      // 222.0 renders as an integer; empty protein dropped.
      expect(parts, ['oats', '222 kcal']);
    });

    test('non-integer numbers keep their decimals', () {
      final parts = recordLineParts(
        view(),
        const [DomainListField(field: 'protein_g', unit: 'g')],
        {'protein_g': '42.5'},
      );
      expect(parts, ['42.5 g']);
    });

    test('no list_fields → falls back to the view list_display', () {
      final parts = recordLineParts(
        view(
          listDisplay: ListDisplay(
            title: 'grade',
            subtitle: r'${ascent_type} · ${gym}',
          ),
        ),
        const [],
        {'grade': 'v5', 'ascent_type': 'Flash', 'gym': 'Movement'},
      );
      expect(parts, ['v5', 'Flash · Movement']);
    });
  });
}
