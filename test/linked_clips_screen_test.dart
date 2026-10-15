import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:airledger/models/database_config.dart';
import 'package:airledger/models/view_schema.dart';
import 'package:airledger/services/photos_link.dart';
import 'package:airledger/services/sheets_repository.dart' show Record;
import 'package:airledger/services/warehouse_connector.dart';
import 'package:airledger/ui/linked_clips_screen.dart';

import 'support/fake_clip_media.dart';

// "Linked clips" review: one card per clip (grouped rows), local vs
// saved cloud thumbnails side by side, status chips, the Needs review
// filter, and the actions (Play local / Open in Google Photos / Unlink
// writes / Link anyway on a persisted mismatch).

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
    _d('weight', DimensionType.number),
    _d('reps', DimensionType.number),
    _d('video_url', DimensionType.string,
        input: InputSpec(widget: WidgetType.video, autofill: false)),
    _d('video_media_id', DimensionType.string),
    _d('video_thumb', DimensionType.string),
    _d('video_taken_at', DimensionType.datetime),
    _d('video_photos_url', DimensionType.string),
    _d('video_photos_check', DimensionType.string),
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

const _p = 'https://photos.google.com/lr/photo/';

List<Record> _rows() => [
      // Clip A: two sets share one clip, verified.
      for (final id in ['a1', 'a2'])
        {
          'id': id,
          'date': DateTime(2026, 10, 12),
          'exercise': 'Barbell Squat',
          'weight': 315.0,
          'reps': 3.0,
          'video_url': 'content://media/1',
          'video_media_id': 'mA',
          'video_taken_at': DateTime(2026, 10, 12, 17, 41),
          'video_photos_url': '${_p}PA',
          'video_photos_check': 'verified:2',
        },
      // Clip B: linked before verification existed (no check).
      {
        'id': 'b',
        'date': DateTime(2026, 10, 11),
        'exercise': 'Bench Press',
        'weight': 225,
        'reps': 5,
        'video_url': 'content://media/2',
        'video_media_id': 'mB',
        'video_photos_url': '${_p}PB',
      },
      // Clip C: persisted mismatch — NOT linked.
      {
        'id': 'c',
        'date': DateTime(2026, 10, 10),
        'exercise': 'Deadlift',
        'video_url': 'content://media/3',
        'video_media_id': 'mC',
        'video_photos_check': 'mismatch:31:PC',
      },
    ];

Future<(_Repo, FakeClipMedia)> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final repo = _Repo(_rows());
  final media = FakeClipMedia(
    sources: const {'a1': '/cache/mA.mp4'},
    thumbs: const {'a1': 'gymA_local_50', 'b': 'gymA_local_0'},
  );
  media.cloudThumbs.map['PA'] = fixture('gymA_cloud');
  media.cloudThumbs.map['PC'] = fixture('gymB_cloud');
  await tester.pumpWidget(MaterialApp(
    home: LinkedClipsScreen(
      view: _view,
      repository: repo,
      videoField: 'video_url',
      media: media,
    ),
  ));
  await tester.pumpAndSettle();
  return (repo, media);
}

void main() {
  testWidgets('one card per clip with status chips; images side by side',
      (tester) async {
    await _pump(tester);
    expect(find.text('Oct 12 · Barbell Squat 315×3 · 2 sets'), findsOneWidget);
    expect(find.text('Oct 11 · Bench Press 225×5'), findsOneWidget);
    expect(find.text('Oct 10 · Deadlift'), findsOneWidget);
    expect(find.text('verified ✓'), findsOneWidget);
    expect(find.text('unverified'), findsOneWidget);
    expect(find.text('images differ'), findsOneWidget);
    expect(find.textContaining('2 of 64 image bits differ'), findsOneWidget);
    expect(find.textContaining('not checked yet'), findsOneWidget);
    expect(find.textContaining('NOT linked'), findsOneWidget);
    expect(find.text('On this phone'), findsNWidgets(3));
    expect(find.text('Google Photos'), findsNWidgets(3));
    // B was never cloud-thumbnailed: placeholder says how to get one.
    expect(find.text('re-link to fetch'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(4)); // A local+cloud, B local, C cloud
  });

  testWidgets('Needs review filter: unverified + mismatch only',
      (tester) async {
    await _pump(tester);
    expect(find.text('All (3)'), findsOneWidget);
    await tester.tap(find.text('Needs review (2)'));
    await tester.pumpAndSettle();
    expect(find.text('verified ✓'), findsNothing);
    expect(find.text('unverified'), findsOneWidget);
    expect(find.text('images differ'), findsOneWidget);
  });

  testWidgets('Play local only when the clip is on the phone; Open in '
      'Google Photos uses the deep link', (tester) async {
    final (_, media) = await _pump(tester);
    final play = find.widgetWithText(TextButton, 'Play local');
    expect(play, findsNWidgets(3));
    final enabled = tester
        .widgetList<TextButton>(play)
        .where((b) => b.onPressed != null)
        .length;
    expect(enabled, 1);
    await tester.tap(play.first);
    await tester.pumpAndSettle();
    expect(media.played, ['/cache/mA.mp4']);
    await tester.tap(find.widgetWithText(TextButton, 'Open in Google Photos').first);
    await tester.pumpAndSettle();
    expect(media.opened, ['${_p}PA']);
  });

  testWidgets('Unlink clears link + check on every row of the clip',
      (tester) async {
    final (repo, _) = await _pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Unlink').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Unlink'));
    await tester.pumpAndSettle();
    expect(repo.updates.map((r) => r['id']), ['a1', 'a2']);
    for (final u in repo.updates) {
      expect(u['video_photos_url'], isNull);
      expect(u['video_photos_check'], isNull);
      expect(u['video_url'], 'content://media/1'); // clip itself kept
    }
    expect(find.text('All (2)'), findsOneWidget);
    // The clip is linkable again.
    expect(linkCandidates(repo.rows, 'video_url').map((c) => c.key),
        contains('mid:mA'));
  });

  testWidgets('mismatch: Link anyway links as manual',
      (tester) async {
    final (repo, _) = await _pump(tester);
    await tester.tap(find.text('Link anyway'));
    await tester.pumpAndSettle();
    final u = repo.updates.single;
    expect(u['id'], 'c');
    expect(u['video_photos_url'], '${_p}PC');
    expect(u['video_photos_check'], 'manual:31');
    expect(find.text('linked by hand'), findsOneWidget);
  });

  testWidgets('mismatch: Dismiss clears the flag', (tester) async {
    final (repo, _) = await _pump(tester);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(repo.updates.single['video_photos_check'], isNull);
    expect(find.text('All (2)'), findsOneWidget);
  });
}
