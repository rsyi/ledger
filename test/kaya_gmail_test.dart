// Kaya Gmail import — pure helpers (message selection, attachment
// extraction, decoding, status lines) and the import orchestration via
// fake gateway/store. The KayaGmailIntegration class itself stays thin
// glue over EngineLedgerRepository (concrete FFI class, not cheaply
// fakeable — same convention as kaya_integration_test.dart).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:airledger/services/integrations/gmail_gateway.dart';
import 'package:airledger/services/integrations/kaya_gmail.dart';

String _b64url(String s) => base64Url.encode(utf8.encode(s));

Map<String, dynamic> _exportMessage({
  required String id,
  required DateTime at,
  String? attachmentId = 'att-1',
  String? inlineCsv,
  String filename = 'kaya_logbook.csv',
}) =>
    {
      'id': id,
      'internalDate': '${at.millisecondsSinceEpoch}',
      'payload': {
        'mimeType': 'multipart/mixed',
        'filename': '',
        'parts': [
          {
            'mimeType': 'text/html',
            'filename': '',
            'body': {'data': _b64url('<p>your logbook</p>')},
          },
          {
            'mimeType': 'text/csv',
            'filename': filename,
            'body': inlineCsv != null
                ? {'data': _b64url(inlineCsv)}
                : {'attachmentId': attachmentId, 'size': 12345},
          },
        ],
      },
    };

class FakeGmailGateway implements GmailGateway {
  FakeGmailGateway({this.email = 'climber@gmail.com'});

  String? email;
  List<Map<String, dynamic>> messages = [];
  Map<String, String> attachments = {}; // attachmentId -> base64url data
  final List<String> queries = [];

  @override
  Future<String?> signedInEmail() async => email;

  @override
  Future<String> signIn() async => email ??= 'climber@gmail.com';

  @override
  Future<void> signOut() async => email = null;

  @override
  Future<List<Map<String, dynamic>>> searchMessages(String query,
      {int maxResults = 5}) async {
    queries.add(query);
    return messages;
  }

  @override
  Future<String> attachmentData({
    required String messageId,
    required String attachmentId,
  }) async {
    final data = attachments[attachmentId];
    if (data == null) throw StateError('no attachment $attachmentId');
    return data;
  }
}

class FakeKayaTabStore implements KayaTabStore {
  List<List<Object?>>? tab;
  int writes = 0;

  @override
  Future<List<List<Object?>>?> read() async => tab;

  @override
  Future<void> replaceAll(List<List<String>> rows) async {
    writes++;
    tab = rows;
  }
}

void main() {
  final t0 = DateTime(2026, 9, 21, 18, 0);

  group('kayaExportQuery', () {
    test('scoped to Kaya export emails with attachments', () {
      expect(
        kayaExportQuery(),
        'from:kayaclimb.com subject:"KAYA Logbook Export" '
        'newer_than:1d has:attachment',
      );
      expect(kayaExportQuery(newerThanDays: 7), contains('newer_than:7d'));
    });
  });

  group('newestExportMessage (strictly-newer rule)', () {
    test('rejects messages at or before the floor', () {
      final atFloor = _exportMessage(id: 'a', at: t0);
      final older = _exportMessage(
          id: 'b', at: t0.subtract(const Duration(hours: 3)));
      expect(
          newestExportMessage([atFloor, older], newerThan: t0), isNull);
    });

    test('picks the newest qualifying message', () {
      final m1 =
          _exportMessage(id: 'a', at: t0.add(const Duration(minutes: 1)));
      final m2 =
          _exportMessage(id: 'b', at: t0.add(const Duration(minutes: 5)));
      final stale = _exportMessage(
          id: 'c', at: t0.subtract(const Duration(days: 1)));
      expect(
        newestExportMessage([m1, stale, m2], newerThan: t0)?['id'],
        'b',
      );
    });

    test('null floor accepts anything; garbled internalDate ignored', () {
      final ok = _exportMessage(id: 'a', at: t0);
      final garbled = {'id': 'z', 'internalDate': 'soon'};
      expect(newestExportMessage([garbled, ok])?['id'], 'a');
      expect(newestExportMessage([garbled]), isNull);
      expect(newestExportMessage([]), isNull);
    });
  });

  group('findCsvAttachment', () {
    test('finds a nested CSV part by filename → attachmentId', () {
      final msg = _exportMessage(id: 'a', at: t0);
      final att =
          findCsvAttachment((msg['payload'] as Map).cast<String, dynamic>());
      expect(att?.attachmentId, 'att-1');
      expect(att?.filename, 'kaya_logbook.csv');
      expect(att?.inlineData, isNull);
    });

    test('small attachments come back inline', () {
      final msg = _exportMessage(id: 'a', at: t0, inlineCsv: 'date\n2026-01-01');
      final att =
          findCsvAttachment((msg['payload'] as Map).cast<String, dynamic>());
      expect(att?.attachmentId, isNull);
      expect(decodeGmailBody(att!.inlineData!), 'date\n2026-01-01');
    });

    test('matches text/csv mime even with a weird filename', () {
      final att = findCsvAttachment({
        'mimeType': 'text/csv',
        'filename': 'logbook.data',
        'body': {'attachmentId': 'x'},
      });
      expect(att?.attachmentId, 'x');
    });

    test('null when the message has no CSV', () {
      expect(
        findCsvAttachment({
          'mimeType': 'text/html',
          'filename': '',
          'body': {'data': _b64url('hi')},
        }),
        isNull,
      );
      expect(findCsvAttachment(null), isNull);
    });
  });

  group('decodeGmailBody', () {
    test('handles the -/_ alphabet and stripped padding', () {
      // ">>?>>" encodes to characters outside base64's +/ alphabet.
      final data = base64Url
          .encode(utf8.encode('a>b?c'))
          .replaceAll('=', ''); // Gmail strips padding
      expect(decodeGmailBody(data), 'a>b?c');
    });
  });

  group('status lines', () {
    test('snapshot base: count + latest', () {
      expect(
        kayaSnapshotStatus([
          ['date', 'grade'],
          ['2026-09-15', 'v5'],
          ['2026-09-11', 'v4'],
        ]),
        'Snapshot · 2 ascents · latest 2026-09-15',
      );
    });

    test('missing tab reads as no snapshot', () {
      expect(kayaSnapshotStatus(null),
          'No snapshot yet — Sync to import from Kaya');
      expect(kayaSnapshotStatus([]),
          'No snapshot yet — Sync to import from Kaya');
    });

    test('tolerates missing date column and junk dates', () {
      expect(
        kayaSnapshotStatus([
          ['grade'],
          ['v5'],
        ]),
        'Snapshot · 1 ascents',
      );
      expect(
        kayaSnapshotStatus([
          ['date'],
          ['not-a-date'],
          ['2026-01-02'],
        ]),
        'Snapshot · 2 ascents · latest 2026-01-02',
      );
    });

    test('full line composes imported-ago, account, error', () {
      final now = DateTime(2026, 9, 21, 12, 0);
      expect(
        kayaStatusLine(
          base: 'Snapshot · 3 ascents · latest 2026-09-20',
          importedAt: now.subtract(const Duration(hours: 2)),
          email: 'climber@gmail.com',
          now: now,
        ),
        'Snapshot · 3 ascents · latest 2026-09-20 · imported 2h ago · '
        'climber@gmail.com',
      );
      expect(
        kayaStatusLine(base: 'x', error: 'boom', now: now),
        'x · error: boom',
      );
    });

    test('formatAgo buckets', () {
      final now = DateTime(2026, 9, 21, 12, 0);
      expect(formatAgo(now.subtract(const Duration(seconds: 30)), now: now),
          'just now');
      expect(formatAgo(now.subtract(const Duration(minutes: 12)), now: now),
          '12m ago');
      expect(formatAgo(now.subtract(const Duration(hours: 3)), now: now),
          '3h ago');
      expect(formatAgo(now.subtract(const Duration(days: 5)), now: now),
          '5d ago');
    });
  });

  group('kayaImportFromGmail', () {
    const csv = 'date,grade,gym\n'
        '2026-09-20,v5,Movement\n'
        'Sun May 23 2021 14:15:39 GMT+0000 (GMT),v3,Touchstone\n';

    test('downloads, parses, and replace-alls the tab', () async {
      final gmail = FakeGmailGateway()
        ..messages = [
          _exportMessage(id: 'm1', at: t0.add(const Duration(minutes: 2))),
        ]
        ..attachments = {'att-1': _b64url(csv)};
      final store = FakeKayaTabStore();

      final result = await kayaImportFromGmail(
        gmail: gmail,
        store: store,
        newerThan: t0,
      );

      expect(result, isNotNull);
      expect(result!.messageId, 'm1');
      expect(result.receivedAt, t0.add(const Duration(minutes: 2)));
      expect(result.snapshot.count, 2);
      expect(result.snapshot.latestDay, '2026-09-20');
      expect(store.writes, 1);
      expect(store.tab, [
        ['date', 'grade', 'gym'],
        ['2026-09-20', 'v5', 'Movement'],
        ['2021-05-23', 'v3', 'Touchstone'],
      ]);
      expect(gmail.queries.single, contains('newer_than:1d'));
    });

    test('inline attachment data skips the attachments endpoint', () async {
      final gmail = FakeGmailGateway()
        ..messages = [
          _exportMessage(
              id: 'm1',
              at: t0.add(const Duration(minutes: 2)),
              inlineCsv: csv),
        ];
      final store = FakeKayaTabStore();
      final result =
          await kayaImportFromGmail(gmail: gmail, store: store, newerThan: t0);
      expect(result?.snapshot.count, 2);
      expect(store.writes, 1);
    });

    test('nothing strictly newer → null, tab untouched', () async {
      final gmail = FakeGmailGateway()
        ..messages = [_exportMessage(id: 'old', at: t0)]
        ..attachments = {'att-1': _b64url(csv)};
      final store = FakeKayaTabStore();
      final result =
          await kayaImportFromGmail(gmail: gmail, store: store, newerThan: t0);
      expect(result, isNull);
      expect(store.writes, 0);
    });

    test('qualifying email without a CSV throws (surfaces, no retry loop)',
        () async {
      final gmail = FakeGmailGateway()
        ..messages = [
          {
            'id': 'm1',
            'internalDate':
                '${t0.add(const Duration(minutes: 1)).millisecondsSinceEpoch}',
            'payload': {
              'mimeType': 'text/html',
              'filename': '',
              'body': {'data': _b64url('no attachment here')},
            },
          },
        ];
      final store = FakeKayaTabStore();
      await expectLater(
        kayaImportFromGmail(gmail: gmail, store: store, newerThan: t0),
        throwsA(isA<StateError>()),
      );
      expect(store.writes, 0);
    });

    test('malformed CSV throws FormatException, tab untouched', () async {
      final gmail = FakeGmailGateway()
        ..messages = [
          _exportMessage(
              id: 'm1',
              at: t0.add(const Duration(minutes: 1)),
              inlineCsv: 'grade,gym\nv5,Movement\n'), // no date column
        ];
      final store = FakeKayaTabStore();
      await expectLater(
        kayaImportFromGmail(gmail: gmail, store: store, newerThan: t0),
        throwsA(isA<FormatException>()),
      );
      expect(store.writes, 0);
    });

    test('manual "latest export" path: 7-day window, no floor', () async {
      final gmail = FakeGmailGateway()
        ..messages = [
          _exportMessage(
              id: 'yesterday',
              at: t0.subtract(const Duration(days: 1)),
              inlineCsv: csv),
        ];
      final store = FakeKayaTabStore();
      final result = await kayaImportFromGmail(
          gmail: gmail, store: store, newerThanDays: 7);
      expect(result?.messageId, 'yesterday');
      expect(gmail.queries.single, contains('newer_than:7d'));
    });
  });
}
