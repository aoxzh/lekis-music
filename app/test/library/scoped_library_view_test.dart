import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/folders_view.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/scoped_library_view.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/paged_track_list.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/playlists/playlists_view.dart';
import 'package:lekis/src/features/search/search_page.dart';
import 'package:lekis/src/features/sources/widgets/add_source.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

const _local = LibraryScope.local();
const _nas = LibraryScope.nas();
const _plugin = LibraryScope.plugin('test.provider');

TrackRowDto _row(int id, {bool loved = false}) => TrackRowDto(
  id: id,
  title: 'Track $id',
  artistLine: 'Performer $id',
  albumTitle: 'Untitled',
  durationMs: BigInt.from(60000),
  isLocal: true,
  loved: loved,
);

ScopedTrackMetadataDto _credit(
  int id, {
  int album = 10,
  int artist = 7,
  List<String> genres = const [],
}) => ScopedTrackMetadataDto(
  trackId: id,
  albumId: album,
  albumArtist: 'Compilation',
  artists: [
    ScopedArtistCreditDto(
      artistId: artist,
      name: 'Band / $artist',
      role: 'main',
    ),
  ],
  genres: genres,
);

class _Idle extends PlaybackController {
  @override
  PlaybackUiState build() => const PlaybackUiState();
}

class _Player extends PlayerActions {
  _Player(super.ref);
  List<int> ids = [];
  int index = -1;
  bool shuffled = false;
  PlayContextDto? contextUsed;

  @override
  void playTracks(List<int> trackIds, {int start = 0, bool shuffle = false}) {
    ids = trackIds;
    index = start;
    shuffled = shuffle;
  }

  @override
  Future<bool> playContext(
    PlayContextDto context, {
    int startIndex = 0,
    bool shuffle = false,
  }) async {
    contextUsed = context;
    index = startIndex;
    shuffled = shuffle;
    return true;
  }
}

class _Fixture {
  _Fixture({
    this.rows = const {},
    this.metadata = const {},
    this.albums = const [],
    this.albumTracks = const {},
  });

  final Map<LibraryScope, List<TrackRowDto>> rows;
  final Map<int, ScopedTrackMetadataDto> metadata;
  final List<AlbumDto> albums;
  final Map<ScopedAlbumQuery, List<TrackRowDto>> albumTracks;
  final albumTrackCalls = <(ScopedAlbumQuery, int)>[];
  final trackCalls = <(ScopedSongQuery, int, int)>[];
  final metadataCalls = <(LibraryScope, List<int>)>[];
  final albumCalls = <ScopedSongQuery>[];
  bool metadataFails = false;

  late final container = ProviderContainer.test(
    retry: (_, _) => null,
    overrides: [
      libraryScopedTrackPageProvider.overrideWith(
        (ref, query) => (offset, limit) async {
          trackCalls.add((query, offset, limit));
          return (rows[query.$1] ?? []).skip(offset).take(limit).toList();
        },
      ),
      scopedTrackMetadataFetcherProvider.overrideWith(
        (ref, scope) => (ids) async {
          metadataCalls.add((scope, ids));
          if (metadataFails) throw StateError('metadata unavailable');
          return [for (final id in ids) ?metadata[id]];
        },
      ),
      scopedAlbumPageProvider.overrideWith(
        (ref, query) => (offset, limit) async {
          albumCalls.add(query);
          return albums.skip(offset).take(limit).toList();
        },
      ),
      scopedAlbumTrackPageProvider.overrideWith(
        (ref, query) => (offset, limit) async {
          albumTrackCalls.add((query, offset));
          return (albumTracks[query] ?? []).skip(offset).take(limit).toList();
        },
      ),
      playbackProvider.overrideWith(_Idle.new),
      playerActionsProvider.overrideWith(_Player.new),
      downloadStateProvider.overrideWith((ref, id) => null),
      downloadProgressProvider.overrideWith((ref, id) => null),
    ],
  );

  _Player get player => container.read(playerActionsProvider) as _Player;

  Future<void> show(WidgetTester tester, Widget body) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: lekisDarkTheme(),
          home: Scaffold(body: body),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

const _album = AlbumDto(
  id: 10,
  title: 'Untitled',
  artistLine: 'Compilation',
  trackCount: 2,
);

void main() {
  testWidgets(
    'folders and playlists delegate the explicit scope before reading tracks',
    (tester) async {
      final fixture = _Fixture();
      late FoldersView folders;
      late PlaylistsView playlists;
      await fixture.show(
        tester,
        Consumer(
          builder: (context, ref, _) {
            folders = const ScopedLibraryView(
              scope: _nas,
              segment: LibrarySegment.folders,
            ).build(context, ref) as FoldersView;
            playlists = const ScopedLibraryView(
              scope: _plugin,
              segment: LibrarySegment.playlists,
            ).build(context, ref) as PlaylistsView;
            return const SizedBox();
          },
        ),
      );
      expect(folders.scope, _nas);
      expect(playlists.scope, _plugin);
      expect(fixture.trackCalls, isEmpty);
      expect(fixture.metadataCalls, isEmpty);
    },
  );
  testWidgets(
    'album landing loads only a scoped album page and preserves bridge order',
    (tester) async {
      final fixture = _Fixture(
        albums: const [
          AlbumDto(
            id: 20,
            title: 'Untitled',
            artistLine: 'Other',
            trackCount: 1,
          ),
          _album,
        ],
        albumTracks: {
          (_nas, 10): [for (var id = 501; id > 0; id--) _row(id)],
        },
      );
      fixture.container
          .read(albumSortProvider.notifier)
          .set(TrackSortDto.recentlyAdded);
      await fixture.show(
        tester,
        const ScopedLibraryView(scope: _nas, segment: LibrarySegment.albums),
      );
      expect(fixture.albumCalls, [(_nas, TrackSortDto.recentlyAdded)]);
      expect(fixture.trackCalls, isEmpty);
      expect(fixture.metadataCalls, isEmpty);
      expect(fixture.albumTrackCalls, isEmpty);
      expect(
        tester
            .widgetList<AlbumCard>(find.byType(AlbumCard))
            .map((card) => card.album.id),
        [20, 10],
      );
      await tester.tap(find.text('Compilation'));
      await tester.pumpAndSettle();
      expect(fixture.albumTrackCalls, [((_nas, 10), 0), ((_nas, 10), 500)]);
      await tester.tap(find.text('Track 500'));
      await tester.pumpAndSettle();
      expect(fixture.player.ids, [for (var id = 501; id > 0; id--) id]);
      expect(fixture.player.index, 1);
      await tester.tap(find.byKey(const ValueKey('play-shuffle.queue-menu')));
      await tester.pumpAndSettle();
      expect(find.text('导出整张专辑'), findsOneWidget);
      expect(find.text('复制曲目列表'), findsOneWidget);
      expect(fixture.metadataCalls, isEmpty);
    },
  );

  testWidgets(
    'album menu plays every scoped page and artist back restores the list offset',
    (tester) async {
      final rows = [for (var i = 1; i <= 80; i++) _row(i)];
      final albumRows = [for (var i = 1; i <= 501; i++) _row(i)];
      final fixture = _Fixture(
        rows: {_nas: rows},
        metadata: {
          for (final row in rows) row.id: _credit(row.id, artist: row.id),
        },
        albums: [_album],
        albumTracks: {(_nas, _album.id): albumRows},
      );
      await fixture.show(
        tester,
        const ScopedLibraryView(scope: _nas, segment: LibrarySegment.albums),
      );
      await tester.tap(find.byTooltip('更多操作：Untitled'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(fixture.player.ids, [for (final row in albumRows) row.id]);
      expect(fixture.albumTrackCalls, [
        ((_nas, _album.id), 0),
        ((_nas, _album.id), 500),
      ]);
      await fixture.show(
        tester,
        const ScopedLibraryView(scope: _nas, segment: LibrarySegment.artists),
      );
      final menu = find.byTooltip('更多操作：Band / 50');
      await tester.scrollUntilVisible(menu, 260);
      await tester.pumpAndSettle();
      final before = tester.getCenter(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看艺人'));
      await tester.pumpAndSettle();
      expect(find.text('Track 50'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.getCenter(menu), before);
    },
  );

  testWidgets(
    'artist opens the whole scoped compilation and source changes clear navigation',
    (tester) async {
      final fixture = _Fixture(
        rows: {
          _nas: [_row(1), _row(2), _row(3)],
          _local: [_row(4)],
        },
        metadata: {
          1: _credit(1),
          2: _credit(2, artist: 8),
          3: _credit(3, album: 20, artist: 9),
          4: _credit(4),
        },
        albumTracks: {
          (_nas, 10): [_row(1), _row(2)],
        },
      );
      await fixture.show(
        tester,
        const ScopedLibraryView(scope: _nas, segment: LibrarySegment.artists),
      );
      await tester.tap(find.text('Band / 7'));
      await tester.pumpAndSettle();
      expect(find.text('Track 2'), findsNothing);
      await tester.tap(find.text('Untitled'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Track 2'));
      expect(fixture.player.ids, [1, 2]);
      expect(fixture.player.index, 1);
      await tester.tap(find.text('随机播放'));
      expect(fixture.player.shuffled, isTrue);
      expect(
        tester
            .widget<PlayShuffleButtons>(find.byType(PlayShuffleButtons))
            .queueTrackIds,
        [1, 2],
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await fixture.show(
        tester,
        const ScopedLibraryView(scope: _local, segment: LibrarySegment.artists),
      );
      expect(find.text('Track 2'), findsNothing);
      expect(find.text('Band / 7'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
    },
  );

  testWidgets(
    'genres join by scoped track ID and liked uses current rows only',
    (tester) async {
      final rows = [_row(1, loved: true), _row(2)];
      final fixture = _Fixture();
      await fixture.show(
        tester,
        ScopedLibraryRowsView(
          scope: _local,
          segment: LibrarySegment.genres,
          rows: rows,
          metadata: {
            1: _credit(1, genres: ['Jazz', ' Jazz ', 'Pop']),
            2: _credit(2),
            9: _credit(9, genres: ['Foreign']),
          },
        ),
      );
      expect(find.text('Jazz'), findsOneWidget);
      expect(find.text('Pop'), findsOneWidget);
      expect(find.text('1 首歌曲'), findsNWidgets(2));
      expect(find.text('Foreign'), findsNothing);
      await tester.tap(find.text('Jazz'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Track 1'));
      expect(fixture.player.ids, [1]);
      await fixture.show(
        tester,
        ScopedLibraryRowsView(
          scope: _local,
          segment: LibrarySegment.liked,
          rows: rows,
        ),
      );
      expect(find.byTooltip('保存为歌单'), findsOneWidget);
      expect(find.text('Track 2'), findsNothing);
      expect(find.byType(BackButton), findsNothing);
    },
  );

  testWidgets(
    'songs page, play, shuffle, and batch selection use the plugin scope',
    (tester) async {
      final fixture = _Fixture(
        rows: {
          _plugin: [_row(5), _row(6)],
          _nas: [_row(1)],
        },
      );
      fixture.container
          .read(songSortProvider.notifier)
          .set(TrackSortDto.artist);
      await fixture.show(
        tester,
        const ScopedLibraryView(scope: _plugin, segment: LibrarySegment.songs),
      );
      final playback = PlayContextDto.sourceLibrary(
        scope: _plugin.toDto(),
        sort: TrackSortDto.artist,
      );
      expect(
        tester.widget<PagedTrackList>(find.byType(PagedTrackList)).playContext,
        playback,
      );
      expect(
        tester
            .widgetList<TrackTile>(find.byType(TrackTile))
            .every((tile) => tile.pluginId == _plugin.pluginId),
        isTrue,
      );
      await tester.tap(find.text('Track 6'));
      expect(fixture.player.contextUsed, playback);
      expect(fixture.player.index, 1);
      await tester.tap(find.text('随机播放'));
      expect(fixture.player.shuffled, isTrue);
      expect(fixture.player.index, 0);
      await tester.longPress(find.text('Track 5'));
      await tester.pumpAndSettle();
      expect(find.text('加入歌单'), findsOneWidget);
      expect(find.text('批量编辑标签'), findsOneWidget);
      await fixture.show(
        tester,
        const ScopedLibraryView(scope: _nas, segment: LibrarySegment.songs),
      );
      expect(find.text('Track 5'), findsNothing);
      expect(find.text('批量编辑标签'), findsNothing);
      expect(fixture.metadataCalls, isEmpty);
    },
  );

  testWidgets(
    'retry on artist metadata failure refetches credits by scoped batch',
    (tester) async {
      final rows = [for (var id = 1; id <= 501; id++) _row(id)];
      final fixture = _Fixture(
        rows: {_nas: rows},
        metadata: {for (final row in rows) row.id: _credit(row.id)},
      )..metadataFails = true;
      await fixture.show(
        tester,
        const ScopedLibraryView(scope: _nas, segment: LibrarySegment.artists),
      );
      expect(find.text('重试'), findsOneWidget);
      fixture.metadataFails = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('Band / 7'), findsOneWidget);
      expect(fixture.metadataCalls.map((call) => (call.$1, call.$2.length)), [
        (_nas, 500),
        (_nas, 500),
        (_nas, 1),
      ]);
    },
  );

  for (final (scope, segment, label) in [
    (_local, LibrarySegment.songs, '添加文件夹'),
    (_nas, LibrarySegment.albums, '添加网络音源'),
    (_plugin, LibrarySegment.songs, '搜索此音源'),
  ]) {
    testWidgets('empty $segment opens $label', (tester) async {
      final fixture = _Fixture();
      await fixture.show(
        tester,
        ScopedLibraryView(scope: scope, segment: segment),
      );
      expect(find.byKey(const ValueKey('empty-state.mark')), findsNothing);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      switch (scope.kind) {
        case LibraryScopeKind.local:
          expect(
            tester.widget<SourceForm>(find.byType(SourceForm)).kind,
            SourceKindDto.local,
          );
        case LibraryScopeKind.nas:
          expect(find.byType(AddSourcePage), findsOneWidget);
        case LibraryScopeKind.plugin:
          expect(
            tester.widget<SearchPage>(find.byType(SearchPage)).pluginId,
            _plugin.pluginId,
          );
      }
    });
  }
}
