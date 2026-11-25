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
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/shell/shell_chrome.dart';
import 'package:lekis/src/shell/tab_bar_style.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:lekis/src/widgets/brand_mark.dart';
import 'package:lekis/src/widgets/liquid_glass.dart';
import 'package:lekis/src/widgets/skeleton.dart';
import 'package:material_ui/material_ui.dart';

/// Home: continue listening, recently added, most played.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final empty = ref.watch(libraryIsEmptyProvider).value ?? false;
    final recentAlbumsAsync = ref.watch(recentlyAddedAlbumsProvider);
    final recentAsync = ref.watch(recentlyAddedProvider);
    final playedAsync = ref.watch(recentlyPlayedProvider);
    final mostAsync = ref.watch(mostPlayedProvider);
    final recentAlbums = recentAlbumsAsync.value ?? const [];
    final recent = recentAsync.value ?? const [];
    final played = playedAsync.value ?? const [];
    final most = mostAsync.value ?? const [];
    // Shelves wait for their first answer behind skeletons; refreshes keep
    // the previous rows (`value`) and never go back to the skeleton.
    final shelvesLoading = [
      recentAlbumsAsync,
      recentAsync,
      playedAsync,
      mostAsync,
    ].any((a) => !a.hasValue && !a.hasError);
    final lovedCount = ref.watch(lovedCountProvider).value ?? 0;
    final quickGenres = ref.watch(homeQuickGenresProvider).value ?? const [];
    final hasTrack = ref.watch(playbackProvider.select((s) => s.hasTrack));
    final flatChrome =
        ref.watch(tabBarStyleProvider).resolved == TabBarStyle.flat;
    final gutter = pageGutterOf(context);
    final safe = MediaQuery.paddingOf(context);
    final actions = ref.read(playerActionsProvider);
    final l10n = context.l10n;

    Widget trackShelfActions(List<TrackRowDto> rows, {Widget? extra}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: l10n.pick('播放全部', 'Play all'),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          padding: EdgeInsets.zero,
          onPressed: rows.isEmpty ? null : () => actions.playRows(rows),
          icon: const Icon(Icons.play_arrow_rounded),
        ),
        IconButton(
          tooltip: l10n.pick('随机播放', 'Shuffle'),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          padding: EdgeInsets.zero,
          onPressed: rows.isEmpty
              ? null
              : () => actions.playRows(rows, shuffle: true),
          icon: const Icon(Icons.shuffle_rounded),
        ),
        ?extra,
      ],
    );

    return Scaffold(
      body: SafeArea(
        // 左右不裁切，使横滑画廊（最近播放 / 最近添加 / 快捷胶囊）直接穿过侧边悬浮玻璃；
        // 静态头部与继续收听卡片显式遵守 safe.left / safe.right，确保所有按钮零遮挡。
        left: false,
        right: false,
        bottom: false,
        child: empty
            ? Padding(
                padding: EdgeInsets.only(left: safe.left, right: safe.right),
                child: LibraryEmptyState(
                  title: l10n.welcomeTitle,
                  message: l10n.welcomeMessage,
                ),
              )
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(recentlyAddedAlbumsProvider);
                  ref.invalidate(recentlyAddedProvider);
                  ref.invalidate(recentlyPlayedProvider);
                  ref.invalidate(mostPlayedProvider);
                  ref.invalidate(lovedCountProvider);
                  ref.invalidate(homeQuickGenresProvider);
                  await ref.read(recentlyAddedAlbumsProvider.future);
                },
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        gutter + safe.left,
                        LekisSpacing.lg,
                        gutter + safe.right,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _HomeHeader(flat: flatChrome),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.only(top: LekisSpacing.md),
                      sliver: SliverToBoxAdapter(
                        child: HomeQuickMixStrip(
                          gutter: gutter,
                          flat: flatChrome,
                          hasTracks: !empty,
                          lovedCount: lovedCount,
                          hasMostPlayed: most.isNotEmpty,
                          genres: quickGenres,
                          onShuffleLibrary: () => actions.playContext(
                            const PlayContextDto.library_(
                              sort: TrackSortDto.title,
                            ),
                            shuffle: true,
                          ),
                          onPlayLoved: () => actions.playContext(
                            const PlayContextDto.loved(),
                            shuffle: true,
                          ),
                          onPlayMostPlayed: () =>
                              actions.playRows(most, shuffle: true),
                          onPlayGenre: (name) => actions.playContext(
                            PlayContextDto.genre(name: name),
                            shuffle: true,
                          ),
                        ),
                      ),
                    ),
                    if (hasTrack)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          gutter + safe.left,
                          LekisSpacing.lg,
                          gutter + safe.right,
                          0,
                        ),
                        sliver: const SliverToBoxAdapter(child: _ResumeHero()),
                      ),
                    SliverToBoxAdapter(
                      child: LekisLoadingSwitcher(
                        loading: shelvesLoading,
                        skeleton: const Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SkeletonShelf(),
                            SkeletonShelf(titleWidth: 120),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (played.isNotEmpty)
                              TrackShelf(
                                title: l10n.recentlyPlayed,
                                tracks: played,
                                trailing: trackShelfActions(
                                  played,
                                  extra: TextButton(
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            const PlaybackHistoryPage(),
                                      ),
                                    ),
                                    child: Text(l10n.seeAll),
                                  ),
                                ),
                              ),
                            if (recentAlbums.isNotEmpty)
                              AlbumShelf(
                                title: l10n.recentlyAdded,
                                albums: recentAlbums,
                              )
                            else if (recent.isNotEmpty)
                              TrackShelf(
                                title: l10n.recentlyAdded,
                                tracks: recent,
                              ),
                            if (most.isNotEmpty)
                              TrackShelf(
                                title: l10n.mostPlayed,
                                tracks: most,
                                trailing: trackShelfActions(most),
                              ),
                          ],
                        ),
                      ),
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
  if (hour < 5) return L10n.tr('夜深了', 'Late Night');
  if (hour < 11) return L10n.tr('早上好', 'Good Morning');
  if (hour < 14) return L10n.tr('中午好', 'Good Afternoon');
  if (hour < 18) return L10n.tr('下午好', 'Good Afternoon');
  return L10n.tr('晚上好', 'Good Evening');
}

/// 首页顶部单行标题栏：
/// 移动端（无侧栏品牌标识时）显示「月亮徽标 + 月兔音乐 / Lekis」；
/// 桌面 / 平板端（侧栏已带品牌标识）直接显示利落的「首页 / Home」，右侧配紧凑听歌统计胶囊，
/// 去掉多余问候语和解释文案，把首屏空间留给音乐本身。
class _HomeHeader extends StatelessWidget {
  const _HomeHeader({this.flat = false});

  final bool flat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = context.l10n;
    final showMark = !ShellChrome.showsBrandMarkOf(context);
    final statsFg = isDark ? colors.moon : colors.accent;
    final titleText = Text(
      showMark ? l10n.brandShort : l10n.navHome,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
    return Semantics(
      header: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showMark) ...[
            const LekisBrandMark(size: 30, glow: true),
            const SizedBox(width: LekisSpacing.sm),
          ],
          Expanded(child: titleText),
          const SizedBox(width: LekisSpacing.sm),
          LekisGlassPill(
            accent: true,
            flat: flat,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ListeningStatsPage(),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LekisSpacing.md,
                vertical: LekisSpacing.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.insights_outlined, size: 18, color: colors.accent),
                  const SizedBox(width: LekisSpacing.xs),
                  Text(
                    l10n.listeningStats,
                    style: theme.textTheme.labelLarge?.copyWith(color: statsFg),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
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
            ? context.l10n.unknownArtist
            : artist == t.title
            ? null
            : artist;
        return ArtworkCardFrame(
          onTap: () =>
              ref.read(playerActionsProvider).playRows(tracks, start: i),
          artwork: TrackArtwork(
            trackId: t.id,
            hasArtwork: t.artworkId != null || !t.isLocal,
            radius: LekisRadius.artworkGrid,
            placeholderLabel: t.title,
          ),
          title: t.title,
          subtitle: subtitle,
          semanticLabel: artist.isEmpty || artist == t.title
              ? context.l10n.pick('播放 ${t.title}', 'Play ${t.title}')
              : context.l10n.pick(
                  '播放 ${t.title}，$artist',
                  'Play ${t.title}, $artist',
                ),
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
              context.l10n.continueListening,
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

/// 首页基于真实资料库数据的快捷电台 / 场景胶囊条。
///
/// 绝不展示写死的虚构分类：仅当用户确有喜欢曲目、常听记录或流派标签时才显示对应胶囊。
class HomeQuickMixStrip extends StatelessWidget {
  const HomeQuickMixStrip({
    super.key,
    required this.gutter,
    this.flat = false,
    required this.hasTracks,
    required this.lovedCount,
    required this.hasMostPlayed,
    required this.genres,
    required this.onShuffleLibrary,
    required this.onPlayLoved,
    required this.onPlayMostPlayed,
    required this.onPlayGenre,
  });

  final double gutter;
  final bool flat;
  final bool hasTracks;
  final int lovedCount;
  final bool hasMostPlayed;
  final List<GenreCountDto> genres;
  final VoidCallback onShuffleLibrary;
  final VoidCallback onPlayLoved;
  final VoidCallback onPlayMostPlayed;
  final ValueChanged<String> onPlayGenre;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = <Widget>[
      if (hasTracks)
        _QuickMixCapsule(
          icon: Icons.shuffle_rounded,
          label: l10n.quickShuffle,
          accent: true,
          flat: flat,
          onTap: onShuffleLibrary,
        ),
      if (lovedCount > 0)
        _QuickMixCapsule(
          icon: Icons.favorite_rounded,
          label: l10n.quickLiked,
          flat: flat,
          onTap: onPlayLoved,
        ),
      if (hasMostPlayed)
        _QuickMixCapsule(
          icon: Icons.local_fire_department_rounded,
          label: l10n.quickMostPlayed,
          flat: flat,
          onTap: onPlayMostPlayed,
        ),
      for (final g in genres)
        if (g.name.trim().isNotEmpty && g.trackCount > 0)
          _QuickMixCapsule(
            icon: Icons.music_note_rounded,
            label: g.name.trim(),
            flat: flat,
            onTap: () => onPlayGenre(g.name),
          ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    final safe = MediaQuery.paddingOf(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.only(
        left: gutter + safe.left,
        right: gutter + safe.right,
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: LekisSpacing.sm),
            items[i],
          ],
        ],
      ),
    );
  }
}

class _QuickMixCapsule extends StatelessWidget {
  const _QuickMixCapsule({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
    this.flat = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fg = accent
        ? (isDark ? colors.moon : colors.accent)
        : theme.colorScheme.onSurface;

    return LekisGlassPill(
      accent: accent,
      flat: flat,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.md,
          vertical: LekisSpacing.sm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: accent ? colors.accent : colors.moon),
            const SizedBox(width: LekisSpacing.xs),
            Text(label, style: theme.textTheme.labelLarge?.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}
