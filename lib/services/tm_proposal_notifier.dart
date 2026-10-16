/// Local notification when a NEW pending training-max proposal appears
/// (HITL gating, 2026-10-16) — once per proposal. Runs on bootstrap,
/// app resume and the home poller tick (the nightly's proposals arrive
/// with the next WM-tab read). Seen proposal ids persist in
/// shared_preferences; the pure selection/composition is testable
/// without the plugin.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';
import 'wm_store.dart';
import 'wm_tabs.dart';

/// Pending proposals whose id isn't in [seen] (lift order).
List<WorkingMaxRow> unseenTmProposals(WmSnapshot snap, Set<String> seen) => [
      for (final p in pendingTmProposals(snap.workingMax))
        if (!seen.contains(tmProposalIdOf(p))) p,
    ];

String _lb(num v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// Notification (title, body) for [fresh] proposals; null when empty.
({String title, String body})? composeTmProposalNotification(
  List<WorkingMaxRow> fresh,
  List<WorkingMaxRow> rows,
) {
  if (fresh.isEmpty) return null;
  String line(WorkingMaxRow p) {
    final name = p.lift == 'press'
        ? 'Overhead press'
        : p.lift[0].toUpperCase() + p.lift.substring(1);
    final from = currentWorkingMax(rows, p.lift)?.valueLb;
    return '$name: ${from == null ? '' : '${_lb(from)} → '}${_lb(p.valueLb)}'
        '${isTmRecommended(p) ? ' (recommended)' : ''} · '
        '${tmProposalEvidence(p)}';
  }

  return (
    title: fresh.length == 1
        ? 'Training max update to review'
        : '${fresh.length} training max updates to review',
    body: '${fresh.map(line).join('\n')}\nAccept or keep in Progress → '
        'Training maxes.',
  );
}

class TmProposalNotifier {
  static const _prefsKey = 'tm_proposals_notified';
  static DateTime? _lastRun;

  /// Reads the WM tabs and notifies once per unseen pending proposal.
  /// Throttled to one run per [minGap]; best-effort (never throws).
  static Future<void> check(
    WmStore store, {
    Duration minGap = const Duration(minutes: 10),
  }) async {
    final now = DateTime.now();
    final last = _lastRun;
    if (last != null && now.difference(last) < minGap) return;
    _lastRun = now;
    try {
      final snap = await store.snapshot();
      if (snap == null) return;
      final prefs = await SharedPreferences.getInstance();
      final seen = (prefs.getStringList(_prefsKey) ?? const []).toSet();
      final fresh = unseenTmProposals(snap, seen);
      final note = composeTmProposalNotification(fresh, snap.workingMax);
      if (note == null) return;
      await NotificationService.instance?.showTmProposal(note.title, note.body);
      final ids = [...seen, for (final p in fresh) tmProposalIdOf(p)];
      // Keep the list bounded (ids are only compared against pending).
      await prefs.setStringList(
          _prefsKey, ids.length > 50 ? ids.sublist(ids.length - 50) : ids);
    } catch (_) {/* best-effort */}
  }
}
