/// Human-facing names for schema identifiers (UI redesign phase 5,
/// docs/superpowers/specs/2026-10-02-ui-redesign-design.md).
///
/// Views and fields are named for the sheet/engine (`daily_notes`,
/// `start_time`, `video_url`); the UI shows people words ("Daily notes",
/// "Start time", "Video"). A general humanizer (underscores → spaces,
/// sentence case, unit suffixes, acronyms) plus a small override map —
/// pure Dart, no schema key (input.yml has no `label:` and adding one
/// would need a Rust/dylib change, CLAUDE.md trap #1). dashboards.yaml
/// domains may still carry an explicit `label:` (engine-free), which
/// wins over [viewLabel].
library;

import '../models/view_schema.dart';

/// Views that are internal plumbing, never a Log-list row. program_moves
/// is edited through the program card (move/skip), not browsed.
const Set<String> kHiddenLogViews = {'program_moves'};

const Map<String, String> _viewOverrides = {
  'whoop_workouts': 'Whoop workouts',
  'program_moves': 'Program moves',
  'coach_chat': 'Coach',
};

const Map<String, String> _fieldOverrides = {
  'rpe': 'RPE',
  'set_type': 'Set type',
  'video_url': 'Video',
  'hold_seconds': 'Hold (s)',
  'duration': 'Duration (s)',
  'max_hr': 'Max HR',
  'weight_lbs': 'Weight (lb)',
  'waist_in': 'Waist (in)',
  'body_fat_caliper': 'Body fat % (caliper)',
  'body_fat_omron': 'Body fat % (Omron)',
  'body_fat_withing': 'Body fat % (Withings)',
  'treadmill_speed': 'Speed (mph)',
  'stairmaster_speed': 'Stairmaster level',
  'incline': 'Incline (%)',
  'zone4_reached': 'Zone 4 reached',
  'zone5_reached': 'Zone 5 reached',
  'eaten_at': 'Eaten at',
  'hc_id': 'Health Connect id',
};

/// Tokens rendered upper-case wherever they appear in a name.
const Set<String> _acronyms = {'rpe', 'rir', 'hr', 'id', 'hc', 'bf', 'ohp'};

/// Unit suffixes → a parenthesised unit on the humanized name.
const Map<String, String> _unitSuffixes = {
  'g': 'g',
  'lbs': 'lb',
  'lb': 'lb',
  'in': 'in',
  'seconds': 's',
  'sec': 's',
  'kcal': 'kcal',
};

String _humanize(String raw, {bool units = false}) {
  final parts = raw
      .trim()
      .split(RegExp(r'[_\-\s]+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return raw;
  String? unit;
  if (units && parts.length > 1 && _unitSuffixes.containsKey(parts.last)) {
    unit = _unitSuffixes[parts.removeLast()];
  }
  if (units && parts.length > 1 && parts.last == 'url') parts.removeLast();
  final words = <String>[];
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i].toLowerCase();
    if (_acronyms.contains(p)) {
      words.add(p.toUpperCase());
    } else if (i == 0) {
      words.add(p[0].toUpperCase() + p.substring(1));
    } else {
      words.add(p);
    }
  }
  final name = words.join(' ');
  return unit == null ? name : '$name ($unit)';
}

/// Display name for a view / domain id: `daily_notes` → "Daily notes".
String viewLabel(String name) => _viewOverrides[name] ?? _humanize(name);

/// Display label for a field: `start_time` → "Start time", `rpe` →
/// "RPE", `protein_g` → "Protein (g)", `video_url` → "Video".
String fieldLabel(String name) =>
    _fieldOverrides[name] ?? _humanize(name, units: true);

/// Field help that earns its line. Null = no helper. The empty string in
/// this map means "suppress the schema description" (the label or the
/// widget already says it).
const Map<String, String> _helpOverrides = {
  'start_time': 'Blank = planned · clock stamps now',
  'end_time': 'Clock stamps now',
  'rpe': 'RIR = 10 − RPE',
  'set_type': '',
  'video_url': 'Attach a clip from your phone',
  'paused': 'Off = touch-and-go',
  'belted': 'Off = beltless',
  'wrist_wraps': '',
  'knee_sleeves': '',
  'exercise': '',
  'duration': '',
  'hold_seconds': '',
  'notes': '',
  'note': '',
  'max_hr': 'Auto-filled from live HR when connected',
  'completed_intervals': 'Session total — fill on the last row',
  'body_fat_withing': 'Auto-filled by Withings',
  'waist_in': 'At the navel, morning, weekly',
  'sleep_quality': '1–5 (5 = best)',
  'fatigue': '1–5 (5 = wrecked)',
  'soreness': '1–5 (5 = worst)',
  'readiness': '1–5 (5 = fully ready)',
  'clean': 'Technically clean execution',
  'weight_lbs': '',
  'protein_g': '',
  'carbs_g': '',
  'fat_g': '',
  'meal_type': '',
  'skill': '',
};

/// Longest schema description still shown as a helper (one line).
const int _maxHelpChars = 48;

/// One-line helper for [dim], or null when it adds nothing: an override
/// when declared, else the description's first clause if it's short and
/// not just the label again. Date fields never get one (the picker says
/// it all).
String? fieldHelp(Dimension dim) {
  // Timer widgets (cardio start_time) say their own thing — the
  // strength-shaped start_time override would be wrong there.
  final override = dim.input?.widget == WidgetType.timer
      ? null
      : _helpOverrides[dim.name];
  if (override != null) return override.isEmpty ? null : override;
  if (dim.type == DimensionType.date || dim.type == DimensionType.datetime) {
    return null;
  }
  final first = shortDescription(dim.description, maxChars: _maxHelpChars);
  if (first == null) return null;
  final label = fieldLabel(dim.name).toLowerCase();
  final f = first.toLowerCase();
  if (f == label || label.startsWith(f) || f.startsWith(label)) return null;
  return first;
}

/// First clause of a schema description — cut at " — ", ". ", " (",
/// ";" — or null when that is still longer than [maxChars] (a truncated
/// half-sentence reads worse than nothing).
String? shortDescription(String? description, {int maxChars = 48}) {
  final d = description?.trim();
  if (d == null || d.isEmpty) return null;
  var cut = d.length;
  for (final sep in const [' — ', ' - ', '. ', ' (', '; ', ': ', ', ']) {
    final i = d.indexOf(sep);
    if (i > 0 && i < cut) cut = i;
  }
  var first = d.substring(0, cut).trim();
  if (first.endsWith('.')) first = first.substring(0, first.length - 1);
  if (first.isEmpty || first.length > maxChars) return null;
  return first;
}

/// Tokens kept upper-case when title-casing an all-lowercase exercise
/// name (calisthenics skills arrive as `hspu`, `handstand`, …).
const Set<String> _exerciseAcronyms = {'hspu', 'rdl', 'bss', 'ohp', 'ez'};

/// Display name for an exercise. Names that already carry capitals
/// (`Cable Face Pull`, `EZ-Bar Preacher Curl`) are shown as-is; an
/// all-lowercase name (a calisthenics skill like `handstand`,
/// `muscle-up`, `front lever`) is title-cased to match the strength
/// list: `Handstand`, `Muscle Up`, `Front Lever`, `HSPU`.
String exerciseLabel(String name) {
  final t = name.trim();
  if (t.isEmpty || t != t.toLowerCase()) return t;
  return t
      .split(RegExp(r'[_\-\s]+'))
      .where((p) => p.isNotEmpty)
      .map((p) => _exerciseAcronyms.contains(p)
          ? p.toUpperCase()
          : p[0].toUpperCase() + p.substring(1))
      .join(' ');
}

/// Sentence case for a generated summary: first letter upper, the rest
/// untouched (`squat heavy · bench volume` → `Squat heavy · bench
/// volume`; `4x4 · hard climb` stays as-is).
String sentenceCase(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
