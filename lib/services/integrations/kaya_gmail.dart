/// Kaya → kaya_ascents, self-contained in-app flow.
///
/// The user's climbing data deliberately does NOT sync into the engine
/// ledger: it lives in the `kaya_ascents` sheet tab purely so the MCP
/// worker can serve it to Claude (and the app's read-only climbing
/// view can render it). Kaya has no supported API, but it emails a full
/// CSV export on demand — so the integration is:
///
///   Connect  = Google sign-in requesting gmail.readonly (any Google
///              account works once the OAuth clients exist — see
///              [kKayaGmailSetupHint]).
///   Sync     = guided flow: open the Kaya app ("tap Profile → Export
///              Logbook via Email"), then poll Gmail for an export
///              email STRICTLY newer than sync-start, download the CSV
///              attachment, and replace-all the tab (same semantics as
///              tool/kaya_import.dart, which shares the parser in
///              services/kaya_csv.dart).
///   Menu     = "Import latest export" skips the Kaya launch and just
///              imports the newest export email (7-day window).
///
/// Scope discipline: gmail.readonly ONLY, isolated behind the
/// injectable [GmailGateway].
library;

import 'package:airledger_engine/airledger_engine.dart'
    show EngineLedgerRepository;
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';

import '../app_config.dart' show KayaGmailConfig;
import '../kaya_csv.dart';
import 'gmail_gateway.dart';
import 'integration.dart';

const kKayaPackage = 'com.project9a.redpoint';
const _kTab = 'kaya_ascents';
const _kStatusTtl = Duration(minutes: 10);
const _kMinPullInterval = Duration(hours: 6);

/// Shown on the card while `integrations.kaya_gmail.server_client_id`
/// is missing from config.yml. Both OAuth clients live in the GCP
/// project's console (ryi-data-entry for this build); the SHA-1 comes
/// from the signing key — release builds currently sign with the debug
/// keystore, so:
///   keytool -list -v -alias androiddebugkey \
///     -keystore ~/.android/debug.keystore -storepass android | grep SHA1
const kKayaGmailSetupHint =
    'Setup needed — GCP console (ryi-data-entry): enable the Gmail API, '
    'then create OAuth clients: (1) type Android, package '
    'com.robertyi.fitness + your signing SHA-1 (keytool on the debug '
    'keystore), (2) type Web application. Put the WEB client id in '
    'config.yml as integrations.kaya_gmail.server_client_id and rebrand.';

// ---------------------------------------------------------------- pure

/// Base freshness line from the raw tab rows (header + data).
/// Null/empty rows means the tab doesn't exist yet (never imported).
String kayaSnapshotStatus(List<List<Object?>>? rows) {
  if (rows == null || rows.isEmpty) {
    return 'No snapshot yet — Sync to import from Kaya';
  }
  final headers = rows.first.map((h) => '$h'.trim().toLowerCase()).toList();
  final dateCol = headers.indexOf('date');
  final count = rows.length - 1;
  String? latest;
  if (dateCol >= 0) {
    for (final r in rows.skip(1)) {
      final v = dateCol < r.length ? '${r[dateCol]}'.trim() : '';
      if (DateTime.tryParse(v) == null) continue;
      if (latest == null || v.compareTo(latest) > 0) latest = v;
    }
  }
  return [
    'Snapshot',
    '$count ascents',
    if (latest != null) 'latest $latest',
  ].join(' · ');
}

/// Full card status: snapshot base + "imported `<ago>`" + account/error.
String kayaStatusLine({
  required String base,
  DateTime? importedAt,
  String? email,
  String? error,
  DateTime? now,
}) {
  return [
    base,
    if (importedAt != null) 'imported ${formatAgo(importedAt, now: now)}',
    if (email != null && email.isNotEmpty) email,
    if (error != null && error.isNotEmpty) 'error: $error',
  ].join(' · ');
}

/// "just now" / "12m ago" / "3h ago" / "5d ago".
String formatAgo(DateTime at, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// One successful Gmail → tab import.
class KayaGmailImport {
  const KayaGmailImport({
    required this.messageId,
    required this.receivedAt,
    required this.snapshot,
  });

  final String messageId;
  final DateTime receivedAt;
  final KayaCsvSnapshot snapshot;
}

/// One import attempt: search Gmail for Kaya export emails, pick the
/// newest STRICTLY newer than [newerThan] (null = any), download +
/// decode its CSV attachment, parse, and replace-all the tab. Returns
/// null when no qualifying email exists; throws when a qualifying email
/// is malformed (no CSV attachment / not a logbook CSV) — callers
/// surface that instead of silently retrying forever.
Future<KayaGmailImport?> kayaImportFromGmail({
  required GmailGateway gmail,
  required KayaTabStore store,
  DateTime? newerThan,
  int newerThanDays = 1,
}) async {
  final messages = await gmail
      .searchMessages(kayaExportQuery(newerThanDays: newerThanDays));
  final msg = newestExportMessage(messages, newerThan: newerThan);
  if (msg == null) return null;
  final id = '${msg['id']}';
  final att =
      findCsvAttachment((msg['payload'] as Map?)?.cast<String, dynamic>());
  if (att == null) {
    throw StateError('Kaya export email $id has no CSV attachment');
  }
  final data = att.inlineData ??
      await gmail.attachmentData(messageId: id, attachmentId: att.attachmentId!);
  final snapshot = parseKayaExportCsv(decodeGmailBody(data));
  await store.replaceAll(snapshot.tabRows);
  return KayaGmailImport(
    messageId: id,
    receivedAt: gmailInternalDate(msg)!,
    snapshot: snapshot,
  );
}

// ------------------------------------------------------------ tab store

/// Injectable seam over the `kaya_ascents` tab (foreign to the ledger —
/// no view targets it for writes; never ensureTable'd).
abstract class KayaTabStore {
  /// Raw tab rows (header + data), or null when the tab doesn't exist.
  Future<List<List<Object?>>?> read();

  /// Replace the whole tab (create → clear → write). The export is a
  /// full snapshot, so replace-all is the idempotent operation — same
  /// semantics as tool/kaya_import.dart.
  Future<void> replaceAll(List<List<String>> rows);
}

/// Real store over the Sheets API via the bundled service account (the
/// same credential path every other sheet write in the app uses).
class ServiceAccountKayaTabStore implements KayaTabStore {
  ServiceAccountKayaTabStore({
    required this.spreadsheetId,
    required this.serviceAccountKeyJson,
  });

  final String spreadsheetId;
  final String serviceAccountKeyJson;

  Future<T> _withApi<T>(
      String scope, Future<T> Function(sheets.SheetsApi) fn) async {
    final client = await clientViaServiceAccount(
      ServiceAccountCredentials.fromJson(serviceAccountKeyJson),
      [scope],
    );
    try {
      return await fn(sheets.SheetsApi(client));
    } finally {
      client.close();
    }
  }

  @override
  Future<List<List<Object?>>?> read() async {
    try {
      return await _withApi(sheets.SheetsApi.spreadsheetsReadonlyScope,
          (api) async {
        final resp =
            await api.spreadsheets.values.get(spreadsheetId, "'$_kTab'");
        return resp.values ?? const [];
      });
    } catch (e) {
      // A 400 "Unable to parse range" means the tab doesn't exist yet.
      if ('$e'.contains('Unable to parse range')) return null;
      rethrow;
    }
  }

  @override
  Future<void> replaceAll(List<List<String>> rows) async {
    await _withApi(sheets.SheetsApi.spreadsheetsScope, (api) async {
      final meta = await api.spreadsheets.get(spreadsheetId);
      final exists =
          (meta.sheets ?? []).any((s) => s.properties?.title == _kTab);
      if (!exists) {
        await api.spreadsheets.batchUpdate(
          sheets.BatchUpdateSpreadsheetRequest(requests: [
            sheets.Request(
              addSheet: sheets.AddSheetRequest(
                properties: sheets.SheetProperties(title: _kTab),
              ),
            ),
          ]),
          spreadsheetId,
        );
      }
      await api.spreadsheets.values
          .clear(sheets.ClearValuesRequest(), spreadsheetId, "'$_kTab'");
      await api.spreadsheets.values.update(
        sheets.ValueRange(values: rows),
        spreadsheetId,
        "'$_kTab'!A1",
        valueInputOption: 'RAW',
      );
    });
  }
}

// ---------------------------------------------------------- integration

class KayaGmailIntegration implements GuidedSyncIntegration {
  KayaGmailIntegration({
    required this.config,
    required this.repo,
    required this.gateway,
    required this.store,
    Future<void> Function()? launchKaya,
    this.pollInterval = const Duration(seconds: 20),
    this.maxPolls = 15,
  }) : _launchKaya = launchKaya ?? _defaultLaunchKaya;

  final KayaGmailConfig? config;
  final EngineLedgerRepository repo;
  final GmailGateway gateway;
  final KayaTabStore store;
  final Future<void> Function() _launchKaya;
  final Duration pollInterval;
  final int maxPolls;

  // Ledger-meta keys (shared source of truth with the card + restarts).
  static const _kImportedAt = 'integration_kaya_gmail_imported_at';
  static const _kCount = 'integration_kaya_gmail_count';
  static const _kMsgMs = 'integration_kaya_gmail_msg_ms';
  static const _kLastCheck = 'integration_kaya_gmail_last_check';
  static const _kError = 'integration_kaya_gmail_error';

  final ValueNotifier<String?> _progress = ValueNotifier(null);
  String? _cachedBase;
  DateTime? _cachedAt;

  @override
  String get id => 'kaya_gmail';
  @override
  String get displayName => 'Kaya';
  @override
  String get targetDescription => '→ Claude (MCP snapshot)';

  @override
  bool get isConfigured => config?.isConfigured ?? false;

  @override
  Future<bool> get isConnected async =>
      isConfigured && await gateway.signedInEmail() != null;

  @override
  ValueListenable<String?> get syncProgress => _progress;

  @override
  Future<String> get statusLine async {
    if (!isConfigured) return kKayaGmailSetupHint;
    String? email;
    String base;
    try {
      email = await gateway.signedInEmail();
      base = await _snapshotBase();
    } catch (e) {
      return 'Status unavailable: $e';
    }
    return kayaStatusLine(
      base: base,
      importedAt:
          DateTime.tryParse(await repo.metaGet(_kImportedAt) ?? ''),
      email: email,
      error: await repo.metaGet(_kError),
    );
  }

  /// Snapshot part (count + latest) from the tab, cached 10 min — the
  /// "imported `<ago>`"/account/error parts are composed fresh each call.
  Future<String> _snapshotBase() async {
    final at = _cachedAt;
    if (_cachedBase != null &&
        at != null &&
        DateTime.now().difference(at) < _kStatusTtl) {
      return _cachedBase!;
    }
    _cachedBase = kayaSnapshotStatus(await store.read());
    _cachedAt = DateTime.now();
    return _cachedBase!;
  }

  @override
  Map<String, Future<void> Function(BuildContext)> get extraMenuActions => {
        // For when the export was already triggered (or arrived while
        // the app was closed): import the newest export email without
        // launching Kaya. 7-day window, no strictly-newer floor —
        // replace-all is idempotent, so re-importing is harmless.
        'Import latest export': (context) async {
          final result = await kayaImportFromGmail(
            gmail: gateway,
            store: store,
            newerThanDays: 7,
          );
          if (result == null) {
            throw StateError(
                'No Kaya export email in the last 7 days — in Kaya, tap '
                'Profile → Export Logbook via Email first.');
          }
          await _recordImport(result);
          if (context.mounted) {
            _toast(context,
                'Imported ${result.snapshot.count} ascents from Kaya export');
          }
        },
      };

  @override
  Future<void> connect(BuildContext context) async {
    if (!isConfigured) return;
    final email = await gateway.signIn();
    await repo.metaSet(_kError, '');
    if (context.mounted) _toast(context, 'Connected as $email');
  }

  @override
  Future<void> disconnect() async {
    // Local sign-out only (no revoke): the tab snapshot and meta stay,
    // so the card still shows the last import; reconnect is one tap.
    await gateway.signOut();
  }

  /// Guided sync: dialog → launch Kaya → poll Gmail for an export email
  /// STRICTLY newer than sync-start (never re-imports yesterday's
  /// export) → import → toast. ~20s × 15 polls ≈ 5 minutes.
  @override
  Future<void> guidedSync(BuildContext context) async {
    if (!isConfigured) return;
    if (await gateway.signedInEmail() == null) {
      throw StateError('Connect Gmail first');
    }
    if (!context.mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sync Kaya'),
        content: const Text(
            'Kaya will open — tap Profile → Export Logbook via Email, '
            'then return here.\n\nLedger will watch Gmail for the export '
            'for up to 5 minutes and import it automatically.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open Kaya'),
          ),
        ],
      ),
    );
    if (go != true) return;
    final syncStart = DateTime.now();
    await _launchKaya();
    try {
      for (var attempt = 1; attempt <= maxPolls; attempt++) {
        _progress.value =
            'Waiting for Kaya export email… ($attempt/$maxPolls)';
        final result = await kayaImportFromGmail(
          gmail: gateway,
          store: store,
          newerThan: syncStart,
        );
        if (result != null) {
          await _recordImport(result);
          if (context.mounted) {
            _toast(
                context,
                'Imported ${result.snapshot.count} ascents'
                '${result.snapshot.latestDay == null ? '' : ' · latest ${result.snapshot.latestDay}'}');
          }
          return;
        }
        await Future<void>.delayed(pollInterval);
      }
      throw StateError(
          'No export email arrived — if you triggered it, it may still '
          'be in flight: use "Import latest export" in the card menu.');
    } finally {
      _progress.value = null;
    }
  }

  /// Quiet background path (scheduler / pullDue): if a new export email
  /// landed since the last imported one, import it. No UI, never throws.
  @override
  Future<void> pull({bool force = false, bool fullReconcile = false}) async {
    if (!isConfigured) return;
    try {
      if (await gateway.signedInEmail() == null) return;
      if (!force) {
        final last =
            DateTime.tryParse(await repo.metaGet(_kLastCheck) ?? '');
        if (last != null &&
            DateTime.now().difference(last) < _kMinPullInterval) {
          return;
        }
      }
      await repo.metaSet(_kLastCheck, DateTime.now().toIso8601String());
      final lastMs = int.tryParse(await repo.metaGet(_kMsgMs) ?? '');
      final result = await kayaImportFromGmail(
        gmail: gateway,
        store: store,
        // Strictly newer than the last imported export email; when
        // nothing was ever imported, any recent export qualifies.
        newerThan: lastMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastMs),
        newerThanDays: fullReconcile ? 7 : 1,
      );
      if (result != null) await _recordImport(result);
      await repo.metaSet(_kError, '');
    } catch (e) {
      await repo.metaSet(_kError, '$e');
    }
  }

  Future<void> _recordImport(KayaGmailImport result) async {
    final now = DateTime.now();
    await repo.metaSet(_kImportedAt, now.toIso8601String());
    await repo.metaSet(_kCount, '${result.snapshot.count}');
    await repo.metaSet(
        _kMsgMs, '${result.receivedAt.millisecondsSinceEpoch}');
    await repo.metaSet(_kError, '');
    // Refresh the card immediately — no need to re-read the tab we
    // just wrote.
    _cachedBase = kayaSnapshotStatus(result.snapshot.tabRows);
    _cachedAt = now;
  }

  void _toast(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Opens Kaya's launcher activity. Requires the manifest `<queries>`
  /// entry for [kKayaPackage] (Android 11+ package visibility).
  static Future<void> _defaultLaunchKaya() async {
    const intent = AndroidIntent(
      action: 'android.intent.action.MAIN',
      category: 'android.intent.category.LAUNCHER',
      package: kKayaPackage,
      flags: [Flag.FLAG_ACTIVITY_NEW_TASK],
    );
    if (await intent.canResolveActivity() != true) {
      throw StateError('Kaya app ($kKayaPackage) is not installed');
    }
    await intent.launch();
  }
}
