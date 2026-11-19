import 'dart:ui' show ImageFilter;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/home/home_providers.dart';
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/album_card.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/shelf.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/player/widgets/current_track.dart';
import 'package:lekis/src/features/player/widgets/player_controls.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/shell/routes.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Home: continue listening, recently added, most played.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final empty = ref.watch(libraryIsEmptyProvider).value ?? false;
    final recent = ref.watch(recentlyAddedProvider).value ?? const [];
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
                  ref.invalidate(recentlyAddedProvider);
                  ref.invalidate(mostPlayedProvider);
                  await ref.read(recentlyAddedProvider.future);
                },
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        LekisSpacing.xl,
                        gutter,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Semantics(
                          header: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'LEKIS · 本地资料库',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: context.lekisColors.moon,
                                      letterSpacing: 1.6,
                                    ),
                              ),
                              const SizedBox(height: LekisSpacing.xs),
                              Text(
                                _greeting(),
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontSize: 34, height: 1.1),
                              ),
                              const SizedBox(height: LekisSpacing.xs),
                              Text(
                                '继续上次的，或从资料库里挑一张。',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color:
                                          context.lekisColors.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (hasTrack)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          gutter,
                          LekisSpacing.xl,
                          gutter,
                          0,
                        ),
                        sliver: const SliverToBoxAdapter(child: _ResumeHero()),
                      ),
                    if (recent.isNotEmpty)
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

String _greeting() {
  final hour = DateTime.now().hour;
  if (hour < 5) return '夜深了';
  if (hour < 11) return '早上好';
  if (hour < 14) return '中午好';
  if (hour < 18) return '下午好';
  return '晚上好';
}

/// Horizontal shelf of track cards; tapping plays the shelf from that card.
class TrackShelf extends ConsumerWidget {
  const TrackShelf({super.key, required this.title, required this.tracks});

  final String title;
  final List<TrackRowDto> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ArtworkShelf(
      title: title,
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        final artist = t.artistLine.trim();
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
          subtitle: artist.isEmpty || artist == t.title ? null : artist,
          semanticLabel: artist.isEmpty || artist == t.title
              ? '播放 ${t.title}'
              : '播放 ${t.title}，$artist',
        );
      },
    );
  }
}

/// The current track as a full-width, artwork-tinted resume card.
class _ResumeHero extends ConsumerWidget {
  const _ResumeHero();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).value;
    if (track == null) return const SizedBox.shrink();

    final palette = ref.watch(currentArtworkProvider).value?.palette;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
        final compact = constraints.maxWidth < 560;
        final artSize = compact ? 96.0 : 136.0;
        return ClipRRect(
          borderRadius: BorderRadius.circular(LekisRadius.xl),
          child: SizedBox(
            height: compact ? 168 : 200,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                  child: Transform.scale(
                    scale: 1.3,
                    child: const CurrentArtwork(radius: 0),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        scheme.surface.withValues(alpha: 0.92),
                        tint.withValues(alpha: 0.38),
                        scheme.surface.withValues(alpha: 0.86),
                      ],
                      stops: const [0, 0.62, 1],
                    ),
                  ),
                ),
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: () => openNowPlaying(context),
                    child: Padding(
                      padding: EdgeInsets.all(
                        compact ? LekisSpacing.lg : LekisSpacing.xl,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '继续收听',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: context.lekisColors.moon,
                                    letterSpacing: 1.4,
                                  ),
                                ),
                                const SizedBox(height: LekisSpacing.sm),
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontSize: compact ? 22 : 26,
                                  ),
                                ),
                                if (subtitle.isNotEmpty) ...[
                                  const SizedBox(height: LekisSpacing.xxs),
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color:
                                          context.lekisColors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                                const Spacer(),
                                Row(
                                  children: [
                                    const PlayPauseButton(
                                      filled: true,
                                      size: 28,
                                    ),
                                    const SizedBox(width: LekisSpacing.sm),
                                    Text(
                                      '从上次停下的地方继续',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: context
                                                .lekisColors
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: LekisSpacing.lg),
                          SizedBox.square(
                            dimension: artSize,
                            child: CurrentArtwork(
                              radius: LekisRadius.artworkGrid,
                            ),
                          ),
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
