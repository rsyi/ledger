/// Spreadsheet id parsing for the Settings "Spreadsheet" card (multi-user
/// sub-project 2): accepts a bare id or any Google Sheets URL shape.
library;

final _urlId = RegExp(r'/spreadsheets/(?:u/\d+/)?d/([A-Za-z0-9_-]{20,})');
final _bareId = RegExp(r'^[A-Za-z0-9_-]{25,}$');

/// The spreadsheet id in [input] — a bare id, or a
/// `docs.google.com/spreadsheets/[u/N/]d/<id>/…` URL. Null when nothing
/// id-shaped is there (other Google Docs URLs included).
String? parseSpreadsheetId(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final m = _urlId.firstMatch(s);
  if (m != null) return m.group(1);
  if (s.contains('/')) return null;
  return _bareId.hasMatch(s) ? s : null;
}
