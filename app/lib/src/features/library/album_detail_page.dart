import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Album detail as its own page (compact windows).
class AlbumDetailPage extends StatelessWidget {
  const AlbumDetailPage({
    super.key,
    required this.albumId,
    this.heroTag,
    this.initialAlbum,
  });

  final int albumId;

  /// Tag of the cover this page was opened from ([AlbumCard.heroTag]).
  final Object? heroTag;

  /// What the opener already knows, shown while the full album loads (so
  /// the header – and the cover flight into it – is there on frame one).
  final AlbumDto? initialAlbum;

  static Route<void> route(
    int albumId, {
    Object? heroTag,
    AlbumDto? initialAlbum,
  }) => MaterialPageRoute<void>(
    settings: RouteSettings(name: '/album/$albumId'),
    builder: (_) => AlbumDetailPage(
      albumId: albumId,
      heroTag: heroTag,
      initialAlbum: initialAlbum,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: AlbumDetailView(
        albumId: albumId,
        heroTag: heroTag,
        initialAlbum: initialAlbum,
      ),
    );
  }
}

/// Album detail body; embeddable as the secondary pane on wide windows.
class AlbumDetailView extends ConsumerWidget {
  const AlbumDetailView({
    super.key,
    required this.albumId,
    this.heroTag,
    this.initialAlbum,
  });

  final int albumId;
  final Object? heroTag;
  final AlbumDto? initialAlbum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loaded = ref.watch(albumProvider(albumId));
    final tracks = ref.watch(albumTracksProvider(albumId));
    final gutter = pageGutterOf(context);

    final shown = loaded.value ?? initialAlbum;
    if (shown == null) {
      return loaded.hasError
          ? LoadErrorView(
              error: loaded.error!,
              onRetry: () => ref.invalidate(albumProvider(albumId)),
            )
          : const Center(child: CircularProgressIndicator());
    }

    return Builder(
      builder: (context) {
        final album = shown;
        final rows = tracks.value ?? const <TrackRowDto>[];
        final actions = ref.read(playerActionsProvider);
        return CustomScrollView(
          key: PageStorageKey('album-$albumId'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                gutter,
                LekisSpacing.lg,
                gutter,
                LekisSpacing.lg,
              ),
              sliver: SliverToBoxAdapter(
                child: _AlbumHeader(
                  album: album,
                  heroTag: heroTag,
                  onPlay: rows.isEmpty ? null : () => actions.playRows(rows),
                  onShuffle: rows.isEmpty
                      ? null
                      : () => actions.playRows(rows, shuffle: true),
                ),
              ),
            ),
            if (tracks.isLoading && rows.isEmpty)
              const SliverToBoxAdapter(
                child: Center(child: CircularProgressIndicator()),
              ),
            if (tracks.hasError)
              SliverToBoxAdapter(child: LoadErrorView(error: tracks.error!)),
            SliverPadding(
              padding: EdgeInsets.symmetric(
                horizontal: gutter - LekisSpacing.sm,
              ),
              sliver: SliverFixedExtentList.builder(
                itemExtent: TrackTile.extent,
                itemCount: rows.length,
                itemBuilder: (context, i) => TrackTile(
                  track: rows[i],
                  leadingNumber: i + 1,
                  onTap: () => actions.playRows(rows, start: i),
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

class _AlbumHeader extends ConsumerWidget {
  const _AlbumHeader({
    required this.album,
    required this.heroTag,
    required this.onPlay,
    required this.onShuffle,
  });

  final AlbumDto album;
  final Object? heroTag;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final artists = ref.watch(albumArtistsProvider(album.id)).value;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= LekisSizes.gridArtworkMin * 3.5;
        final artSize = wide
            ? LekisSizes.gridArtworkMin * 1.5
            : (constraints.maxWidth * 0.66).clamp(
                LekisSizes.gridArtworkMin,
                LekisSizes.gridArtworkMin * 2,
              );
        final align = wide
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center;
        final textAlign = wide ? TextAlign.start : TextAlign.center;
        final meta = [
          if (album.year != null) '${album.year}',
          '${album.trackCount} 首歌曲',
        ].join(' · ');

        final artistLink = InkWell(
          borderRadius: BorderRadius.circular(LekisRadius.xs),
          onTap: (artists == null || artists.isEmpty)
              ? null
              : () =>
                    Navigator.of(context)
                        .push(ArtistDetailPage.route(artists.first.id)),
          child: Text(
            album.artistLine,
            textAlign: textAlign,
            style: theme.textTheme.titleMedium?.copyWith(color: colors.accent),
          ),
        );

        final info = Column(
          crossAxisAlignment: align,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                album.title,
                textAlign: textAlign,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: LekisSpacing.xs),
            artistLink,
            const SizedBox(height: LekisSpacing.xs),
            Text(
              meta,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: LekisSpacing.lg),
            PlayShuffleButtons(onPlay: onPlay, onShuffle: onShuffle),
          ],
        );

        final art = SizedBox.square(
          dimension: artSize,
          child: AlbumArtHero(album: album, tag: heroTag, elevation: 6),
        );

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              art,
              const SizedBox(width: LekisSpacing.xl),
              Expanded(child: info),
            ],
          );
        }
        return Column(
          children: [
            art,
            const SizedBox(height: LekisSpacing.lg),
            info,
          ],
        );
      },
    );
  }
}

/// "Play" + "Shuffle" pair used on album / artist / genre headers.
class PlayShuffleButtons extends StatelessWidget {
  const PlayShuffleButtons({
    super.key,
    required this.onPlay,
    required this.onShuffle,
  });

  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    const minSize = Size(
      LekisSizes.gridArtworkMin * 0.75,
      LekisSizes.touchTargetMin,
    );
    return Wrap(
      spacing: LekisSpacing.md,
      runSpacing: LekisSpacing.sm,
      alignment: WrapAlignment.center,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: minSize),
          onPressed: onPlay,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('播放'),
        ),
        FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: minSize),
          onPressed: onShuffle,
          icon: const Icon(Icons.shuffle_rounded),
          label: const Text('随机播放'),
        ),
      ],
    );
  }
}
