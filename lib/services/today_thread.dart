import 'sheets_repository.dart' show Record;
import 'coach_thread_const.dart';

/// Stable per-day thread id the Today-synthesis card seeds + opens, so
/// tapping the card's AI read continues the day's synthesis as a normal
/// coach thread. One id per calendar day → repeat taps land in the same
/// thread (idempotent, see [shouldSeedTodayThread]).
String todaySynthesisThreadId(DateTime day) =>
    'today-${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Whether the day thread still needs its opening coach (synthesis) row.
/// True only when no coach-role row already exists among the thread's
/// rows — so re-tapping the card never duplicates the seed. [rows] are
/// the coach_chat rows ALREADY filtered to the day thread (empty when the
/// thread doesn't exist yet). A user reply (role=user) does not count —
/// the seed is specifically the coach opener.
bool shouldSeedTodayThread(List<Record> rows) {
  for (final r in rows) {
    if (r['role']?.toString() == 'coach') return false;
  }
  return true;
}

/// Short display title for a day thread's tile ("Today's read · Sep 30").
String todaySynthesisThreadTitle(DateTime day) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return "Today's read · ${months[day.month - 1]} ${day.day}";
}

/// Convenience: filter all coach_chat [rows] down to the day thread.
List<Record> todayThreadRows(List<Record> rows, String threadId) {
  return rows.where((r) {
    final t = r['thread']?.toString().trim();
    final resolved = (t == null || t.isEmpty) ? kCoachThreadGeneral : t;
    return resolved == threadId;
  }).toList();
}
