import 'dart:async';
import 'dart:io';

import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'cell_codec.dart';
import 'google_auth/sheets_auth.dart';
import 'warehouse_connector.dart';

/// One row from a sheet, keyed by dimension name.
///
/// Records loaded from [list] carry their sheet row position in a special
/// `__row` key (zero-based data row index, i.e. row 0 == row 2 in the
/// sheet because row 1 is the header). [update] uses this when the `id`
/// dimension is missing or empty — e.g. existing rows that predate ledger
/// adding an id column.
typedef Record = Map<String, Object?>;

/// Key used to stash the zero-based data row index on records loaded from
/// the sheet, so [SheetsRepository.update] can identify them even when id
/// is missing. Public so callers can bump indexes after an insert-at-top.
const rowIndexKey = '__row';

/// Parses a time-of-day string into a duration-since-midnight, so sort
/// comparators can order rows chronologically rather than lexically.
/// Recognized formats: 12-hour `h:mm:ss a` / `h:mm a` (with the AM/PM
/// suffix used by `now_button`'s `DateFormat('h:mm:ss a')`) and
/// 24-hour `H:mm:ss` / `H:mm` for sheets the user edited by hand.
/// Returns null for inputs that don't match either family — callers
/// fall back to string compare in that case.
Duration? _parseTime(String s) {
  for (final fmt in const [
    'h:mm:ss a',
    'h:mm a',
    'H:mm:ss',
    'H:mm',
  ]) {
    try {
      final dt = DateFormat(fmt).parseLoose(s);
      return Duration(
        hours: dt.hour,
        minutes: dt.minute,
        seconds: dt.second,
      );
    } catch (_) {/* try next */}
  }
  return null;
}

/// CRUD over Google Sheets — one implementation of [WarehouseConnector].
/// Each [ViewSchema] picks a spreadsheet (its own `spreadsheet_id` override
/// or the default) and a tab (its `table`). Row 1 is the header row; cell
/// columns are matched to dimensions by [Dimension.expr].
class SheetsRepository implements WarehouseConnector {
  @override
  final SheetsConfig config;
  final String defaultSpreadsheetId;
  final sheets.SheetsApi _api;
  static const _uuid = Uuid();

  /// Cache of headers per (spreadsheet, tab) so writes don't re-fetch row 1.
  final Map<String, List<String>> _headerCache = {};

  SheetsRepository._(this.config, this.defaultSpreadsheetId, this._api);

  /// Authenticates via a service account key and returns a client. Caller
  /// is responsible for sourcing the JSON (file, asset, etc).
  static Future<SheetsRepository> connectFromKey({
    required String defaultSpreadsheetId,
    required String serviceAccountKeyJson,
    SheetsConfig? config,
  }) async {
    final credentials = ServiceAccountCredentials.fromJson(
      serviceAccountKeyJson,
    );
    final authed = await clientViaServiceAccount(
      credentials,
      [sheets.SheetsApi.spreadsheetsScope],
    );
    // Wrap the auth client so every Sheets call survives transient cold-
    // start network errors ("software caused connection abort", DNS not
    // ready, TLS handshake races) without surfacing them to the user.
    final client = _RetryingClient(authed);
    final api = sheets.SheetsApi(client);
    return SheetsRepository._(
      config ?? SheetsConfig(name: 'gsheets', spreadsheetId: defaultSpreadsheetId),
      defaultSpreadsheetId,
      api,
    );
  }

  /// Same as [connectFromKey] over any [SheetsAuth] (service account on
  /// the owner build, the user's Google token otherwise — multi-user).
  static Future<SheetsRepository> connectWithAuth({
    required String defaultSpreadsheetId,
    required SheetsAuth auth,
    SheetsConfig? config,
  }) async {
    final client = _RetryingClient(await auth.client());
    return SheetsRepository._(
      config ??
          SheetsConfig(name: 'gsheets', spreadsheetId: defaultSpreadsheetId),
      defaultSpreadsheetId,
      sheets.SheetsApi(client),
    );
  }

  String _spreadsheetIdFor(ViewSchema view) =>
      view.spreadsheetId ?? defaultSpreadsheetId;

  String _cacheKey(ViewSchema view) =>
      '${_spreadsheetIdFor(view)}|${view.table}';

  /// Ensures the sheet tab exists and has every header the view expects.
  /// Additive — preserves existing headers (and their order) and only appends
  /// missing columns at the end. Safe to run against pre-existing sheets.
  @override
  Future<void> ensureTable(ViewSchema view) => ensureSheet(view);

  /// Sheets-specific name preserved for clarity. Identical behavior to
  /// [ensureTable].
  Future<void> ensureSheet(ViewSchema view) async {
    final spreadsheetId = _spreadsheetIdFor(view);
    final ss = await _api.spreadsheets.get(spreadsheetId);
    final tabExists = (ss.sheets ?? []).any(
      (s) => s.properties?.title == view.table,
    );

    if (!tabExists) {
      await _api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(
          requests: [
            sheets.Request(
              addSheet: sheets.AddSheetRequest(
                properties: sheets.SheetProperties(title: view.table),
              ),
            ),
          ],
        ),
        spreadsheetId,
      );
    }

    final hdrResp = await _api.spreadsheets.values.get(
      spreadsheetId,
      "'${view.table}'!1:1",
    );
    final existingHeaders = (hdrResp.values?.isEmpty ?? true)
        ? <String>[]
        : hdrResp.values!.first.map((e) => e.toString()).toList();
    final wantHeaders = view.dimensions.map((d) => d.expr).toList();
    final missing = wantHeaders.where((h) => !existingHeaders.contains(h)).toList();

    if (existingHeaders.isNotEmpty && missing.isEmpty) {
      _headerCache[_cacheKey(view)] = existingHeaders;
      return;
    }

    final newHeaders = existingHeaders.isEmpty
        ? wantHeaders
        : [...existingHeaders, ...missing];
    await _api.spreadsheets.values.update(
      sheets.ValueRange(values: [newHeaders]),
      spreadsheetId,
      "'${view.table}'!A1",
      valueInputOption: 'RAW',
    );
    _headerCache[_cacheKey(view)] = newHeaders;
  }

  /// Lists all records for [view], optionally filtered to those whose
  /// `date_field` falls on [onDate].
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async {
    final spreadsheetId = _spreadsheetIdFor(view);
    final values = await _readAll(spreadsheetId, view.table);
    if (values.isEmpty) return [];
    final headers = values.first.map((e) => e.toString()).toList();
    _headerCache[_cacheKey(view)] = headers;

    final records = <Record>[];
    for (var i = 1; i < values.length; i++) {
      final record = _rowToRecord(view, headers, values[i]);
      record[rowIndexKey] = i - 1; // zero-based data row
      records.add(record);
    }

    if (onDate != null && view.dateField != null) {
      final filtered = records.where((r) {
        final v = r[view.dateField];
        if (v is! DateTime) return false;
        return v.year == onDate.year &&
            v.month == onDate.month &&
            v.day == onDate.day;
      }).toList();
      // Within a date, sort ascending by the plannable log field (start_time)
      // so the first set of the day appears first. We parse as a real
      // time-of-day before comparing — naive string compare puts
      // "10:42:00 AM" before "9:23:00 AM" because "1" < "9" lexically.
      final logField = view.plannable?.logField;
      filtered.sort((a, b) {
        if (logField != null) {
          final av = a[logField]?.toString() ?? '';
          final bv = b[logField]?.toString() ?? '';
          if (av.isEmpty && bv.isEmpty) return 0;
          if (av.isEmpty) return 1; // missing times sort last
          if (bv.isEmpty) return -1;
          final at = _parseTime(av);
          final bt = _parseTime(bv);
          if (at != null && bt != null) return at.compareTo(bt);
          return av.compareTo(bv);
        }
        final ar = a[rowIndexKey] as int? ?? 0;
        final br = b[rowIndexKey] as int? ?? 0;
        return ar.compareTo(br);
      });
      return filtered;
    }
    return records;
  }

  /// Inserts a new record at the top of the data section (sheet row 2, right
  /// below the header). Assigns a UUID for `id` if the view has an id
  /// dimension and the record doesn't already have one. The returned record
  /// carries `__row = 0` so the caller can use it without round-tripping.
  ///
  /// Note: every existing in-memory record's `__row` index becomes stale by
  /// -1 after this call. Callers that maintain a list of records must bump
  /// their `__row` values by +1 (see [shiftRowIndexes]).
  @override
  Future<Record> create(ViewSchema view, Record record) async {
    final spreadsheetId = _spreadsheetIdFor(view);
    final headers = await _ensureHeaders(view);
    final toWrite = Map<String, Object?>.from(record);
    if (view.dimensionByName('id') != null) {
      toWrite['id'] ??= _uuid.v4();
    }

    final row = headers.map<Object>((h) {
      final dim = view.dimensionByExpr(h);
      if (dim == null) return '';
      return CellCodec.encode(dim.type, toWrite[dim.name]);
    }).toList();

    final sheetId = await _sheetIdFor(spreadsheetId, view.table);
    await _api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(
        requests: [
          sheets.Request(
            insertDimension: sheets.InsertDimensionRequest(
              range: sheets.DimensionRange(
                sheetId: sheetId,
                dimension: 'ROWS',
                startIndex: 1,
                endIndex: 2,
              ),
              inheritFromBefore: false,
            ),
          ),
        ],
      ),
      spreadsheetId,
    );
    await _api.spreadsheets.values.update(
      sheets.ValueRange(values: [row]),
      spreadsheetId,
      "'${view.table}'!A2",
      valueInputOption: 'RAW',
    );
    toWrite[rowIndexKey] = 0;
    return toWrite;
  }

  /// In-memory shift of `__row` indexes on a list of records. After a
  /// successful [create] (insert-at-top), call this with `by: 1` on every
  /// previously-loaded record so subsequent updates/deletes resolve to the
  /// correct sheet row.
  static void shiftRowIndexes(Iterable<Record> records, {required int by}) {
    for (final r in records) {
      final v = r[rowIndexKey];
      if (v is int) r[rowIndexKey] = v + by;
    }
  }

  /// Updates an existing record. Resolution order:
  ///   1. If the record carries a `__row` index (set by [list]), use that
  ///      directly. This works for rows loaded from the sheet even when they
  ///      lack an id value (e.g. legacy rows predating the id column).
  ///   2. Otherwise, look up by `id`.
  ///
  /// Preserves cells in columns we don't know about — only overwrites cells
  /// whose header maps to a dimension in [view]. Auto-assigns a UUID to the
  /// id field if the view has one and the record doesn't yet.
  @override
  Future<void> update(ViewSchema view, Record record) async {
    final spreadsheetId = _spreadsheetIdFor(view);
    final headers = await _ensureHeaders(view);

    int? rowIndex;
    final stashed = record[rowIndexKey];
    if (stashed is int) {
      rowIndex = stashed;
    } else {
      final id = record['id'];
      if (id == null) {
        throw ArgumentError(
          'Cannot update a record without an id or row index',
        );
      }
      rowIndex = await _findRowIndex(view, id.toString());
      if (rowIndex == null) {
        throw StateError('No row with id=$id in ${view.table}');
      }
    }

    // Backfill id for legacy rows that don't have one yet.
    if (view.dimensionByName('id') != null && record['id'] == null) {
      record['id'] = _uuid.v4();
    }

    final existingRow = await _readRow(spreadsheetId, view.table, rowIndex);

    final row = <Object>[];
    for (var i = 0; i < headers.length; i++) {
      final h = headers[i];
      final dim = view.dimensionByExpr(h);
      if (dim != null) {
        row.add(CellCodec.encode(dim.type, record[dim.name]));
      } else {
        // Preserve unknown columns verbatim (whatever type the API gave us).
        row.add(i < existingRow.length ? (existingRow[i] ?? '') : '');
      }
    }

    await _api.spreadsheets.values.update(
      sheets.ValueRange(values: [row]),
      spreadsheetId,
      "'${view.table}'!A${rowIndex + 2}",
      valueInputOption: 'RAW',
    );
  }

  /// Deletes [record]'s sheet row. Resolution order mirrors [update]:
  /// the stashed `__row` index from [list], then falling back to lookup by
  /// `id`. Returns silently if the row can't be located.
  @override
  Future<void> delete(ViewSchema view, Record record) async {
    final spreadsheetId = _spreadsheetIdFor(view);
    int? rowIndex;
    final stashed = record[rowIndexKey];
    if (stashed is int) {
      rowIndex = stashed;
    } else {
      final id = record['id']?.toString();
      if (id != null && id.isNotEmpty) {
        rowIndex = await _findRowIndex(view, id);
      }
    }
    if (rowIndex == null) return;
    final sheetId = await _sheetIdFor(spreadsheetId, view.table);
    await _api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(
        requests: [
          sheets.Request(
            deleteDimension: sheets.DeleteDimensionRequest(
              range: sheets.DimensionRange(
                sheetId: sheetId,
                dimension: 'ROWS',
                startIndex: rowIndex + 1,
                endIndex: rowIndex + 2,
              ),
            ),
          ),
        ],
      ),
      spreadsheetId,
    );
  }

  // --- internals ---

  Future<List<List<Object?>>> _readAll(String spreadsheetId, String table) async {
    final resp = await _api.spreadsheets.values.get(
      spreadsheetId,
      "'$table'",
    );
    return (resp.values ?? <List<Object?>>[])
        .map((row) => row.cast<Object?>())
        .toList();
  }

  Future<List<Object?>> _readRow(
    String spreadsheetId,
    String table,
    int rowIndex,
  ) async {
    final resp = await _api.spreadsheets.values.get(
      spreadsheetId,
      "'$table'!${rowIndex + 2}:${rowIndex + 2}",
    );
    final rows = resp.values ?? [];
    return rows.isEmpty ? [] : rows.first.cast<Object?>();
  }

  Future<List<String>> _ensureHeaders(ViewSchema view) async {
    final cached = _headerCache[_cacheKey(view)];
    if (cached != null) return cached;
    final spreadsheetId = _spreadsheetIdFor(view);
    final resp = await _api.spreadsheets.values.get(
      spreadsheetId,
      "'${view.table}'!1:1",
    );
    final row = resp.values?.first ?? [];
    final headers = row.map((e) => e.toString()).toList();
    _headerCache[_cacheKey(view)] = headers;
    return headers;
  }

  Future<int?> _findRowIndex(ViewSchema view, String id) async {
    final spreadsheetId = _spreadsheetIdFor(view);
    final idDim = view.dimensionByName('id');
    if (idDim == null) return null;
    final values = await _readAll(spreadsheetId, view.table);
    if (values.isEmpty) return null;
    final headers = values.first.map((e) => e.toString()).toList();
    final idCol = headers.indexOf(idDim.expr);
    if (idCol < 0) return null;
    for (var i = 1; i < values.length; i++) {
      final row = values[i];
      if (row.length > idCol && row[idCol].toString() == id) {
        return i - 1;
      }
    }
    return null;
  }

  Future<int> _sheetIdFor(String spreadsheetId, String tabName) async {
    final ss = await _api.spreadsheets.get(spreadsheetId);
    for (final s in ss.sheets ?? <sheets.Sheet>[]) {
      if (s.properties?.title == tabName) {
        return s.properties!.sheetId!;
      }
    }
    throw StateError('No sheet tab named "$tabName"');
  }

  Record _rowToRecord(
    ViewSchema view,
    List<String> headers,
    List<Object?> row,
  ) {
    final record = <String, Object?>{};
    for (var i = 0; i < headers.length; i++) {
      final dim = view.dimensionByExpr(headers[i]);
      if (dim == null) continue;
      final raw = i < row.length ? row[i] : null;
      record[dim.name] = CellCodec.decode(dim.type, raw);
    }
    return record;
  }
}

/// Wraps an http.Client and retries transient send-level failures with
/// exponential backoff. Targets cold-start network races (DNS not ready,
/// TLS handshake aborts) that present as SocketException / HandshakeException
/// / "Connection abort" — the Sheets API itself returns 5xx for its own
/// transient issues and Google's SDK already handles those; we only need to
/// cover the case where the request never reached the wire.
///
/// HTTP responses (any status code) are passed through unchanged — we do
/// NOT retry 4xx/5xx, only thrown exceptions. Non-idempotent writes are
/// therefore safe: a retry only fires when we know the previous attempt
/// didn't get a response from the server.
class _RetryingClient extends http.BaseClient {
  final http.Client _inner;
  static const _maxAttempts = 4;
  static const _baseDelay = Duration(milliseconds: 300);

  _RetryingClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await _inner.send(_clone(request));
      } catch (e) {
        if (attempt >= _maxAttempts || !_isTransient(e)) rethrow;
        await Future<void>.delayed(_baseDelay * (1 << (attempt - 1)));
      }
    }
  }

  @override
  void close() => _inner.close();

  /// Recreates the request so a retried send isn't reusing a consumed body.
  http.BaseRequest _clone(http.BaseRequest src) {
    if (src is http.Request) {
      return http.Request(src.method, src.url)
        ..headers.addAll(src.headers)
        ..bodyBytes = src.bodyBytes
        ..followRedirects = src.followRedirects
        ..maxRedirects = src.maxRedirects
        ..persistentConnection = src.persistentConnection;
    }
    // Streamed/multipart requests aren't safely re-sendable (their bodies
    // are consumed on first attempt). Pass through as-is — first try only.
    return src;
  }

  bool _isTransient(Object e) {
    if (e is SocketException) return true;
    if (e is HandshakeException) return true;
    if (e is TimeoutException) return true;
    if (e is http.ClientException) {
      final m = e.message.toLowerCase();
      return m.contains('connection abort') ||
          m.contains('connection closed') ||
          m.contains('connection reset') ||
          m.contains('connection refused') ||
          m.contains('connection terminated') ||
          m.contains('handshake');
    }
    return false;
  }
}
