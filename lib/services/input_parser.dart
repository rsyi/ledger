/// Pure-Dart YAML → input-layer overlay parser.
///
/// `.input.yml` files carry the input-layer concerns for a paired
/// `<name>.view.yml`:
///
///   - view-level: `date_field`, `plannable`, `list_display`,
///     `spreadsheet_id`
///   - per-dimension: `input`, `samples`, `show_when`, `derive`
///
/// The `view:` field is the back-pointer (must match the paired
/// `.view.yml`'s `name:`). Per-dimension overlays are keyed by dimension
/// name.
///
/// Applying an overlay returns a new [ViewSchema] with the input-layer
/// fields populated. See `schema_parser.dart` for the semantic-layer
/// half.
library;

import 'package:yaml/yaml.dart';

import '../models/view_schema.dart';

class InputOverlay {
  final String viewName;
  final String? dateField;
  final Plannable? plannable;
  final ListDisplay? listDisplay;
  final String? spreadsheetId;

  /// Icon for the view — lucide name (e.g. `dumbbell`), emoji, or URL.
  final String? icon;

  /// Post-log hook (LLM comment after a row is logged).
  final PostLogHook? postLog;

  /// Per-dimension overlays, keyed by dimension name.
  final Map<String, DimensionOverlay> dimensions;

  /// Top-level `groups:` block — named value sets that show_when
  /// predicates reference via `in_group: <name>` / `not_in_group: <name>`.
  /// Empty when no groups: declared.
  final Map<String, Set<String>> groups;

  /// Optional name of a measure used to score rows for the history panel's
  /// per-day "top" highlight. See [ViewSchema.topMetric].
  final String? topMetric;

  /// Optional repeat-group declaration (which fields fan out into N rows).
  /// See [RepeatGroup].
  final RepeatGroup? repeatGroup;

  InputOverlay({
    required this.viewName,
    this.dateField,
    this.plannable,
    this.listDisplay,
    this.spreadsheetId,
    this.icon,
    this.postLog,
    this.dimensions = const {},
    this.groups = const {},
    this.topMetric,
    this.repeatGroup,
  });
}

class DimensionOverlay {
  final InputSpec? input;
  final List<String>? samples;
  final Map<String, Object?>? showWhen;
  final Derive? derive;

  DimensionOverlay({this.input, this.samples, this.showWhen, this.derive});
}

InputOverlay parseInputOverlay(String yamlText) {
  final node = loadYaml(yamlText);
  if (node is! YamlMap) {
    throw const FormatException('Top-level YAML must be a map');
  }
  // `target:` points at the paired .view.yml by full filename, mirroring
  // oxy's .test.yml → target: <agent>.agent.yml convention. The view name
  // is derived from the basename minus the .view.yml extension.
  final target = node['target'];
  if (target is! String || !target.endsWith('.view.yml')) {
    throw const FormatException(
      'Missing or malformed `target:` field in .input.yml. '
      'Expected: target: <view_name>.view.yml',
    );
  }
  final viewName = target.substring(0, target.length - '.view.yml'.length);
  final dimensions = <String, DimensionOverlay>{};
  // `fields:` is the preferred top-level key in .input.yml (it's a form
  // spec, "fields" matches form vocabulary). `dimensions:` is accepted
  // for backwards compatibility with the original schema that mirrored
  // .view.yml's term — files written that way still parse.
  final fieldsNode = node['fields'] ?? node['dimensions'];
  if (fieldsNode is YamlMap) {
    for (final entry in fieldsNode.entries) {
      final dimName = entry.key.toString();
      final v = entry.value;
      if (v is! YamlMap) {
        throw FormatException(
          'Field overlay for "$dimName" must be a map',
        );
      }
      dimensions[dimName] = _parseDimensionOverlay(v);
    }
  } else if (fieldsNode != null) {
    throw const FormatException(
      'fields: (or legacy dimensions:) must be a map keyed by field name '
      'in .input.yml',
    );
  }
  return InputOverlay(
    viewName: viewName,
    dateField: node['date_field'] as String?,
    plannable: node['plannable'] == null
        ? null
        : _parsePlannable(node['plannable'] as YamlMap),
    listDisplay: node['list_display'] == null
        ? null
        : _parseListDisplay(node['list_display'] as YamlMap),
    spreadsheetId: node['spreadsheet_id'] as String?,
    icon: node['icon'] as String?,
    postLog: node['post_log'] == null
        ? null
        : _parsePostLog(node['post_log'] as YamlMap),
    dimensions: dimensions,
    groups: _parseGroups(node['groups']),
    topMetric: node['top_metric'] as String?,
    repeatGroup: _parseRepeatGroup(node['repeat_group']),
  );
}

/// Parses a top-level `repeat_group:` block. Returns null when absent.
/// Required keys: `fields:` (list of strings), `label:` (string).
/// Optional: `min:` (int, default 1).
RepeatGroup? _parseRepeatGroup(Object? node) {
  if (node == null) return null;
  if (node is! YamlMap) {
    throw const FormatException('repeat_group: must be a map');
  }
  final fields = node['fields'];
  if (fields is! YamlList || fields.isEmpty) {
    throw const FormatException(
      'repeat_group.fields: must be a non-empty list of field names',
    );
  }
  final label = node['label'];
  if (label is! String || label.isEmpty) {
    throw const FormatException('repeat_group.label: must be a non-empty string');
  }
  return RepeatGroup(
    fields: fields.map((e) => e.toString()).toList(),
    label: label,
    min: (node['min'] as int?) ?? 1,
    groupKey: node['group_key'] as String?,
  );
}

/// Parses a top-level `groups:` block — `<name>: [val, val, ...]` per
/// entry. Empty/missing block yields an empty map. Tolerant of YamlMap.
Map<String, Set<String>> _parseGroups(Object? node) {
  if (node is! YamlMap) return const {};
  final out = <String, Set<String>>{};
  for (final entry in node.entries) {
    final name = entry.key.toString();
    final values = entry.value;
    if (values is YamlList) {
      out[name] = values.map((e) => e.toString()).toSet();
    } else if (values is List) {
      out[name] = values.map((e) => e.toString()).toSet();
    }
  }
  return out;
}

PostLogHook _parsePostLog(YamlMap node) {
  return PostLogHook(
    model: _requireString(node, 'model'),
    prompt: _requireString(node, 'prompt'),
  );
}

/// Parses a single field overlay. Accepts two layouts:
///
/// **New (preferred)** — flat. Form-spec keys live at the field's top level
/// alongside derive/show_when. `options:` lists allowed/suggested values:
/// ```yaml
/// weight_lbs:
///   widget: number
///   required: true
///   placeholder: "180.0"
///   options: [a, b]
///   derive: { from: ..., format: ... }
///   show_when: { type: treadmill }
/// ```
///
/// **Legacy** — form-spec keys nested under `input:`, autocomplete values
/// under `samples:`:
/// ```yaml
/// weight_lbs:
///   input:
///     widget: number
///     required: true
///   samples: [a, b]
///   derive: {...}
/// ```
///
/// Detection: if an `input:` sub-map is present, treat as legacy. Otherwise
/// flat. Both shapes produce the same DimensionOverlay.
DimensionOverlay _parseDimensionOverlay(YamlMap node) {
  final legacyInput = node['input'];
  final isLegacy = legacyInput is YamlMap;
  // Build the effective "form-spec source" map: in legacy it's the `input:`
  // sub-map; in new flat layout it's the field node itself. _parseInput
  // doesn't care which.
  final formSource = isLegacy ? legacyInput : node;

  // Decide whether to construct an InputSpec at all. In flat layout the
  // field node and the form-spec source are the same map, so we have to
  // distinguish "field has input config" from "field is derive-only" by
  // checking for a form-spec marker (widget/required/default/etc.).
  // derive-only fields (computed columns like day_of_week) skip the
  // InputSpec entirely.
  final hasInputConfig = isLegacy ||
      _looksLikeFormSpec(formSource);

  // Allowed/suggested values for the field, used by both autocomplete
  // (suggestions) and dropdown (allowed list) widgets. Looked up in
  // priority order:
  //   1. `options:` at field level (preferred, new layout)
  //   2. `samples:` at field level (legacy autocomplete location)
  //   3. `input.options:` inside the legacy input: block (legacy dropdown)
  final optionsNode = node['options'] ??
      node['samples'] ??
      (isLegacy ? (legacyInput as YamlMap)['options'] : null);

  return DimensionOverlay(
    input: hasInputConfig ? _parseInput(formSource) : null,
    samples: optionsNode is YamlList
        ? optionsNode.map((e) => e.toString()).toList()
        : null,
    showWhen: node['show_when'] == null
        ? null
        : <String, Object?>{
            for (final entry in (node['show_when'] as YamlMap).entries)
              entry.key.toString(): entry.value,
          },
    derive: node['derive'] == null
        ? null
        : _parseDerive(node['derive'] as YamlMap),
  );
}

/// True if any of the form-spec keys are present — used by flat layout to
/// tell "this field has form config" from "this field is derive-only".
bool _looksLikeFormSpec(YamlMap node) {
  const formKeys = {
    'widget',
    'required',
    'default',
    'min',
    'max',
    'options',
    'placeholder',
    'editable',
    'now_button',
    'history',
    'ladders',
    'stop_target',
    'stop_targets',
    'hr_max_target',
  };
  return formKeys.any(node.containsKey);
}

Plannable _parsePlannable(YamlMap node) {
  return Plannable(
    logField: _requireString(node, 'log_field'),
    logFormat: _parseLogFormat(_requireString(node, 'log_format')),
  );
}

InputSpec _parseInput(YamlMap node) {
  return InputSpec(
    widget: _parseWidgetType((node['widget'] as String?) ?? 'text'),
    required: (node['required'] as bool?) ?? false,
    defaultValue: node['default'],
    min: node['min'] as num?,
    max: node['max'] as num?,
    options: node['options'] == null
        ? null
        : (node['options'] as YamlList).map((e) => e.toString()).toList(),
    placeholder: node['placeholder'] as String?,
    editable: (node['editable'] as bool?) ?? true,
    nowButton: (node['now_button'] as bool?) ?? false,
    history: (node['history'] as bool?) ?? false,
    ladders: _parseLadders(node['ladders']),
    stopTargets: _parseStopTargets(node),
    hrMaxTarget: node['hr_max_target'] as String?,
  );
}

/// Parses the timer's stop config. Accepts two shapes:
///   - `stop_target: <name>` — shortcut for one target with format `elapsed`
///   - `stop_targets: [{target, format}, ...]` — full form
/// `format` is one of: `elapsed` (default), `seconds`, `time_of_day`.
/// Returns null when neither key is set.
List<TimerStopTarget>? _parseStopTargets(YamlMap node) {
  final list = node['stop_targets'];
  if (list is YamlList) {
    return list.map<TimerStopTarget>((entry) {
      if (entry is! YamlMap) {
        throw const FormatException(
          'stop_targets[]: each entry must be a map with target [+ format]',
        );
      }
      return TimerStopTarget(
        target: _requireString(entry, 'target'),
        format: _parseTimerStopFormat(
          (entry['format'] as String?) ?? 'elapsed',
        ),
      );
    }).toList();
  }
  final single = node['stop_target'] as String?;
  if (single != null) {
    return [TimerStopTarget(target: single, format: TimerStopFormat.elapsed)];
  }
  return null;
}

TimerStopFormat _parseTimerStopFormat(String s) {
  switch (s) {
    case 'elapsed':
      return TimerStopFormat.elapsed;
    case 'seconds':
      return TimerStopFormat.seconds;
    case 'time_of_day':
      return TimerStopFormat.timeOfDay;
    default:
      throw FormatException('Unknown timer stop format: $s');
  }
}

/// Parses `ladders: [{label, target}, ...]` from a timer widget's field
/// config. Returns null when absent.
List<TimerLadder>? _parseLadders(Object? node) {
  if (node == null) return null;
  if (node is! YamlList) {
    throw const FormatException('ladders: must be a list');
  }
  return node.map<TimerLadder>((entry) {
    if (entry is! YamlMap) {
      throw const FormatException(
        'ladders[]: each entry must be a map with label + target',
      );
    }
    return TimerLadder(
      label: _requireString(entry, 'label'),
      target: _requireString(entry, 'target'),
      hrPct: (entry['hr_pct'] as num?)?.toDouble(),
    );
  }).toList();
}

Derive _parseDerive(YamlMap node) {
  return Derive(
    from: _requireString(node, 'from'),
    format: _parseDeriveFormat(_requireString(node, 'format')),
  );
}

ListDisplay _parseListDisplay(YamlMap node) {
  return ListDisplay(
    title: _requireString(node, 'title'),
    subtitle: node['subtitle'] as String?,
  );
}

LogFormat _parseLogFormat(String s) {
  switch (s) {
    case 'time_string':
      return LogFormat.timeString;
    case 'iso_time':
      return LogFormat.isoTime;
    case 'iso_datetime':
      return LogFormat.isoDateTime;
    default:
      throw FormatException('Unknown log format: $s');
  }
}

WidgetType _parseWidgetType(String s) {
  switch (s) {
    case 'text':
      return WidgetType.text;
    case 'longtext':
      return WidgetType.longtext;
    case 'number':
      return WidgetType.number;
    case 'date':
      return WidgetType.date;
    case 'datetime':
      return WidgetType.datetime;
    case 'timer':
      return WidgetType.timer;
    case 'dropdown':
      return WidgetType.dropdown;
    case 'autocomplete':
      return WidgetType.autocomplete;
    default:
      throw FormatException('Unknown widget type: $s');
  }
}

DeriveFormat _parseDeriveFormat(String s) {
  switch (s) {
    case 'weekday_long':
      return DeriveFormat.weekdayLong;
    case 'weekday_short':
      return DeriveFormat.weekdayShort;
    case 'iso_date':
      return DeriveFormat.isoDate;
    case 'iso_datetime':
      return DeriveFormat.isoDateTime;
    default:
      throw FormatException('Unknown derive format: $s');
  }
}

String _requireString(YamlMap node, String key) {
  final v = node[key];
  if (v is! String) {
    throw FormatException('Missing or non-string field: $key');
  }
  return v;
}

/// Merges [overlay] into [view], returning a new [ViewSchema] with
/// input-layer fields populated. Throws if [overlay] references a
/// dimension not declared in [view].
ViewSchema applyInputOverlay(ViewSchema view, InputOverlay overlay) {
  if (overlay.viewName != view.name) {
    throw FormatException(
      'Input overlay view-name mismatch: '
      '${view.name} (.view.yml) != ${overlay.viewName} (.input.yml)',
    );
  }
  final declared = {for (final d in view.dimensions) d.name};
  for (final dimName in overlay.dimensions.keys) {
    if (!declared.contains(dimName)) {
      throw FormatException(
        '.input.yml references dimension "$dimName" '
        'that is not declared in .view.yml ($declared)',
      );
    }
  }
  // top_metric must point at a real measure on the .view.yml. Without this
  // check the history-panel highlight silently no-ops at render time,
  // which is hard to debug.
  if (overlay.topMetric != null) {
    final measureNames = {for (final m in view.measures) m.name};
    if (!measureNames.contains(overlay.topMetric)) {
      throw FormatException(
        '.input.yml top_metric "${overlay.topMetric}" '
        'is not declared as a measure on .view.yml ($measureNames)',
      );
    }
  }
  final newDimensions = view.dimensions.map((d) {
    final o = overlay.dimensions[d.name];
    if (o == null) return d;
    return Dimension(
      name: d.name,
      type: d.type,
      expr: d.expr,
      description: d.description,
      input: o.input,
      samples: o.samples,
      showWhen: o.showWhen,
      derive: o.derive,
    );
  }).toList();
  return ViewSchema(
    name: view.name,
    description: view.description,
    datasource: view.datasource,
    table: view.table,
    dateField: overlay.dateField,
    spreadsheetId: overlay.spreadsheetId,
    entities: view.entities,
    dimensions: newDimensions,
    measures: view.measures,
    listDisplay: overlay.listDisplay,
    plannable: overlay.plannable,
    icon: overlay.icon,
    postLog: overlay.postLog,
    groups: overlay.groups,
    topMetric: overlay.topMetric,
    hasInputOverlay: true,
    repeatGroup: overlay.repeatGroup,
  );
}
