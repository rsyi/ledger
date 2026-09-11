import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/view_schema.dart';
import '../services/autocomplete_cache.dart';
import '../services/derive.dart';
import '../services/sheets_repository.dart';
import '../services/warehouse_connector.dart';
import 'widgets/field_widgets.dart';
import 'widgets/history_panel.dart';

/// Auto-generated entry form. Renders one input per editable dimension.
///
/// Four modes:
///   - **Create** (default): blank form with defaults from `input.default`.
///     On save, calls `repository.create` and pops with `true`.
///   - **Edit** (`existing != null`): pre-fills from `existing`. On save,
///     calls `repository.update` and pops with `true`.
///   - **Plan** (`planMode == true`): pre-fills from `existing`. On save,
///     pops with the edited values map so the caller can persist locally
///     instead of writing to the sheet.
///   - **Batch** (view has `repeat_group` AND either create or `batch !=
///     null` for edit): renders shared fields once + N repeat blocks. On
///     save fans out into N rows sharing one `group_key` UUID. For batch
///     edit, deletes the original rows after creating the replacements
///     (safer than the reverse order — never an empty intermediate state).
class FormScreen extends StatefulWidget {
  final ViewSchema view;
  final WarehouseConnector repository;

  /// Single-row edit target. Mutually exclusive with [batch].
  final Record? existing;

  /// Batch edit target — all rows sharing one `group_key`. Mutually
  /// exclusive with [existing]. Required for editing a batch; ignored
  /// otherwise.
  final List<Record>? batch;

  final bool planMode;

  const FormScreen({
    super.key,
    required this.view,
    required this.repository,
    this.existing,
    this.batch,
    this.planMode = false,
  });

  bool get isEdit => existing != null || (batch != null && batch!.isNotEmpty);
  bool get isBatch => batch != null && batch!.isNotEmpty;

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> {
  /// Shared (non-repeating) field values. For views without `repeat_group`,
  /// this IS the full record. For repeat-group views it holds only the
  /// non-repeating values (plus the `group_key` UUID on save).
  late final Record _shared;

  /// Per-block repeating field values. Length is 0 when the view has no
  /// repeat_group, otherwise ≥ `repeatGroup.min` (defaults to 1).
  final List<Map<String, Object?>> _repeats = [];

  bool _saving = false;

  /// Recent rows for this view, fetched once on init. Drives autocomplete
  /// autofill. Null until the fetch resolves; empty when the fetch fails.
  List<Record>? _recentRows;

  /// Cached ad-hoc autocomplete values per dim name. Newest-first. Values
  /// the user typed in past sessions that aren't in the schema's samples.
  /// Merged with samples in the dropdown and marked distinctly.
  final Map<String, List<String>> _adHocCache = {};

  RepeatGroup? get _rg => widget.view.repeatGroup;
  Set<String> get _repeatFields => _rg?.fields.toSet() ?? const {};

  /// Field names that a timer widget on this view writes into — every
  /// ladder.target + every stop_target across editable dims that use
  /// widget: timer. Drives the timer-link prefix icon on those fields.
  late final Set<String> _timerLinkedFields = (() {
    final out = <String>{};
    for (final d in widget.view.editableDimensions) {
      if (d.input?.widget != WidgetType.timer) continue;
      for (final l in d.input?.ladders ?? const <TimerLadder>[]) {
        out.add(l.target);
      }
      for (final s in d.input?.stopTargets ?? const <TimerStopTarget>[]) {
        out.add(s.target);
      }
      final hrMax = d.input?.hrMaxTarget;
      if (hrMax != null) out.add(hrMax);
    }
    return out;
  })();

  @override
  void initState() {
    super.initState();
    _shared = <String, Object?>{};
    final rg = _rg;

    if (widget.isBatch) {
      // Batch edit: copy non-repeating fields from the first row (they're
      // identical across the batch by construction), spin up one repeat
      // block per row.
      final first = widget.batch!.first;
      for (final entry in first.entries) {
        if (rg != null && rg.fields.contains(entry.key)) continue;
        _shared[entry.key] = entry.value;
      }
      for (final row in widget.batch!) {
        final block = <String, Object?>{};
        for (final f in rg!.fields) {
          block[f] = row[f];
        }
        _repeats.add(block);
      }
    } else if (widget.existing != null) {
      _shared.addAll(widget.existing!);
      // Non-batch create/edit on a view that has a repeat_group still
      // renders the block fields — populate one block from the existing
      // row so a tap-to-edit on a stray single row stays meaningful.
      if (rg != null) {
        final block = <String, Object?>{};
        for (final f in rg.fields) {
          block[f] = _shared.remove(f);
        }
        _repeats.add(block);
      }
    } else if (rg != null) {
      // Fresh create with repeat_group: start with min blocks.
      for (var i = 0; i < rg.min.clamp(1, 99); i++) {
        _repeats.add(<String, Object?>{});
      }
    }

    // Defaults for any shared field not already populated.
    for (final dim in widget.view.editableDimensions) {
      if (_repeatFields.contains(dim.name)) continue;
      if (_shared[dim.name] != null) continue;
      final d = resolveDefault(dim);
      if (d != null) _shared[dim.name] = d;
    }
    // Defaults for repeat blocks. Apply per-block so each Add gets a fresh
    // copy of date/today/etc if any repeat field uses a default.
    for (final block in _repeats) {
      for (final dim in widget.view.editableDimensions) {
        if (!_repeatFields.contains(dim.name)) continue;
        if (block[dim.name] != null) continue;
        final d = resolveDefault(dim);
        if (d != null) block[dim.name] = d;
      }
    }

    final autocompleteDims = widget.view.editableDimensions
        .where((d) => d.input?.widget == WidgetType.autocomplete)
        .toList();
    if (autocompleteDims.isNotEmpty) {
      _loadRecentRows();
      _loadAdHocCache(autocompleteDims);
    }
  }

  Future<void> _loadAdHocCache(List<Dimension> dims) async {
    for (final dim in dims) {
      final cached = await AutocompleteCache.load(widget.view, dim.name);
      if (!mounted) return;
      if (cached.isNotEmpty) {
        setState(() => _adHocCache[dim.name] = cached);
      }
    }
  }

  Future<void> _loadRecentRows() async {
    try {
      final rows = await widget.repository.list(widget.view);
      if (!mounted) return;
      _recentRows = rows;
    } catch (_) {
      _recentRows = const [];
    }
  }

  /// Autocomplete autofill — find the most recent row matching the new
  /// value and copy its other fields into the form. For shared-field
  /// triggers, copies into [_shared]. For repeat-field triggers, copies
  /// into the same block (`_repeats[blockIdx]`) — so picking an
  /// ingredient fills its usual qty/unit but doesn't touch other blocks
  /// or the shared sauce metadata.
  void _autofillFromHistory(
    Dimension trigger,
    Object? newValue, {
    int? blockIdx,
  }) {
    final rows = _recentRows;
    if (rows == null || rows.isEmpty) return;
    if (widget.isEdit && !widget.planMode) return;
    if (newValue == null || newValue.toString().isEmpty) return;
    final match = rows.firstWhere(
      (r) => r[trigger.name]?.toString() == newValue.toString(),
      orElse: () => const {},
    );
    if (match.isEmpty) return;
    final isRepeatTrigger = _repeatFields.contains(trigger.name);
    for (final dim in widget.view.editableDimensions) {
      if (dim.name == trigger.name) continue;
      if (dim.type == DimensionType.date) continue;
      if (dim.type == DimensionType.datetime) continue;
      if (dim.derive != null) continue;
      // Skip session-stamp fields. These get filled fresh in-session via
      // a now_button click, a timer Start tap, or a Stop landing into a
      // stop_target — never carry over from history. Otherwise picking
      // an exercise after starting the timer would silently overwrite
      // today's start_time with yesterday's.
      if (dim.input?.widget == WidgetType.timer) continue;
      if (dim.input?.nowButton == true) continue;
      if (_timerLinkedFields.contains(dim.name)) continue;
      if (!match.containsKey(dim.name)) continue;
      final isRepeatTarget = _repeatFields.contains(dim.name);
      if (isRepeatTrigger && isRepeatTarget && blockIdx != null) {
        _repeats[blockIdx][dim.name] = match[dim.name];
      } else if (!isRepeatTrigger && !isRepeatTarget) {
        _shared[dim.name] = match[dim.name];
      }
      // Cross-scope autofill (shared → repeat or vice versa) intentionally
      // skipped — too easy to clobber the user's other blocks.
    }
  }

  @override
  Widget build(BuildContext context) {
    final titlePrefix = widget.planMode
        ? 'Log'
        : (widget.isEdit ? 'Edit' : 'New');
    final dims = widget.view.editableDimensions;
    final children = <Widget>[];
    var repeatRendered = false;
    for (final dim in dims) {
      if (_repeatFields.contains(dim.name)) {
        if (!repeatRendered) {
          children.add(_buildRepeatSection());
          children.add(const SizedBox(height: 12));
          repeatRendered = true;
        }
        continue;
      }
      if (!dim.isVisibleGiven(_shared, widget.view.groups)) continue;
      children.add(buildFieldWidget(
        key: ValueKey(dim.name),
        dim: dim,
        value: _shared[dim.name],
        adHocSuggestions: _adHocCache[dim.name],
        isTimerLinked: _timerLinkedFields.contains(dim.name),
        // Snapshot of current values for every dim this timer writes
        // into. Lets the widget show a "this will clear X, Y" dialog
        // before restarting.
        timerLinkedValues: dim.input?.widget == WidgetType.timer
            ? {
                for (final l in dim.input?.ladders ?? const <TimerLadder>[])
                  l.target: _shared[l.target],
                for (final s
                    in dim.input?.stopTargets ?? const <TimerStopTarget>[])
                  s.target: _shared[s.target],
                if (dim.input?.hrMaxTarget != null)
                  dim.input!.hrMaxTarget!: _shared[dim.input!.hrMaxTarget!],
              }
            : null,
        onShowHistory: () => showHistorySheet(
          context: context,
          view: widget.view,
          dim: dim,
          value: _shared[dim.name],
          repository: widget.repository,
        ),
        onChanged: (v) => setState(() {
          _shared[dim.name] = v;
          if (dim.input?.widget == WidgetType.autocomplete) {
            _autofillFromHistory(dim, v);
          }
        }),
        // For timer widgets: ladder taps write into other shared fields
        // (zone4_reached, zone5_reached, ...). Targets are by dim name.
        onLadderTap: (target, value) =>
            setState(() => _shared[target] = value),
      ));
      children.add(const SizedBox(height: 12));
    }
    if (_saving) {
      children.add(const Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('$titlePrefix ${widget.view.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _saving ? null : _save,
            tooltip: 'Save',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _buildRepeatSection() {
    final rg = _rg!;
    final blockDims = widget.view.editableDimensions
        .where((d) => rg.fields.contains(d.name))
        .toList();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _repeats.length; i++) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${rg.label} #${i + 1}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_repeats.length > rg.min)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => _repeats.removeAt(i)),
                  ),
              ],
            ),
          ),
          for (final dim in blockDims) ...[
            buildFieldWidget(
              key: ValueKey('repeat-${i}-${dim.name}'),
              dim: dim,
              value: _repeats[i][dim.name],
              adHocSuggestions: _adHocCache[dim.name],
              onShowHistory: () => showHistorySheet(
                context: context,
                view: widget.view,
                dim: dim,
                value: _repeats[i][dim.name],
                repository: widget.repository,
              ),
              onChanged: (v) => setState(() {
                _repeats[i][dim.name] = v;
                if (dim.input?.widget == WidgetType.autocomplete) {
                  _autofillFromHistory(dim, v, blockIdx: i);
                }
              }),
            ),
            const SizedBox(height: 12),
          ],
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.add),
            label: Text('Add ${rg.label}'),
            onPressed: () {
              setState(() {
                final block = <String, Object?>{};
                for (final dim in blockDims) {
                  final d = resolveDefault(dim);
                  if (d != null) block[dim.name] = d;
                }
                _repeats.add(block);
              });
            },
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final rg = _rg;

    // Drop hidden shared values (show_when stale state).
    for (final dim in widget.view.editableDimensions) {
      if (_repeatFields.contains(dim.name)) continue;
      if (!dim.isVisibleGiven(_shared, widget.view.groups)) {
        _shared.remove(dim.name);
      }
    }

    // Required-field check across shared + each block.
    final missing = <String>{};
    for (final dim in widget.view.editableDimensions) {
      if (dim.input?.required != true) continue;
      if (_repeatFields.contains(dim.name)) {
        for (var i = 0; i < _repeats.length; i++) {
          if (_repeats[i][dim.name] == null) {
            missing.add('${rg!.label} #${i + 1}: ${dim.name}');
          }
        }
      } else {
        if (!dim.isVisibleGiven(_shared, widget.view.groups)) continue;
        if (_shared[dim.name] == null) missing.add(dim.name);
      }
    }
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Required: ${missing.join(", ")}')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      // Plan mode: never touches the sheet. For repeat-group views we'd
      // need to encode N blocks into a single planned entry — out of
      // scope for now, plan + repeat_group don't combine. Falls back to
      // shared-only.
      if (widget.planMode) {
        await _persistAdHocValues();
        if (!mounted) return;
        Navigator.of(context).pop(_shared);
        return;
      }

      if (rg == null) {
        // Classic single-row path (unchanged).
        final record = Map<String, Object?>.from(_shared);
        applyDerives(widget.view, record);
        if (widget.existing != null) {
          await widget.repository.update(widget.view, record);
        } else {
          await widget.repository.create(widget.view, record);
        }
      } else {
        // Batch path: one group_key UUID, N rows fanned out.
        final batchId =
            widget.isBatch && rg.groupKey != null
                ? (widget.batch!.first[rg.groupKey] as String?) ??
                    const Uuid().v4()
                : const Uuid().v4();
        // Create new rows FIRST, then delete old ones — never an
        // empty-batch intermediate state.
        for (final block in _repeats) {
          final record = Map<String, Object?>.from(_shared);
          record.addAll(block);
          if (rg.groupKey != null) record[rg.groupKey!] = batchId;
          // Force fresh id per row even in edit — the originals get
          // deleted below. Repo auto-assigns when missing.
          record.remove('id');
          record.remove(rowIndexKey);
          applyDerives(widget.view, record);
          await widget.repository.create(widget.view, record);
        }
        if (widget.isBatch) {
          for (final old in widget.batch!) {
            // Best-effort delete. A failure here leaves the OLD rows
            // alongside the new ones (duplicate batch with same group_key)
            // — recoverable by re-editing and saving again.
            try {
              await widget.repository.delete(widget.view, old);
            } catch (_) {/* swallow */}
          }
        }
      }
      await _persistAdHocValues();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  /// Persist any autocomplete values entered that weren't in the schema's
  /// samples — across shared AND repeat blocks. Future autocomplete
  /// dropdowns surface them marked as ad-hoc.
  Future<void> _persistAdHocValues() async {
    for (final dim in widget.view.editableDimensions) {
      if (dim.input?.widget != WidgetType.autocomplete) continue;
      if (_repeatFields.contains(dim.name)) {
        for (final block in _repeats) {
          final v = block[dim.name];
          if (v == null) continue;
          await AutocompleteCache.add(widget.view, dim, v.toString());
        }
      } else {
        final v = _shared[dim.name];
        if (v == null) continue;
        await AutocompleteCache.add(widget.view, dim, v.toString());
      }
    }
  }
}
