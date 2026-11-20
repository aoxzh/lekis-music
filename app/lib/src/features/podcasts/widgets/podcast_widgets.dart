// 播客列表行和小部件：封面、节目行、单集行、格式化工具。

import 'package:lekis/src/features/podcasts/podcast_providers.dart';
import 'package:lekis/src/features/podcasts/podcast_strings.dart';
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

/// 网络封面；没有地址或加载失败时显示占位。
class PodcastArtwork extends StatelessWidget {
  const PodcastArtwork({
    super.key,
    required this.url,
    this.size = LekisSizes.listArtwork,
    this.radius = LekisRadius.artworkList,
    this.playing = false,
  });

  final String? url;
  final double size;
  final double radius;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(
          playing ? Icons.graphic_eq_rounded : Icons.podcasts_rounded,
          size: size * 0.45,
          color: playing ? colors.accent : colors.onSurfaceVariant,
        ),
      ),
    );
    final src = url;
    if (src == null || src.isEmpty) return fallback;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          src,
          fit: BoxFit.cover,
          cacheWidth: (size * dpr).round(),
          errorBuilder: (_, _, _) => fallback,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : fallback,
        ),
      ),
    );
  }
}

/// 目录（搜索 / 排行榜）里的一档节目。
class DirectoryPodcastTile extends StatelessWidget {
  const DirectoryPodcastTile({
    super.key,
    required this.podcast,
    required this.onTap,
    this.rank,
  });

  final DirectoryPodcastDto podcast;
  final VoidCallback onTap;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final meta = [
      if (podcast.author?.isNotEmpty == true) podcast.author!,
      if (podcast.genre?.isNotEmpty == true) podcast.genre!,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
        minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.lg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LekisRadius.md),
        ),
        onTap: onTap,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (rank != null)
              SizedBox(
                width: 28,
                child: Text(
                  '$rank',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: rank! <= 3 ? colors.accent : colors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            PodcastArtwork(url: podcast.artworkUrl),
          ],
        ),
        title: Text(
          podcast.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        subtitle: meta.isEmpty
            ? null
            : Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: podcast.subscribed
            ? Icon(
                Icons.check_circle_rounded,
                color: colors.accent,
                semanticLabel: PodcastStrings.subscribed,
              )
            : Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
      ),
    );
  }
}

/// 订阅列表里的一档节目。
class SubscribedPodcastTile extends StatelessWidget {
  const SubscribedPodcastTile({
    super.key,
    required this.podcast,
    required this.onTap,
  });

  final PodcastDto podcast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final bits = <String>[
      if (podcast.author?.isNotEmpty == true) podcast.author!,
      if (podcast.latestPublishedAt != null)
        formatEpisodeDate(podcast.latestPublishedAt!),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
        minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.lg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LekisRadius.md),
        ),
        onTap: onTap,
        leading: PodcastArtwork(url: podcast.artworkUrl),
        title: Text(
          podcast.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        subtitle: Text(
          podcast.lastError != null
              ? PodcastStrings.lastError(podcast.lastError!)
              : bits.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: podcast.lastError != null
              ? TextStyle(color: theme.colorScheme.error)
              : null,
        ),
        trailing: podcast.unplayedCount > 0
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.accentSoft,
                  borderRadius: BorderRadius.circular(LekisRadius.pill),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LekisSpacing.sm,
                    vertical: 2,
                  ),
                  child: Text(
                    '${podcast.unplayedCount}',
                    semanticsLabel: PodcastStrings.unplayedCount(
                      podcast.unplayedCount,
                    ),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// 一集。
class PodcastEpisodeTile extends StatelessWidget {
  const PodcastEpisodeTile({
    super.key,
    required this.episode,
    required this.playing,
    required this.onPlay,
    required this.onTogglePlayed,
    this.showPodcastTitle = false,
    this.showArtwork = true,
  });

  final PodcastEpisodeDto episode;
  final bool playing;
  final VoidCallback onPlay;
  final VoidCallback onTogglePlayed;
  final bool showPodcastTitle;
  final bool showArtwork;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final muted = episode.played && !playing;
    final meta = <String>[
      if (showPodcastTitle) episode.podcastTitle,
      if (episode.publishedAt != null) formatEpisodeDate(episode.publishedAt!),
      if (episode.durationMs > BigInt.zero)
        formatEpisodeDuration(episode.durationMs.toInt()),
    ].join(' · ');
    final duration = episode.durationMs.toInt();
    final position = episode.positionMs.toInt();
    final inProgress = !episode.played && position > 0;
    final progress = inProgress && duration > 0
        ? (position / duration).clamp(0.0, 1.0)
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: LekisSpacing.sm),
        minTileHeight: LekisSizes.touchTargetMin + LekisSpacing.lg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LekisRadius.md),
        ),
        selected: playing,
        selectedTileColor: colors.accentSoft,
        onTap: onPlay,
        leading: showArtwork
            ? PodcastArtwork(url: episode.artworkUrl, playing: playing)
            : null,
        title: Text(
          episode.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: playing ? FontWeight.w600 : FontWeight.w500,
            color: muted ? colors.onSurfaceVariant : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (meta.isNotEmpty)
              Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (episode.played)
              Text(
                PodcastStrings.played,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              )
            else if (inProgress)
              Padding(
                padding: const EdgeInsets.only(top: LekisSpacing.xs),
                child: Row(
                  children: [
                    if (progress != null)
                      SizedBox(
                        width: 72,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    const SizedBox(width: LekisSpacing.sm),
                    Flexible(
                      child: Text(
                        duration > 0
                            ? '剩余 ${formatEpisodeDuration(duration - position)}'
                            : '听到 ${formatEpisodeDuration(position)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          tooltip: PodcastStrings.more,
          onSelected: (value) {
            if (value == 'played') onTogglePlayed();
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'played',
              child: Text(
                episode.played
                    ? PodcastStrings.markUnplayed
                    : PodcastStrings.markPlayed,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 发布日期：今天 / 昨天 / N 天前 / 年-月-日。
String formatEpisodeDate(int ms, {DateTime? now}) {
  final date = DateTime.fromMillisecondsSinceEpoch(ms);
  final today = now ?? DateTime.now();
  final d0 = DateTime(today.year, today.month, today.day);
  final d1 = DateTime(date.year, date.month, date.day);
  final days = d0.difference(d1).inDays;
  if (days == 0) return '今天';
  if (days == 1) return '昨天';
  if (days > 1 && days < 7) return '$days 天前';
  final mm = date.month.toString().padLeft(2, '0');
  final dd = date.day.toString().padLeft(2, '0');
  if (date.year == today.year) return '$mm-$dd';
  return '${date.year}-$mm-$dd';
}

/// 时长：`1 小时 5 分`、`45 分钟`、`30 秒`。
String formatEpisodeDuration(int ms) {
  final totalMinutes = (ms / 60000).round();
  if (ms < 60000) return '${(ms / 1000).round()} 秒';
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) return '$minutes 分钟';
  if (minutes == 0) return '$hours 小时';
  return '$hours 小时 $minutes 分';
}
