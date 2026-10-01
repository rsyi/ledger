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

/// One prescribed exercise (+ whether it's been logged today).
class PrescribedItem {
  final String name; // display name ("Squat", "Front lever up-downs")
  final String scheme; // rep/scheme remainder ("3x8-15", "top set …")
  final String period; // 'AM' | 'PM'
  final bool done;

  const PrescribedItem({
    required this.name,
    required this.scheme,
    required this.period,
    this.done = false,
  });

  PrescribedItem markDone(bool d) =>
      PrescribedItem(name: name, scheme: scheme, period: period, done: d);
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
    final tidy = tidyProgramProse(prose);
    for (var seg in tidy.split(';')) {
      seg = seg.trim();
      if (seg.isEmpty) continue;
      final low = seg.toLowerCase();
      if (_skip.any((k) => low.startsWith(k) || low.contains(k))) continue;
      // Name = text before the first ':', '(' or digit.
      final m = RegExp(r'[:(\d]').firstMatch(seg);
      var name = (m == null ? seg : seg.substring(0, m.start)).trim();
      name = name.replaceAll(RegExp(r'[,.]+$'), '').trim();
      if (name.isEmpty || name.length < 2) continue;
      var scheme = (m == null ? '' : seg.substring(m.start)).trim();
      scheme = scheme.replaceFirst(RegExp(r'^:\s*'), '').trim();
      out.add(PrescribedItem(name: _cap(name), scheme: scheme, period: entry.$1));
    }
  }
  return out;
}

Set<String> _tokens(String s) {
  final cleaned =
      s.toLowerCase().replaceAll('-', ' ').replaceAll(RegExp(r'[^a-z ]'), ' ');
  final out = <String>{};
  for (var w in cleaned.split(RegExp(r'\s+'))) {
    if (w.isEmpty) continue;
    w = _alias[w] ?? w;
    if (w.length > 3 && w.endsWith('s')) w = w.substring(0, w.length - 1);
    if (_stop.contains(w) || w.length < 2) continue;
    out.add(w);
  }
  return out;
}

/// Marks each prescribed item done when any [loggedNames] exercise shares a
/// significant token with it.
List<PrescribedItem> markPrescribedDone(
    List<PrescribedItem> items, Iterable<String> loggedNames) {
  final loggedTokens = loggedNames.map(_tokens).where((t) => t.isNotEmpty).toList();
  return [
    for (final it in items)
      it.markDone(() {
        final k = _tokens(it.name);
        if (k.isEmpty) return false;
        return loggedTokens.any((l) => l.intersection(k).isNotEmpty);
      }()),
  ];
}
