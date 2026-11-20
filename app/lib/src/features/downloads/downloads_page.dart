// 下载页：下载队列、已完成、失败和缓存总大小。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/downloads/downloads_models.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/rust/api/core.dart' as core;
import 'package:lekis/src/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

class DownloadsPage extends ConsumerWidget {
  const DownloadsPage({super.key});

  Future<List<int>> _lovedIds() async {
    final ids = <int>[];
    var offset = 0;
    while (ids.length < 2000) {
      final page = await core.lovedTracks(offset: offset, limit: 200);
      ids.addAll(page.map((track) => track.id));
      if (page.length < 200) break;
      offset += 200;
    }
    return ids;
  }

  Future<void> _downloadLoved(BuildContext context, WidgetRef ref) async {
    final ids = await _lovedIds();
    if (!context.mounted) return;
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('还没有收藏的歌曲')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载收藏'),
        content: Text('把 ${ids.length} 首收藏歌曲加入离线队列？已下载的会跳过。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('加入下载'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await startDownloads(context, ref, ids);
    }
  }

  Future<void> _downloadMostPlayed(BuildContext context, WidgetRef ref) async {
    final tracks = await core.mostPlayed(limit: 50);
    final ids = tracks.map((track) => track.id).toList(growable: false);
    if (!context.mounted) return;
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('还没有播放记录')));
      return;
    }
    await startDownloads(context, ref, ids);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(downloadsProvider);
    return SettingsScaffold(
      title: '下载',
      actions: [
        PopupMenuButton<String>(
          tooltip: '批量下载',
          onSelected: (value) {
            switch (value) {
              case 'loved':
                _downloadLoved(context, ref);
              case 'most-played':
                _downloadMostPlayed(context, ref);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'loved',
              child: ListTile(
                leading: Icon(Icons.favorite_outline),
                title: Text('下载收藏'),
              ),
            ),
            PopupMenuItem(
              value: 'most-played',
              child: ListTile(
                leading: Icon(Icons.trending_up_rounded),
                title: Text('下载最常听 50 首'),
              ),
            ),
          ],
        ),
        IconButton(
          tooltip: '刷新',
          onPressed: () => ref.read(downloadsProvider.notifier).refresh(),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: switch (async) {
        AsyncData(:final value) => _DownloadsBody(state: value),
        AsyncError(:final error) => LoadErrorView(
          error: error,
          onRetry: () => ref.read(downloadsProvider.notifier).refresh(),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// 封面行的分隔线起点：与封面右侧的文字对齐。
const double _artworkTextInset =
    LekisSpacing.lg + LekisSizes.listArtwork + LekisSpacing.md;

class _DownloadsBody extends ConsumerWidget {
  const _DownloadsBody({required this.state});

  final DownloadsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => ref.read(downloadsProvider.notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(
              height: 420,
              child: LekisEmptyState(
                eyebrow: '离线',
                title: '还没有下载',
                message: '在歌曲、专辑或正在播放里点下载，音乐就会保存到本机，断网也能听。',
              ),
            ),
          ],
        ),
      );
    }

    Widget section(String title, List<DownloadEntry> entries) =>
        SettingsSliverSection(
          title: title,
          itemCount: entries.length,
          dividerIndent: _artworkTextInset,
          itemBuilder: (_, i) => _DownloadTile(
            key: ValueKey(entries[i].trackId),
            entry: entries[i],
          ),
        );

    return RefreshIndicator(
      onRefresh: () => ref.read(downloadsProvider.notifier).refresh(),
      child: SettingsScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _SummaryCard(state: state)),
          if (state.active.isNotEmpty) section('下载队列', state.active),
          if (state.failed.isNotEmpty) section('失败', state.failed),
          if (state.ready.isNotEmpty) section('已下载', state.ready),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.state});

  final DownloadsState state;

  @override
  Widget build(BuildContext context) {
    final active = state.active.where((e) => e.isActive).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: LekisSpacing.xl),
      child: SettingsGroup(
        children: [
          SettingsTile(
            icon: Icons.offline_pin_outlined,
            title: '已下载 ${state.readyCount} 首',
            subtitle: Text(
              '共 ${formatBytes(state.totalBytes)}'
              '${active > 0 ? ' · $active 首正在下载' : ''}',
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadTile extends ConsumerWidget {
  const _DownloadTile({super.key, required this.entry});

  final DownloadEntry entry;

  Future<bool> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除下载？'),
        content: Text('“${entry.title}”的缓存文件会被删除，之后需要重新下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    if (!await _confirmRemove(context)) return;
    try {
      await ref.read(downloadsProvider.notifier).removeDownload(entry.trackId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('删除下载失败：${describeCoreError(e)}')),
          );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final track = entry.track;
    final actions = <Widget>[
      if (entry.isReady || entry.isActive)
        IconButton(
          tooltip: entry.isActive ? '取消下载' : '播放已下载',
          onPressed: entry.isActive
              ? () => ref
                    .read(downloadsProvider.notifier)
                    .removeDownload(entry.trackId)
              : () => ref
                    .read(downloadsProvider.notifier)
                    .playDownloaded(entry.trackId),
          icon: Icon(
            entry.isActive ? Icons.close_rounded : Icons.play_arrow_rounded,
          ),
        ),
      if (entry.isFailed || entry.isQueued)
        IconButton(
          tooltip: entry.isQueued ? '开始下载' : '重试',
          onPressed: () =>
              ref.read(downloadsProvider.notifier).retry(entry.trackId),
          icon: const Icon(Icons.refresh_rounded),
        ),
      if (!entry.isActive)
        IconButton(
          tooltip: '删除下载',
          onPressed: () => _remove(context, ref),
          icon: const Icon(Icons.delete_outline_rounded),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: LekisSpacing.lg,
        vertical: LekisSpacing.sm,
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: LekisSizes.listArtwork,
            child: track == null
                ? Icon(Icons.music_note_rounded, color: colors.onSurfaceVariant)
                : TrackArtwork(
                    trackId: track.id,
                    hasArtwork: track.artworkId != null,
                    placeholderLabel: track.title,
                  ),
          ),
          const SizedBox(width: LekisSpacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: entry.isReady
                        ? FontWeight.w500
                        : FontWeight.w600,
                  ),
                ),
                if (entry.subtitle.isNotEmpty)
                  Text(
                    entry.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                Text(
                  entry.statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: entry.isFailed
                        ? colors.danger
                        : colors.onSurfaceVariant,
                  ),
                ),
                if (entry.isActive) ...[
                  const SizedBox(height: LekisSpacing.xs),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(LekisRadius.pill),
                    child: LinearProgressIndicator(
                      value: entry.progress,
                      minHeight: LekisSpacing.xxs,
                      color: colors.accent,
                      backgroundColor: colors.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: LekisSpacing.sm),
            // 最后一个按钮的图标与面板右侧的文字边距对齐。
            Transform.translate(
              offset: const Offset(LekisSpacing.md, 0),
              child: IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    foregroundColor: colors.onSurfaceVariant,
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: actions),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
