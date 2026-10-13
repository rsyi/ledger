import '../models/database_config.dart';
import '../models/view_schema.dart';
import 'sheets_repository.dart' show Record;

/// CRUD operations every warehouse connector must implement.
///
/// Mirrors [SheetsRepository]'s shape — the existing sheets implementation
/// already conforms. Adding a new warehouse means implementing this
/// interface for the corresponding [DatabaseConfig] variant.
abstract class WarehouseConnector {
  /// The config this connector was built from. Useful for diagnostics
  /// and for the registry to identify connectors.
  DatabaseConfig get config;

  /// Idempotent — creates the destination table/tab if missing, adds any
  /// columns the view needs that aren't already there. Never removes
  /// columns. Run once per view at startup.
  Future<void> ensureTable(ViewSchema view);

  /// Returns all records for [view]. If [onDate] is provided and the view
  /// has a `date_field:`, filter to that day.
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate});

  /// Inserts a new record at the top of the data section (newest-first).
  /// Returns the inserted record with any auto-assigned fields populated
  /// (notably `id` if the view has one). Caller may need to shift
  /// in-memory row indexes after this; see [SheetsRepository.shiftRowIndexes].
  Future<Record> create(ViewSchema view, Record record);

  /// Updates an existing record. Resolution order is connector-specific
  /// but should at minimum support lookup by `id` if the view has one.
  Future<void> update(ViewSchema view, Record record);

  /// Deletes [record]. Connector-specific resolution; mirrors [update].
  Future<void> delete(ViewSchema view, Record record);
}

/// Stub connector used for [DatabaseConfig] variants ledger knows about but
/// doesn't yet implement (e.g. Snowflake, Databricks). Parses cleanly so
/// the app loads other views, throws clear errors only when something
/// tries to actually use it.
class UnimplementedConnector implements WarehouseConnector {
  @override
  final DatabaseConfig config;

  UnimplementedConnector(this.config);

  Never _bail(String op) => throw UnimplementedError(
        'Warehouse type "${config.typeName}" (datasource "${config.name}") '
        'is not yet supported by ledger. Attempted: $op',
      );

  @override
  Future<void> ensureTable(ViewSchema view) async => _bail('ensureTable');
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      _bail('list');
  @override
  Future<Record> create(ViewSchema view, Record record) async => _bail('create');
  @override
  Future<void> update(ViewSchema view, Record record) async => _bail('update');
  @override
  Future<void> delete(ViewSchema view, Record record) async => _bail('delete');
}

/// A connector that can serve a DATE-RANGE read natively (perf batch 2:
/// the engine ledger's indexed `date_key`). Use [WarehouseRangeList.listRange]
/// at call sites — it dispatches here when available and falls back to
/// `list` + [filterRecordsToRange] for every other connector (fakes,
/// Sheets, SQL warehouses), so callers never need to know.
abstract interface class RangeListable {
  /// Live rows whose `date_field` CALENDAR DATE is within [from]..[to]
  /// (inclusive; either bound optional — times are ignored). Views
  /// without a date_field return every row; no bounds = the full list.
  Future<List<Record>> listRange(ViewSchema view,
      {DateTime? from, DateTime? to});
}

extension WarehouseRangeList on WarehouseConnector {
  /// See [RangeListable.listRange]. Same semantics on every connector.
  Future<List<Record>> listRange(ViewSchema view,
      {DateTime? from, DateTime? to}) async {
    final Object self = this;
    if (self is RangeListable) {
      // Promoted to RangeListable (not a WarehouseConnector subtype, so
      // this calls the interface member, not this extension).
      return self.listRange(view, from: from, to: to);
    }
    final rows = await list(view);
    return filterRecordsToRange(view, rows, from: from, to: to);
  }
}

/// The calendar day of a date-field cell: a DateTime, or a string that
/// starts with an ISO date (lenient, like the engine's `date_key`).
DateTime? recordDayOf(Object? v) {
  if (v is DateTime) return DateTime(v.year, v.month, v.day);
  if (v is String && v.length >= 10) {
    final d = DateTime.tryParse(v.substring(0, 10));
    if (d != null) return DateTime(d.year, d.month, d.day);
  }
  return null;
}

/// The engine's `list_range` semantics over an in-memory list: rows whose
/// date-field calendar day is within [from]..[to] (inclusive). No
/// date_field (or no bounds) → [rows] unchanged; a dateless row never
/// matches a bounded range. Order preserved.
List<Record> filterRecordsToRange(ViewSchema view, List<Record> rows,
    {DateTime? from, DateTime? to}) {
  final field = view.dateField;
  if (field == null || (from == null && to == null)) return rows;
  final lo = from == null ? null : DateTime(from.year, from.month, from.day);
  final hi = to == null ? null : DateTime(to.year, to.month, to.day);
  return [
    for (final r in rows)
      if (recordDayOf(r[field]) case final d?
          when (lo == null || !d.isBefore(lo)) && (hi == null || !d.isAfter(hi)))
        r,
  ];
}
