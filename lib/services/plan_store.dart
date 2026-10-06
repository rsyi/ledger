import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/planned_entry.dart';
import '../models/view_schema.dart';

/// Per-view local store of [PlannedEntry] rows. Backed by `shared_preferences`
/// under one JSON-array key per view: `plan:<view_name>`. Small and synchronous
/// enough that we don't bother with sqflite.
///
/// Entries are date-scoped at read time — the timeline asks for the entries
/// for a specific date, and we filter the full list. Past-date entries are
/// "cobwebs" that hang around silently until the user dismisses them; they
/// don't appear on the timeline (which filters by selected date).
class PlanStore {
  static const _prefix = 'plan:';
  static String _key(String viewName) => '$_prefix$viewName';

  static Future<List<PlannedEntry>> loadForDate(
    ViewSchema view,
    DateTime date,
  ) async {
    final all = await _loadAll(view);
    final target = DateFormat('yyyy-MM-dd').format(date);
    return all
        .where((e) => DateFormat('yyyy-MM-dd').format(e.date) == target)
        .toList();
  }

  static Future<List<PlannedEntry>> _loadAll(ViewSchema view) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(view.name));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => PlannedEntry.fromJson(
              (e as Map).cast<String, dynamic>(),
              view,
            ))
        .toList();
  }

  static Future<void> _saveAll(
    ViewSchema view,
    List<PlannedEntry> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final list = entries.map((e) => e.toJson(view)).toList();
    await prefs.setString(_key(view.name), jsonEncode(list));
  }

  /// Appends [entries] to the plan for [view]. Useful for template apply.
  static Future<void> addAll(
    ViewSchema view,
    List<PlannedEntry> entries,
  ) async {
    final all = await _loadAll(view);
    all.addAll(entries);
    await _saveAll(view, all);
  }

  /// Replaces a single entry by [PlannedEntry.localId]. No-op if not found.
  static Future<void> update(ViewSchema view, PlannedEntry entry) async {
    final all = await _loadAll(view);
    final idx = all.indexWhere((e) => e.localId == entry.localId);
    if (idx < 0) return;
    all[idx] = entry;
    await _saveAll(view, all);
  }

  /// Removes the entry with [localId]. No-op if not found.
  static Future<void> remove(ViewSchema view, String localId) async {
    final all = await _loadAll(view);
    all.removeWhere((e) => e.localId == localId);
    await _saveAll(view, all);
  }

  /// Removes every entry matching [test]. Used by the week planner's
  /// regenerate step to drop a week's remaining (still-planned) rows.
  static Future<void> removeWhere(
    ViewSchema view,
    bool Function(PlannedEntry) test,
  ) async {
    final all = await _loadAll(view);
    all.removeWhere(test);
    await _saveAll(view, all);
  }

  // ---------------------------------------------------------------------
  // Undo-logging mappings: logged rowId → the planned entry it came from.
  // Backed by one JSON-object key per view (`plan_undo:<view_name>`),
  // same shared_preferences persistence as the plan itself. Lets "UNDO"
  // on the Log-now snackbar and "Revert to plan" on a logged row delete
  // the sheet row and restore the original planned entry. Mappings are
  // pruned lazily after [undoRetention] and eagerly when the row is
  // deleted through the normal delete path.
  // ---------------------------------------------------------------------

  static const _undoPrefix = 'plan_undo:';
  static String _undoKey(String viewName) => '$_undoPrefix$viewName';

  /// Mappings older than this are dropped on the next load.
  static const undoRetention = Duration(days: 14);

  /// Loads the raw undo map ({rowId: {at, entry}}), pruning entries older
  /// than [undoRetention] (persisting the prune when anything dropped).
  static Future<Map<String, dynamic>> _loadUndoRaw(
    ViewSchema view,
    DateTime now,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_undoKey(view.name));
    if (raw == null) return {};
    final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
    final kept = <String, dynamic>{};
    var pruned = false;
    for (final e in decoded.entries) {
      final at = e.value is Map
          ? DateTime.tryParse((e.value as Map)['at']?.toString() ?? '')
          : null;
      if (at != null && now.difference(at) <= undoRetention) {
        kept[e.key] = e.value;
      } else {
        pruned = true;
      }
    }
    if (pruned) {
      await prefs.setString(_undoKey(view.name), jsonEncode(kept));
    }
    return kept;
  }

  static Future<void> _saveUndoRaw(
    ViewSchema view,
    Map<String, dynamic> raw,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_undoKey(view.name), jsonEncode(raw));
  }

  /// All live undo mappings for [view]: logged rowId → restorable entry.
  /// Malformed payloads are skipped. [now] is injectable for tests.
  static Future<Map<String, PlannedEntry>> undoMappings(
    ViewSchema view, {
    DateTime? now,
  }) async {
    final raw = await _loadUndoRaw(view, now ?? DateTime.now());
    final out = <String, PlannedEntry>{};
    for (final e in raw.entries) {
      try {
        out[e.key] = PlannedEntry.fromJson(
          ((e.value as Map)['entry'] as Map).cast<String, dynamic>(),
          view,
        );
      } catch (_) {
        // Skip malformed mapping — worst case the row just can't revert.
      }
    }
    return out;
  }

  /// Records that sheet row [rowId] was logged from [entry].
  static Future<void> putUndo(
    ViewSchema view,
    String rowId,
    PlannedEntry entry, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final raw = await _loadUndoRaw(view, at);
    raw[rowId] = {'at': at.toIso8601String(), 'entry': entry.toJson(view)};
    await _saveUndoRaw(view, raw);
  }

  /// Drops the mapping for [rowId]. Called after a revert and whenever the
  /// row is deleted through the normal delete path (a deleted row can't be
  /// reverted). No-op when absent.
  static Future<void> removeUndo(
    ViewSchema view,
    String rowId, {
    DateTime? now,
  }) async {
    final raw = await _loadUndoRaw(view, now ?? DateTime.now());
    if (raw.remove(rowId) == null) return;
    await _saveUndoRaw(view, raw);
  }
}
