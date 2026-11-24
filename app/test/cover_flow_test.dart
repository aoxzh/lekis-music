// 封面流：居中的封面最大，两侧旋转；点侧边封面把它换到中间。

import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/bridge/core_events.dart';
import 'package:lekis/src/features/library/cover_flow_page.dart';
import 'package:lekis/src/features/library/library_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/scoped_library_view.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/rust/frb_generated.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _total = 40;

AlbumDto _album(int index) => AlbumDto(
  id: index,
  title: '专辑 $index',
  artistLine: '月兔',
  year: 2020,
  trackCount: 10,
);

/// 分页的假资料库；封面为空，测试不需要核心。
ProviderContainer _container({
  PageFetcher<AlbumDto> Function(ScopedSongQuery)? albums,
  PageFetcher<TrackRowDto> Function(ScopedAlbumQuery)? albumTracks,
  void Function(int)? resolveCover,
  VoidCallback? readCatalog,
}) {
  final list = PagedList<AlbumDto>(
    pageSize: 20,
    count: () async => _total,
    fetch: (offset, limit) async {
      final end = (offset + limit).clamp(0, _total);
      return [for (var i = offset; i < end; i++) _album(i)];
    },
  );
  final container = ProviderContainer(
    overrides: [
      coreEventSourceProvider.overrideWithValue(const Stream.empty()),
      albumsListProvider.overrideWith((ref, sort) => list),
      albumArtworkProvider.overrideWith((ref, albumId) async {
        resolveCover?.call(albumId);
        return null;
      }),
      trackArtworkProvider.overrideWith((ref, trackId) async => null),
      libraryScopedTrackPageProvider.overrideWith((ref, query) {
        readCatalog?.call();
        return (offset, limit) async => [];
      }),
      scopedAlbumPageProvider.overrideWith(
        (ref, query) => albums?.call(query) ?? (offset, limit) async => [],
      ),
      scopedAlbumTrackPageProvider.overrideWith(
        (ref, query) => albumTracks?.call(query) ?? (offset, limit) async => [],
      ),
      scopedTrackMetadataFetcherProvider.overrideWith((ref, scope) {
        readCatalog?.call();
        return (ids) async => [];
      }),
      playerActionsProvider.overrideWith(_CapturePlayer.new),
    ],
  );
  addTearDown(list.dispose);
  addTearDown(container.dispose);
  return container;
}

class _CapturePlayer extends PlayerActions {
  _CapturePlayer(super.ref);
  List<int> ids = [];
  int? index;

  @override
  void playTracks(List<int> trackIds, {int start = 0, bool shuffle = false}) {
    ids = trackIds;
    index = start;
  }
}

class _CoverApi implements RustLibApi {
  @override
  String crateApiCoreArtworkPath({required String hash, required int width}) =>
      'assets/brand/mark.png';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TrackRowDto _row(int id, String title, {String album = 'Shared album'}) =>
    TrackRowDto(
      id: id,
      title: title,
      albumTitle: album,
      artistLine: 'Artist',
      durationMs: BigInt.from(60000),
      loved: false,
      isLocal: true,
    );

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(theme: lekisDarkTheme(), home: const CoverFlowPage()),
);

Finder _cover(int index) => find.byKey(ValueKey('cover-flow.cover-$index'));

String _centredTitle(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('cover-flow.title'))).data!;

void main() {
  testWidgets('uses the scoped album artwork hash without resolving it again', (
    tester,
  ) async {
    const album = AlbumDto(
      id: 83,
      title: 'Cached',
      artistLine: 'Artist',
      trackCount: 1,
      artworkHash: 'source-cover',
    );
    RustLib.initMock(api: _CoverApi());
    addTearDown(RustLib.dispose);
    final resolutions = <int>[];
    final container = _container(
      albums: (_) =>
          (offset, limit) async => [album],
      resolveCover: resolutions.add,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const CoverFlowPage(scope: LibraryScope.nas()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final faces = tester.widgetList<ArtworkImage>(find.byType(ArtworkImage));
    expect(faces.map((face) => face.hash), ['source-cover', 'source-cover']);
    expect(resolutions, isEmpty);
  });

  testWidgets('a scoped cover opens and plays only its source recordings', (
    tester,
  ) async {
    const nas = LibraryScope.nas();
    const album = AlbumDto(
      id: 91,
      title: 'Shared album',
      artistLine: 'Artist',
      trackCount: 2,
    );
    final albumQueries = <ScopedSongQuery>[];
    final detailQueries = <ScopedAlbumQuery>[];
    final artworkRequests = <int>[];
    var catalogReads = 0;
    final container = _container(
      albums: (query) {
        albumQueries.add(query);
        return (offset, limit) async => [album];
      },
      albumTracks: (query) {
        detailQueries.add(query);
        return (offset, limit) async => query == (nas, album.id)
            ? [_row(10, 'NAS first'), _row(11, 'NAS second')]
            : [_row(7, 'Local track')];
      },
      readCatalog: () => catalogReads++,
      resolveCover: artworkRequests.add,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  Navigator.of(context).push(CoverFlowPage.route(scope: nas)),
              child: const Text('Open NAS'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open NAS'));
    await tester.pumpAndSettle();
    expect(_centredTitle(tester), 'Shared album');
    expect(find.text('1 / 1'), findsOneWidget);
    expect(albumQueries, [(nas, TrackSortDto.title)]);
    expect(detailQueries, isEmpty);
    expect(artworkRequests, isEmpty);
    expect(
      find.descendant(of: _cover(0), matching: find.byType(ArtworkPlaceholder)),
      findsNWidgets(2),
    );
    await tester.tap(_cover(0));
    await tester.pumpAndSettle();
    expect(find.text('NAS first'), findsOneWidget);
    expect(find.text('Local track'), findsNothing);
    await tester.tap(find.text('NAS second'));
    await tester.pumpAndSettle();
    final player = container.read(playerActionsProvider) as _CapturePlayer;
    expect(player.ids, [10, 11]);
    expect(player.index, 1);
    expect(detailQueries, [(nas, album.id)]);
    expect(catalogReads, 0);
  });

  testWidgets(
    'an empty plugin source stays empty even when the global library has albums',
    (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: _container(),
          child: MaterialApp(
            theme: lekisDarkTheme(),
            home: const CoverFlowPage(scope: LibraryScope.plugin('test.empty')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('这个音源还没有专辑'), findsOneWidget);
      expect(_cover(0), findsNothing);
    },
  );

  testWidgets('plugin cover flow fetches distant album pages on demand', (
    tester,
  ) async {
    const plugin = LibraryScope.plugin('test.music');
    const total = 641;
    final fullPages = <int>[];
    final lastPage = Completer<List<AlbumDto>>();
    var catalogReads = 0;
    var detailReads = 0;
    final container = _container(
      albums: (query) => (offset, limit) async {
        expect(query.$1, plugin);
        if (limit > 1) {
          fullPages.add(offset);
          if (offset < total && offset + limit >= total) return lastPage.future;
        }
        return [
          for (
            var index = offset;
            index < offset + limit && index < total;
            index++
          )
            _album(index),
        ];
      },
      readCatalog: () => catalogReads++,
      albumTracks: (query) {
        detailReads++;
        return (offset, limit) async => [];
      },
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const CoverFlowPage(scope: plugin),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / $total'), findsOneWidget);
    expect(fullPages, [0]);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('$total / $total'), findsOneWidget);
    expect(_centredTitle(tester), isEmpty);
    await tester.tap(_cover(total - 1));
    expect(detailReads, 0);
    final lastOffset = fullPages.last;
    expect(lastOffset, greaterThan(0));
    lastPage.complete([
      for (var index = lastOffset; index < total; index++) _album(index),
    ]);
    await tester.pumpAndSettle();
    expect(_centredTitle(tester), '专辑 ${total - 1}');
    expect(catalogReads, 0);
    expect(detailReads, 0);
  });
  testWidgets('centres one cover and shows its album', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_container()));
    await tester.pumpAndSettle();

    expect(find.byType(CoverFlowPage), findsOneWidget);
    expect(_cover(0), findsOneWidget);
    expect(_cover(1), findsOneWidget);
    expect(_centredTitle(tester), '专辑 0');
    expect(find.text('1 / 40'), findsOneWidget);

    // 居中的封面正面朝前：投影后比两侧旋转过的宽。
    final centred = tester.getRect(_cover(0));
    final neighbour = tester.getRect(_cover(1));
    expect(centred.width, greaterThan(neighbour.width));

    // 每张封面都是一个带专辑名的按钮，居中的那张是选中态。
    final centredNode = tester.getSemantics(_cover(0)).getSemanticsData();
    expect(centredNode.label, '专辑 0');
    expect(centredNode.flagsCollection.isButton, isTrue);
    expect(centredNode.flagsCollection.isSelected, Tristate.isTrue);
    final sideNode = tester.getSemantics(_cover(1)).getSemanticsData();
    expect(sideNode.label, '专辑 1');
    expect(sideNode.flagsCollection.isSelected, Tristate.isFalse);

    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a side cover recentres it', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_container()));
    await tester.pumpAndSettle();

    await tester.tap(_cover(1));
    await tester.pumpAndSettle();

    expect(_centredTitle(tester), '专辑 1');
    expect(find.text('2 / 40'), findsOneWidget);
    expect(
      tester
          .getSemantics(_cover(1))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slow drag moves one cover and snaps to it', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_container()));
    await tester.pumpAndSettle();

    // 一格的距离从两张封面的投影中心量出来：拖这么远正好翻一张。
    final start = tester.getCenter(_cover(0));
    final slot = tester.getCenter(_cover(1)).dx - start.dx;
    final gesture = await tester.startGesture(start);
    const steps = 10;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(-slot / steps, 0));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_centredTitle(tester), '专辑 1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the albums header opens the cover flow', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: _container(),
        child: MaterialApp(theme: lekisDarkTheme(), home: const LibraryPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('封面流'));
    await tester.pumpAndSettle();

    expect(find.byType(CoverFlowPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a phone and a desktop window without overflow', (
    tester,
  ) async {
    for (final size in const [Size(400, 800), Size(1200, 800)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;

      await tester.pumpWidget(_app(_container()));
      await tester.pumpAndSettle();

      expect(find.byType(CoverFlowPage), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$size must not overflow');
    }
    addTearDown(tester.view.reset);
  });
}
