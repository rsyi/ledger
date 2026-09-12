import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../models/view_schema.dart';
import '../../services/heart_rate_service.dart';
import '../../services/hr_session.dart';
import 'hr_max_dialog.dart';

/// Resolves an input.default value into an actual Dart value at form-creation
/// time. Supports the strings 'now' (DateTime.now()) and 'today' (date only).
Object? resolveDefault(Dimension dim) {
  final raw = dim.input?.defaultValue;
  if (raw == null) return null;
  if (raw is String) {
    if (raw == 'now') return DateTime.now();
    if (raw == 'today') {
      final n = DateTime.now();
      return DateTime(n.year, n.month, n.day);
    }
  }
  return raw;
}

/// Dispatches to the correct field widget for [dim.input.widget].
///
/// [adHocSuggestions] are autocomplete values the user has previously
/// entered that aren't in the schema's `samples` — only consumed by the
/// autocomplete widget; ignored by everything else.
///
/// [onShowHistory] is invoked when the user taps the history icon on a
/// dimension opted-in via `input.history: true`. The form owns the
/// repository + view context, so the field widget only needs the callback.
/// Pass null to disable the history affordance.
Widget buildFieldWidget({
  Key? key,
  required Dimension dim,
  required Object? value,
  required ValueChanged<Object?> onChanged,
  List<String>? adHocSuggestions,
  VoidCallback? onShowHistory,
  void Function(String target, Object? value)? onLadderTap,
  bool isTimerLinked = false,
  /// For widget: timer fields only — current values of every dim this
  /// timer writes into (ladder targets + stop_target). Used to detect
  /// "restart with state" and prompt the user before clearing.
  Map<String, Object?>? timerLinkedValues,
}) {
  final widget = dim.input?.widget ?? _widgetForType(dim.type);
  final historyEnabled = (dim.input?.history ?? false) &&
      onShowHistory != null &&
      value != null &&
      value.toString().isNotEmpty;
  final history = historyEnabled ? onShowHistory : null;
  switch (widget) {
    case WidgetType.text:
      return _TextFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        onShowHistory: history,
        isTimerLinked: isTimerLinked,
      );
    case WidgetType.longtext:
      return _TextFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        maxLines: 4,
        onShowHistory: history,
        isTimerLinked: isTimerLinked,
      );
    case WidgetType.number:
      return _NumberFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        onShowHistory: history,
        isTimerLinked: isTimerLinked,
      );
    case WidgetType.date:
      return _DateFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        includeTime: false,
      );
    case WidgetType.datetime:
      return _DateFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        includeTime: true,
      );
    case WidgetType.dropdown:
      return _DropdownFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        onShowHistory: history,
      );
    case WidgetType.autocomplete:
      return _AutocompleteFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        adHocSuggestions: adHocSuggestions ?? const [],
        onShowHistory: history,
      );
    case WidgetType.timer:
      return _TimerFieldWidget(
        key: key,
        dim: dim,
        value: value,
        onChanged: onChanged,
        onLadderTap: onLadderTap,
        linkedValues: timerLinkedValues ?? const {},
      );
  }
}

WidgetType _widgetForType(DimensionType t) {
  switch (t) {
    case DimensionType.number:
      return WidgetType.number;
    case DimensionType.date:
      return WidgetType.date;
    case DimensionType.datetime:
      return WidgetType.datetime;
    case DimensionType.string:
    case DimensionType.boolean:
      return WidgetType.text;
  }
}

String _labelFor(Dimension dim) {
  final required = dim.input?.required == true ? ' *' : '';
  return '${dim.name}$required';
}

class _TextFieldWidget extends StatefulWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final int maxLines;
  final VoidCallback? onShowHistory;

  /// True when another field on this view has a `widget: timer` whose
  /// ladders or stop_target point at this dim — the timer is wired to
  /// stamp values here. Renders a clock prefix icon as the visual cue.
  final bool isTimerLinked;

  const _TextFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
    this.maxLines = 1,
    this.onShowHistory,
    this.isTimerLinked = false,
  });

  @override
  State<_TextFieldWidget> createState() => _TextFieldWidgetState();
}

class _TextFieldWidgetState extends State<_TextFieldWidget> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value?.toString() ?? '');
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(_TextFieldWidget old) {
    super.didUpdateWidget(old);
    // External update path: parent passed a new value (e.g. timer ladder
    // stamped an elapsed string into this field via setState upstream).
    // The controller is stateful so the field would otherwise still show
    // the stale text until rebuild. Skip while the user is actively
    // typing — overriding mid-keystroke wipes intermediate values like
    // "3." that don't yet parse (decimal entry bug).
    if (_focusNode.hasFocus) return;
    final next = widget.value?.toString() ?? '';
    if (next != _controller.text) {
      _controller.text = next;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nowButton = widget.dim.input?.nowButton ?? false;
    final history = widget.onShowHistory;
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      maxLines: widget.maxLines,
      decoration: InputDecoration(
        labelText: _labelFor(widget.dim),
        hintText: widget.dim.input?.placeholder,
        helperText: widget.dim.description,
        border: const OutlineInputBorder(),
        prefixIcon: widget.isTimerLinked
            ? Icon(Icons.timer_outlined, size: 18, color: scheme.primary)
            : null,
        suffixIcon: _suffix(nowButton: nowButton, onHistory: history),
      ),
      onChanged: (s) => widget.onChanged(s.isEmpty ? null : s),
    );
  }

  Widget? _suffix({required bool nowButton, required VoidCallback? onHistory}) {
    final buttons = <Widget>[
      if (nowButton)
        IconButton(
          icon: const Icon(Icons.schedule),
          tooltip: 'Now',
          onPressed: () {
            final now = DateFormat('h:mm:ss a').format(DateTime.now());
            _controller.text = now;
            widget.onChanged(now);
          },
        ),
      if (onHistory != null)
        IconButton(
          icon: const Icon(Icons.history),
          tooltip: 'History',
          onPressed: onHistory,
        ),
    ];
    if (buttons.isEmpty) return null;
    if (buttons.length == 1) return buttons.first;
    return Row(mainAxisSize: MainAxisSize.min, children: buttons);
  }
}

class _NumberFieldWidget extends StatefulWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final VoidCallback? onShowHistory;
  final bool isTimerLinked;

  const _NumberFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
    this.onShowHistory,
    this.isTimerLinked = false,
  });

  @override
  State<_NumberFieldWidget> createState() => _NumberFieldWidgetState();
}

class _NumberFieldWidgetState extends State<_NumberFieldWidget> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value?.toString() ?? '');
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(_NumberFieldWidget old) {
    super.didUpdateWidget(old);
    // Skip while user is typing — half-formed inputs like "3." parse to
    // null and would otherwise wipe the field mid-keystroke. The decimal
    // entry bug ("3.5" coming out as "3.05"/"5") was caused by this.
    if (_focusNode.hasFocus) return;
    final next = widget.value?.toString() ?? '';
    if (next != _controller.text) _controller.text = next;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final input = widget.dim.input;
    final history = widget.onShowHistory;
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: _labelFor(widget.dim),
        hintText: input?.placeholder,
        helperText: widget.dim.description,
        border: const OutlineInputBorder(),
        prefixIcon: widget.isTimerLinked
            ? Icon(Icons.timer_outlined, size: 18, color: scheme.primary)
            : null,
        suffixIcon: history == null
            ? null
            : IconButton(
                icon: const Icon(Icons.history),
                tooltip: 'History',
                onPressed: history,
              ),
      ),
      onChanged: (s) {
        if (s.isEmpty) {
          widget.onChanged(null);
          return;
        }
        final n = num.tryParse(s);
        widget.onChanged(n);
      },
    );
  }
}

class _DateFieldWidget extends StatelessWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final bool includeTime;

  const _DateFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
    required this.includeTime,
  });

  @override
  Widget build(BuildContext context) {
    final current = value is DateTime ? value as DateTime : null;
    final formatter = includeTime
        ? DateFormat('yyyy-MM-dd HH:mm')
        : DateFormat('yyyy-MM-dd');
    final display = current == null ? '—' : formatter.format(current);

    return InkWell(
      onTap: () => _pick(context, current),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: _labelFor(dim),
          helperText: dim.description,
          border: const OutlineInputBorder(),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(display),
            const Icon(Icons.calendar_today, size: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context, DateTime? current) async {
    final now = DateTime.now();
    final initialDate = current ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    if (!includeTime) {
      onChanged(DateTime(picked.year, picked.month, picked.day));
      return;
    }
    if (!context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
    );
    final t = time ?? TimeOfDay.fromDateTime(initialDate);
    onChanged(
      DateTime(picked.year, picked.month, picked.day, t.hour, t.minute),
    );
  }
}

/// Free-form text input with suggestions from `dim.samples`. Lets the user
/// pick from a known list or type a new value (ad hoc). Matching is
/// substring + case-insensitive; the full list shows when the field is empty
/// or freshly focused.
class _AutocompleteFieldWidget extends StatelessWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  /// User-saved ad-hoc values from past sessions (loaded from
  /// AutocompleteCache). Surfaced in the dropdown after the schema's
  /// `samples` with a distinct visual marker — italic + a small "•"
  /// prefix — so the user can tell their own additions from canonical
  /// schema entries.
  final List<String> adHocSuggestions;

  final VoidCallback? onShowHistory;

  const _AutocompleteFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
    required this.adHocSuggestions,
    this.onShowHistory,
  });

  /// Returns `(label, isAdHoc)` pairs for every suggestion. Samples first
  /// (canonical), then ad-hoc (user's). De-duped case-insensitively
  /// against samples — defensive even though AutocompleteCache.add does
  /// this on the write side, in case the schema's samples gained an entry
  /// after the user already cached the same string.
  List<(String, bool)> _allOptions() {
    final samples = dim.samples ?? const <String>[];
    final sampleLower = samples.map((s) => s.toLowerCase()).toSet();
    final adHoc = adHocSuggestions
        .where((s) => !sampleLower.contains(s.toLowerCase()))
        .toList();
    return [
      for (final s in samples) (s, false),
      for (final s in adHoc) (s, true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final allOptions = _allOptions();
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: value?.toString() ?? ''),
      optionsBuilder: (input) {
        final q = input.text.trim().toLowerCase();
        final filtered = q.isEmpty
            ? allOptions
            : allOptions
                .where((o) => o.$1.toLowerCase().contains(q))
                .toList();
        return filtered.take(50).map((o) => o.$1);
      },
      onSelected: (s) => onChanged(s.isEmpty ? null : s),
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        final history = onShowHistory;
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: _labelFor(dim),
            hintText: dim.input?.placeholder,
            helperText: dim.description,
            border: const OutlineInputBorder(),
            suffixIcon: history == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.history),
                    tooltip: 'History',
                    onPressed: history,
                  ),
          ),
          onChanged: (s) => onChanged(s.isEmpty ? null : s),
          onSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        // Walk the un-truncated options list in parallel so we can show
        // the ad-hoc marker on user-added entries.
        final shown = options.toList();
        final adHocSet = <String>{
          for (final (s, isAdHoc) in allOptions)
            if (isAdHoc) s,
        };
        final scheme = Theme.of(context).colorScheme;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 400),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: shown.length,
                itemBuilder: (context, index) {
                  final option = shown[index];
                  final isAdHoc = adHocSet.contains(option);
                  return InkWell(
                    onTap: () => onSelected(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: isAdHoc
                          ? Row(
                              children: [
                                Text(
                                  '• ',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    option,
                                    style: TextStyle(
                                      fontStyle: FontStyle.italic,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Text(option),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DropdownFieldWidget extends StatelessWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final VoidCallback? onShowHistory;

  const _DropdownFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
    this.onShowHistory,
  });

  @override
  Widget build(BuildContext context) {
    final options = dim.input?.options ?? dim.samples ?? const <String>[];
    final current = value?.toString();
    final history = onShowHistory;
    final field = DropdownButtonFormField<String>(
      initialValue: options.contains(current) ? current : null,
      decoration: InputDecoration(
        labelText: _labelFor(dim),
        helperText: dim.description,
        border: const OutlineInputBorder(),
      ),
      items: options
          .map((o) => DropdownMenuItem(value: o, child: Text(o)))
          .toList(),
      onChanged: onChanged,
    );
    if (history == null) return field;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: field),
        IconButton(
          icon: const Icon(Icons.history),
          tooltip: 'History',
          onPressed: history,
        ),
      ],
    );
  }
}

/// Stopwatch widget for interval logging. Owns its own start moment
/// internally so elapsed time computation isn't sensitive to formatting
/// roundtrips on the start_time text field. UX:
///
///   - Before Start tapped: shows the time-of-day text field as usual.
///     A Start (▶) suffix button stamps now into the field AND captures
///     `_startedAt = DateTime.now()`, kicking off a 1Hz redraw to show
///     live elapsed below.
///   - While running: an elapsed badge (`m:ss` / `H:MM:SS`) and one
///     `[label]` chip per ladder entry. Each chip tap stamps the
///     elapsed time into its target field via `onLadderTap`.
///   - Stop (⏸) freezes the live display; the field values stay.
///
/// Edit-after-the-fact use case: when the row already has a start_time
/// value but the widget hasn't been Started in this session, the chips
/// still work — elapsed is computed from the parsed time-of-day in the
/// text field. Lets you finalize a session after navigating away.
class _TimerFieldWidget extends StatefulWidget {
  final Dimension dim;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final void Function(String target, Object? value)? onLadderTap;

  /// Current values of every target field the timer can write to (ladder
  /// targets + stop_target). Used by `_start` to detect "restart with
  /// state on disk" and prompt the user before silently clearing.
  final Map<String, Object?> linkedValues;

  const _TimerFieldWidget({
    super.key,
    required this.dim,
    required this.value,
    required this.onChanged,
    required this.onLadderTap,
    required this.linkedValues,
  });

  @override
  State<_TimerFieldWidget> createState() => _TimerFieldWidgetState();
}

class _TimerFieldWidgetState extends State<_TimerFieldWidget> {
  late final TextEditingController _controller;

  /// Wall-clock when the current run-segment began. Cleared on pause
  /// (the segment's elapsed gets folded into [_accumulated]) and
  /// re-stamped on resume. Independent of stop: stop just freezes
  /// without clearing.
  DateTime? _startedAt;

  /// Elapsed time across previous run-segments (pauses-then-resumes).
  /// Total elapsed = `_accumulated + (now - _startedAt)` when running.
  Duration _accumulated = Duration.zero;

  /// True while the user has hit Pause but not Stop. The display
  /// freezes at the paused total but state is preserved so Resume
  /// continues where it left off.
  bool _paused = false;

  /// True once the user has hit Stop. The final elapsed has been
  /// written to stop_targets. Visually the row stays so the user sees
  /// what was logged; tapping Start again triggers the
  /// restart-with-state confirmation.
  bool _stopped = false;

  Timer? _ticker;

  /// True while we hold the wakelock (Start → Stop/dispose). Guards
  /// disable() so we never release a lock some other screen holds.
  bool _wakelockHeld = false;

  StreamSubscription<int>? _bpmSub;
  HrSession? _hrSession;

  /// True when this timer's schema declares any HR behavior — a ladder
  /// with hr_pct or an hr_max_target. Gates all HR UI and subscriptions.
  bool get _hrConfigured =>
      widget.dim.input?.hrMaxTarget != null ||
      (widget.dim.input?.ladders?.any((l) => l.hrPct != null) ?? false);

  static final _timeFmt = DateFormat('h:mm:ss a');

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value?.toString() ?? '');
    final hr = HeartRateService.instance;
    if (_hrConfigured && hr != null) {
      _bpmSub = hr.bpm.listen(_onBpm);
      hr.maxHr.addListener(_onMaxHrChanged);
    }
  }

  @override
  void dispose() {
    _bpmSub?.cancel();
    HeartRateService.instance?.maxHr.removeListener(_onMaxHrChanged);
    if (_wakelockHeld) {
      unawaited(WakelockPlus.disable());
      _wakelockHeld = false;
    }
    _ticker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onMaxHrChanged() {
    _hrSession?.maxHr = HeartRateService.instance?.maxHr.value;
  }

  /// Live sample: track session max; auto-stamp any hr_pct ladder whose
  /// threshold this sample crosses — same guard as a manual tap (only
  /// blank targets), same write path (onLadderTap).
  void _onBpm(int bpm) {
    if (!mounted) return;
    final running = _ticker != null && _startedAt != null && !_paused;
    final session = _hrSession;
    if (!running || session == null) return;
    final due = session.onSample(bpm);
    for (final ladder in due) {
      if (_isNonEmpty(widget.linkedValues[ladder.target])) continue;
      final elapsed = _liveElapsed();
      if (elapsed == null) continue;
      final formatted = _formatElapsed(elapsed);
      widget.onLadderTap?.call(ladder.target, formatted);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${ladder.label}: $formatted · auto (HR $bpm)'),
          duration: const Duration(milliseconds: 1200),
        ),
      );
    }
  }

  /// Names of dims the timer writes to — ladder targets and every
  /// stop_targets entry. Filtered through [widget.linkedValues] to find
  /// which are currently populated.
  List<String> _populatedTargets() {
    final targets = <String>{
      for (final l in widget.dim.input?.ladders ?? const <TimerLadder>[])
        l.target,
      for (final s
          in widget.dim.input?.stopTargets ?? const <TimerStopTarget>[])
        s.target,
      if (widget.dim.input?.hrMaxTarget != null)
        widget.dim.input!.hrMaxTarget!,
    };
    return [
      for (final t in targets)
        if (_isNonEmpty(widget.linkedValues[t])) t,
    ];
  }

  static bool _isNonEmpty(Object? v) {
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    return true;
  }

  Future<void> _start() async {
    // Restart-with-state guard. If any target field already has a value
    // (carried in from a previous run or a load), make the user confirm
    // before we blow it away.
    final populated = _populatedTargets();
    if (populated.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restart timer?'),
          content: Text(
            'This clears ${populated.join(", ")}. '
            'Cancel to keep the values.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Restart'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      for (final t in populated) {
        widget.onLadderTap?.call(t, null);
      }
    }

    final now = DateTime.now();
    final stamp = _timeFmt.format(now);
    _controller.text = stamp;
    widget.onChanged(stamp);
    setState(() {
      _startedAt = now;
      _accumulated = Duration.zero;
      _paused = false;
      _stopped = false;
      _hrSession = HrSession(
        maxHr: HeartRateService.instance?.maxHr.value,
        ladders: widget.dim.input?.ladders ?? const [],
        hrMaxTarget: widget.dim.input?.hrMaxTarget,
      );
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    });
    _wakelockHeld = true;
    unawaited(WakelockPlus.enable());
  }

  /// Pause: freeze the elapsed counter but keep state. Resume picks up
  /// at the same total. Stop is the only way to RECORD the value.
  /// The screen intentionally stays awake through pauses (rest intervals).
  void _pause() {
    if (_startedAt == null) return;
    setState(() {
      _accumulated += DateTime.now().difference(_startedAt!);
      _startedAt = null;
      _paused = true;
      _ticker?.cancel();
      _ticker = null;
    });
  }

  void _resume() {
    setState(() {
      _startedAt = DateTime.now();
      _paused = false;
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    });
  }

  /// Stop: snap the final elapsed, write it to every stop_targets entry
  /// in its configured format, freeze. The user still sees the values;
  /// tapping Start again triggers the restart-with-state guard.
  void _stop() {
    final targets =
        widget.dim.input?.stopTargets ?? const <TimerStopTarget>[];
    final elapsed = _liveElapsed() ?? _accumulated;
    for (final tgt in targets) {
      final value = _formatForStop(elapsed, tgt.format);
      widget.onLadderTap?.call(tgt.target, value);
    }
    if (targets.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Stopped at ${_formatElapsed(elapsed)}'),
          duration: const Duration(milliseconds: 1000),
        ),
      );
    }
    final hrTarget = widget.dim.input?.hrMaxTarget;
    final sessionMax = _hrSession?.sessionMax;
    if (hrTarget != null && sessionMax != null) {
      // Highest BPM seen this session → e.g. max_hr. A later manual
      // edit wins; it's a normal form field.
      widget.onLadderTap?.call(hrTarget, sessionMax);
    }
    if (_wakelockHeld) {
      unawaited(WakelockPlus.disable());
      _wakelockHeld = false;
    }
    setState(() {
      _ticker?.cancel();
      _ticker = null;
      _accumulated = elapsed;
      _startedAt = null;
      _paused = false;
      _stopped = true;
    });
  }

  Object _formatForStop(Duration elapsed, TimerStopFormat fmt) {
    switch (fmt) {
      case TimerStopFormat.elapsed:
        return _formatElapsed(elapsed);
      case TimerStopFormat.seconds:
        return elapsed.inSeconds;
      case TimerStopFormat.timeOfDay:
        return _timeFmt.format(DateTime.now());
    }
  }

  /// Current run-segment's elapsed plus accumulated history. Null when
  /// the timer hasn't been started at all in this session.
  Duration? _liveElapsed() {
    if (_startedAt == null && _accumulated == Duration.zero) return null;
    if (_startedAt == null) return _accumulated;
    return _accumulated + DateTime.now().difference(_startedAt!);
  }

  /// Parses the field's time-of-day string back into a DateTime for
  /// today. Used when the user didn't tap Start in-session but wants
  /// the ladder buttons to still work (e.g., started the workout from
  /// memory and now finalizing). Returns null if the string doesn't
  /// parse.
  DateTime? _parseTimeOfDayToday() {
    final s = widget.value?.toString().trim();
    if (s == null || s.isEmpty) return null;
    try {
      final hms = _timeFmt.parseLoose(s);
      final today = DateTime.now();
      return DateTime(today.year, today.month, today.day, hms.hour,
          hms.minute, hms.second);
    } catch (_) {
      return null;
    }
  }

  String _formatElapsed(Duration d) {
    final secs = d.inSeconds;
    if (secs < 0) return '0:00';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Push a fullscreen mirror that reads from this state object. The
  /// dialog ticks at 1Hz on its own and routes Pause/Resume/Stop/ladder
  /// taps back into this state's methods, so closing the dialog returns
  /// to the embedded view with everything in sync.
  void _showFullscreen() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _FullscreenTimerDialog(host: this),
    );
  }

  void _tapLadder(TimerLadder ladder) {
    final elapsed = _liveElapsed() ??
        // Fallback: parse the text-of-day field for after-the-fact use.
        () {
          final start = _parseTimeOfDayToday();
          if (start == null) return null;
          return DateTime.now().difference(start);
        }();
    if (elapsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tap Start first.')),
      );
      return;
    }
    final formatted = _formatElapsed(elapsed);
    widget.onLadderTap?.call(ladder.target, formatted);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${ladder.label}: $formatted'),
        duration: const Duration(milliseconds: 800),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ladders = widget.dim.input?.ladders ?? const <TimerLadder>[];
    final scheme = Theme.of(context).colorScheme;
    final running = _ticker != null && _startedAt != null && !_paused;
    final liveDuration = _liveElapsed();
    final elapsedNow =
        liveDuration == null ? null : _formatElapsed(liveDuration);

    // Visual delineation: the whole timer block sits inside a tinted
    // container with a left accent stripe in primary color. The tint
    // gets stronger when the timer is actively ticking, and the stripe
    // switches to a solid bar (vs hairline outline) — gives the user an
    // unmissable "this is running" state without animation.
    final tint = running
        ? scheme.primaryContainer.withValues(alpha: 0.55)
        : scheme.primaryContainer.withValues(alpha: 0.18);
    final stripeWidth = running ? 5.0 : 3.0;
    return Container(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: scheme.primary, width: stripeWidth),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: _labelFor(widget.dim),
              hintText: widget.dim.input?.placeholder,
              helperText: widget.dim.description,
              filled: true,
              fillColor: Theme.of(context).scaffoldBackgroundColor,
              border: const OutlineInputBorder(),
              // Start button only lives in the suffix when there's no
              // active session yet (idle or just-stopped). Once started,
              // controls move to the dedicated row below so Pause + Stop
              // both fit comfortably.
              suffixIcon: (_startedAt == null && !_paused)
                  ? IconButton(
                      icon: const Icon(Icons.play_arrow),
                      tooltip: _stopped ? 'Restart' : 'Start',
                      color: scheme.primary,
                      onPressed: _start,
                    )
                  : null,
            ),
            onChanged: (s) => widget.onChanged(s.isEmpty ? null : s),
          ),
          if (_hrConfigured)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _HrBadge(),
              ),
            ),
          if (elapsedNow != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Row(
                children: [
                  if (running) ...[
                    _PulsingDot(color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'RUNNING',
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ] else if (_paused) ...[
                    Text(
                      'PAUSED',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ] else if (_stopped) ...[
                    Text(
                      'STOPPED',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Text(
                    'Elapsed: $elapsedNow',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  // Pause/Resume — only active during a live session.
                  if (running)
                    IconButton(
                      icon: const Icon(Icons.pause),
                      tooltip: 'Pause',
                      visualDensity: VisualDensity.compact,
                      color: scheme.primary,
                      onPressed: _pause,
                    )
                  else if (_paused)
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      tooltip: 'Resume',
                      visualDensity: VisualDensity.compact,
                      color: scheme.primary,
                      onPressed: _resume,
                    ),
                  // Stop is the only control that RECORDS the elapsed
                  // value into stop_targets. Available while running or
                  // paused; hidden once stopped (no value to write).
                  if (!_stopped && (running || _paused))
                    IconButton(
                      icon: const Icon(Icons.stop),
                      tooltip: 'Stop & log',
                      visualDensity: VisualDensity.compact,
                      color: scheme.error,
                      onPressed: _stop,
                    ),
                  // Expand to fullscreen mode — big elapsed display, big
                  // ladder buttons paired with their target field values,
                  // big Pause/Stop. Lets the user run an interval without
                  // hunting through the form. Available whenever the
                  // timer has any state to show.
                  IconButton(
                    icon: const Icon(Icons.fullscreen),
                    tooltip: 'Fullscreen',
                    visualDensity: VisualDensity.compact,
                    color: scheme.primary,
                    onPressed: _showFullscreen,
                  ),
                ],
              ),
            ),
          if (ladders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tap to record · fills the field marked ⏱',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final ladder in ladders)
                        ActionChip(
                          label: Text(ladder.label),
                          avatar: Icon(
                            Icons.timer_outlined,
                            size: 16,
                            color: scheme.primary,
                          ),
                          backgroundColor: running
                              ? scheme.primary.withValues(alpha: 0.12)
                              : null,
                          side: BorderSide(
                            color: scheme.primary.withValues(
                              alpha: running ? 0.6 : 0.3,
                            ),
                          ),
                          onPressed: () => _tapLadder(ladder),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Two-frame "pulsing" dot indicating live tick. Toggles opacity with
/// an AnimatedOpacity tied to the timer's seconds-place so the pulse
/// stays in sync with the elapsed counter (no separate animation
/// controller required).
class _PulsingDot extends StatelessWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final on = now.second.isEven;
    return AnimatedOpacity(
      opacity: on ? 1.0 : 0.35,
      duration: const Duration(milliseconds: 500),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// Fullscreen mirror of `_TimerFieldWidget`. Reads state from the host
/// (`_TimerFieldWidgetState`), reacts to it via its own 1Hz ticker, and
/// routes user interactions back to the host's methods — so embedded and
/// fullscreen views stay in sync without a separate state object.
class _FullscreenTimerDialog extends StatefulWidget {
  final _TimerFieldWidgetState host;
  const _FullscreenTimerDialog({required this.host});

  @override
  State<_FullscreenTimerDialog> createState() =>
      _FullscreenTimerDialogState();
}

class _FullscreenTimerDialogState extends State<_FullscreenTimerDialog> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _formatElapsed(Duration d) {
    final secs = d.inSeconds;
    if (secs < 0) return '0:00';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final host = widget.host;
    final running =
        host._ticker != null && host._startedAt != null && !host._paused;
    final paused = host._paused;
    final stopped = host._stopped;
    final liveDuration = host._liveElapsed();
    final elapsedText =
        liveDuration == null ? '0:00' : _formatElapsed(liveDuration);
    final stripeColor = running
        ? scheme.primary
        : paused
            ? scheme.tertiary
            : scheme.outlineVariant;
    final stateLabel = running
        ? 'RUNNING'
        : paused
            ? 'PAUSED'
            : stopped
                ? 'STOPPED'
                : 'READY';
    final ladders =
        host.widget.dim.input?.ladders ?? const <TimerLadder>[];
    final stops = host.widget.dim.input?.stopTargets ??
        const <TimerStopTarget>[];
    return Dialog.fullscreen(
      backgroundColor: scheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.fullscreen_exit),
                    tooltip: 'Collapse',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    host.widget.dim.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (host._hrConfigured) ...[
                    const _HrBadge(),
                    const SizedBox(width: 8),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: stripeColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (running) ...[
                          _PulsingDot(color: stripeColor),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          stateLabel,
                          style: TextStyle(
                            color: stripeColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  elapsedText,
                  style: TextStyle(
                    fontSize: 140,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                    height: 1.0,
                    letterSpacing: -3,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ListView(
                  children: [
                    for (final ladder in ladders)
                      _BigLadderRow(
                        label: ladder.label,
                        currentValue: host
                                .widget.linkedValues[ladder.target]
                                ?.toString() ??
                            '—',
                        onTap: () {
                          host._tapLadder(ladder);
                          setState(() {});
                        },
                      ),
                    for (final tgt in stops)
                      _BigLadderRow(
                        label: '${tgt.target} (on Stop)',
                        currentValue: host
                                .widget.linkedValues[tgt.target]
                                ?.toString() ??
                            '—',
                        onTap: null,
                      ),
                    if (ladders.isEmpty && stops.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            'No ladders configured on this timer.',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (host._startedAt == null && !host._paused && !host._stopped)
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 18),
                          textStyle: const TextStyle(fontSize: 18),
                        ),
                        icon: const Icon(Icons.play_arrow, size: 28),
                        label: const Text('Start'),
                        onPressed: () async {
                          await host._start();
                          if (mounted) setState(() {});
                        },
                      ),
                    )
                  else ...[
                    if (running)
                      Expanded(
                        child: FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 18),
                            textStyle: const TextStyle(fontSize: 18),
                          ),
                          icon: const Icon(Icons.pause, size: 28),
                          label: const Text('Pause'),
                          onPressed: () {
                            host._pause();
                            setState(() {});
                          },
                        ),
                      )
                    else if (paused)
                      Expanded(
                        child: FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 18),
                            textStyle: const TextStyle(fontSize: 18),
                          ),
                          icon: const Icon(Icons.play_arrow, size: 28),
                          label: const Text('Resume'),
                          onPressed: () {
                            host._resume();
                            setState(() {});
                          },
                        ),
                      )
                    else if (stopped)
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 18),
                            textStyle: const TextStyle(fontSize: 18),
                          ),
                          icon: const Icon(Icons.replay, size: 28),
                          label: const Text('Restart'),
                          onPressed: () async {
                            await host._start();
                            if (mounted) setState(() {});
                          },
                        ),
                      ),
                    if (!stopped) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: scheme.error,
                            foregroundColor: scheme.onError,
                            padding:
                                const EdgeInsets.symmetric(vertical: 18),
                            textStyle: const TextStyle(fontSize: 18),
                          ),
                          icon: const Icon(Icons.stop, size: 28),
                          label: const Text('Stop & log'),
                          onPressed: () {
                            host._stop();
                            setState(() {});
                          },
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Single row in the fullscreen view — big tap-to-record button on the
/// left, live target value on the right, arrow between.
class _BigLadderRow extends StatelessWidget {
  final String label;
  final String currentValue;
  final VoidCallback? onTap;

  const _BigLadderRow({
    required this.label,
    required this.currentValue,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = onTap == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: FilledButton.tonal(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 22,
                ),
                textStyle: const TextStyle(fontSize: 18),
                disabledBackgroundColor:
                    scheme.surfaceContainerHighest,
              ),
              onPressed: onTap,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: disabled ? scheme.onSurfaceVariant : null,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.arrow_forward,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 20,
              ),
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
                color: scheme.surfaceContainerLow,
              ),
              child: Text(
                currentValue,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: currentValue == '—'
                      ? scheme.onSurfaceVariant
                      : scheme.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live BPM chip for HR-configured timers. Shows connection state, the
/// current BPM colored by zone, a connect affordance when disconnected,
/// and a "set max HR" prompt when unset. Zone colors are display-only
/// approximations (80%/90% of max HR); stamping thresholds come from
/// the schema's hr_pct values.
class _HrBadge extends StatelessWidget {
  const _HrBadge();

  @override
  Widget build(BuildContext context) {
    final hr = HeartRateService.instance;
    if (hr == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<HrState>(
      valueListenable: hr.state,
      builder: (context, state, _) {
        switch (state) {
          case HrState.disconnected:
            return ActionChip(
              avatar: Icon(Icons.favorite_border,
                  size: 16, color: scheme.onSurfaceVariant),
              label: const Text('Connect HR'),
              onPressed: () async {
                final ok = await hr.connectRemembered();
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'Pair your Whoop on the Integrations page first.'),
                  ));
                }
              },
            );
          case HrState.connecting:
            return const Chip(
              avatar: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              label: Text('Connecting…'),
            );
          case HrState.reconnecting:
            return Chip(
              avatar:
                  Icon(Icons.sync_problem, size: 16, color: scheme.error),
              label: const Text('Reconnecting…'),
            );
          case HrState.connected:
            return ValueListenableBuilder<int?>(
              valueListenable: hr.lastBpm,
              builder: (context, bpm, _) {
                return ValueListenableBuilder<int?>(
                  valueListenable: hr.maxHr,
                  builder: (context, max, _) {
                    if (max == null) {
                      return ActionChip(
                        avatar: Icon(Icons.favorite,
                            size: 16, color: scheme.primary),
                        label: Text(
                            bpm == null ? '— bpm' : '$bpm bpm · set max HR'),
                        onPressed: () => promptMaxHr(context, hr),
                      );
                    }
                    var color = scheme.onSurfaceVariant;
                    if (bpm != null && bpm >= max * 0.9) {
                      color = Colors.red;
                    } else if (bpm != null && bpm >= max * 0.8) {
                      color = Colors.orange;
                    }
                    // ActionChip (same visuals as the plain Chip it
                    // replaced) so tapping the live BPM always reopens
                    // the max-HR dialog — not just while max is unset.
                    return ActionChip(
                      avatar: Icon(Icons.favorite, size: 16, color: color),
                      label: Text(
                        bpm == null ? '— bpm' : '$bpm bpm',
                        style: TextStyle(
                            color: color, fontWeight: FontWeight.w700),
                      ),
                      onPressed: () => promptMaxHr(context, hr),
                    );
                  },
                );
              },
            );
        }
      },
    );
  }
}

