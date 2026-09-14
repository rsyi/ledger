import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Lifecycle of a coach proposal on THIS device. Absent from the store
/// means pending (never acted on).
enum CoachProposalStatus { scheduled, undone, dismissed }

class CoachProposalState {
  final CoachProposalStatus status;

  /// PlanStore localIds created by the last Schedule tap — what Undo
  /// removes. Empty for undone/dismissed.
  final List<String> localIds;

  const CoachProposalState({required this.status, required this.localIds});
}

/// Device-local proposal state, one SharedPreferences key per proposal
/// chat row: `coach_proposal:<rowId>`. Local by design — planned
/// entries themselves are device-local (PlanStore), so their
/// bookkeeping is too.
class CoachProposalStore {
  static String _key(String rowId) => 'coach_proposal:$rowId';

  static Future<CoachProposalState?> load(String rowId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(rowId));
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map;
      final status = CoachProposalStatus.values
          .where((s) => s.name == map['status'])
          .firstOrNull;
      if (status == null) return null;
      final ids = (map['local_ids'] as List? ?? const [])
          .map((e) => e.toString())
          .toList();
      return CoachProposalState(status: status, localIds: ids);
    } catch (_) {
      return null; // corrupt entry → treat as pending
    }
  }

  static Future<void> save(String rowId, CoachProposalState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(rowId),
      jsonEncode({'status': state.status.name, 'local_ids': state.localIds}),
    );
  }
}
