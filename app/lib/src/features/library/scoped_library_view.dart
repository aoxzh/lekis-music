import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/enrich/enrich_actions.dart';
import 'package:lekis/src/features/library/artwork_actions.dart';
import 'package:lekis/src/features/library/album_detail_page.dart'
    show PlayShuffleButtons;
import 'package:lekis/src/features/library/albums_view.dart' show AlbumGrid;
import 'package:lekis/src/features/library/folders_view.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/music_export_dialog.dart';
import 'package:lekis/src/features/library/scoped_album_panes.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/library_browse_menu.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/paged_track_list.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/playlists/playlists_view.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart'
    show copyTrackListAsText, saveTracksAsPlaylistFlow;
import 'package:lekis/src/features/search/search_page.dart';
import 'package:lekis/src/features/sources/widgets/add_source.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/action_menu.dart';
import 'package:material_ui/material_ui.dart';

final scopedOrderedTracksProvider = FutureProvider.autoDispose
    .family<List<TrackRowDto>, ScopedSongQuery>((ref, query) async {
      final fetch = ref.watch(libraryScopedTrackPageProvider(query));
      ref.invalidateOnCatalogChange();
      ref.invalidateOnUserStateChange();
      final tracks = <int, TrackRowDto>{};
      const limit = 500;
      for (var offset = 0; ref.mounted; offset += limit) {
        final page = await fetch(offset, limit);
        for (final track in page) {
          tracks[track.id] = track;
        }
        if (page.length < limit) break;
      }
      return tracks.values.toList(growable: false);
    });

final scopedLibraryTracksProvider = FutureProvider.autoDispose
    .family<List<TrackRowDto>, LibraryScope>(
      (ref, scope) => ref.watch(
        scopedOrderedTracksProvider((scope, ref.watch(songSortProvider)))
            .future,
      ),
    );

typedef ScopedTrackMetadataFetcher =
    Future<List<ScopedTrackMetadataDto>> Function(List<int> ids);

final scopedTrackMetadataFetcherProvider = Provider.autoDispose
    .family<ScopedTrackMetadataFetcher, LibraryScope>(
      (ref, scope) =>
          (ids) => core.trackMetadataBySource(
            scope: scope.toDto(),
            trackIds: Int64List.fromList(ids),
          ),
    );

final scopedAlbumPageProvider = Provider.autoDispose
    .family<PageFetcher<AlbumDto>, ScopedSongQuery>(
      (ref, query) =>
          (offset, limit) async => core.listAlbumsBySource(
            scope: query.$1.toDto(),
            sort: query.$2,
            offset: offset,
            limit: limit,
          ),
    );

final _catalogProvider = FutureProvider.autoDispose
    .family<_Catalog, LibraryScope>((ref, scope) async {
      final fetch = ref.watch(scopedTrackMetadataFetcherProvider(scope));
      final rows = await ref.watch(scopedLibraryTracksProvider(scope).future);
      final metadata = <int, ScopedTrackMetadataDto>{};
      const batch = 500;
      for (var start = 0; start < rows.length && ref.mounted; start += batch) {
        final slice = rows.getRange(
          start,
          math.min(start + batch, rows.length),
        );
        for (final detail in await fetch([for (final row in slice) row.id])) {
          metadata[detail.trackId] = detail;
        }
      }
      return (rows: rows, metadata: metadata);
    });

typedef _Catalog = ({
  List<TrackRowDto> rows,
  Map<int, ScopedTrackMetadataDto> metadata,
});

final scopedAlbumsListProvider = Provider.autoDispose
    .family<PagedList<AlbumDto>, ScopedSongQuery>((ref, query) {
      ref.invalidateOnCatalogChange();
      final list = PagedList<AlbumDto>(
        fetch: ref.watch(scopedAlbumPageProvider(query)),
      );
      ref.onDispose(list.dispose);
      return list;
    });

typedef ScopedAlbumQuery = (LibraryScope, int);
final scopedAlbumTrackPageProvider = Provider.autoDispose
    .family<PageFetcher<TrackRowDto>, ScopedAlbumQuery>(
      (ref, query) =>
          (offset, limit) => core.albumTracksBySource(
            scope: query.$1.toDto(),
            albumId: query.$2,
            offset: offset,
            limit: limit,
          ),
    );

final _albumTracksProvider = FutureProvider.autoDispose
    .family<List<TrackRowDto>, ScopedAlbumQuery>((ref, query) async {
      ref.invalidateOnCatalogChange();
      ref.invalidateOnUserStateChange();
      final fetch = ref.watch(scopedAlbumTrackPageProvider(query));
      final rows = <TrackRowDto>[];
      const limit = 500;
      for (var offset = 0; ref.mounted; offset += limit) {
        final page = await fetch(offset, limit);
        rows.addAll(page);
        if (page.length < limit) break;
      }
      return rows;
    });

Map<int, List<TrackRowDto>> _albumRows(
  List<TrackRowDto> rows,
  Map<int, ScopedTrackMetadataDto> metadata,
) {
  final groups = <int, List<TrackRowDto>>{};
  for (final row in rows) {
    final id = metadata[row.id]?.albumId;
    if (id != null) (groups[id] ??= []).add(row);
  }
  return groups;
}

List<AlbumDto> _artistAlbums(
  List<TrackRowDto> rows,
  Map<int, ScopedTrackMetadataDto> metadata,
) => [
  for (final entry in _albumRows(rows, metadata).entries)
    AlbumDto(
      id: entry.key,
      title: entry.value.first.albumTitle ?? '',
      artistLine: metadata[entry.value.first.id]?.albumArtist ?? '',
      trackCount: entry.value.length,
    ),
]..sort((first, second) => first.title.compareTo(second.title));

class ScopedLibraryView extends ConsumerWidget {
  const ScopedLibraryView({
    super.key,
    required this.scope,
    required this.segment,
  });

  final LibraryScope scope;
  final LibrarySegment segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (segment == LibrarySegment.folders) return FoldersView(scope: scope);
    if (segment == LibrarySegment.playlists) return PlaylistsView(scope: scope);
    if (segment == LibrarySegment.songs) {
      final query = (scope, ref.watch(songSortProvider));
      final playback = PlayContextDto.sourceLibrary(
        scope: scope.toDto(),
        sort: query.$2,
      );
      final gutter = pageGutterOf(context);
      final list = ref.watch(scopedSongsListProvider(query));
      return PagedTrackList(
        key: ObjectKey(list),
        list: list,
        playContext: playback,
        pluginId: scope.pluginId,
        empty: _Empty(scope: scope, segment: segment),
        header: Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            LekisSpacing.md,
            gutter,
            LekisSpacing.sm,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: PlayShuffleButtons(
              onPlay: () =>
                  ref.read(playerActionsProvider).playContext(playback),
              onShuffle: () => ref
                  .read(playerActionsProvider)
                  .playContext(playback, shuffle: true),
            ),
          ),
        ),
      );
    }
    if (segment == LibrarySegment.albums) {
      final query = (scope, ref.watch(albumSortProvider));
      final albums = ref.watch(scopedAlbumsListProvider(query));
      return ScopedAlbumPanes(
        key: ValueKey(scope),
        albums: albums,
        empty: _Empty(scope: scope, segment: segment),
        menuBuilder: (context, album, open) =>
            _AlbumMenu(scope: scope, album: album, open: open),
        openRoute: (album) =>
            ScopedLibraryAlbumPage.route(scope: scope, album: album),
        detailBuilder: (album, close) =>
            ScopedLibraryAlbumPage(scope: scope, album: album, onClose: close),
      );
    }
    if (segment == LibrarySegment.liked) {
      final tracks = scopedOrderedTracksProvider((
        scope,
        ref.watch(songSortProvider),
      ));
      return ref
          .watch(tracks)
          .when(
            data: (rows) => ScopedLibraryRowsView(
              scope: scope,
              segment: segment,
              rows: rows,
            ),
            error: (error, _) => LoadErrorView(
              error: error,
              onRetry: () => ref.invalidate(tracks),
            ),
            loading: _loading,
          );
    }
    if (segment == LibrarySegment.artists) {
      return _ScopedArtists(key: ValueKey(scope), scope: scope);
    }
    final catalog = _catalogProvider(scope);
    return ref
        .watch(catalog)
        .when(
          data: (data) => ScopedLibraryRowsView(
            scope: scope,
            segment: segment,
            rows: data.rows,
            metadata: data.metadata,
          ),
          error: (error, _) => LoadErrorView(
            error: error,
            onRetry: () => retryScopedCatalog(ref, scope),
          ),
          loading: _loading,
        );
  }
}

void retryScopedCatalog(
  WidgetRef ref,
  LibraryScope scope, [
  VoidCallback? retry,
]) {
  ref.invalidate(
    scopedOrderedTracksProvider((scope, ref.read(songSortProvider))),
  );
  ref.invalidate(_catalogProvider(scope));
  retry?.call();
}

Widget _loading() => const Center(child: CircularProgressIndicator());

class _AlbumMenu extends ConsumerWidget {
  const _AlbumMenu({
    required this.scope,
    required this.album,
    required this.open,
  });
  final LibraryScope scope;
  final AlbumDto album;
  final VoidCallback open;

  @override
  Widget build(BuildContext context, WidgetRef ref) => LibraryBrowseMenu(
    title: album.title,
    subtitle: _songCount(context, album.trackCount),
    openLabel: context.l10n.pick('查看专辑', 'View album'),
    icon: Icons.album_outlined,
    onOpen: open,
    onPlay: album.trackCount == 0
        ? null
        : () async {
            final provider = _albumTracksProvider((scope, album.id));
            // Keep all pages of this source's album alive until playback starts.
            final sub = ref.listenManual(provider, (_, _) {});
            try {
              final rows = await ref.read(provider.future);
              if (context.mounted && rows.isNotEmpty) {
                ref.read(playerActionsProvider).playRows(rows);
              }
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(error.toString())));
              }
            } finally {
              sub.close();
            }
          },
  );
}

typedef _LibraryGroup = ({Object id, String name});

Iterable<_LibraryGroup> _artistCredits(ScopedTrackMetadataDto? metadata) sync* {
  for (final artist in metadata?.artists ?? const <ScopedArtistCreditDto>[]) {
    if (artist.name.trim().isNotEmpty) {
      yield (id: artist.artistId ?? artist.name, name: artist.name);
    }
  }
}

List<TrackRowDto> _artistRows(_Catalog catalog, Object id) => [
  for (final row in catalog.rows)
    if (_artistCredits(catalog.metadata[row.id])
        .any((credit) => credit.id == id))
      row,
];

class _ScopedArtists extends ConsumerStatefulWidget {
  const _ScopedArtists({super.key, required this.scope});
  final LibraryScope scope;

  @override
  ConsumerState<_ScopedArtists> createState() => _ScopedArtistsState();
}

class _ScopedArtistsState extends ConsumerState<_ScopedArtists> {
  Route<void>? _detail;

  @override
  void dispose() {
    // The source can be replaced while its artist page is still on the tab.
    final route = _detail;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = widget.scope;
    final provider = _catalogProvider(scope);
    return ref
        .watch(provider)
        .when(
          loading: _loading,
          error: (error, _) => LoadErrorView(
            error: error,
            onRetry: () => retryScopedCatalog(ref, scope),
          ),
          data: (catalog) {
            return ScopedLibraryRowsView(
              scope: scope,
              segment: LibrarySegment.artists,
              rows: catalog.rows,
              metadata: catalog.metadata,
              onOpenArtist: (artist) async {
                if (_detail?.isActive == true) return;
                final route = MaterialPageRoute<void>(
                  builder: (_) =>
                      _ScopedArtistPage(scope: scope, artist: artist),
                );
                _detail = route;
                await Navigator.of(context).push(route);
                if (_detail == route) _detail = null;
              },
            );
          },
        );
  }
}

class _ScopedArtistPage extends ConsumerWidget {
  const _ScopedArtistPage({required this.scope, required this.artist});
  final LibraryScope scope;
  final _LibraryGroup artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: Text(artist.name)),
    body: ref
        .watch(_catalogProvider(scope))
        .when(
          loading: _loading,
          error: (error, _) => LoadErrorView(
            error: error,
            onRetry: () => retryScopedCatalog(ref, scope),
          ),
          data: (catalog) {
            final rows = _artistRows(catalog, artist.id);
            return _Songs(
              scope: scope,
              rows: rows,
              albums: _artistAlbums(rows, catalog.metadata),
              menuTitle: artist.name,
            );
          },
        ),
  );
}

class ScopedLibraryAlbumPage extends ConsumerWidget {
  const ScopedLibraryAlbumPage({
    super.key,
    required this.scope,
    required this.album,
    this.onClose,
  });

  final LibraryScope scope;
  final AlbumDto album;
  final VoidCallback? onClose;

  static Route<void> route({
    required LibraryScope scope,
    required AlbumDto album,
  }) => MaterialPageRoute<void>(
    builder: (_) => ScopedLibraryAlbumPage(scope: scope, album: album),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = _albumTracksProvider((scope, album.id));
    return Scaffold(
      appBar: AppBar(
        title: Text(album.title),
        automaticallyImplyLeading: onClose == null,
        actions: [if (onClose != null) CloseButton(onPressed: onClose)],
      ),
      body: ref
          .watch(provider)
          .when(
            data: (rows) => _Songs(
              scope: scope,
              rows: rows,
              albumDetail: true,
              menuTitle: album.title,
            ),
            error: (error, _) => LoadErrorView(
              error: error,
              onRetry: () => ref.invalidate(provider),
            ),
            loading: _loading,
          ),
    );
  }
}

class ScopedLibraryRowsView extends ConsumerStatefulWidget {
  const ScopedLibraryRowsView({
    super.key,
    required this.scope,
    required this.segment,
    required this.rows,
    this.metadata = const {},
    this.onOpenArtist,
  });

  final LibraryScope scope;
  final LibrarySegment segment;
  final List<TrackRowDto> rows;
  final Map<int, ScopedTrackMetadataDto> metadata;
  final ValueChanged<({Object id, String name})>? onOpenArtist;

  @override
  ConsumerState<ScopedLibraryRowsView> createState() =>
      _ScopedLibraryRowsViewState();
}

class _ScopedLibraryRowsViewState extends ConsumerState<ScopedLibraryRowsView> {
  ({Object id, String name})? _group;

  @override
  void didUpdateWidget(ScopedLibraryRowsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scope != oldWidget.scope ||
        widget.segment != oldWidget.segment) {
      _group = null;
    }
  }

  void _back() => setState(() => _group = null);

  Iterable<({Object id, String name})> _labels(TrackRowDto row) =>
      switch (widget.segment) {
        LibrarySegment.artists => _artistCredits(widget.metadata[row.id]),
        LibrarySegment.genres => [
          for (final label
              in widget.metadata[row.id]?.genres ?? const <String>[])
            if (label.trim().isNotEmpty) (id: label.trim(), name: label.trim()),
        ],
        _ => const [],
      };

  @override
  Widget build(BuildContext context) {
    final segment = widget.segment;
    final group = _group;
    final scoped = widget.rows;
    if (segment == LibrarySegment.folders) {
      return FoldersView(scope: widget.scope);
    }
    if (segment == LibrarySegment.playlists) {
      return PlaylistsView(scope: widget.scope);
    }
    if (segment == LibrarySegment.songs || segment == LibrarySegment.liked) {
      return _Songs(
        scope: widget.scope,
        liked: segment == LibrarySegment.liked,
        rows: segment == LibrarySegment.songs
            ? scoped
            : scoped.where((row) => row.loved).toList(),
      );
    }
    if (group == null && segment != LibrarySegment.albums) {
      final counts = <({Object id, String name}), int>{};
      for (final row in scoped) {
        for (final name in _labels(row).toSet()) {
          counts.update(name, (count) => count + 1, ifAbsent: () => 1);
        }
      }
      final names = counts.keys.toList()
        ..sort((first, second) => first.name.compareTo(second.name));
      if (names.isEmpty) return const _Empty();
      return ListView.builder(
        padding: EdgeInsets.symmetric(horizontal: pageGutterOf(context)),
        itemCount: names.length,
        itemBuilder: (context, index) {
          final name = names[index];
          final count = _songCount(context, counts[name]!);
          final artist = segment == LibrarySegment.artists;
          void open() {
            if (artist && widget.onOpenArtist != null) {
              widget.onOpenArtist!(name);
            } else {
              setState(() => _group = name);
            }
          }

          return ListTile(
            leading: artist ? ArtistAvatar(name: name.name) : null,
            title: Text(name.name),
            subtitle: Text(count),
            trailing: artist
                ? LibraryBrowseMenu(
                    title: name.name,
                    subtitle: count,
                    openLabel: context.l10n.pick('查看艺人', 'View artist'),
                    icon: Icons.person_outline_rounded,
                    onOpen: open,
                    onPlay: () => ref
                        .read(playerActionsProvider)
                        .playRows(
                          _artistRows((
                            rows: scoped,
                            metadata: widget.metadata,
                          ), name.id),
                        ),
                  )
                : const Icon(Icons.chevron_right_rounded),
            onTap: open,
          );
        },
      );
    }
    final members = group == null
        ? scoped
        : [
            for (final row in scoped)
              if (_labels(row).any((label) => label.id == group.id)) row,
          ];
    final albums = segment != LibrarySegment.genres
        ? _artistAlbums(members, widget.metadata)
        : const <AlbumDto>[];
    if (group == null) {
      return Consumer(
        builder: (context, ref, _) => AlbumGrid(
          list: ref.watch(_groupAlbumsProvider(albums)),
          empty: _Empty(scope: widget.scope, segment: segment),
          onOpen: (album) => Navigator.of(context).push(
            ScopedLibraryAlbumPage.route(scope: widget.scope, album: album),
          ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Column(
        children: [
          Row(
            children: [
              BackButton(onPressed: _back),
              Expanded(
                child: Text(
                  group.name,
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Expanded(
            child: _Songs(scope: widget.scope, rows: members, albums: albums),
          ),
        ],
      ),
    );
  }
}

String _songCount(BuildContext context, int count) =>
    context.l10n.pick('$count 首歌曲', '$count ${count == 1 ? 'song' : 'songs'}');

class _Empty extends StatelessWidget {
  const _Empty({this.scope, this.segment});
  final LibraryScope? scope;
  final LibrarySegment? segment;

  @override
  Widget build(BuildContext context) {
    final pick = context.l10n.pick;
    final albums = segment == LibrarySegment.albums;
    final kind = scope?.kind;
    final (message, action) = switch (kind) {
      LibraryScopeKind.local => (
        albums
            ? pick('本地曲库暂无专辑', 'No local albums yet')
            : pick('本地曲库暂无歌曲', 'No local songs yet'),
        pick('添加文件夹', 'Add folder'),
      ),
      LibraryScopeKind.nas => (
        albums
            ? pick('NAS 曲库暂无专辑', 'No NAS albums yet')
            : pick('NAS 曲库暂无歌曲', 'No NAS songs yet'),
        pick('添加网络音源', 'Add network source'),
      ),
      LibraryScopeKind.plugin => (
        albums
            ? pick('此音源暂无已入库的专辑', 'No saved albums from this source')
            : pick('此音源暂无已入库的歌曲', 'No saved songs from this source'),
        pick('搜索此音源', 'Search this source'),
      ),
      null => (pick('此来源暂无相关内容', 'No matching items in this source'), null),
    };
    void open() {
      if (kind == LibraryScopeKind.nas) {
        Navigator.of(
          context,
        ).push<int>(MaterialPageRoute(builder: (_) => const AddSourcePage()));
        return;
      }
      if (kind == LibraryScopeKind.local) {
        Navigator.of(context).push<int>(
          MaterialPageRoute(
            builder: (_) => const SourceFormPage(kind: SourceKindDto.local),
          ),
        );
        return;
      }
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(action!)),
            body: SearchPage(pluginId: scope!.pluginId),
          ),
        ),
      );
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(LekisSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (action != null) ...[
              const SizedBox(height: LekisSpacing.sm),
              OutlinedButton(onPressed: open, child: Text(action)),
            ],
          ],
        ),
      ),
    );
  }
}

class _GroupList<T> extends PagedList<T> {
  _GroupList(this.rows)
    : super(
        count: () async => rows.length,
        fetch: (offset, limit) async => rows.skip(offset).take(limit).toList(),
      );
  final List<T> rows;

  @override
  (List<T>, int) loadedWindow(int index) => (rows, index);
}

_GroupList<T> _fromRows<T>(Ref ref, List<T> rows) {
  final list = _GroupList(rows);
  ref.onDispose(list.dispose);
  return list;
}

final _groupListProvider = Provider.autoDispose
    .family<_GroupList<TrackRowDto>, List<TrackRowDto>>(_fromRows);
final _groupAlbumsProvider = Provider.autoDispose
    .family<_GroupList<AlbumDto>, List<AlbumDto>>(_fromRows);

class _Songs extends ConsumerWidget {
  const _Songs({
    required this.scope,
    required this.rows,
    this.albums = const [],
    this.albumDetail = false,
    this.menuTitle,
    this.liked = false,
  });
  final LibraryScope scope;
  final List<TrackRowDto> rows;
  final List<AlbumDto> albums;
  final bool albumDetail;
  final String? menuTitle;
  final bool liked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (rows.isEmpty) return const _Empty();
    void play({bool shuffle = false}) =>
        ref.read(playerActionsProvider).playRows(rows, shuffle: shuffle);
    final gutter = pageGutterOf(context);
    final ids = [for (final row in rows) row.id];
    final downloadable = [
      for (final row in rows)
        if (!row.isLocal) row.id,
    ];
    return PagedTrackList(
      key: ObjectKey(rows),
      list: ref.watch(_groupListProvider(rows)),
      pluginId: scope.pluginId,
      header: Padding(
        padding: EdgeInsets.fromLTRB(
          gutter,
          LekisSpacing.sm,
          gutter,
          LekisSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PlayShuffleButtons(
              alignment: WrapAlignment.start,
              onPlay: () => play(),
              onShuffle: () => play(shuffle: true),
              queueTrackIds: ids,
              onEnrich: albumDetail
                  ? () => enrichTracksFlow(context, ids)
                  : null,
              onChangeArtwork: albumDetail
                  ? () => changeArtworkFlow(context, trackIds: ids)
                  : null,
              menuTitle: menuTitle,
              menuSubtitle: menuTitle == null
                  ? null
                  : _songCount(context, rows.length),
              moreActions: [
                if (albumDetail && scope.kind != LibraryScopeKind.plugin)
                  LekisMenuAction(
                    () => showMusicExport(context, albumTrackIds: ids),
                    Icons.drive_file_move_outline,
                    context.l10n.pick('导出整张专辑', 'Export album'),
                    startsGroup: true,
                  ),
                if (albumDetail)
                  LekisMenuAction(
                    () => copyTrackListAsText(context, rows),
                    Icons.content_copy_rounded,
                    context.l10n.pick('复制曲目列表', 'Copy Track List'),
                    startsGroup: scope.kind == LibraryScopeKind.plugin,
                  ),
              ],
              trailing: [
                if (liked)
                  IconButton(
                    tooltip: context.l10n.pick('保存为歌单', 'Save as Playlist'),
                    icon: const Icon(Icons.playlist_add_rounded),
                    onPressed: () => saveTracksAsPlaylistFlow(
                      context,
                      ref,
                      rows,
                      suggestedName: context.l10n.pick('喜欢的歌曲', 'Liked Songs'),
                    ),
                  ),
                if (downloadable.isNotEmpty)
                  BatchDownloadButton(trackIds: downloadable),
              ],
            ),
            for (final album in albums)
              Builder(
                builder: (context) {
                  void open() => Navigator.of(context).push(
                    ScopedLibraryAlbumPage.route(scope: scope, album: album),
                  );
                  return ListTile(
                    leading: const Icon(Icons.album_rounded),
                    title: Text(album.title),
                    subtitle: Text(_songCount(context, album.trackCount)),
                    trailing: _AlbumMenu(
                      scope: scope,
                      album: album,
                      open: open,
                    ),
                    onTap: open,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
