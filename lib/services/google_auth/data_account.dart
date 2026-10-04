/// Resolves + holds the DATA account (multi-user sub-project 2): which
/// credential the app's Sheets traffic uses and which spreadsheet it
/// targets.
///
///  - OWNER build (a usable `assets/service-account.json` is baked): the
///    service account + the baked `spreadsheet_id` — exactly the
///    pre-multi-user behavior; nothing here can change it.
///  - Everyone else: the user's Google sign-in ([GoogleAccountGateway],
///    scopes spreadsheets + drive.file) + a per-user spreadsheet id kept
///    in SECURE STORAGE under [spreadsheetKey] — deliberately NOT the
///    synced `app_settings` tab, which lives inside that spreadsheet.
///
/// Bootstrap order (ConfigGate): config source → this → home. The gate
/// shows the minimal DataSetupScreen while [DataAccount.ready] is false.
library;

import 'package:flutter/foundation.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;

import '../config_source/config_source_registry.dart'
    show SecretStore, SecureSecretStore;
import 'google_identity.dart';
import 'sheets_auth.dart';
import 'spreadsheet_id.dart';

class DataAccount {
  const DataAccount({
    required this.auth,
    required this.spreadsheetId,
    this.email,
  });

  final SheetsAuth auth;

  /// '' when a non-owner user hasn't picked/created one yet.
  final String spreadsheetId;

  /// Signed-in Google email (non-owner mode only).
  final String? email;

  bool get isOwner => auth.isServiceAccount;
  bool get needsSignIn => !isOwner && email == null;
  bool get needsSpreadsheet => spreadsheetId.isEmpty;
  bool get ready => !needsSignIn && !needsSpreadsheet;

  /// Identity of the data location — the home screen re-bootstraps when
  /// it changes (non-owner only; the owner's never changes).
  String get key => isOwner ? 'owner' : 'google:$spreadsheetId';

  /// The non-owner token source (null for the owner build).
  AccessTokenSource? get tokens =>
      auth is TokenSheetsAuth ? (auth as TokenSheetsAuth).tokens : null;

  DataAccount copyWith({
    String? spreadsheetId,
    String? email,
    bool clearEmail = false,
  }) => DataAccount(
    auth: auth,
    spreadsheetId: spreadsheetId ?? this.spreadsheetId,
    email: clearEmail ? null : (email ?? this.email),
  );
}

class DataAccountRegistry {
  DataAccountRegistry._();

  /// Secure-storage key for the per-user spreadsheet id.
  static const spreadsheetKey = 'spreadsheet_id';

  /// Title of the workbook "Create new" makes in the user's Drive.
  static const newSpreadsheetTitle = 'Ledger';

  static final current = ValueNotifier<DataAccount?>(null);

  static SecretStore _store = const SecureSecretStore();
  static GoogleAccountGateway? _google;

  /// Resolve + publish. Never throws (an unreadable store reads as unset).
  static Future<DataAccount> init({
    required String bakedKeyJson,
    required String bakedSpreadsheetId,
    required GoogleAccountGateway google,
    SecretStore? store,
  }) async {
    if (store != null) _store = store;
    _google = google;
    final auth = selectSheetsAuth(bakedKeyJson: bakedKeyJson, google: google);
    DataAccount account;
    if (auth.isServiceAccount) {
      account = DataAccount(auth: auth, spreadsheetId: bakedSpreadsheetId);
    } else {
      String? sid;
      try {
        sid = await _store.read(spreadsheetKey);
      } catch (_) {}
      String? email;
      try {
        email = await google.signedInEmail();
      } catch (_) {}
      account = DataAccount(auth: auth, spreadsheetId: sid ?? '', email: email);
    }
    current.value = account;
    return account;
  }

  /// The Google gateway (non-owner mode); null before [init].
  static GoogleAccountGateway? get google => _google;

  /// Interactive Google sign-in (+ data-scope consent). Throws on cancel.
  static Future<void> signIn() async {
    final g = _google, a = current.value;
    if (g == null || a == null || a.isOwner) return;
    final email = await g.signIn();
    current.value = a.copyWith(email: email);
  }

  static Future<void> signOut() async {
    final g = _google, a = current.value;
    if (g == null || a == null || a.isOwner) return;
    await g.signOut();
    current.value = a.copyWith(clearEmail: true);
  }

  /// Use an existing spreadsheet ([input] = id or URL). False when the
  /// input has no id, or on the owner build (baked id is fixed).
  static Future<bool> useSpreadsheet(String input) async {
    final a = current.value;
    final id = parseSpreadsheetId(input);
    if (a == null || a.isOwner || id == null) return false;
    await _store.write(spreadsheetKey, id);
    current.value = a.copyWith(spreadsheetId: id);
    return true;
  }

  /// Creates a "Ledger" workbook in the user's Drive (Sheets
  /// `spreadsheets.create` — the drive.file grant covers app-created
  /// files) and selects it. Tabs are NOT pre-created: the engine's
  /// ensure_sheet adds each view's tab + header row on the first sync.
  /// [authOverride] is a test seam.
  static Future<String> createSpreadsheet({SheetsAuth? authOverride}) async {
    final a = current.value;
    if (a == null || a.isOwner) {
      throw StateError('No signed-in Google account to create a sheet for');
    }
    final auth = authOverride ?? a.auth;
    final created = await auth.withApi(
      (api) => api.spreadsheets.create(
        sheets.Spreadsheet(
          properties: sheets.SpreadsheetProperties(title: newSpreadsheetTitle),
        ),
      ),
    );
    final id = created.spreadsheetId;
    if (id == null || id.isEmpty) {
      throw StateError('Sheets create returned no spreadsheet id');
    }
    await _store.write(spreadsheetKey, id);
    current.value = a.copyWith(spreadsheetId: id);
    return id;
  }

  @visibleForTesting
  static void reset() {
    current.value = null;
    _store = const SecureSecretStore();
    _google = null;
  }
}
