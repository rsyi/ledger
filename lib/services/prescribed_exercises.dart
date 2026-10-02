/// Pure parser that turns a day's routine prose into a structured
/// checklist of prescribed exercises, and marks each one done when a
/// logged set satisfies it. This keeps the program view tightly coupled
/// to what was actually logged WITHOUT a separate "template" to drift —
/// the routine prose (which names front-lever up-downs, hanging leg
/// raises, muscle-ups and all) is the single source.
///
/// Matching is token-based and best-effort: a prescribed item is done
/// when a logged exercise shares a significant word (with a few aliases:
/// MU→muscle, RDL→romanian, BSS→bulgarian, OHP→overhead, HSPU→handstand).
///
/// Zero Flutter/IO imports; testable in pure Dart.
library;

import 'day_prescription.dart' show tidyProgramProse;

/// One prescribed exercise with its SET target (first-class) and how many
/// matching sets have been logged.
class PrescribedItem {
  final String name; // display name ("Squat", "Front lever up-downs")
  final String scheme; // rep/scheme remainder ("3x8-15", "top set …")
  final String period; // 'AM' | 'PM'

  /// Prescribed number of sets (parsed from the scheme — "2x5" → 2,
  /// "6 sets" → 6; defaults to 1 when the prose gives no count).
  final int targetSets;

  /// Matching sets logged so far.
  final int loggedSets;

  /// Set when an external source (Whoop) credited this item instead of
  /// logged sets — shown in place of the "k/N" counter ("strain 14.8").
  final String? creditNote;

  const PrescribedItem({
    required this.name,
    required this.scheme,
    required this.period,
    this.targetSets = 1,
    this.loggedSets = 0,
    this.creditNote,
  });

  /// Complete only when every prescribed set is logged.
  bool get done => loggedSets >= targetSets;

  PrescribedItem withLogged(int n) => PrescribedItem(
        name: name,
        scheme: scheme,
        period: period,
        targetSets: targetSets,
        loggedSets: n,
        creditNote: creditNote,
      );

  /// Marks the item complete on an external source's say-so.
  PrescribedItem withCredit(String note) => PrescribedItem(
        name: name,
        scheme: scheme,
        period: period,
        targetSets: targetSets,
        loggedSets: targetSets,
        creditNote: note,
      );
}

/// Parses the prescribed set count from a segment ("2x5" → 2,
/// "3-5x1-2" → 3, "6 sets" → 6, "3-4 quality sets" → 3). Defaults to 1.
int parseTargetSets(String text) {
  final x = RegExp(r'(\d+)(?:-\d+)?\s*x', caseSensitive: false).firstMatch(text);
  if (x != null) return int.parse(x.group(1)!);
  final sets =
      RegExp(r'(\d+)(?:-\d+)?\s*sets?', caseSensitive: false).firstMatch(text);
  if (sets != null) return int.parse(sets.group(1)!);
  return 1;
}

// Clauses that aren't exercises — skipped wholesale.
const _skip = [
  'no squat',
  'no deadlift',
  'no heavy',
  'avoid',
  'mind ',
  'easy day',
  'partner',
  'flex slot',
  'default is',
  'longest session',
  'through june',
  'mobility',
  'optional',
  'max hangs',
  'rest',
  'accessories:',
];

// Words that qualify an exercise but don't identify it.
const _stop = {
  'top', 'set', 'sets', 'heavy', 'light', 'back', 'offs', 'backoffs',
  'volume', 'skill', 'single', 'work', 'then', 'the', 'a', 'of', 'per',
  'quality', 'second', 'exposure', 'banded', 'strict', 'up', 'down',
  'downs', 'plus', 'and', 'or', 'first', 'easy', 'supplemental',
};

const _alias = {
  'mu': 'muscle',
  'rdl': 'romanian',
  'bss': 'bulgarian',
  'ohp': 'overhead',
  'hspu': 'handstand',
};

String _cap(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Parses the morning/afternoon prose into prescribed items (AM then PM).
List<PrescribedItem> parsePrescribedProse(String? morning, String? afternoon) {
  final out = <PrescribedItem>[];
  for (final entry in [('AM', morning), ('PM', afternoon)]) {
    final prose = entry.$2;
    if (prose == null) continue;
    // A leading "AM:"/"PM:" label is the period, not an exercise name.
    final tidy = tidyProgramProse(prose)
        .replaceFirst(RegExp(r'^\s*(?:AM|PM)\s*:\s*'), '');
    // Split on ';' and on ". then"/", then" (exercises are chained both
    // ways in the prose — "… hanging leg raise 3x8-15. Then dips 3x8-12"),
    // never inside parentheses ("(… movement quality; low fatigue)").
    for (var seg in _splitTopLevel(tidy)) {
      seg = seg.trim();
      if (seg.isEmpty) continue;
      // Skip words count only OUTSIDE parentheses — "(…; partner day)"
      // annotates a real session, it isn't a non-exercise clause.
      final low =
          seg.replaceAll(RegExp(r'\([^)]*\)?'), ' ').toLowerCase();
      if (_skip.any((k) => low.startsWith(k) || low.contains(k))) continue;
      // Name = text before the first ':', '(' or digit.
      final m = RegExp(r'[:(\d]').firstMatch(seg);
      var name = (m == null ? seg : seg.substring(0, m.start)).trim();
      name = name.replaceAll(RegExp(r'[^A-Za-z)]+$'), '').trim();
      // Drop filler segments that name no actual movement (e.g. a bare
      // "back-offs" left after a split) — nothing to match or check.
      if (name.length < 2 || _tokens(name).isEmpty) continue;
      var scheme = (m == null ? '' : seg.substring(m.start)).trim();
      scheme = scheme.replaceFirst(RegExp(r'^:\s*'), '').trim();
      out.add(PrescribedItem(
        name: _cap(name),
        scheme: scheme,
        period: entry.$1,
        targetSets: parseTargetSets(seg),
      ));
    }
  }
  return out;
}

/// Splits prose into exercise segments on ';', ". then"/", then" and a
/// sentence boundary that opens a labelled clause (". Accessories: …" —
/// a note, dropped via [_skip]), ignoring separators inside parentheses.
List<String> _splitTopLevel(String prose) {
  // Mask parenthesised spans so their ';' / "then" can't split.
  final masked = StringBuffer();
  var depth = 0;
  for (final ch in prose.split('')) {
    if (ch == '(') depth++;
    masked.write(depth > 0 ? '\u0000' : ch);
    if (ch == ')' && depth > 0) depth--;
  }
  final out = <String>[];
  var start = 0;
  for (final m
      in RegExp(r';|(?:[.,]\s+)[Tt]hen\s+|(?<=\.)\s+(?=[A-Z][a-z]+:)')
          .allMatches(masked.toString())) {
    out.add(prose.substring(start, m.start));
    start = m.end;
  }
  out.add(prose.substring(start));
  return out;
}

Set<String> _tokens(String s) {
  final cleaned =
      s.toLowerCase().replaceAll('-', ' ').replaceAll(RegExp(r'[^a-z ]'), ' ');
  final out = <String>{};
  for (var w in cleaned.split(RegExp(r'\s+'))) {
    if (w.isEmpty) continue;
    w = _alias[w] ?? w;
    // Stop words are checked BEFORE and after plural stripping — "offs"
    // is a stop word but stripped to "off" it leaked through, so
    // "Deadlift back-offs" never strong-matched "Barbell Deadlift".
    if (_stop.contains(w)) continue;
    // Plurals ("ups" too, so "Pull-ups" ~ "Pull-up").
    if (w.length > 2 && w.endsWith('s')) w = w.substring(0, w.length - 1);
    if (_stop.contains(w) || w.length < 2) continue;
    out.add(w);
  }
  return out;
}

/// True when a logged exercise name matches a prescribed name (shared
/// significant token). Public so the UI can pull a prescribed item's
/// history.
bool loggedMatchesPrescribed(String loggedName, String prescribedName) {
  final a = _tokens(loggedName);
  final b = _tokens(prescribedName);
  return a.isNotEmpty && b.isNotEmpty && a.intersection(b).isNotEmpty;
}

// Qualifiers that make a logged movement a DIFFERENT lift from a bare
// prescription ("Bulgarian Split Squat" is not "Squat", "Bench Press" is
// not "Press") — token form, see [_tokens].
const _variant = {
  'romanian', 'bulgarian', 'split', 'leg', 'bench', 'overhead', 'military',
  'hack', 'front', 'goblet', 'pistol', 'incline', 'decline',
};

/// STRONG match, for crediting spare sets from another day: EVERY
/// identifying token of the prescribed name appears in the logged name
/// ("Bench Press" covers "Bench heavy"; "Parallel Bar Triceps Dip" does
/// NOT cover "Triceps extension"), and the logged name adds no variant
/// qualifier the prescription lacks ("Bench Press" does not cover
/// "Press top set").
bool loggedCoversPrescribed(String loggedName, String prescribedName) {
  final a = _tokens(loggedName);
  // "RDL or leg curl" is a choice: covering EITHER alternative counts.
  for (final alt in prescribedName.split(RegExp(r'\s+or\s+', caseSensitive: false))) {
    final b = _tokens(alt);
    if (a.isEmpty || b.isEmpty || !a.containsAll(b)) continue;
    if (!a.difference(b).any(_variant.contains)) return true;
  }
  return false;
}

/// Shared significant tokens between a logged and a prescribed name — the
/// loose phase's tie-breaker (more shared words = better fit).
int sharedTokenCount(String loggedName, String prescribedName) =>
    _tokens(loggedName).intersection(_tokens(prescribedName)).length;

/// Counts, per prescribed item, how many logged sets match it (token
/// overlap). [loggedNames] is ONE entry per logged set, so the count is
/// the set count — an item completes only once its full set target lands.
List<PrescribedItem> markPrescribedDone(
    List<PrescribedItem> items, Iterable<String> loggedNames) {
  final loggedTokens =
      loggedNames.map(_tokens).where((t) => t.isNotEmpty).toList();
  return [
    for (final it in items)
      it.withLogged(() {
        final k = _tokens(it.name);
        if (k.isEmpty) return 0;
        return loggedTokens.where((l) => l.intersection(k).isNotEmpty).length;
      }()),
  ];
}
