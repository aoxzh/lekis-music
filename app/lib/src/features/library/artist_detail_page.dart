import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
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
    final albums =
        ref.watch(artistAlbumsProvider(artistId)).value ?? const <AlbumDto>[];
    final tracks =
        ref.watch(artistTracksProvider(artistId)).value ??
        const <TrackRowDto>[];
    final gutter = pageGutterOf(context);
    final theme = Theme.of(context);
    final actions = ref.read(playerActionsProvider);

    return artist.when(
      loading: () => const Center(child: CircularProgressIndicator()),
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
                child: Column(
                  children: [
                    ArtistAvatar(
                      name: artist.name,
                      size: LekisSizes.gridArtworkMin,
                    ),
                    const SizedBox(height: LekisSpacing.lg),
                    Semantics(
                      header: true,
                      child: Text(
                        artist.name,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: LekisSpacing.lg),
                    PlayShuffleButtons(
                      onPlay: tracks.isEmpty
                          ? null
                          : () => actions.playRows(tracks),
                      onShuffle: tracks.isEmpty
                          ? null
                          : () => actions.playRows(tracks, shuffle: true),
                    ),
                  ],
                ),
              ),
            ),
            if (albums.isNotEmpty)
              SliverToBoxAdapter(
                child: ArtworkShelf(
                  title: '专辑',
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
                  child: Text('歌曲', style: theme.textTheme.titleLarge),
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
