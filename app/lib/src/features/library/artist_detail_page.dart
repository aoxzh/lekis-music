import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

class ArtistDetailPage extends StatelessWidget {
  const ArtistDetailPage({super.key, required this.artistId});

  final int artistId;

  static Route<void> route(int artistId) => MaterialPageRoute<void>(
    settings: RouteSettings(name: '/artist/$artistId'),
    builder: (_) => ArtistDetailPage(artistId: artistId),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: ArtistDetailView(artistId: artistId),
    );
  }
}

/// Artist header, albums shelf and songs. Embeddable as a secondary pane.
class ArtistDetailView extends ConsumerWidget {
  const ArtistDetailView({super.key, required this.artistId});

  final int artistId;

  /// Songs shown before "show all" would be needed.
  static const int _songPreview = 50;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artist = ref.watch(artistProvider(artistId));
    final albumsAsync = ref.watch(artistAlbumsProvider(artistId));
    final tracksAsync = ref.watch(artistTracksProvider(artistId));
    final albums = albumsAsync.value ?? const <AlbumDto>[];
    final tracks = tracksAsync.value ?? const <TrackRowDto>[];
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);
    final actions = ref.read(playerActionsProvider);

    return artist.whenSkeleton(
      skeleton: const _ArtistSkeleton(),
      // Albums and songs arrive with the header instead of popping in.
      waitFor: [
        albumsAsync,
        tracksAsync,
      ].any((a) => !a.hasValue && !a.hasError),
      error: (e, _) => LoadErrorView(
        error: e,
        onRetry: () => ref.invalidate(artistProvider(artistId)),
      ),
      data: (artist) {
        final shown = tracks.length > _songPreview
            ? tracks.sublist(0, _songPreview)
            : tracks;
        return CustomScrollView(
          key: PageStorageKey('artist-$artistId'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(gutter, LekisSpacing.lg, gutter, 0),
              sliver: SliverToBoxAdapter(
                child: _ArtistHeader(
                  name: artist.name,
                  trackIds: [for (final track in tracks) track.id],
                  onPlay: tracks.isEmpty
                      ? null
                      : () => actions.playRows(tracks),
                  onShuffle: tracks.isEmpty
                      ? null
                      : () => actions.playRows(tracks, shuffle: true),
                ),
              ),
            ),
            if (albums.isNotEmpty)
              SliverToBoxAdapter(
                child: ArtworkShelf(
                  title: context.l10n.pick('专辑', 'Albums'),
                  itemCount: albums.length,
                  itemBuilder: (context, i) {
                    final tag = AlbumHeroTag(albums[i].id, 'artist-$artistId');
                    return AlbumCard(
                      album: albums[i],
                      heroTag: tag,
                      onTap: () => Navigator.of(context).push(
                        AlbumDetailPage.route(
                          albums[i].id,
                          heroTag: tag,
                          initialAlbum: albums[i],
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (shown.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  LekisSpacing.xl,
                  gutter,
                  LekisSpacing.sm,
                ),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    context.l10n.pick('歌曲', 'Songs'),
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.symmetric(
                horizontal: gutter - LekisSpacing.sm,
              ),
              sliver: SliverFixedExtentList.builder(
                itemExtent: TrackTile.extent,
                itemCount: shown.length,
                itemBuilder: (context, i) => TrackTile(
                  track: shown[i],
                  onTap: () => actions.playRows(tracks, start: i),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.only(bottom: scrollEndPadding(context)),
            ),
          ],
        );
      },
    );
  }
}

/// Loading layout of [ArtistDetailView]: header, an albums shelf, songs.
class _ArtistSkeleton extends StatelessWidget {
  const _ArtistSkeleton();

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutterOf(context);
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return LayoutBuilder(
      builder: (context, constraints) {
        final row = landscape || constraints.maxWidth >= _ArtistHeader._rowFrom;
        final avatar = row
            ? _ArtistHeader._compactAvatar
            : LekisSizes.gridArtworkMin;
        final name = LekisSkeleton.line(
          width: LekisSizes.gridArtworkMin,
          height: LekisSpacing.xl,
        );
        const buttons = LekisSkeleton(
          width: LekisSizes.gridArtworkMin * 1.4,
          height: LekisSizes.buttonHeight,
          radius: LekisRadius.button,
        );
        final header = row
            ? Row(
                children: [
                  LekisSkeleton.circle(size: avatar),
                  const SizedBox(width: LekisSpacing.xl),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      name,
                      const SizedBox(height: LekisSpacing.md),
                      buttons,
                    ],
                  ),
                ],
              )
            : Column(
                children: [
                  LekisSkeleton.circle(size: avatar),
                  const SizedBox(height: LekisSpacing.lg),
                  name,
                  const SizedBox(height: LekisSpacing.lg),
                  buttons,
                ],
              );
        return SkeletonTrackListView(
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  LekisSpacing.lg,
                  gutter,
                  0,
                ),
                child: header,
              ),
              const SkeletonShelf(titleWidth: 56),
              const SizedBox(height: LekisSpacing.xl),
            ],
          ),
        );
      },
    );
  }
}

/// Avatar, name and play / shuffle.
///
/// Narrow portrait windows keep the centred stack; anything wider or in
/// landscape puts a smaller avatar on the left so the albums shelf below
/// stays on the first screen.
class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({
    required this.name,
    required this.trackIds,
    required this.onPlay,
    required this.onShuffle,
  });

  final String name;
  final List<int> trackIds;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  /// Avatar side in the side-by-side layout.
  static const double _compactAvatar = LekisSizes.gridArtworkMin * 0.75;

  /// Panes at least this wide use the side-by-side layout.
  static const double _rowFrom = LekisSizes.gridArtworkMin * 3.5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return LayoutBuilder(
      builder: (context, constraints) {
        final row = landscape || constraints.maxWidth >= _rowFrom;
        final title = Semantics(
          header: true,
          child: Text(
            name,
            textAlign: row ? TextAlign.start : TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        );
        final buttons = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PlayShuffleButtons(onPlay: onPlay, onShuffle: onShuffle),
            if (trackIds.isNotEmpty) ...[
              const SizedBox(width: LekisSpacing.sm),
              BatchDownloadButton(
                trackIds: trackIds,
                tooltip: context.l10n.pick('下载全部歌曲', 'Download All Songs'),
              ),
            ],
          ],
        );
        if (!row) {
          return Column(
            children: [
              ArtistAvatar(name: name, size: LekisSizes.gridArtworkMin),
              const SizedBox(height: LekisSpacing.lg),
              title,
              const SizedBox(height: LekisSpacing.lg),
              buttons,
            ],
          );
        }
        return Row(
          children: [
            ArtistAvatar(name: name, size: _compactAvatar),
            const SizedBox(width: LekisSpacing.xl),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  title,
                  const SizedBox(height: LekisSpacing.md),
                  buttons,
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
