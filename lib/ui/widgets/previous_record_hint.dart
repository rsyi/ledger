import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/previous_record.dart';

/// Previous-record hint inside the strength form's weight field (right
/// side): "PR 275×5 @ 8.5" in the accent (tertiary) colour over a
/// smaller "last 260×5 @ 8 · Mon 10/12". Tapping either line opens that
/// set's day; long-pressing the PR line fills the weight field with it.
class PreviousRecordHint extends StatelessWidget {
  final PreviousRecord record;
  final void Function(RecordSet set) onOpen;
  final void Function(RecordSet set)? onFillWeight;

  const PreviousRecordHint({
    super.key,
    required this.record,
    required this.onOpen,
    this.onFillWeight,
  });

  static String dayLabel(DateTime d) => DateFormat('E M/d').format(d);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final best = record.best;
    final last = record.last;
    if (best == null) return const SizedBox.shrink();
    // The last session IS the record → one line is enough.
    final showLast = last != null && !identical(last, best);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        InkWell(
          key: const ValueKey('prev-record-best'),
          onTap: () => onOpen(best),
          onLongPress:
              onFillWeight == null ? null : () => onFillWeight!(best),
          child: Text(
            'PR ${best.label}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: scheme.tertiary,
            ),
          ),
        ),
        if (showLast)
          InkWell(
            key: const ValueKey('prev-record-last'),
            onTap: () => onOpen(last),
            child: Text(
              'last ${last.label} · ${dayLabel(last.date)}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}
