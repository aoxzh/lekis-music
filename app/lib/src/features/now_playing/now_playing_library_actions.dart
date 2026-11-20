// 正在播放里的收藏 / 评分 / 下载 / 添加到歌单。
//
// 只占标题行尾部的几个图标位：喜欢 + 评分（一个星标，显示当前星级，点开
// 评分面板）+ “更多”菜单（下载、添加到歌单）。永远不换行。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/widgets/track_actions.dart';
import 'package:lekis/src/features/now_playing/lyrics_editor_sheet.dart';
import 'package:lekis/src/features/player/player_providers.dart';
import 'package:lekis/src/features/playlists/add_to_playlist_sheet.dart';
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import '../connect/connect_strings.dart';
import '../connect/play_on_device.dart';

const BoxConstraints _touchTarget = BoxConstraints(
  minWidth: LekisSizes.touchTargetMin,
  minHeight: LekisSizes.touchTargetMin,
);

enum _MoreAction { rate, download, addToPlaylist, playOnDevice, editLyrics }

class NowPlayingLibraryActions extends ConsumerWidget {
  const NowPlayingLibraryActions({super.key, this.showRating = true});

  /// `false` on narrow columns: rating moves into the “more” menu so the
  /// title keeps its room.
  final bool showRating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).value;
    if (track == null) return const SizedBox.shrink();
    return Row(
      key: const ValueKey('now-playing.library-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        CompactDownloadProgress(trackId: track.id),
        LovedButton(
          trackId: track.id,
          initialLoved: track.loved,
          size: LekisSpacing.xl,
          compact: false,
        ),
        if (showRating) _RatingButton(track: track),
        _MoreButton(track: track, includeRating: !showRating),
      ],
    );
  }
}

/// One star showing the current rating; opens the 1–5 star sheet.
class _RatingButton extends ConsumerWidget {
  const _RatingButton({required this.track});

  final TrackDto track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    final rating = ratingOf(ref, track.id, track.rating?.toInt()) ?? 0;
    final rated = rating > 0;
    return IconButton(
      key: const ValueKey('now-playing.rating'),
      tooltip: rated ? '评分：$rating 星' : '评分',
      constraints: _touchTarget,
      padding: EdgeInsets.zero,
      onPressed: () =>
          showTrackRatingSheet(context, trackId: track.id, title: track.title),
      icon: rated
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.star_rounded,
                  size: LekisSpacing.lg + LekisSpacing.xs,
                  color: colors.accent,
                ),
                Text(
                  '$rating',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.accent,
                    fontFeatures: LekisText.tabularFigures,
                  ),
                ),
              ],
            )
          : Icon(
              Icons.star_border_rounded,
              size: LekisSpacing.xl,
              color: colors.onSurfaceVariant,
            ),
    );
  }
}

/// Download and add-to-playlist (plus rating on narrow columns).
class _MoreButton extends ConsumerWidget {
  const _MoreButton({required this.track, required this.includeRating});

  final TrackDto track;
  final bool includeRating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lekisColors;
    final downloadState = ref.watch(downloadStateProvider(track.id));
    final rating = ratingOf(ref, track.id, track.rating?.toInt()) ?? 0;
    Widget item(IconData icon, String label) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
    );
    return PopupMenuButton<_MoreAction>(
      key: const ValueKey('now-playing.more'),
      tooltip: '更多操作',
      constraints: const BoxConstraints(
        minWidth: LekisSizes.desktopSidebarWidth * 0.75,
      ),
      icon: Icon(Icons.more_horiz_rounded, color: colors.onSurfaceVariant),
      onSelected: (action) {
        switch (action) {
          case _MoreAction.rate:
            showTrackRatingSheet(
              context,
              trackId: track.id,
              title: track.title,
            );
          case _MoreAction.download:
            runDownloadMenuAction(context, ref, track.id, downloadState);
          case _MoreAction.addToPlaylist:
            showAddToPlaylistSheet(
              context,
              trackId: track.id,
              trackTitle: track.title,
            );
          case _MoreAction.playOnDevice:
            showPlayOnDeviceSheet(context, ref);
          case _MoreAction.editLyrics:
            showLyricsEditor(context, ref, track.id);
        }
      },
      itemBuilder: (_) => [
        if (includeRating)
          PopupMenuItem(
            value: _MoreAction.rate,
            child: item(
              rating > 0 ? Icons.star_rounded : Icons.star_outline_rounded,
              rating > 0 ? '评分（$rating 星）' : '评分',
            ),
          ),
        PopupMenuItem(
          value: _MoreAction.download,
          child: item(switch (downloadState) {
            null => Icons.download_for_offline_outlined,
            OfflineStateDto.ready => Icons.delete_outline_rounded,
            OfflineStateDto.failed => Icons.refresh_rounded,
            OfflineStateDto.downloading => Icons.close_rounded,
            OfflineStateDto.queued => Icons.download_rounded,
          }, downloadMenuLabel(downloadState)),
        ),
        PopupMenuItem(
          value: _MoreAction.addToPlaylist,
          child: item(Icons.playlist_add_rounded, '添加到歌单'),
        ),
        PopupMenuItem(
          value: _MoreAction.playOnDevice,
          child: item(Icons.cast_rounded, ConnectStrings.playHere),
        ),
        // Editors live in the menu, not as a floating button over the lyrics
        // (iOS 26 puts them with the rest of the lyric controls).
        PopupMenuItem(
          value: _MoreAction.editLyrics,
          child: item(Icons.edit_note_rounded, '编辑歌词'),
        ),
      ],
    );
  }
}
