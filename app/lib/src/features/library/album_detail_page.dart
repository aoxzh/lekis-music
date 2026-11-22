import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/enrich/enrich_actions.dart';
import 'package:lekis/src/features/library/artwork_actions.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/queue_actions.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:lekis/src/widgets/route_entrance.dart';
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
    // Live page during the transition, so the header and track list can
    // settle in behind the cover flight (RouteEntrance).
    allowSnapshotting: false,
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
          : const LekisDelayedSkeleton(
              child: SkeletonTrackListView(
                top: LekisSpacing.lg,
                numbered: true,
              ),
            );
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
                  trackIds: [for (final row in rows) row.id],
                  downloadableTrackIds: [
                    for (final row in rows)
                      if (!row.isLocal) row.id,
                  ],
                  onPlay: rows.isEmpty ? null : () => actions.playRows(rows),
                  onShuffle: rows.isEmpty
                      ? null
                      : () => actions.playRows(rows, shuffle: true),
                ),
              ),
            ),
            if (tracks.isLoading && rows.isEmpty)
              SliverToBoxAdapter(
                child: LekisDelayedSkeleton(
                  child: SkeletonTrackList(
                    numbered: true,
                    padding: EdgeInsets.symmetric(
                      horizontal: gutter - LekisSpacing.sm,
                    ),
                  ),
                ),
              ),
            if (tracks.hasError)
              SliverToBoxAdapter(child: LoadErrorView(error: tracks.error!)),
            RouteEntrance.sliver(
              order: 2,
              sliver: SliverPadding(
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
    required this.trackIds,
    required this.downloadableTrackIds,
    required this.onPlay,
    required this.onShuffle,
  });

  final AlbumDto album;
  final Object? heroTag;
  final List<int> trackIds;
  final List<int> downloadableTrackIds;
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
            RouteEntrance(
              child: Column(
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
                ],
              ),
            ),
            const SizedBox(height: LekisSpacing.lg),
            RouteEntrance(
              order: 1,
              child: PlayShuffleButtons(
                onPlay: onPlay,
                onShuffle: onShuffle,
                alignment: wide ? WrapAlignment.start : WrapAlignment.center,
                queueTrackIds: trackIds,
                onEnrich: trackIds.isEmpty
                    ? null
                    : () => enrichTracksFlow(context, trackIds),
                onChangeArtwork: () => changeArtworkFlow(
                  context,
                  trackIds: trackIds,
                  albumId: album.id.toInt(),
                ),
                trailing: [
                  if (downloadableTrackIds.isNotEmpty)
                    BatchDownloadButton(
                      trackIds: downloadableTrackIds,
                      tooltip: '下载整张专辑',
                    ),
                ],
              ),
            ),
          ],
        );

        final art = SizedBox.square(
          dimension: artSize,
          child: AlbumArtHero(
            album: album,
            tag: heroTag,
            elevation: 6,
            landing: true,
          ),
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
    this.queueTrackIds = const [],
    this.onEnrich,
    this.onChangeArtwork,
    this.alignment = WrapAlignment.center,
    this.trailing = const [],
  });

  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  /// 非空时多一个"更多"按钮：整组下一首播放 / 加入播放队列。
  final List<int> queueTrackIds;

  /// 非空时"更多"菜单里多一项"补全封面和歌词"。
  final VoidCallback? onEnrich;

  /// 非空时"更多"菜单里多一项"更换封面…"。
  final VoidCallback? onChangeArtwork;

  final WrapAlignment alignment;

  /// 放在同一行末尾的其他按钮（比如下载）。
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final buttonStyle = FilledButton.styleFrom(
      minimumSize: const Size(0, LekisSizes.touchTargetMin),
      padding: const EdgeInsets.symmetric(horizontal: LekisSpacing.md),
    );
    return Wrap(
      spacing: LekisSpacing.sm,
      runSpacing: LekisSpacing.sm,
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          style: buttonStyle,
          onPressed: onPlay,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('播放'),
        ),
        FilledButton.tonalIcon(
          style: buttonStyle,
          onPressed: onShuffle,
          icon: const Icon(Icons.shuffle_rounded),
          label: const Text('随机播放'),
        ),
        if (queueTrackIds.isNotEmpty)
          PopupMenuButton<String>(
            key: const ValueKey('play-shuffle.queue-menu'),
            tooltip: '更多操作',
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (value) => switch (value) {
              'next' => queueTracks(
                context,
                queueTrackIds,
                where: QueuePlacement.next,
              ),
              'end' => queueTracks(
                context,
                queueTrackIds,
                where: QueuePlacement.end,
              ),
              'artwork' => onChangeArtwork?.call(),
              _ => onEnrich?.call(),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'next',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.queue_play_next_rounded),
                  title: Text(QueueStrings.playNext),
                ),
              ),
              const PopupMenuItem(
                value: 'end',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.add_to_queue_rounded),
                  title: Text(QueueStrings.addToQueue),
                ),
              ),
              if (onEnrich != null) ...[
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'enrich',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.auto_fix_high_rounded),
                    title: Text(EnrichActionStrings.action),
                  ),
                ),
              ],
              if (onChangeArtwork != null)
                const PopupMenuItem(
                  value: 'artwork',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.image_outlined),
                    title: Text(ArtworkActionStrings.change),
                  ),
                ),
            ],
          ),
        ...trailing,
      ],
    );
  }
}
