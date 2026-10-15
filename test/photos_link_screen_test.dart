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

import 'support/fake_clip_media.dart';

// The "Link clips to Google Photos" screen: headline + unconfigured
// build, the schema-missing explanation, timestamp backfill on open,
// and pick → recording-time match → IMAGE VERIFICATION (verified →
// linked + check; mismatch → not linked, review with both images, Link
// anyway = manual; no video timestamp → manual review only; re-picking
// a linked item re-checks it).

Dimension _d(String name, DimensionType t, {InputSpec? input}) =>
    Dimension(name: name, type: t, expr: name, input: input);

ViewSchema _viewWith(List<String> extra) => ViewSchema(
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
        for (final e in extra)
          _d(e,
              e == 'video_taken_at'
                  ? DimensionType.datetime
                  : DimensionType.string),
      ],
    );

final _view = _viewWith(const [
  'video_thumb',
  'video_taken_at',
  'video_duration_ms',
  'video_photos_url',
  'video_photos_check',
]);

class _Repo implements WarehouseConnector {
  _Repo(this.rows);
  final List<Record> rows;
  final updates = <Record>[];
  @override
  DatabaseConfig get config => throw UnimplementedError();
  @override
  Future<void> ensureTable(ViewSchema view) async {}
  @override
  Future<List<Record>> list(ViewSchema view, {DateTime? onDate}) async =>
      [for (final r in rows) Map.of(r)];
  @override
  Future<Record> create(ViewSchema view, Record record) async => record;
  @override
  Future<void> update(ViewSchema view, Record record) async {
    updates.add(record);
    final i = rows.indexWhere((r) => r['id'] == record['id']);
    if (i >= 0) rows[i] = Map.of(record);
  }

  @override
  Future<void> delete(ViewSchema view, Record record) async {}
}

class _Gateway implements PhotosPickerGateway {
  _Gateway(this.items, {this.cloud = 'gymA_cloud'});
  final List<dynamic> items;
  final String cloud;
  final downloads = <String>[];
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
  Future<Uint8List> download(String url) async {
    downloads.add(url);
    return url.endsWith('=w256-h256') ? fixture(cloud) : Uint8List(500);
  }
}

final _taken = DateTime(2026, 10, 12, 17, 41, 5);

Map<String, Object?> _item(String id, DateTime local) => {
      'id': id,
      'createTime': local.toUtc().toIso8601String(),
      'type': 'VIDEO',
      'mediaFile': {'baseUrl': 'https://lh3/$id'},
    };

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
        'start_time': '5:41:00 PM', // never evidence
        'video_url': 'content://media/picker/0/x/media/2',
        'video_media_id': 'm2',
      },
      {
        'id': '3',
        'date': DateTime(2026, 10, 1),
        'video_url': 'https://photos.google.com/lr/photo/OLD', // legacy
      },
    ];

FakeClipMedia _media({Map<String, String> sources = const {'1': 'content://1'}}) =>
    FakeClipMedia(
      frames: FakeFrames(frames: {
        'content://1': ['gymA_local_0', 'gymA_local_10', 'gymA_local_50'],
      }),
      sources: sources,
      thumbs: const {'1': 'gymA_local_50', '2': 'gymB_cloud'},
    );

Widget _app(_Repo repo,
        {PhotosLinkService? svc, FakeClipMedia? media, ViewSchema? view}) =>
    MaterialApp(
      home: PhotosLinkScreen(
        view: view ?? _view,
        repository: repo,
        videoField: 'video_url',
        service: svc,
        media: media ?? _media(),
      ),
    );

PhotosLinkService _svc(_Gateway g) =>
    PhotosLinkService(PhotosLinkFlow(gateway: g, launchPicker: (_) async {}));

/// Taps the pick button with REAL async (image decoding needs it) and
/// waits until [done] or ~4 s.
Future<void> _pickAndWait(WidgetTester tester, bool Function() done) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('Pick clips in Google Photos'));
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Let the flow finish (phase → review) after the awaited write.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pumpAndSettle();
}

/// A tall surface: the review cards sit below the fold of a lazy list.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('headline counts distinct unlinked clips; no-timestamp note',
      (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(_Repo(_rows())));
    await tester.pumpAndSettle();
    expect(find.text('2 clips not linked'), findsOneWidget);
    expect(find.textContaining('isn\'t configured'), findsOneWidget);
    // Clip 2 has no recording time and its file isn't readable.
    expect(find.textContaining('1 clip has no video timestamp'),
        findsOneWidget);
  });

  testWidgets('older clip: recording time backfilled from the local file',
      (tester) async {
    _tall(tester);
    final repo = _Repo(_rows());
    final when = DateTime(2026, 10, 12, 17, 50);
    final media = FakeClipMedia(
      frames: FakeFrames(probes: {
        'content://2': {
          'dateTaken': when.millisecondsSinceEpoch,
          'durationMs': 12000,
        },
      }),
      sources: const {'2': 'content://2'},
    );
    await tester.pumpWidget(_app(repo, media: media));
    await tester.pumpAndSettle();
    final u = repo.updates.single;
    expect(u['id'], '2');
    expect(u['video_taken_at'], when);
    expect(u['video_duration_ms'], 12000);
    expect(find.textContaining('Read the recording time of 1 older clip'),
        findsOneWidget);
  });

  testWidgets('time + image agree → linked, check verified:<bits>',
      (tester) async {
    _tall(tester);
    final repo = _Repo(_rows());
    final g = _Gateway([_item('AF1Qip_squat', _taken.add(const Duration(seconds: 4)))]);
    await tester.pumpWidget(_app(repo, svc: _svc(g)));
    await tester.pumpAndSettle();
    await _pickAndWait(tester, () => repo.updates.isNotEmpty);
    final u = repo.updates.single;
    expect(u['id'], '1');
    expect(u['video_photos_url'],
        'https://photos.google.com/lr/photo/AF1Qip_squat');
    expect(u['video_photos_check'], matches(RegExp(r'^verified:\d+$')));
    expect(u['video_thumb'], startsWith('data:image/jpeg;base64,'));
    expect(g.downloads, contains('https://lh3/AF1Qip_squat=w256-h256'));
    expect(g.downloads.any((d) => d.contains('=dv')), isFalse);
    expect(find.text('1 clip not linked'), findsOneWidget);
    expect(find.text('verified ✓'), findsOneWidget);
  });

  testWidgets('time matches but images differ → NOT linked; review shows '
      'both; Link anyway = manual', (tester) async {
    _tall(tester);
    final repo = _Repo(_rows());
    final g = _Gateway([_item('AF1Qip_other', _taken)], cloud: 'gymB_cloud');
    await tester.pumpWidget(_app(repo, svc: _svc(g)));
    await tester.pumpAndSettle();
    await _pickAndWait(tester, () => repo.updates.isNotEmpty);
    final u = repo.updates.single;
    expect(u['video_photos_url'], isNull);
    expect(u['video_photos_check'],
        matches(RegExp(r'^mismatch:\d+:AF1Qip_other$')));
    expect(find.text('NEEDS YOUR CALL  1'), findsOneWidget);
    expect(find.text('On this phone'), findsOneWidget);
    expect(find.text('Google Photos'), findsOneWidget);
    expect(find.text('2 clips not linked'), findsOneWidget);
    await tester.ensureVisible(find.text('Link anyway'));
    await tester.tap(find.text('Link anyway'));
    await tester.pumpAndSettle();
    final l = repo.updates.last;
    expect(l['video_photos_url'],
        'https://photos.google.com/lr/photo/AF1Qip_other');
    expect(l['video_photos_check'], matches(RegExp(r'^manual:\d+$')));
  });

  testWidgets('no local clip → linked by time only, unverified',
      (tester) async {
    _tall(tester);
    final repo = _Repo(_rows());
    final g = _Gateway([_item('AF1', _taken)]);
    await tester.pumpWidget(
        _app(repo, svc: _svc(g), media: _media(sources: const {})));
    await tester.pumpAndSettle();
    await _pickAndWait(tester, () => repo.updates.isNotEmpty);
    final u = repo.updates.single;
    expect(u['video_photos_url'], 'https://photos.google.com/lr/photo/AF1');
    expect(u['video_photos_check'], 'unverified');
    expect(find.text('unverified'), findsOneWidget);
  });

  testWidgets('no video timestamp → review only (logged time ignored); '
      'Link = manual', (tester) async {
    _tall(tester);
    final repo = _Repo(_rows());
    // 5:41:02 PM — seconds from clip 2's logged start_time, but clip 2
    // has no recording time: never automatic.
    final g = _Gateway([_item('AF1Qip_bench', DateTime(2026, 10, 12, 18, 30))]);
    await tester.pumpWidget(_app(repo, svc: _svc(g)));
    await tester.pumpAndSettle();
    await _pickAndWait(tester, () => g.downloads.isNotEmpty);
    await tester.pumpAndSettle();
    expect(repo.updates, isEmpty);
    expect(find.textContaining('no video timestamp — same day'),
        findsOneWidget);
    await tester.ensureVisible(find.text('Link'));
    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();
    final u = repo.updates.single;
    expect(u['id'], '2');
    expect(u['video_photos_check'], 'manual');
  });

  testWidgets('re-picking a linked clip re-checks it by exact id',
      (tester) async {
    _tall(tester);
    final rows = _rows();
    rows[0]['video_photos_url'] = 'https://photos.google.com/lr/photo/P1';
    final repo = _Repo(rows);
    // createTime far from anything: the exact id decides, not time.
    final g = _Gateway([_item('P1', DateTime(2026, 1, 1))]);
    await tester.pumpWidget(_app(repo, svc: _svc(g)));
    await tester.pumpAndSettle();
    await _pickAndWait(tester, () => repo.updates.isNotEmpty);
    final u = repo.updates.single;
    expect(u['id'], '1');
    expect(u['video_photos_url'], 'https://photos.google.com/lr/photo/P1');
    expect(u['video_photos_check'], matches(RegExp(r'^verified:\d+$')));
    expect(find.text('RE-CHECKED  1'), findsOneWidget);
  });

  testWidgets('schema without the durable dims explains what is needed',
      (tester) async {
    _tall(tester);
    final bare = _viewWith(const []);
    await tester.pumpWidget(_app(_Repo(_rows()), view: bare));
    await tester.pumpAndSettle();
    expect(find.text('Linking isn\'t available yet'), findsOneWidget);
    expect(find.textContaining('"video_photos_url"'), findsOneWidget);
    expect(find.text('Pick clips in Google Photos'), findsNothing);
  });

  test('videoFieldOf shows the icon for any video field; linkable needs '
      'the photos_url sibling', () {
    expect(PhotosLinkScreen.linkableVideoField(_view), 'video_url');
    final bare = _viewWith(const []);
    expect(PhotosLinkScreen.videoFieldOf(bare), 'video_url');
    expect(PhotosLinkScreen.linkableVideoField(bare), isNull);
    final none = ViewSchema(
        name: 'x',
        datasource: 'gsheets',
        table: 'x',
        entities: [],
        measures: [],
        dimensions: [_d('id', DimensionType.string)]);
    expect(PhotosLinkScreen.videoFieldOf(none), isNull);
  });
}
