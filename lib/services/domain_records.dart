/// Read-friendly record list — pure assembly for the integration-domain
/// record view (app-IA redesign P3). The UI (domain_screen.dart) stays
/// layout-only: day grouping and line formatting live here, unit-tested.
///
/// One line per record, newest first, salient fields only ("v5 · Yellow
/// · Movement Gowanus · Flash"). Field choice comes from the domain's
/// declared `list_fields:` (dashboards.yaml); domains that don't declare
/// any fall back to the view's `list_display` title/subtitle.
library;

import '../models/view_schema.dart';
import 'domain_config.dart';
import 'list_display_render.dart';

/// One day's worth of records, newest-in-day first.
class DayGroup {
  final DateTime day;
  final List<Map<String, Object?>> records;
  const DayGroup({required this.day, required this.records});
}

/// Groups records by the UTC day of [dateKey], newest day first; within
/// a day, newest raw timestamp first (meals' `eaten_at` carries a time;
/// date-only values tie and keep their relative order). Records without
/// a parseable date are dropped — an undated row has no home in a
/// date-grouped list.
List<DayGroup> groupRecordsByDay(
  Iterable<Map<String, Object?>> records, {
  required String dateKey,
}) {
  final byDay = <DateTime, List<({DateTime ts, Map<String, Object?> r})>>{};
  for (final r in records) {
    final ts = _asDateTime(r[dateKey]);
    if (ts == null) continue;
    final day = DateTime.utc(ts.year, ts.month, ts.day);
    (byDay[day] ??= []).add((ts: ts, r: r));
  }
  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final d in days)
      DayGroup(
        day: d,
        records: [
          // Stable sort (List.sort isn't): decorate with the original
          // index so date-only ties keep their sheet order.
          for (final e in (byDay[d]!
                .asMap()
                .entries
                .toList()
              ..sort((a, b) {
                final c = b.value.ts.compareTo(a.value.ts);
                return c != 0 ? c : a.key.compareTo(b.key);
              })))
            e.value.r,
        ],
      ),
  ];
}

/// The display parts of one record line, in order — the UI joins them
/// with " · ". Configured [fields] win (blank/absent values skipped,
/// numeric values compacted, units appended); an empty config falls
/// back to the view's `list_display` title + subtitle.
List<String> recordLineParts(
  ViewSchema view,
  List<DomainListField> fields,
  Map<String, Object?> record,
) {
  if (fields.isEmpty) {
    final title = ListDisplayRender.title(view, record);
    return [
      if (title.trim().isNotEmpty) title,
      ?ListDisplayRender.subtitle(view, record),
    ];
  }
  final parts = <String>[];
  for (final f in fields) {
    final raw = record[f.field];
    final s = raw?.toString().trim() ?? '';
    if (s.isEmpty) continue;
    final n = raw is num ? raw : num.tryParse(s);
    final display = n == null
        ? s
        : (n == n.roundToDouble() ? n.round().toString() : n.toString());
    parts.add(f.unit == null ? display : '$display ${f.unit}');
  }
  return parts;
}

DateTime? _asDateTime(Object? v) =>
    v is DateTime ? v : DateTime.tryParse(v?.toString() ?? '');
