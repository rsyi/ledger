/// Parsed representation of a `.view.yml` file from the schemas repo.
///
/// The schema combines two concerns in one file:
/// - The semantic layer (entities, dimensions, measures) — compatible with the
///   oxy/airlayer Cube-inspired format.
/// - The input layer (per-dimension `input:` block, top-level `date_field`,
///   `list_display`) — CRUD-specific extensions that the semantic-layer tools
///   ignore.
library;

enum DimensionType { string, number, date, datetime, boolean }

enum WidgetType {
  text,
  longtext,
  number,
  date,
  datetime,
  dropdown,
  autocomplete,
  /// Stopwatch input. Renders the field as a time-of-day text input with
  /// a Start button; once tapped, shows live elapsed time + one button
  /// per ladder. Each ladder button stamps `m:ss` (or `H:MM:SS` if past
  /// an hour) elapsed-since-Start into the named target field. Designed
  /// for interval logging (cardio Z4/Z5 reaches, climbing send times).
  timer,
}

enum EntityType { primary, foreign }

/// Mirrors airlayer's measure types. `custom` and `number` are
/// "passthrough" — the `expr` is emitted verbatim into SQL with no
/// aggregation wrapper, so the schema author can write things like
/// `STDDEV_SAMP(weight_lbs)` or a constant.
enum MeasureType { count, sum, average, max, min, countDistinct, custom, number }

/// Format used by the `derive:` block to compute a hidden field at save time.
enum DeriveFormat { weekdayLong, weekdayShort, isoDate, isoDateTime }

/// Format used by the `plannable.log_format` field for the "Log now" action.
enum LogFormat { timeString, isoTime, isoDateTime }

class ViewSchema {
  final String name;
  final String? description;
  final String datasource;
  final String table;
  final String? dateField;

  /// Optional per-view override of the default spreadsheet id (from
  /// `assets/config.yaml`). Lets one view target a different sheet without
  /// affecting others.
  final String? spreadsheetId;

  final List<Entity> entities;
  final List<Dimension> dimensions;
  final List<Measure> measures;
  final ListDisplay? listDisplay;
  final Plannable? plannable;

  /// Icon shown on the HomeScreen view tile and in tile leadings.
  /// Resolved via [IconResolver] — accepts lucide names (`dumbbell`),
  /// emoji (`💪`), or URLs.
  final String? icon;

  /// Optional post-log hook — triggers an LLM after a row is logged.
  /// See [PostLogHook].
  final PostLogHook? postLog;

  /// Named, reusable value sets sourced from the .input.yml's top-level
  /// `groups:` block. Referenced by `show_when: { ..: in_group: <name> }`
  /// so fields can share a list (e.g. "isometric exercises") without
  /// duplicating it on every show_when. Empty when no groups: declared.
  final Map<String, Set<String>> groups;

  /// Optional name of a measure on this view used to score rows for the
  /// history panel's per-day "top" highlight. The measure's `expr` is
  /// evaluated per row (via Jinja) — the row with the largest score on
  /// each day gets highlighted. Lets the schema author say "top set is
  /// max e1rm" instead of falling back to noisy "max of any numeric
  /// dimension." Null disables the highlight.
  final String? topMetric;

  /// True when this view has a paired `.input.yml` overlay (i.e. it's a
  /// data-entry tracker). False when the view is analytics-only — its
  /// dimensions and measures are intended for airlayer queries
  /// (e.g. virtual dimensions with SQL exprs like `CAST(date AS DATE)`,
  /// custom measures like `STDDEV_SAMP(...)`) and it should NOT appear
  /// as a tappable tracker on the home screen or be passed to
  /// `ensureTable` (which would try to write the SQL exprs as sheet
  /// headers).
  final bool hasInputOverlay;

  /// Optional declaration that a subset of fields repeats together. The
  /// form renders a "+ Add <label>" button; on save the repeating fields
  /// fan out into N rows (one per block) that share every other field.
  /// See [RepeatGroup].
  final RepeatGroup? repeatGroup;

  ViewSchema({
    required this.name,
    this.description,
    required this.datasource,
    required this.table,
    this.dateField,
    this.spreadsheetId,
    required this.entities,
    required this.dimensions,
    required this.measures,
    this.listDisplay,
    this.plannable,
    this.icon,
    this.postLog,
    this.groups = const {},
    this.topMetric,
    this.hasInputOverlay = false,
    this.repeatGroup,
  });

  Dimension? dimensionByName(String name) =>
      dimensions.where((d) => d.name == name).firstOrNull;

  /// Looks up a dimension by its `expr` (the sheet column name).
  /// Falls back to `name` for backward compatibility with views whose
  /// dimensions don't specify expr.
  Dimension? dimensionByExpr(String expr) =>
      dimensions.where((d) => d.expr == expr).firstOrNull ??
      dimensions.where((d) => d.name == expr).firstOrNull;

  /// Dimensions that should appear in the entry form (input.editable != false
  /// and not derived).
  List<Dimension> get editableDimensions => dimensions
      .where((d) => (d.input?.editable ?? true) && d.derive == null)
      .toList();

  /// Dimensions with a `derive:` block (auto-computed at save time).
  List<Dimension> get derivedDimensions =>
      dimensions.where((d) => d.derive != null).toList();
}

class Entity {
  final String name;
  final EntityType type;
  final List<String> keys;

  Entity({required this.name, required this.type, required this.keys});
}

class Dimension {
  final String name;
  final DimensionType type;
  final String expr;
  final String? description;
  final List<String>? samples;
  final InputSpec? input;
  final Derive? derive;

  /// Conditional visibility: only show this dimension in the form when every
  /// (key, value) pair here matches the form's current values. Used for
  /// polymorphic records like cardio sets where treadmill-specific fields
  /// should only appear when type=treadmill.
  ///
  /// Comparison is loose: dimension values are compared by `==` after
  /// coercing both sides to their string form (handles num/string mismatches
  /// from form vs YAML).
  final Map<String, Object?>? showWhen;

  Dimension({
    required this.name,
    required this.type,
    required this.expr,
    this.description,
    this.samples,
    this.input,
    this.derive,
    this.showWhen,
  });

  /// Whether this dimension should be visible in the form given the current
  /// values map. Always visible when `show_when` is absent.
  ///
  /// Each `show_when` entry is `<field>: <predicate>`. All entries are AND'd.
  /// A predicate is one of:
  ///   - scalar     → exact-equal match against the field's stringified value
  ///   - list       → implicit `in` (field value must be one of these)
  ///   - operator-map with any combination of:
  ///       eq:           <scalar>           → exact match
  ///       in:           [<val>, ...]       → field value in this list
  ///       not_in:       [<val>, ...]       → field value NOT in this list
  ///       in_group:     <name> or [<name>] → in the union of these groups
  ///       not_in_group: <name> or [<name>] → in none of these groups
  ///     All ops in the same map are AND'd.
  ///
  /// Groups are named value-sets sourced from the .input.yml's top-level
  /// `groups:` block (passed in [groups]). They let multiple fields
  /// reference the same list without duplication — e.g. "isometric
  /// exercises" defined once, used by weight/reps to hide and by
  /// duration to show.
  bool isVisibleGiven(
    Map<String, Object?> values, [
    Map<String, Set<String>>? groups,
  ]) {
    if (showWhen == null) return true;
    final groupMap = groups ?? const <String, Set<String>>{};
    for (final entry in showWhen!.entries) {
      final actual = values[entry.key]?.toString();
      if (!_evalPredicate(entry.value, actual, groupMap)) return false;
    }
    return true;
  }

  static bool _evalPredicate(
    Object? pred,
    String? actual,
    Map<String, Set<String>> groups,
  ) {
    if (pred == null) return actual == null;
    if (pred is String || pred is num || pred is bool) {
      return pred.toString() == actual;
    }
    if (pred is List) {
      return actual != null &&
          pred.map((e) => e.toString()).contains(actual);
    }
    if (pred is Map) {
      // Every operator in the map must hold (AND).
      if (pred.containsKey('eq')) {
        if (pred['eq']?.toString() != actual) return false;
      }
      if (pred.containsKey('in')) {
        final list = (pred['in'] as List).map((e) => e.toString()).toSet();
        if (actual == null || !list.contains(actual)) return false;
      }
      if (pred.containsKey('not_in')) {
        final list =
            (pred['not_in'] as List).map((e) => e.toString()).toSet();
        if (actual != null && list.contains(actual)) return false;
      }
      if (pred.containsKey('in_group')) {
        final names = _asNameList(pred['in_group']);
        final union = <String>{};
        for (final n in names) {
          union.addAll(groups[n] ?? const {});
        }
        if (actual == null || !union.contains(actual)) return false;
      }
      if (pred.containsKey('not_in_group')) {
        final names = _asNameList(pred['not_in_group']);
        final union = <String>{};
        for (final n in names) {
          union.addAll(groups[n] ?? const {});
        }
        if (actual != null && union.contains(actual)) return false;
      }
      return true;
    }
    return false;
  }

  static List<String> _asNameList(Object? v) {
    if (v is String) return [v];
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }
}

class InputSpec {
  final WidgetType widget;
  final bool required;
  final dynamic defaultValue;
  final num? min;
  final num? max;
  final List<String>? options;
  final String? placeholder;
  final bool editable;

  /// If true, the field renders a clock-icon suffix button that stamps the
  /// current time (formatted like "3:54:00 PM") into the field on tap.
  /// Useful for "Start Time"-style columns.
  final bool nowButton;

  /// If true, the field renders a history-icon suffix button that opens a
  /// bottom sheet listing all past records sharing the field's current
  /// value. Useful for dimensions whose value identifies a recurring
  /// entity (an exercise, a meal, a route) where users want to see how
  /// they've logged it before.
  final bool history;

  /// For `widget: timer` fields. Each entry adds a "tap when reached"
  /// button below the timer that writes elapsed time into the named
  /// [TimerLadder.target] dim. Ignored for non-timer widgets.
  final List<TimerLadder>? ladders;

  /// For `widget: timer` fields. Each entry is a dim the Stop button
  /// writes into when tapped, with a [TimerStopFormat] controlling how
  /// the value is encoded — elapsed `m:ss` string, raw seconds as a
  /// number, or the current time-of-day. Multiple entries let one timer
  /// fan out (e.g. write `duration: 90` AND `end_time: "10:42:00 AM"`
  /// in the same Stop tap; show_when then drops whichever doesn't
  /// apply for the selected exercise at save). Empty = Stop just
  /// freezes the display.
  final List<TimerStopTarget>? stopTargets;

  /// For `widget: timer` fields. Dim that receives the highest live BPM
  /// observed while the timer ran (written as a number on Stop). Fed by
  /// the BLE heart-rate service; null = no HR max capture.
  final String? hrMaxTarget;

  InputSpec({
    required this.widget,
    this.required = false,
    this.defaultValue,
    this.min,
    this.max,
    this.options,
    this.placeholder,
    this.editable = true,
    this.nowButton = false,
    this.history = false,
    this.ladders,
    this.stopTargets,
    this.hrMaxTarget,
  });
}

/// Encoding for a timer's Stop value.
///   - `elapsed` (default): `m:ss` or `H:MM:SS` string, the same shape
///     ladder chips emit. Use for fields like `total_time`.
///   - `seconds`: total elapsed as an integer number (seconds). Use for
///     numeric fields like `duration`.
///   - `timeOfDay`: current wall-clock time as `h:mm:ss a` string. Use
///     for fields like `end_time` where you want the moment of stop,
///     not a duration.
enum TimerStopFormat { elapsed, seconds, timeOfDay }

class TimerStopTarget {
  final String target;
  final TimerStopFormat format;

  const TimerStopTarget({required this.target, required this.format});
}

/// One step in a [WidgetType.timer]'s ladder. Tapping the rendered button
/// stamps elapsed-time-since-start into [target] (a dim name on the
/// same view).
class TimerLadder {
  final String label;
  final String target;

  /// Auto-stamp threshold as percent of the user's max HR (ledger meta
  /// `user_max_hr`). When set and a live BLE HR source is connected,
  /// the ladder fires automatically the first time live BPM reaches
  /// the threshold while the timer runs. Null = manual tap only.
  final double? hrPct;

  const TimerLadder({required this.label, required this.target, this.hrPct});
}

/// A small derived-field spec: take the value of dimension [from], pass it
/// through [format], and write the result into this dimension at save time.
/// Derived dimensions are hidden from the form.
class Derive {
  final String from;
  final DeriveFormat format;

  Derive({required this.from, required this.format});
}

class Measure {
  final String name;
  final MeasureType type;
  final String? expr;
  final String? description;

  Measure({
    required this.name,
    required this.type,
    this.expr,
    this.description,
  });
}

class ListDisplay {
  final String title;
  final String? subtitle;

  ListDisplay({required this.title, this.subtitle});
}

/// Config for "plan then log" workflow: rows with [logField] empty are
/// considered planned and get a "Log now" action in the timeline.
class Plannable {
  final String logField;
  final LogFormat logFormat;

  Plannable({required this.logField, required this.logFormat});
}

/// Post-log hook: after a row is committed to the warehouse, render
/// [prompt] (Jinja2) against the row + view context, send it to the
/// configured [model], and surface the response in the timeline.
///
/// Configured in `.input.yml`:
///
/// ```yaml
/// post_log:
///   model: openai-mini             # references a name from config.yml models:
///   prompt: |
///     Briefly comment on this {{ view.name }} entry:
///     {{ row }}
/// ```
/// Declares that a subset of a view's fields repeats together within a
/// single form session. The form renders the non-repeating fields once,
/// then N blocks of the repeating fields (each block being one "row" the
/// user is logging), with a "+ Add <label>" button to spawn another
/// block. On save the form fans out into N records, each sharing every
/// non-repeating field.
///
/// For sauces: shared = (date, sauce, batch_qty, batch_unit, notes);
/// repeating = (ingredient, ingredient_qty, ingredient_unit). One batch
/// with three ingredients writes three rows.
///
/// Schema example:
/// ```yaml
/// repeat_group:
///   fields: [ingredient, ingredient_qty, ingredient_unit]
///   label: Ingredient
///   min: 1
/// ```
class RepeatGroup {
  /// Names of the dimensions that repeat together. Each named dim must
  /// exist as an editable field on the view.
  final List<String> fields;

  /// Singular noun for the "+ Add X" button and per-block header.
  /// (e.g. "Ingredient" → "+ Add Ingredient", "Ingredient #1").
  final String label;

  /// Minimum block count. Below this the delete (×) on a block hides so
  /// the user can't drop below it. Default 1.
  final int min;

  /// Optional dimension name that holds the batch UUID — the value
  /// shared across all rows in one save. When set, the form generates
  /// one UUID at save time and stamps it into this field on every fan-
  /// out row. The timeline groups rows by this field so the batch
  /// renders as a single tile, and edit/delete operate on the whole
  /// batch (all rows sharing the same value). Required for the
  /// "batch-as-entity" UX; without it, rows live independently.
  final String? groupKey;

  RepeatGroup({
    required this.fields,
    required this.label,
    this.min = 1,
    this.groupKey,
  });
}

class PostLogHook {
  /// Model name from `config.yml` `models:`.
  final String model;

  /// Jinja2 prompt template. Available context: `view` (ViewSchema-ish
  /// map), `row` (the just-logged record).
  final String prompt;

  PostLogHook({required this.model, required this.prompt});
}
