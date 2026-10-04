import 'dart:convert';

import 'package:airledger/services/config_source/config_source_registry.dart'
    show MemorySecretStore;
import 'package:airledger/services/forecast_meta_store.dart';
import 'package:airledger/services/google_auth/data_account.dart';
import 'package:airledger/services/google_auth/google_identity.dart';
import 'package:airledger/services/google_auth/sheets_auth.dart';
import 'package:airledger/services/projection_snapshot_store.dart';
import 'package:airledger/services/wm_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeGoogle implements GoogleAccountGateway {
  String? email;
  String token = 'ya29.fake';
  int signIns = 0;

  @override
  Future<String?> signedInEmail() async => email;
  @override
  Future<String> signIn() async {
    signIns++;
    return email = 'friend@gmail.com';
  }

  @override
  Future<void> signOut() async => email = null;
  @override
  Future<String?> accessToken() async => email == null ? null : token;
  @override
  Future<void> invalidate(String token) async {}
}

const _key =
    '{"client_email":"a@b.iam.gserviceaccount.com",'
    '"private_key":"-----BEGIN PRIVATE KEY-----\\nx\\n-----END PRIVATE KEY-----\\n",'
    '"token_uri":"https://oauth2.googleapis.com/token"}';
const _sid = '1C1rSudguUv00gYsb7i82XV6OM1V2KSZ4BGwMliwKDG4';

void main() {
  late MemorySecretStore store;
  late FakeGoogle google;

  setUp(() {
    store = MemorySecretStore();
    google = FakeGoogle();
    DataAccountRegistry.reset();
  });

  group('resolve', () {
    test(
      'owner build: baked key + baked spreadsheet, ready, no sign-in',
      () async {
        store.values[DataAccountRegistry.spreadsheetKey] = 'ignored-user-id';
        final a = await DataAccountRegistry.init(
          bakedKeyJson: _key,
          bakedSpreadsheetId: 'owner-sheet',
          store: store,
          google: google,
        );
        expect(a.isOwner, isTrue);
        expect(a.auth, isA<ServiceAccountSheetsAuth>());
        expect(a.spreadsheetId, 'owner-sheet');
        expect(a.ready, isTrue);
        expect(google.signIns, 0);
      },
    );

    test('no key, not signed in → needs sign-in', () async {
      final a = await DataAccountRegistry.init(
        bakedKeyJson: '{}',
        bakedSpreadsheetId: 'owner-sheet',
        store: store,
        google: google,
      );
      expect(a.isOwner, isFalse);
      expect(a.auth, isA<TokenSheetsAuth>());
      expect(a.email, isNull);
      expect(a.needsSignIn, isTrue);
      expect(a.ready, isFalse);
      // The owner's baked id is NEVER used for a non-owner identity.
      expect(a.spreadsheetId, '');
    });

    test('signed in, no spreadsheet → needs spreadsheet', () async {
      google.email = 'friend@gmail.com';
      final a = await DataAccountRegistry.init(
        bakedKeyJson: '',
        bakedSpreadsheetId: '',
        store: store,
        google: google,
      );
      expect(a.needsSignIn, isFalse);
      expect(a.needsSpreadsheet, isTrue);
      expect(a.ready, isFalse);
    });

    test('signed in + stored spreadsheet → ready', () async {
      google.email = 'friend@gmail.com';
      store.values[DataAccountRegistry.spreadsheetKey] = _sid;
      final a = await DataAccountRegistry.init(
        bakedKeyJson: '',
        bakedSpreadsheetId: '',
        store: store,
        google: google,
      );
      expect(a.ready, isTrue);
      expect(a.spreadsheetId, _sid);
      expect(a.key, 'google:$_sid');
    });
  });

  group('actions', () {
    Future<void> initUser() => DataAccountRegistry.init(
      bakedKeyJson: '',
      bakedSpreadsheetId: '',
      store: store,
      google: google,
    );

    test('signIn publishes the email', () async {
      await initUser();
      await DataAccountRegistry.signIn();
      expect(DataAccountRegistry.current.value!.email, 'friend@gmail.com');
    });

    test('useSpreadsheet accepts a URL, persists the bare id', () async {
      google.email = 'friend@gmail.com';
      await initUser();
      final ok = await DataAccountRegistry.useSpreadsheet(
        'https://docs.google.com/spreadsheets/d/$_sid/edit#gid=0',
      );
      expect(ok, isTrue);
      expect(store.values[DataAccountRegistry.spreadsheetKey], _sid);
      expect(DataAccountRegistry.current.value!.ready, isTrue);
    });

    test('useSpreadsheet rejects junk without changing state', () async {
      await initUser();
      expect(await DataAccountRegistry.useSpreadsheet('nope'), isFalse);
      expect(store.values, isEmpty);
    });

    test('owner build ignores spreadsheet changes', () async {
      await DataAccountRegistry.init(
        bakedKeyJson: _key,
        bakedSpreadsheetId: 'owner-sheet',
        store: store,
        google: google,
      );
      expect(await DataAccountRegistry.useSpreadsheet(_sid), isFalse);
      expect(DataAccountRegistry.current.value!.spreadsheetId, 'owner-sheet');
    });

    test(
      'createSpreadsheet: Sheets create titled "Ledger", stores the id',
      () async {
        google.email = 'friend@gmail.com';
        await initUser();
        final reqs = <http.Request>[];
        final id = await DataAccountRegistry.createSpreadsheet(
          authOverride: TokenSheetsAuth(
            google,
            innerFactory: () => MockClient((req) async {
              reqs.add(req);
              return http.Response(
                jsonEncode({'spreadsheetId': 'new-id-123'}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        );
        expect(id, 'new-id-123');
        expect(reqs.single.method, 'POST');
        expect(reqs.single.url.path, '/v4/spreadsheets');
        expect(reqs.single.headers['Authorization'], 'Bearer ya29.fake');
        expect(jsonDecode(reqs.single.body)['properties']['title'], 'Ledger');
        expect(store.values[DataAccountRegistry.spreadsheetKey], 'new-id-123');
        expect(DataAccountRegistry.current.value!.ready, isTrue);
      },
    );

    test('signOut forgets the identity but keeps the spreadsheet id', () async {
      google.email = 'friend@gmail.com';
      store.values[DataAccountRegistry.spreadsheetKey] = _sid;
      await initUser();
      await DataAccountRegistry.signOut();
      final a = DataAccountRegistry.current.value!;
      expect(a.email, isNull);
      expect(a.ready, isFalse);
      expect(store.values[DataAccountRegistry.spreadsheetKey], _sid);
    });
  });

  group('direct Sheets stores use the injected auth client', () {
    late List<http.Request> reqs;
    late TokenSheetsAuth auth;

    setUp(() {
      google.email = 'friend@gmail.com';
      reqs = [];
      auth = TokenSheetsAuth(
        google,
        innerFactory: () => MockClient((req) async {
          reqs.add(req);
          return http.Response(
            jsonEncode({
              'range': 'x',
              'values': [
                ['key', 'value'],
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
    });

    test('ForecastMetaStore', () async {
      await ForecastMetaStore(spreadsheetId: 'S1', auth: auth).load();
      expect(reqs, isNotEmpty);
      expect(reqs.first.url.path, startsWith('/v4/spreadsheets/S1/values/'));
      expect(reqs.first.headers['Authorization'], 'Bearer ya29.fake');
    });

    test('ProjectionSnapshotStore', () async {
      await ProjectionSnapshotStore(spreadsheetId: 'S2', auth: auth).load();
      expect(reqs.first.url.path, startsWith('/v4/spreadsheets/S2/values/'));
      expect(reqs.first.headers['Authorization'], 'Bearer ya29.fake');
    });

    test('WmStore', () async {
      await WmStore(spreadsheetId: 'S3', auth: auth).snapshot(force: true);
      expect(reqs, isNotEmpty);
      expect(
        reqs.every((r) => r.url.path.startsWith('/v4/spreadsheets/S3')),
        isTrue,
      );
      expect(reqs.first.headers['Authorization'], 'Bearer ya29.fake');
    });
  });
}
