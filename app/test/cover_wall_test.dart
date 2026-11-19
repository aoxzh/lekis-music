// Cover wall: paged album grid, no whole-library load, tap-to-play.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/now_playing/cover_wall.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _totalAlbums = 100000;
const _pageSize = 24;

AlbumDto _album(int index) => AlbumDto(
  id: index,
  title: '专辑 $index',
  artistLine: '月兔',
  year: 2020,
  trackCount: 10,
);

class _FakeActions extends PlayerActions {
  _FakeActions(super.ref);

  final played = <int>[];

  @override
  Future<void> playAlbum(int albumId) async => played.add(albumId);
}

void main() {
  testWidgets('cover wall pages through a 100k album library', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final fetches = <(int, int)>[];
    final list = PagedList<AlbumDto>(
      pageSize: _pageSize,
      count: () async => _totalAlbums,
      fetch: (offset, limit) async {
        fetches.add((offset, limit));
        final end = (offset + limit).clamp(0, _totalAlbums);
        return [for (var i = offset; i < end; i++) _album(i)];
      },
    );
    addTearDown(list.dispose);

    late _FakeActions actions;
    final container = ProviderContainer(
      overrides: [
        albumsListProvider.overrideWith((ref, sort) => list),
        playerActionsProvider.overrideWith(
          (ref) => actions = _FakeActions(ref),
        ),
        albumArtworkProvider.overrideWith((ref, albumId) async => null),
      ],
    );
    addTearDown(container.dispose);
    container.read(playerActionsProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: const Scaffold(body: CoverWall()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CoverWall), findsOneWidget);
    expect(fetches, isNotEmpty);
    expect(fetches.first.$1, 0);
    expect(fetches.first.$2, _pageSize);
    expect(
      fetches.every((f) => f.$2 <= _pageSize),
      isTrue,
      reason: 'the wall must fetch pages, never the whole library',
    );

    final firstTile = find.byKey(const ValueKey('cover-wall.tile-0'));
    expect(firstTile, findsOneWidget);
    await tester.tap(firstTile);
    await tester.pump();
    expect(actions.played, [0]);

    final before = fetches.length;
    await tester.drag(
      find.byKey(const ValueKey('cover-wall.grid')),
      const Offset(0, -1600),
    );
    await tester.pumpAndSettle();

    expect(
      fetches.skip(before).any((f) => f.$1 > 0),
      isTrue,
      reason: 'scrolling should pull the next page',
    );
    expect(
      fetches.length,
      lessThan(20),
      reason: 'only visible pages should ever be requested',
    );
    expect(tester.takeException(), isNull);
  });
}
