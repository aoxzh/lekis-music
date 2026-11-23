// "喜欢的歌曲" 视图：直接读核心的 loved_tracks，不建虚拟歌单。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/album_detail_page.dart'
    show PlayShuffleButtons;
import 'package:lekis/src/features/library/library_providers.dart';
import 'package:lekis/src/features/library/widgets/page_gutter.dart';
import 'package:lekis/src/features/library/widgets/paged_track_list.dart';
import 'package:lekis/src/features/playlists/playlist_actions.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/rust/api/dto.dart';
import 'package:lekis/src/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

class LikedSongsView extends ConsumerWidget {
  const LikedSongsView({super.key});

  Future<void> _playAll(BuildContext context, {bool shuffle = false}) async {
    try {
      if (shuffle) {
        core.setShuffle(mode: ShuffleModeDto.random);
      }
      await core.playContext(
        context: const PlayContextDto.loved(),
        startIndex: 0,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.pick('播放失败：$e', 'Playback failed: $e')),
        ),
      );
    }
  }

  Future<void> _saveAllAsPlaylist(
    BuildContext context,
    WidgetRef ref,
    int total,
  ) async {
    if (total == 0) return;
    final progress = ValueNotifier<int>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Text(context.l10n.pick('正在收集喜欢的歌曲', 'Collecting Liked Songs')),
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: total <= 0 ? 0 : (done / total).clamp(0.0, 1.0),
                ),
                const SizedBox(height: LekisSpacing.md),
                Text('$done / $total'),
              ],
            ),
          ),
        ),
      ),
    );

    final rows = <TrackRowDto>[];
    try {
      var offset = 0;
      while (offset < total) {
        final page = await core.lovedTracks(
          offset: offset,
          limit: math.min(500, total - offset),
        );
        if (page.isEmpty) break;
        rows.addAll(page);
        offset += page.length;
        progress.value = math.min(offset, total);
        if (page.length < 500) break;
      }
      if (navigator.mounted && navigator.canPop()) navigator.pop();
      progress.dispose();
      if (!context.mounted) return;
      final stamp = DateTime.now()
          .toString()
          .substring(0, 16)
          .replaceAll('T', ' ');
      await saveTracksAsPlaylistFlow(
        context,
        ref,
        rows,
        suggestedName: '${context.l10n.pick('喜欢的歌曲', 'Liked Songs')} $stamp',
      );
    } catch (e) {
      if (navigator.mounted && navigator.canPop()) navigator.pop();
      progress.dispose();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.pick('保存失败：$e', 'Save failed: $e')),
          ),
        );
    }
  }

  Future<void> _downloadAll(
    BuildContext context,
    WidgetRef ref,
    int total,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.pick('下载喜欢的歌曲？', 'Download Liked Songs?')),
        content: Text(
          context.l10n.pick(
            '将把 $total 首喜欢的歌曲加入下载队列，已在本机的曲目会跳过。',
            'This queues the $total liked songs for download, skipping tracks already on this device.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(context.l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(context.l10n.pick('下载', 'Download')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final progress = ValueNotifier<int>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: Text(context.l10n.pick('正在准备下载', 'Preparing Downloads')),
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: total <= 0 ? 0 : (done / total).clamp(0.0, 1.0),
                ),
                const SizedBox(height: LekisSpacing.md),
                Text('$done / $total'),
              ],
            ),
          ),
        ),
      ),
    );

    final ids = <int>[];
    try {
      var offset = 0;
      while (offset < total) {
        final page = await core.lovedTracks(
          offset: offset,
          limit: math.min(500, total - offset),
        );
        if (page.isEmpty) break;
        for (final track in page) {
          if (!track.isLocal) ids.add(track.id);
        }
        offset += page.length;
        progress.value = math.min(offset, total);
        if (page.length < 500) break;
      }
      final accepted = ids.isEmpty
          ? 0
          : await ref.read(downloadsProvider.notifier).downloadTracks(ids);
      if (navigator.mounted && navigator.canPop()) navigator.pop();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              ids.isEmpty
                  ? context.l10n.pick(
                      '没有可下载的曲目',
                      'No tracks available to download',
                    )
                  : context.l10n.pick(
                      '已加入 $accepted 首到下载队列',
                      'Queued $accepted tracks for download',
                    ),
            ),
          ),
        );
    } catch (e) {
      if (navigator.mounted && navigator.canPop()) navigator.pop();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.pick('下载失败：$e', 'Download failed: $e')),
          ),
        );
    } finally {
      progress.dispose();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final gutter = pageGutterOf(context);
    final count = ref.watch(lovedCountProvider).value;
    final list = ref.watch(likedTracksListProvider);

    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        LekisSpacing.md,
        gutter,
        LekisSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_rounded, color: colors.accent),
              const SizedBox(width: LekisSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        context.l10n.pick('喜欢的歌曲', 'Liked Songs'),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      count == null
                          ? context.l10n.pick('正在统计…', 'Counting…')
                          : context.l10n.pick('$count 首', '$count songs'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: LekisSpacing.md),
          PlayShuffleButtons(
            alignment: WrapAlignment.start,
            onPlay: count == 0 ? null : () => _playAll(context),
            onShuffle: count == 0
                ? null
                : () => _playAll(context, shuffle: true),
            trailing: [
              IconButton(
                tooltip: context.l10n.pick('保存为歌单', 'Save as Playlist'),
                onPressed: count == null || count == 0
                    ? null
                    : () => _saveAllAsPlaylist(context, ref, count),
                icon: const Icon(Icons.playlist_add_rounded),
              ),
              IconButton(
                tooltip: context.l10n.pick('下载全部', 'Download All'),
                onPressed: count == null || count == 0
                    ? null
                    : () => _downloadAll(context, ref, count),
                icon: const Icon(Icons.download_for_offline_outlined),
              ),
            ],
          ),
        ],
      ),
    );

    return PagedTrackList(
      list: list,
      header: header,
      empty: const _EmptyLiked(),
    );
  }
}

class _EmptyLiked extends StatelessWidget {
  const _EmptyLiked();

  @override
  Widget build(BuildContext context) {
    final colors = context.lekisColors;
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.favorite_border_rounded,
            size: LekisSpacing.xxxl,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(height: LekisSpacing.sm),
          Text(
            context.l10n.pick('还没有喜欢的歌曲', 'No Liked Songs Yet'),
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: LekisSpacing.xxs),
          Text(
            context.l10n.pick(
              '在歌曲行或正在播放里点一下心形',
              'Tap the heart on any song or in Now Playing',
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
