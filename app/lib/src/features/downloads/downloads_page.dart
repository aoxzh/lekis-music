// 下载页：下载队列、已完成、失败和缓存总大小。

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lekis/src/features/downloads/download_status.dart';
import 'package:lekis/src/features/downloads/downloads_models.dart';
import 'package:lekis/src/features/downloads/downloads_providers.dart';
import 'package:lekis/src/features/library/album_detail_page.dart';
import 'package:lekis/src/features/library/artist_detail_page.dart';
import 'package:lekis/src/features/library/library_actions.dart';
import 'package:lekis/src/features/library/library_providers.dart'
    show artistIdForNameProvider;
import 'package:lekis/src/features/library/widgets/artwork.dart';
import 'package:lekis/src/features/library/widgets/empty_state.dart';
import 'package:lekis/src/features/settings/widgets/settings_widgets.dart';
import 'package:lekis/src/l10n/app_l10n.dart';
import 'package:lekis/src/platform/reveal_file.dart';
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
    final l10n = context.l10n;
    final ids = await _lovedIds();
    if (!context.mounted) return;
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(l10n.pick('还没有收藏的歌曲', 'No liked songs yet'))),
        );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.pick('下载收藏', 'Download Liked')),
        content: Text(
          l10n.pick(
            '把 ${ids.length} 首收藏歌曲加入离线队列？已下载的会跳过。',
            'Queue ${ids.length} liked songs for offline? Already downloaded ones will be skipped.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.pick('加入下载', 'Download')),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await startDownloads(context, ref, ids);
    }
  }

  Future<void> _downloadMostPlayed(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final tracks = await core.mostPlayed(limit: 50);
    final ids = tracks.map((track) => track.id).toList(growable: false);
    if (!context.mounted) return;
    if (ids.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.pick('还没有播放记录', 'No playback history yet')),
          ),
        );
      return;
    }
    await startDownloads(context, ref, ids);
  }

  Future<void> _retryFailed(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final count = ref.read(downloadsProvider).value?.failed.length ?? 0;
    if (count == 0) return;
    try {
      final retried = await ref.read(downloadsProvider.notifier).retryFailed();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              l10n.pick('已重新加入 $retried 个下载', 'Re-queued $retried downloads'),
            ),
          ),
        );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              l10n.pick('重试下载失败：$e', 'Failed to retry downloads: $e'),
            ),
          ),
        );
    }
  }

  Future<void> _clearCompleted(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final count = ref.read(downloadsProvider).value?.ready.length ?? 0;
    if (count == 0) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(l10n.pick('没有已完成的下载', 'No completed downloads')),
          ),
        );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pick('清理已完成的下载？', 'Clear completed downloads?')),
        content: Text(
          l10n.pick(
            '会删除 $count 个离线文件，之后可以重新下载。',
            'This removes $count offline files; you can download them again later.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.pick('清理', 'Clear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final removed = await ref
          .read(downloadsProvider.notifier)
          .clearCompleted();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              l10n.pick('已清理 $removed 个下载', 'Cleared $removed downloads'),
            ),
          ),
        );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              l10n.pick('清理下载失败：$e', 'Failed to clear downloads: $e'),
            ),
          ),
        );
    }
  }

  Future<void> _clearFailed(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final count = ref.read(downloadsProvider).value?.failed.length ?? 0;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pick('清理失败下载？', 'Clear failed downloads?')),
        content: Text(
          l10n.pick(
            '会移除 $count 条失败记录，不会删除已完成的离线文件。',
            'This removes $count failed records; completed offline files stay.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.pick('清理', 'Clear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final removed = await ref.read(downloadsProvider.notifier).clearFailed();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              l10n.pick(
                '已清理 $removed 条失败记录',
                'Cleared $removed failed records',
              ),
            ),
          ),
        );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              l10n.pick('清理失败记录失败：$e', 'Failed to clear failed records: $e'),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(downloadsProvider);
    final hasCompleted = async.value?.ready.isNotEmpty ?? false;
    final hasFailed = async.value?.failed.isNotEmpty ?? false;
    return SettingsScaffold(
      title: l10n.pick('下载', 'Downloads'),
      actions: [
        PopupMenuButton<String>(
          tooltip: l10n.pick('批量下载', 'Batch Download'),
          onSelected: (value) {
            switch (value) {
              case 'loved':
                _downloadLoved(context, ref);
              case 'most-played':
                _downloadMostPlayed(context, ref);
              case 'clear-completed':
                _clearCompleted(context, ref);
              case 'play-downloaded':
                ref.read(downloadsProvider.notifier).playAllReady();
              case 'shuffle-downloaded':
                ref
                    .read(downloadsProvider.notifier)
                    .playAllReady(shuffle: true);
              case 'retry-failed':
                _retryFailed(context, ref);
              case 'clear-failed':
                _clearFailed(context, ref);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'loved',
              child: ListTile(
                leading: const Icon(Icons.favorite_outline),
                title: Text(l10n.pick('下载收藏', 'Download Liked')),
              ),
            ),
            PopupMenuItem(
              value: 'most-played',
              child: ListTile(
                leading: const Icon(Icons.trending_up_rounded),
                title: Text(l10n.pick('下载最常听 50 首', 'Download Top 50')),
              ),
            ),
            if (hasCompleted)
              PopupMenuItem(
                value: 'play-downloaded',
                child: ListTile(
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: Text(l10n.pick('播放已下载', 'Play Downloaded')),
                ),
              ),
            if (hasCompleted)
              PopupMenuItem(
                value: 'shuffle-downloaded',
                child: ListTile(
                  leading: const Icon(Icons.shuffle_rounded),
                  title: Text(l10n.pick('随机播放已下载', 'Shuffle Downloaded')),
                ),
              ),
            if (hasCompleted)
              PopupMenuItem(
                value: 'clear-completed',
                child: ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: Text(
                    l10n.pick('清理已完成的下载', 'Clear Completed Downloads'),
                  ),
                ),
              ),
            if (hasFailed)
              PopupMenuItem(
                value: 'retry-failed',
                child: ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: Text(l10n.pick('重试全部失败下载', 'Retry All Failed')),
                ),
              ),
            if (hasFailed)
              PopupMenuItem(
                value: 'clear-failed',
                child: ListTile(
                  leading: const Icon(Icons.error_outline_rounded),
                  title: Text(l10n.pick('清理失败记录', 'Clear Failed Downloads')),
                ),
              ),
          ],
        ),
        IconButton(
          tooltip: l10n.pick('刷新', 'Refresh'),
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

enum _DownloadFilter { all, active, failed, ready }

class _DownloadsBody extends ConsumerStatefulWidget {
  const _DownloadsBody({required this.state});

  final DownloadsState state;

  @override
  ConsumerState<_DownloadsBody> createState() => _DownloadsBodyState();
}

class _DownloadsBodyState extends ConsumerState<_DownloadsBody> {
  _DownloadFilter _filter = _DownloadFilter.all;
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = widget.state;
    if (state.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => ref.read(downloadsProvider.notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 420,
              child: LekisEmptyState(
                eyebrow: l10n.pick('离线', 'Offline'),
                title: l10n.pick('还没有下载', 'No Downloads Yet'),
                message: l10n.pick(
                  '在歌曲、专辑或正在播放里点下载，音乐就会保存到本机，断网也能听。',
                  'Tap download on a song, album, or Now Playing to save music for offline listening.',
                ),
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

    final query = _query.trim().toLowerCase();
    bool matches(DownloadEntry entry) =>
        query.isEmpty ||
        entry.title.toLowerCase().contains(query) ||
        entry.subtitle.toLowerCase().contains(query);
    final active = state.active.where(matches).toList(growable: false);
    final failed = state.failed.where(matches).toList(growable: false);
    final ready = state.ready.where(matches).toList(growable: false);
    final matchCount = active.length + failed.length + ready.length;

    final showAll = _filter == _DownloadFilter.all;
    final showActive = showAll || _filter == _DownloadFilter.active;
    final showFailed = showAll || _filter == _DownloadFilter.failed;
    final showReady = showAll || _filter == _DownloadFilter.ready;
    final anythingVisible =
        (showActive && active.isNotEmpty) ||
        (showFailed && failed.isNotEmpty) ||
        (showReady && ready.isNotEmpty);

    Widget chip(String label, _DownloadFilter value, int count) => ChoiceChip(
      label: Text('$label $count'),
      selected: _filter == value,
      onSelected: (_) => setState(() => _filter = value),
    );

    return RefreshIndicator(
      onRefresh: () => ref.read(downloadsProvider.notifier).refresh(),
      child: SettingsScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _SummaryCard(state: state)),
          if (state.entries.length >= 8)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  LekisSpacing.xl,
                  0,
                  LekisSpacing.xl,
                  LekisSpacing.sm,
                ),
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    hintText: l10n.pick('搜索下载', 'Search downloads'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: l10n.pick('清除', 'Clear'),
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                    isDense: true,
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(LekisRadius.pill),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                LekisSpacing.xl,
                0,
                LekisSpacing.xl,
                LekisSpacing.md,
              ),
              child: Wrap(
                spacing: LekisSpacing.sm,
                runSpacing: LekisSpacing.xs,
                children: [
                  chip(l10n.pick('全部', 'All'), _DownloadFilter.all, matchCount),
                  if (active.isNotEmpty)
                    chip(
                      l10n.pick('队列', 'Queue'),
                      _DownloadFilter.active,
                      active.length,
                    ),
                  if (failed.isNotEmpty)
                    chip(
                      l10n.pick('失败', 'Failed'),
                      _DownloadFilter.failed,
                      failed.length,
                    ),
                  if (ready.isNotEmpty)
                    chip(
                      l10n.pick('已下载', 'Downloaded'),
                      _DownloadFilter.ready,
                      ready.length,
                    ),
                ],
              ),
            ),
          ),
          if (showActive && active.isNotEmpty)
            section(l10n.pick('下载队列', 'Queue'), active),
          if (showFailed && failed.isNotEmpty)
            section(l10n.pick('失败', 'Failed'), failed),
          if (showReady && ready.isNotEmpty)
            section(l10n.pick('已下载', 'Downloaded'), ready),
          if (!anythingVisible)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(LekisSpacing.xl),
                child: Text(
                  l10n.pick(
                    query.isEmpty ? '这个分类暂时没有下载' : '没有匹配的下载',
                    query.isEmpty
                        ? 'Nothing in this filter'
                        : 'No matching downloads',
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
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
    final l10n = context.l10n;
    final active = state.active.where((e) => e.isActive).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: LekisSpacing.xl),
      child: SettingsGroup(
        children: [
          SettingsTile(
            icon: Icons.offline_pin_outlined,
            title: l10n.pick(
              '已下载 ${state.readyCount} 首',
              '${state.readyCount} Downloaded',
            ),
            subtitle: Text(
              l10n.pick(
                '共 ${formatBytes(state.totalBytes)}'
                    '${active > 0 ? ' · $active 首正在下载' : ''}',
                '${formatBytes(state.totalBytes)} total'
                    '${active > 0 ? ' · $active downloading' : ''}',
              ),
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
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.pick('删除下载？', 'Remove Download?')),
        content: Text(
          l10n.pick(
            '“${entry.title}”的缓存文件会被删除，之后需要重新下载。',
            'The cached file for "${entry.title}" will be deleted and will need to be downloaded again.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.pick('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.pick('删除', 'Remove')),
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
            SnackBar(
              content: Text(
                context.l10n.pick(
                  '删除下载失败：${describeCoreError(e)}',
                  'Failed to remove download: ${describeCoreError(e)}',
                ),
              ),
            ),
          );
      }
    }
  }

  Future<void> _copyPath(BuildContext context) async {
    final path = entry.download.cachePath;
    if (path.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: path));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(context.l10n.pick('已复制文件路径', 'File path copied')),
          ),
        );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.pick('复制路径失败：$e', 'Failed to copy path: $e'),
            ),
          ),
        );
    }
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final track = entry.track;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.download.cachePath.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: Text(l10n.pick('复制文件路径', 'Copy File Path')),
                onTap: () => Navigator.of(sheet).pop('copy-path'),
              ),
            if (entry.download.cachePath.isNotEmpty && canRevealFiles)
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: Text(l10n.pick('在文件夹中显示', 'Show in Folder')),
                onTap: () => Navigator.of(sheet).pop('reveal'),
              ),
            if (track?.albumId != null)
              ListTile(
                leading: const Icon(Icons.album_outlined),
                title: Text(l10n.pick('查看专辑', 'View Album')),
                onTap: () => Navigator.of(sheet).pop('album'),
              ),
            if (track != null && track.artists.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(l10n.pick('查看艺人', 'View Artist')),
                onTap: () => Navigator.of(sheet).pop('artist'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'copy-path':
        await _copyPath(context);
      case 'reveal':
        final ok = await revealFile(entry.download.cachePath);
        if (!ok && context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  l10n.pick('无法打开文件夹', 'Could not open the folder'),
                ),
              ),
            );
        }
      case 'album':
        final albumId = track?.albumId;
        if (albumId == null || !context.mounted) return;
        await Navigator.of(context)
            .push(AlbumDetailPage.route(albumId.toInt()));
      case 'artist':
        final name = track?.artists.first.trim();
        if (name == null || name.isEmpty) return;
        final id = await ref.read(artistIdForNameProvider(name).future);
        if (id == null) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  l10n.pick('资料库里没有这位艺人', 'Artist not found in library'),
                ),
              ),
            );
          return;
        }
        if (!context.mounted) return;
        await Navigator.of(context).push(ArtistDetailPage.route(id));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = context.lekisColors;
    final track = entry.track;
    final actions = <Widget>[
      if (entry.isReady || entry.isActive)
        IconButton(
          tooltip: entry.isActive
              ? l10n.pick('取消下载', 'Cancel Download')
              : l10n.pick('播放已下载', 'Play Downloaded'),
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
          tooltip: entry.isQueued
              ? l10n.pick('开始下载', 'Start Download')
              : l10n.pick('重试', 'Retry'),
          onPressed: () =>
              ref.read(downloadsProvider.notifier).retry(entry.trackId),
          icon: const Icon(Icons.refresh_rounded),
        ),
      if (!entry.isActive)
        IconButton(
          tooltip: l10n.pick('删除下载', 'Remove Download'),
          onPressed: () => _remove(context, ref),
          icon: const Icon(Icons.delete_outline_rounded),
        ),
    ];
    return InkWell(
      onTap: entry.isReady
          ? () => ref
                .read(downloadsProvider.notifier)
                .playDownloaded(entry.trackId)
          : null,
      onLongPress: () => _showActions(context, ref),
      onSecondaryTap: () => _showActions(context, ref),
      borderRadius: BorderRadius.circular(LekisRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LekisSpacing.lg,
          vertical: LekisSpacing.sm,
        ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: LekisSizes.listArtwork,
              child: track == null
                  ? Icon(
                      Icons.music_note_rounded,
                      color: colors.onSurfaceVariant,
                    )
                  : TrackArtwork(
                      trackId: track.id,
                      hasArtwork: track.artworkId != null || !track.isLocal,
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
                  if (entry.isFailed &&
                      entry.error != null &&
                      entry.error!.trim().isNotEmpty)
                    Text(
                      entry.error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.danger,
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
      ),
    );
  }
}
