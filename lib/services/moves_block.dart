/// Splits an LLM briefing into its prose and the optional fenced
/// ```` ```moves ```` JSON block the nightly prompt asks for (missed-work
/// carryover, spec 2026-10-02 §5).
///
/// Pure: no Flutter/IO imports.
library;

import 'dart:convert';

import '../models/coach_proposal.dart';

// Opener: a line that is exactly ```moves (any case, trailing spaces ok).
final _opener = RegExp(r'^[ \t]*```[ \t]*moves[ \t]*$',
    caseSensitive: false, multiLine: true);
final _closer = RegExp(r'^[ \t]*```[ \t]*$', multiLine: true);

/// Finds the FIRST ```moves … ``` block in [llmOutput]. The block body is
/// `{summary, moves:[…]}` (a full `{v, type, …}` payload is accepted
/// too). Returns the output with the block removed (trimmed, runs of
/// blank lines collapsed to one) and the parsed proposal — null when
/// there is no block, the JSON doesn't parse, or no move is valid. An
/// unterminated block runs to the end of the text.
({String text, MovesProposal? proposal}) extractMovesBlock(
    String llmOutput) {
  final open = _opener.firstMatch(llmOutput);
  if (open == null) return (text: llmOutput.trim(), proposal: null);
  final close = _closer.firstMatch(llmOutput.substring(open.end));
  final bodyEnd = close == null ? llmOutput.length : open.end + close.start;
  final blockEnd = close == null ? llmOutput.length : open.end + close.end;
  final body = llmOutput.substring(open.end, bodyEnd);
  final text = (llmOutput.substring(0, open.start) +
          llmOutput.substring(blockEnd))
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return (text: text, proposal: _parse(body));
}

MovesProposal? _parse(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body.trim());
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final payload = <String, Object?>{
    ...decoded.map((k, v) => MapEntry(k.toString(), v)),
    'v': MovesProposal.version,
    'type': MovesProposal.type,
  };
  if (decoded['type'] != null && decoded['type'] != MovesProposal.type) {
    return null;
  }
  return MovesProposal.tryParse(jsonEncode(payload));
}
