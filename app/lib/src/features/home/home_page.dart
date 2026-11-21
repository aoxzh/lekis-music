import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/home/home_providers.dart';
import 'package:lekis/src/features/home/playback_history_page.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/library/widgets/track_tile.dart'
    show formatDuration;
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/features/stats/listening_stats_page.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/shell/shell_chrome.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/brand_mark.dart';
import 'package:material_ui/material_ui.dart';

/// Home: continue listening, recently added, most played.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final empty = ref.watch(libraryIsEmptyProvider).value ?? false;
    final recentAlbums =
        ref.watch(recentlyAddedAlbumsProvider).value ?? const [];
    final recent = ref.watch(recentlyAddedProvider).value ?? const [];
    final played = ref.watch(recentlyPlayedProvider).value ?? const [];
    final most = ref.watch(mostPlayedProvider).value ?? const [];
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final gutter = pageGutterOf(context);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: empty
            ? const LibraryEmptyState(
                title: '欢迎使用 Lekis',
                message: '先在“音源”里添加音乐，首页会展示最近添加和常听的歌曲。',
              )
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(recentlyAddedAlbumsProvider);
                  ref.invalidate(recentlyAddedProvider);
                  ref.invalidate(recentlyPlayedProvider);
                  ref.invalidate(mostPlayedProvider);
                  await ref.read(recentlyAddedAlbumsProvider.future);
                },
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        LekisSpacing.lg,
                        gutter,
                        0,
                      ),
                      sliver: const SliverToBoxAdapter(child: _HomeHeader()),
                    ),
                    if (hasTrack)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          LekisSpacing.lg,
                          gutter,
                          0,
                        ),
                        sliver: const SliverToBoxAdapter(child: _ResumeHero()),
                      ),
                    if (played.isNotEmpty)
                      SliverToBoxAdapter(
                        child: TrackShelf(
                          title: '最近播放',
                          tracks: played,
                          trailing: TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const PlaybackHistoryPage(),
                              ),
                            ),
                            child: const Text('查看全部'),
                          ),
                        ),
                      ),
                    if (recentAlbums.isNotEmpty)
                      SliverToBoxAdapter(
                        child: AlbumShelf(title: '最近添加', albums: recentAlbums),
                      )
                    else if (recent.isNotEmpty)
                      SliverToBoxAdapter(
                        child: TrackShelf(title: '最近添加', tracks: recent),
                      ),
                    if (most.isNotEmpty)
                      SliverToBoxAdapter(
                        child: TrackShelf(title: '最常播放', tracks: most),
                      ),
                    SliverPadding(
                      padding: EdgeInsets.only(
                        bottom: scrollEndPadding(context),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

String greetingFor(DateTime now) {
  final hour = now.hour;
  if (hour < 5) return '夜深了';
  if (hour < 11) return '早上好';
  if (hour < 14) return '中午好';
  if (hour < 18) return '下午好';
  return '晚上好';
}

/// Eyebrow, greeting and the stats shortcut at the top of Home.
///
/// The brand mark is only shown when the navigation chrome (rail / sidebar)
/// does not already show it.
class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final showMark = !ShellChrome.showsBrandMarkOf(context);
    final eyebrow = Text(
      'LEKIS · 本地资料库',
      style: theme.textTheme.labelSmall?.copyWith(
        color: colors.moon,
        letterSpacing: 1.6,
      ),
    );
    return Semantics(
      header: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showMark)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LekisBrandMark(size: LekisSpacing.xxl - LekisSpacing.xs),
                const SizedBox(width: LekisSpacing.sm),
                Flexible(child: eyebrow),
              ],
            )
          else
            eyebrow,
          const SizedBox(height: LekisSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(child: _Greeting()),
              const SizedBox(width: LekisSpacing.sm),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: LekisSpacing.md,
                    vertical: LekisSpacing.xs,
                  ),
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ListeningStatsPage(),
                  ),
                ),
                icon: const Icon(Icons.insights_outlined, size: 18),
                label: const Text('听歌统计'),
              ),
            ],
          ),
          const SizedBox(height: LekisSpacing.xs),
          Text(
            '继续上次的，或从资料库里挑一张。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Time-of-day greeting that stays current: re-evaluated every minute while
/// on screen and whenever the app comes back to the foreground.
class _Greeting extends StatefulWidget {
  const _Greeting();

  @override
  State<_Greeting> createState() => _GreetingState();
}

class _GreetingState extends State<_Greeting> with WidgetsBindingObserver {
  late String _text = greetingFor(DateTime.now());
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    final next = greetingFor(DateTime.now());
    if (next != _text && mounted) setState(() => _text = next);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text(_text, style: Theme.of(context).textTheme.headlineLarge);
}

/// Horizontal shelf of album cards; tapping opens the album detail page.
class AlbumShelf extends StatelessWidget {
  const AlbumShelf({
    super.key,
    required this.title,
    required this.albums,
    this.trailing,
  });

  final String title;
  final List<AlbumDto> albums;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ArtworkShelf(
      title: title,
      trailing: trailing,
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final album = albums[i];
        final tag = 'home-album-${album.id}';
        final subtitle = [
          if (album.artistLine.trim().isNotEmpty) album.artistLine.trim(),
          if (album.year != null) '${album.year}',
        ].join(' · ');
        return ArtworkCardFrame(
          onTap: () => Navigator.of(context).push(
            AlbumDetailPage.route(
              album.id.toInt(),
              heroTag: tag,
              initialAlbum: album,
            ),
          ),
          artwork: AlbumArtHero(album: album, tag: tag),
          title: album.title,
          subtitle: subtitle.isEmpty ? null : subtitle,
          semanticLabel: subtitle.isEmpty
              ? album.title
              : '${album.title}，$subtitle',
        );
      },
    );
  }
}

/// Horizontal shelf of track cards; tapping plays the shelf from that card.
class TrackShelf extends ConsumerWidget {
  const TrackShelf({
    super.key,
    required this.title,
    required this.tracks,
    this.trailing,
  });

  final String title;
  final List<TrackRowDto> tracks;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ArtworkShelf(
      title: title,
      trailing: trailing,
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        final artist = t.artistLine.trim();
        // Every card keeps the second line: a missing artist reads as
        // "unknown" instead of leaving a ragged gap in the shelf.
        final subtitle = artist.isEmpty
            ? '未知艺人'
            : artist == t.title
            ? null
            : artist;
        return ArtworkCardFrame(
          onTap: () =>
              ref.read(playerActionsProvider).playRows(tracks, start: i),
          artwork: TrackArtwork(
            trackId: t.id,
            hasArtwork: t.artworkId != null,
            radius: LekisRadius.artworkGrid,
            placeholderLabel: t.title,
          ),
          title: t.title,
          subtitle: subtitle,
          semanticLabel: artist.isEmpty || artist == t.title
              ? '播放 ${t.title}'
              : '播放 ${t.title}，$artist',
        );
      },
    );
  }
}

/// The current track as a compact, artwork-tinted resume card.
///
/// Its height follows the artwork, so wide windows no longer get a tall card
/// with an empty middle: artwork | label, title, artist · album, play button
/// and progress.
class _ResumeHero extends ConsumerWidget {
  const _ResumeHero();

  /// Artwork side on narrow cards / on wider cards. Kept small enough that
  /// the first shelf stays visible above the floating mini player.
  static const double _artCompact = LekisSizes.listArtwork * 2;
  static const double _artWide = LekisSizes.gridArtworkMin * 0.7;

  /// Cards narrower than this use the smaller artwork and padding.
  static const double _compactBelow = LekisSizes.gridArtworkMin * 3.5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).value;
    if (track == null) return const SizedBox.shrink();

    final palette = ref.watch(currentArtworkProvider).value?.palette;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = context.lekisColors;
    final tint = palette == null
        ? scheme.primary
        : Color(0xFF000000 | palette.primary);
    final artist = track.artists.join(' / ');
    final subtitle = [
      if (artist.isNotEmpty) artist,
      if (track.albumTitle != null && track.albumTitle!.isNotEmpty)
        track.albumTitle!,
    ].join(' · ');

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < _compactBelow;
        final artSize = compact ? _artCompact : _artWide;
        final pad = compact ? LekisSpacing.md : LekisSpacing.lg;
        final gap = compact ? LekisSpacing.sm : LekisSpacing.md;

        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '继续收听',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.moon,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: LekisSpacing.xxs),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: compact
                  ? theme.textTheme.titleMedium
                  : theme.textTheme.titleLarge,
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: LekisSpacing.sm),
            const _ResumeProgress(),
          ],
        );

        final hash = ref.watch(currentArtworkProvider).value?.hash;
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LekisRadius.lg),
            border: Border.all(color: colors.outline),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(LekisRadius.lg),
            child: Stack(
              children: [
                Positioned.fill(
                  child: _ResumeHeroBackdrop(hash: hash, tint: tint),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          tint.withValues(alpha: 0.30),
                          scheme.surface.withValues(alpha: 0.78),
                          scheme.surface.withValues(alpha: 0.92),
                        ],
                        stops: const [0, 0.52, 1],
                      ),
                    ),
                  ),
                ),
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: () => openNowPlaying(context),
                    child: Padding(
                      padding: EdgeInsets.all(pad),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: artSize,
                            child: const CurrentArtwork(
                              radius: LekisRadius.artworkGrid,
                            ),
                          ),
                          SizedBox(width: pad),
                          Expanded(child: info),
                          SizedBox(width: gap),
                          // The transport fills the far end of the card on wide
                          // windows instead of leaving the right half empty.
                          const PlayPauseButton(filled: true),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Full-bleed soft artwork wash for [_ResumeHero].
///
/// Decodes the cover at a tiny width and stretches it with [BoxFit.cover]
/// across the whole card: no 1:1 [AspectRatio] seam on wide cards and no live
/// Impeller blur layer inside the scrollable Home view.
class _ResumeHeroBackdrop extends StatelessWidget {
  const _ResumeHeroBackdrop({required this.hash, required this.tint});

  final String? hash;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tint.withValues(alpha: 0.45), surface],
        ),
      ),
    );
    final h = hash;
    if (h == null) return fallback;
    Widget imageFor(
      int bucket,
      Widget Function(BuildContext, Object, StackTrace?) onErr,
    ) => Image.file(
      File(artworkFilePath(h, bucket)),
      fit: BoxFit.cover,
      cacheWidth: 32,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: onErr,
    );
    final small = artworkWidthBuckets.first;
    return imageFor(
      small,
      small == artworkFallbackWidth
          ? (_, _, _) => fallback
          : (_, _, _) => imageFor(artworkFallbackWidth, (_, _, _) => fallback),
    );
  }
}

/// Thin progress line + elapsed / total time. A widget of its own so only it
/// rebuilds on position ticks.
class _ResumeProgress extends ConsumerWidget {
  const _ResumeProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final progress = ref.watch(progressProvider);
    final duration = ref.watch(playbackProvider.select((s) => s.durationMs));
    final position = ref.watch(throttledPositionProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(LekisRadius.pill),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: LekisSpacing.xs,
            color: colors.accent,
            backgroundColor: colors.outline,
          ),
        ),
        if (duration > 0) ...[
          const SizedBox(height: LekisSpacing.xs),
          Text(
            '${formatDuration(position)} / ${formatDuration(duration)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}
