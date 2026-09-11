/// Converts JSON returned by the Rust engine (`AirledgerEngine.parseView`
/// + `parseViewPair`) into the Dart [`ViewSchema`] object the rest of
/// the app uses.
///
/// The shape matches `src/schema/view.rs` in the engine repo. Both
/// sides round-trip through serde's snake_case for nested keys
/// (`date_field`, `list_display`, `post_log`, `has_input_overlay`,
/// `top_metric`, `repeat_group`, `now_button`, `stop_targets`,
/// `log_field`, `log_format`, `group_key`).
///
/// Used by [`SchemaLoader`] when the engine-parser path is enabled.
library;

import 'package:airledger_engine/airledger_engine.dart';

import '../models/view_schema.dart';

/// Top-level: parse `.view.yml` + `.input.yml` via the engine and
/// return a fully-merged Dart [`ViewSchema`]. Throws on any engine
/// error (parse failure, view-name mismatch, etc).
ViewSchema parseViewPairViaEngine(
  AirledgerEngine engine, {
  required String viewYaml,
  required String inputYaml,
}) {
  final json = engine.parseViewPair(viewYaml: viewYaml, inputYaml: inputYaml);
  return viewSchemaFromEngineJson(json);
}

/// Inverse of [`viewSchemaFromEngineJson`]: serialize a Dart
/// [`ViewSchema`] back into the JSON shape the engine accepts (e.g.
/// for the sheets FFI ops). Snake_case keys, Rust-side enum spellings
/// (`iso_date_time` rather than `iso_datetime` for `LogFormat`).
Map<String, dynamic> viewSchemaToEngineJson(ViewSchema view) {
  return {
    'name': view.name,
    if (view.description != null) 'description': view.description,
    'datasource': view.datasource,
    'table': view.table,
    if (view.dateField != null) 'date_field': view.dateField,
    if (view.spreadsheetId != null) 'spreadsheet_id': view.spreadsheetId,
    if (view.entities.isNotEmpty)
      'entities': view.entities.map(_entityToJson).toList(),
    'dimensions': view.dimensions.map(_dimensionToJson).toList(),
    if (view.measures.isNotEmpty)
      'measures': view.measures.map(_measureToJson).toList(),
    if (view.listDisplay != null) 'list_display': _listDisplayToJson(view.listDisplay!),
    if (view.plannable != null) 'plannable': _plannableToJson(view.plannable!),
    if (view.icon != null) 'icon': view.icon,
    if (view.postLog != null) 'post_log': _postLogToJson(view.postLog!),
    if (view.groups.isNotEmpty)
      'groups': {
        for (final entry in view.groups.entries)
          entry.key: entry.value.toList(),
      },
    if (view.topMetric != null) 'top_metric': view.topMetric,
    'has_input_overlay': view.hasInputOverlay,
    if (view.repeatGroup != null) 'repeat_group': _repeatGroupToJson(view.repeatGroup!),
  };
}

Map<String, dynamic> _entityToJson(Entity e) => {
      'name': e.name,
      'type': _entityTypeToJson(e.type),
      if (e.keys.isNotEmpty) 'keys': e.keys,
    };

String _entityTypeToJson(EntityType t) => switch (t) {
      EntityType.primary => 'primary',
      EntityType.foreign => 'foreign',
    };

Map<String, dynamic> _dimensionToJson(Dimension d) => {
      'name': d.name,
      'type': _dimensionTypeToJson(d.type),
      'expr': d.expr,
      if (d.description != null) 'description': d.description,
      if (d.samples != null) 'samples': d.samples,
      if (d.input != null) 'input': _inputSpecToJson(d.input!),
      if (d.derive != null) 'derive': _deriveToJson(d.derive!),
      if (d.showWhen != null) 'show_when': d.showWhen,
    };

String _dimensionTypeToJson(DimensionType t) => switch (t) {
      DimensionType.string => 'string',
      DimensionType.number => 'number',
      DimensionType.date => 'date',
      DimensionType.datetime => 'datetime',
      DimensionType.boolean => 'boolean',
    };

Map<String, dynamic> _inputSpecToJson(InputSpec s) => {
      'widget': _widgetToJson(s.widget),
      'required': s.required,
      if (s.defaultValue != null) 'default': s.defaultValue,
      if (s.min != null) 'min': s.min,
      if (s.max != null) 'max': s.max,
      if (s.options != null) 'options': s.options,
      if (s.placeholder != null) 'placeholder': s.placeholder,
      'editable': s.editable,
      'now_button': s.nowButton,
      'history': s.history,
      if (s.ladders != null)
        'ladders': s.ladders!
            .map((l) => {
                  'label': l.label,
                  'target': l.target,
                  if (l.hrPct != null) 'hr_pct': l.hrPct,
                })
            .toList(),
      if (s.stopTargets != null)
        'stop_targets': s.stopTargets!
            .map((t) => {
                  'target': t.target,
                  'format': _stopFormatToJson(t.format),
                })
            .toList(),
      if (s.hrMaxTarget != null) 'hr_max_target': s.hrMaxTarget,
    };

String _widgetToJson(WidgetType w) => switch (w) {
      WidgetType.text => 'text',
      WidgetType.longtext => 'longtext',
      WidgetType.number => 'number',
      WidgetType.date => 'date',
      WidgetType.datetime => 'datetime',
      WidgetType.dropdown => 'dropdown',
      WidgetType.autocomplete => 'autocomplete',
      WidgetType.timer => 'timer',
    };

String _stopFormatToJson(TimerStopFormat f) => switch (f) {
      TimerStopFormat.elapsed => 'elapsed',
      TimerStopFormat.seconds => 'seconds',
      TimerStopFormat.timeOfDay => 'time_of_day',
    };

Map<String, dynamic> _deriveToJson(Derive d) => {
      'from': d.from,
      'format': _deriveFormatToJson(d.format),
    };

// Rust LogFormat / DeriveFormat use snake_case via serde, so
// `IsoDateTime` round-trips as `iso_date_time`, not `iso_datetime`.
String _deriveFormatToJson(DeriveFormat f) => switch (f) {
      DeriveFormat.weekdayLong => 'weekday_long',
      DeriveFormat.weekdayShort => 'weekday_short',
      DeriveFormat.isoDate => 'iso_date',
      DeriveFormat.isoDateTime => 'iso_date_time',
    };

Map<String, dynamic> _measureToJson(Measure m) => {
      'name': m.name,
      'type': _measureTypeToJson(m.type),
      if (m.expr != null) 'expr': m.expr,
      if (m.description != null) 'description': m.description,
    };

String _measureTypeToJson(MeasureType t) => switch (t) {
      MeasureType.count => 'count',
      MeasureType.sum => 'sum',
      MeasureType.average => 'average',
      MeasureType.max => 'max',
      MeasureType.min => 'min',
      MeasureType.countDistinct => 'count_distinct',
      MeasureType.custom => 'custom',
      MeasureType.number => 'number',
    };

Map<String, dynamic> _listDisplayToJson(ListDisplay l) => {
      'title': l.title,
      if (l.subtitle != null) 'subtitle': l.subtitle,
    };

Map<String, dynamic> _plannableToJson(Plannable p) => {
      'log_field': p.logField,
      'log_format': _logFormatToJson(p.logFormat),
    };

String _logFormatToJson(LogFormat f) => switch (f) {
      LogFormat.timeString => 'time_string',
      LogFormat.isoTime => 'iso_time',
      LogFormat.isoDateTime => 'iso_date_time',
    };

Map<String, dynamic> _postLogToJson(PostLogHook h) => {
      'model': h.model,
      'prompt': h.prompt,
    };

Map<String, dynamic> _repeatGroupToJson(RepeatGroup r) => {
      'fields': r.fields,
      'label': r.label,
      'min': r.min,
      if (r.groupKey != null) 'group_key': r.groupKey,
    };

/// Convert the engine's merged-view JSON into a Dart [`ViewSchema`].
/// Public so callers can run their own diff vs. the pure-Dart parser
/// for parity checks during the cutover.
ViewSchema viewSchemaFromEngineJson(Map<String, dynamic> json) {
  return ViewSchema(
    name: json['name'] as String,
    description: json['description'] as String?,
    datasource: json['datasource'] as String,
    table: json['table'] as String,
    dateField: json['date_field'] as String?,
    spreadsheetId: json['spreadsheet_id'] as String?,
    entities: _entities(json['entities']),
    dimensions: _dimensions(json['dimensions']),
    measures: _measures(json['measures']),
    listDisplay: _listDisplay(json['list_display']),
    plannable: _plannable(json['plannable']),
    icon: json['icon'] as String?,
    postLog: _postLog(json['post_log']),
    groups: _groups(json['groups']),
    topMetric: json['top_metric'] as String?,
    hasInputOverlay: (json['has_input_overlay'] as bool?) ?? false,
    repeatGroup: _repeatGroup(json['repeat_group']),
  );
}

// ---------------------------------------------------------------- entities

List<Entity> _entities(Object? node) {
  if (node is! List) return const [];
  return node.map<Entity>((e) {
    final m = e as Map<String, dynamic>;
    return Entity(
      name: m['name'] as String,
      type: _entityType(m['type'] as String),
      keys: ((m['keys'] as List?) ?? const []).map((k) => k.toString()).toList(),
    );
  }).toList();
}

EntityType _entityType(String s) {
  switch (s) {
    case 'primary':
      return EntityType.primary;
    case 'foreign':
      return EntityType.foreign;
  }
  throw FormatException('engine: unknown entity type "$s"');
}

// -------------------------------------------------------------- dimensions

List<Dimension> _dimensions(Object? node) {
  if (node is! List) return const [];
  return node.map<Dimension>((e) {
    final m = e as Map<String, dynamic>;
    return Dimension(
      name: m['name'] as String,
      type: _dimensionType(m['type'] as String),
      expr: m['expr'] as String,
      description: m['description'] as String?,
      samples: (m['samples'] as List?)?.map((s) => s.toString()).toList(),
      input: _inputSpec(m['input']),
      derive: _derive(m['derive']),
      showWhen: _showWhen(m['show_when']),
    );
  }).toList();
}

DimensionType _dimensionType(String s) {
  switch (s) {
    case 'string':
      return DimensionType.string;
    case 'number':
      return DimensionType.number;
    case 'date':
      return DimensionType.date;
    case 'datetime':
      return DimensionType.datetime;
    case 'boolean':
      return DimensionType.boolean;
  }
  throw FormatException('engine: unknown dimension type "$s"');
}

InputSpec? _inputSpec(Object? node) {
  if (node is! Map) return null;
  final m = node.cast<String, dynamic>();
  return InputSpec(
    widget: _widget(m['widget'] as String),
    required: (m['required'] as bool?) ?? false,
    defaultValue: m['default'],
    min: m['min'] as num?,
    max: m['max'] as num?,
    options: (m['options'] as List?)?.map((s) => s.toString()).toList(),
    placeholder: m['placeholder'] as String?,
    editable: (m['editable'] as bool?) ?? true,
    nowButton: (m['now_button'] as bool?) ?? false,
    history: (m['history'] as bool?) ?? false,
    ladders: _ladders(m['ladders']),
    stopTargets: _stopTargets(m['stop_targets']),
    hrMaxTarget: m['hr_max_target'] as String?,
  );
}

WidgetType _widget(String s) {
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
    case 'dropdown':
      return WidgetType.dropdown;
    case 'autocomplete':
      return WidgetType.autocomplete;
    case 'timer':
      return WidgetType.timer;
  }
  throw FormatException('engine: unknown widget type "$s"');
}

List<TimerLadder>? _ladders(Object? node) {
  if (node is! List) return null;
  return node.map<TimerLadder>((e) {
    final m = e as Map<String, dynamic>;
    return TimerLadder(
      label: m['label'] as String,
      target: m['target'] as String,
      hrPct: (m['hr_pct'] as num?)?.toDouble(),
    );
  }).toList();
}

List<TimerStopTarget>? _stopTargets(Object? node) {
  if (node is! List) return null;
  return node.map<TimerStopTarget>((e) {
    final m = e as Map<String, dynamic>;
    return TimerStopTarget(
      target: m['target'] as String,
      format: _stopFormat(m['format'] as String? ?? 'elapsed'),
    );
  }).toList();
}

TimerStopFormat _stopFormat(String s) {
  switch (s) {
    case 'elapsed':
      return TimerStopFormat.elapsed;
    case 'seconds':
      return TimerStopFormat.seconds;
    // Rust serde rename_all = snake_case turns `TimeOfDay` into
    // `time_of_day`; YAML / Dart use the same. No alias needed.
    case 'time_of_day':
      return TimerStopFormat.timeOfDay;
  }
  throw FormatException('engine: unknown stop format "$s"');
}

Derive? _derive(Object? node) {
  if (node is! Map) return null;
  final m = node.cast<String, dynamic>();
  return Derive(
    from: m['from'] as String,
    format: _deriveFormat(m['format'] as String),
  );
}

DeriveFormat _deriveFormat(String s) {
  switch (s) {
    case 'weekday_long':
      return DeriveFormat.weekdayLong;
    case 'weekday_short':
      return DeriveFormat.weekdayShort;
    case 'iso_date':
      return DeriveFormat.isoDate;
    // Rust serde turns `IsoDateTime` into `iso_date_time`; the Dart-
    // side YAML parser also accepts `iso_datetime` (one underscore).
    // Accept both here so the adapter is symmetric.
    case 'iso_date_time':
    case 'iso_datetime':
      return DeriveFormat.isoDateTime;
  }
  throw FormatException('engine: unknown derive format "$s"');
}

Map<String, Object?>? _showWhen(Object? node) {
  if (node is! Map) return null;
  return node.cast<String, Object?>();
}

// ----------------------------------------------------------------- measures

List<Measure> _measures(Object? node) {
  if (node is! List) return const [];
  return node.map<Measure>((e) {
    final m = e as Map<String, dynamic>;
    return Measure(
      name: m['name'] as String,
      type: _measureType(m['type'] as String),
      expr: m['expr'] as String?,
      description: m['description'] as String?,
    );
  }).toList();
}

MeasureType _measureType(String s) {
  switch (s) {
    case 'count':
      return MeasureType.count;
    case 'sum':
      return MeasureType.sum;
    case 'average':
      return MeasureType.average;
    case 'max':
      return MeasureType.max;
    case 'min':
      return MeasureType.min;
    case 'count_distinct':
      return MeasureType.countDistinct;
    case 'custom':
      return MeasureType.custom;
    case 'number':
      return MeasureType.number;
  }
  throw FormatException('engine: unknown measure type "$s"');
}

// ----------------------------------------------------------- view-level bits

ListDisplay? _listDisplay(Object? node) {
  if (node is! Map) return null;
  final m = node.cast<String, dynamic>();
  return ListDisplay(
    title: m['title'] as String,
    subtitle: m['subtitle'] as String?,
  );
}

Plannable? _plannable(Object? node) {
  if (node is! Map) return null;
  final m = node.cast<String, dynamic>();
  return Plannable(
    logField: m['log_field'] as String,
    logFormat: _logFormat(m['log_format'] as String),
  );
}

LogFormat _logFormat(String s) {
  switch (s) {
    case 'time_string':
      return LogFormat.timeString;
    case 'iso_time':
      return LogFormat.isoTime;
    case 'iso_date_time':
    case 'iso_datetime':
      return LogFormat.isoDateTime;
  }
  throw FormatException('engine: unknown log format "$s"');
}

PostLogHook? _postLog(Object? node) {
  if (node is! Map) return null;
  final m = node.cast<String, dynamic>();
  return PostLogHook(
    model: m['model'] as String,
    prompt: m['prompt'] as String,
  );
}

Map<String, Set<String>> _groups(Object? node) {
  if (node is! Map) return const {};
  final out = <String, Set<String>>{};
  for (final entry in node.entries) {
    final name = entry.key.toString();
    final values = entry.value;
    if (values is List) {
      out[name] = values.map((e) => e.toString()).toSet();
    }
  }
  return out;
}

RepeatGroup? _repeatGroup(Object? node) {
  if (node is! Map) return null;
  final m = node.cast<String, dynamic>();
  return RepeatGroup(
    fields: (m['fields'] as List).map((e) => e.toString()).toList(),
    label: m['label'] as String,
    min: (m['min'] as int?) ?? 1,
    groupKey: m['group_key'] as String?,
  );
}
