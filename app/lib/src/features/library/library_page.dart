import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/albums_view.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/artists_view.dart';
import 'package:lekis/src/features/library/folders_view.dart';
import 'package:lekis/src/features/library/genres_view.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/liked_view.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/paged_track_list.dart';
import 'package:lekis/src/features/playlists/playlists_view.dart';
import 'package:lekis/src/layout/adaptive_two_pane.dart';
import 'package:lekis/src/layout/fold.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Library: Albums / Artists / Songs / Genres.
///
/// On wide windows (and across a foldable's hinge) Albums and Artists show
/// one more level of hierarchy: the list on one side, the detail on the
/// other.
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final segment = ref.watch(librarySegmentProvider);
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);

    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.lg,
        gutter - LekisSpacing.sm,
        LekisSpacing.md,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        spacing: LekisSpacing.lg,
        runSpacing: LekisSpacing.sm,
        children: [
          Semantics(
            header: true,
            child: Text(
              '资料库',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<LibrarySegment>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LekisSpacing.sm,
                      ),
                    ),
                    segments: const [
                      ButtonSegment(
                        value: LibrarySegment.albums,
                        label: Text('专辑'),
                      ),
                      ButtonSegment(
                        value: LibrarySegment.artists,
                        label: Text('艺人'),
                      ),
                      ButtonSegment(
                        value: LibrarySegment.songs,
                        label: Text('歌曲'),
                      ),
                      ButtonSegment(
                        value: LibrarySegment.genres,
                        label: Text('流派'),
                      ),
                      ButtonSegment(
                        value: LibrarySegment.playlists,
                        label: Text('歌单'),
                      ),
                      ButtonSegment(
                        value: LibrarySegment.liked,
                        label: Text('喜欢'),
                      ),
                      ButtonSegment(
                        value: LibrarySegment.folders,
                        label: Text('文件夹'),
                      ),
                    ],
                    selected: {segment},
                    onSelectionChanged: (s) =>
                        ref.read(librarySegmentProvider.notifier).set(s.first),
                  ),
                ),
              ),
              if (segment == LibrarySegment.albums)
                const _SortMenu(target: _SortTarget.albums),
              if (segment == LibrarySegment.albums)
                IconButton(
                  tooltip: '封面流',
                  onPressed: () => openCoverFlow(context),
                  icon: const Icon(Icons.view_carousel_rounded),
                ),
              if (segment == LibrarySegment.songs)
                const _SortMenu(target: _SortTarget.songs),
            ],
          ),
        ],
      ),
    );

    final body = switch (segment) {
      LibrarySegment.albums => const _AlbumsSegment(),
      LibrarySegment.artists => const _ArtistsSegment(),
      LibrarySegment.songs => const _SongsSegment(),
      LibrarySegment.genres => const GenreList(),
      LibrarySegment.playlists => const PlaylistsView(),
      LibrarySegment.liked => const LikedSongsView(),
      LibrarySegment.folders => const FoldersView(),
    };

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(
              child: AnimatedSwitcher(
                duration: LekisMotion.fast,
                child: KeyedSubtree(key: ValueKey(segment), child: body),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _showsTwoPanes(BuildContext context) =>
    isWideLayout(context) || context.fold.isSeparating;

class _AlbumsSegment extends ConsumerWidget {
  const _AlbumsSegment();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedAlbumProvider);
    final twoPane = _showsTwoPanes(context);
    return AdaptiveTwoPane(
      primaryFraction: 0.5,
      primary: AlbumGrid(
        selectedId: twoPane ? selected : null,
        onOpen: (album) {
          if (_showsTwoPanes(context)) {
            ref.read(selectedAlbumProvider.notifier).set(album.id);
          } else {
            Navigator.of(context).push(
              AlbumDetailPage.route(
                album.id,
                heroTag: AlbumHeroTag(album.id, AlbumGrid.heroScope),
                initialAlbum: album,
              ),
            );
          }
        },
      ),
      // The album grid is the page; the detail pane only opens once an
      // album is picked (an empty "pick one" half wasted a desktop window).
      // On a separating hinge the split stays so nothing sits on the crease.
      secondary: !twoPane
          ? null
          : selected != null
          ? _ClosablePane(
              onClose: () => ref.read(selectedAlbumProvider.notifier).set(null),
              child: AlbumDetailView(
                key: ValueKey(selected),
                albumId: selected,
              ),
            )
          : context.fold.isSeparating
          ? const _PickPrompt(text: '选择一张专辑')
          : null,
    );
  }
}

/// A detail pane with a close button in its top trailing corner.
class _ClosablePane extends StatelessWidget {
  const _ClosablePane({required this.onClose, required this.child});
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: LekisSpacing.sm,
          right: LekisSpacing.sm,
          child: SafeArea(
            bottom: false,
            left: false,
            child: IconButton.filledTonal(
              tooltip: '关闭',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ),
      ],
    );
  }
}

class _ArtistsSegment extends ConsumerWidget {
  const _ArtistsSegment();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedArtistProvider);
    final twoPane = _showsTwoPanes(context);
    return AdaptiveTwoPane(
      primaryFraction: 0.35,
      primary: ArtistList(
        selectedId: twoPane ? selected : null,
        onOpen: (id) {
          if (_showsTwoPanes(context)) {
            ref.read(selectedArtistProvider.notifier).set(id);
          } else {
            Navigator.of(context).push(ArtistDetailPage.route(id));
          }
        },
      ),
      secondary: twoPane
          ? (selected == null
                ? const _PickPrompt(text: '选择一位艺人')
                : ArtistDetailView(key: ValueKey(selected), artistId: selected))
          : null,
    );
  }
}

class _SongsSegment extends ConsumerWidget {
  const _SongsSegment();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sort = ref.watch(songSortProvider);
    final indexOffsets = sort == TrackSortDto.title
        ? ref.watch(trackIndexOffsetsProvider).value
        : null;
    return PagedTrackList(
      key: ValueKey(sort),
      list: ref.watch(songsListProvider(sort)),
      indexOffsets: indexOffsets,
    );
  }
}

class _PickPrompt extends StatelessWidget {
  const _PickPrompt({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.touch_app_outlined,
            size: LekisSpacing.xxxl,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Text(
            text,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

enum _SortTarget { albums, songs }

class _SortMenu extends ConsumerWidget {
  const _SortMenu({required this.target});
  final _SortTarget target;

  static const _labels = {
    TrackSortDto.title: '标题',
    TrackSortDto.artist: '艺人',
    TrackSortDto.album: '专辑',
    TrackSortDto.recentlyAdded: '最近添加',
    TrackSortDto.mostPlayed: '最常播放',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = target == _SortTarget.albums
        ? albumSortProvider
        : songSortProvider;
    final current = ref.watch(provider);
    final options = target == _SortTarget.albums
        ? const [
            TrackSortDto.title,
            TrackSortDto.artist,
            TrackSortDto.recentlyAdded,
          ]
        : TrackSortDto.values;
    return PopupMenuButton<TrackSortDto>(
      tooltip: '排序：${_labels[current]}',
      icon: const Icon(Icons.sort_rounded),
      initialValue: current,
      onSelected: (v) => ref.read(provider.notifier).set(v),
      itemBuilder: (_) => [
        for (final o in options)
          CheckedPopupMenuItem(
            value: o,
            checked: o == current,
            child: Text(_labels[o]!),
          ),
      ],
    );
  }
}
