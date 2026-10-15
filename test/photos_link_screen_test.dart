import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/integrations/photos_picker_gateway.dart';
import 'package:airledger/services/photos_link.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/photos_link_screen.dart';

// The "Link clips to Google Photos" screen: the "N clips not linked"
// headline, the unconfigured-build message, and an end-to-end pick →
// auto-link that writes the deep link + a fetched thumbnail.

Dimension _d(String name, DimensionType t, {InputSpec? input}) =>
    Dimension(name: name, type: t, expr: name, input: input);

final _view = ViewSchema(
  name: 'strength',
  datasource: 'gsheets',
  table: 'strength',
  entities: [],
  measures: [],
  dimensions: [
    _d('id', DimensionType.string),
    _d('date', DimensionType.date),
    _d('exercise', DimensionType.string),
    _d('video_url', DimensionType.string,
        input: InputSpec(widget: WidgetType.video, autofill: false)),
    _d('video_media_id', DimensionType.string),
    _d('video_thumb', DimensionType.string),
    _d('video_taken_at', DimensionType.datetime),
    _d('video_duration_ms', DimensionType.number),
    _d('video_photos_url', DimensionType.string),
  ],
);

class _Repo implements WarehouseConnector {
  _Repo(this.rows);
  final List<Record> rows;
  final updates = <Record>[];
  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async => rows;
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async =>
      updates.add(record);
  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

class _Gateway implements PhotosPickerGateway {
  _Gateway(this.items);
  final List<dynamic> items;
  @override
  Future<String?> signedInEmail() async => 'me';
  @override
  Future<String> signIn() async => 'me';
  @override
  Future<Map<String, dynamic>> createSession() async =>
      {'id': 's', 'pickerUri': 'https://p/s', 'mediaItemsSet': true};
  @override
  Future<Map<String, dynamic>> getSession(String id) async =>
      {'id': id, 'mediaItemsSet': true};
  @override
  Future<List<dynamic>> listMediaItems(String id) async => items;
  @override
  Future<void> deleteSession(String id) async {}
  @override
  Future<Uint8List> download(String url) async => Uint8List(500);
}

final _taken = DateTime(2026, 10, 12, 17, 41, 5);

List<Record> _rows() => [
      {
        'id': '1',
        'date': DateTime(2026, 10, 12),
        'exercise': 'Barbell Squat',
        'video_url': 'content://media/picker/0/x/media/1',
        'video_media_id': 'm1',
        'video_taken_at': _taken,
      },
      {
        'id': '2',
        'date': DateTime(2026, 10, 12),
        'exercise': 'Bench Press',
        'video_url': 'content://media/picker/0/x/media/2',
        'video_media_id': 'm2',
      },
      {
        'id': '3',
        'date': DateTime(2026, 10, 1),
        'video_url': 'https://photos.google.com/lr/photo/OLD', // legacy
      },
    ];

Widget _app(_Repo repo, {PhotosLinkService? svc}) => MaterialApp(
      home: PhotosLinkScreen(
        view: _view,
        repository: repo,
        videoField: 'video_url',
        service: svc,
      ),
    );

void main() {
  testWidgets('headline counts distinct unlinked clips', (tester) async {
    await tester.pumpWidget(_app(_Repo(_rows())));
    await tester.pumpAndSettle();
    expect(find.text('2 clips not linked'), findsOneWidget);
    expect(find.textContaining('isn\'t configured'), findsOneWidget);
  });

  testWidgets('pick → metadata match auto-links with a thumbnail',
      (tester) async {
    final repo = _Repo(_rows());
    final svc = PhotosLinkService(PhotosLinkFlow(
      gateway: _Gateway([
        {
          'id': 'AF1Qip_squat',
          'createTime': _taken.add(const Duration(seconds: 4)).toUtc()
              .toIso8601String(),
          'type': 'VIDEO',
          'mediaFile': {'baseUrl': 'https://lh3/b'},
        },
      ]),
      launchPicker: (_) async {},
    ));
    await tester.pumpWidget(_app(repo, svc: svc));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick clips in Google Photos'));
    await tester.pumpAndSettle();
    expect(repo.updates, hasLength(1));
    final u = repo.updates.single;
    expect(u['id'], '1');
    expect(u['video_photos_url'],
        'https://photos.google.com/lr/photo/AF1Qip_squat');
    expect(u['video_thumb'], startsWith('data:image/jpeg;base64,'));
    expect(find.text('1 clip not linked'), findsOneWidget);
    expect(find.text('Linked 1'), findsOneWidget);
  });

  test('linkableVideoField needs the photos_url sibling', () {
    expect(PhotosLinkScreen.linkableVideoField(_view), 'video_url');
    final bare = ViewSchema(
      name: 'x',
      datasource: 'gsheets',
      table: 'x',
      entities: [],
      measures: [],
      dimensions: [
        _d('video_url', DimensionType.string,
            input: InputSpec(widget: WidgetType.video)),
      ],
    );
    expect(PhotosLinkScreen.linkableVideoField(bare), isNull);
  });
}
